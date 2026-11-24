import Foundation
import zlib

enum ShareTheme { case light, dark }
enum ShareFigureKind { case bar, pie, trend, plot }

/// One labelled chart magnitude with the sheet's own formatted value.
struct ShareChartItem: Equatable { let label: String; let magnitude: Double; let display: String }

/// A frozen figure. Charts keep magnitudes; plots keep points quantized to `ShareLink.plotGrid` steps of their frame.
struct ShareFigure: Equatable {
    struct Point: Equatable { let x: Int; let y: Int; init(_ x: Int, _ y: Int) { self.x = x; self.y = y } }
    let kind: ShareFigureKind
    let description: String
    var items: [ShareChartItem] = []
    var total: String?
    /// Plot frame as display text: x from, x to, y from, y to.
    var frame: [String] = []
    /// Plot points as (x, y) grid coordinates; y may leave the frame and is clipped by the viewer.
    var points: [Point] = []
    var segments: [Int] = []
    init(_ kind: ShareFigureKind, _ description: String) { self.kind = kind; self.description = description }
}

/// One source line and what Calc showed for it when the link was made.
struct ShareLine: Equatable {
    let source: String
    let result: String?
    let error: Bool
    let explanation: String?
    let figure: ShareFigure?
    init(_ source: String, _ result: String? = nil, error: Bool = false, explanation: String? = nil, figure: ShareFigure? = nil) {
        self.source = source; self.result = result; self.error = error; self.explanation = explanation; self.figure = figure
    }
}

/// A frozen snapshot: source, results, theme and explanations as computed when shared. A viewer never recomputes it.
struct ShareSnapshot: Equatable {
    let title: String
    let theme: ShareTheme
    let date: DateOnly?
    let lines: [ShareLine]
}

/// Versioned share links: canonical UTF-8 JSON, raw DEFLATE, unpadded base64url, carried only in the URL fragment.
/// Fragments are not sent in HTTP requests, so a static viewer reads the sheet without any server seeing it.
/// The same limits bind the encoder here and the decoder in the share viewer's codec.js.
enum ShareLink {
    static let version = 1
    static let prefix = "c1."
    static let maxFragmentCharacters = 65_536
    static let maxPayloadBytes = 1_048_576
    static let maxLines = 20_000
    static let maxSourceCharacters = SheetStore.maxCharacters
    static let maxTitle = WorkspaceStore.maxNameLength
    static let maxResult = 8_192
    static let maxExplanation = 32_768
    static let maxDescription = 1_024
    static let maxLabel = 64
    static let maxItems = 512
    static let maxPoints = 512
    static let plotGrid = 4_096

    private static func fail(_ message: String) -> DocumentError { .shareLink(message) }

    /// Freezes what the sheet currently shows. `explain` lets the host supply its own explanation text.
    static func capture(_ title: String, _ source: String, _ results: [LineResult], _ dark: Bool, date: DateOnly? = nil,
                        explain: ((LineResult) -> String)? = nil) throws -> ShareSnapshot {
        if source.netLength > maxSourceCharacters { throw fail("Sheet too large to share as a link") }
        let map = try SourceLineMap(source)
        if map.count > maxLines { throw fail("Sheet too large to share as a link") }
        var byLine: [Int: LineResult] = [:]
        for result in results where result.line >= 0 && result.line < map.count { byLine[result.line] = result }
        let explain = explain ?? defaultExplanation
        var lines: [ShareLine] = []
        for i in 0..<map.count {
            let text = clean(map.text(i))
            guard let answer = byLine[i] else { lines.append(ShareLine(text)); continue }
            let display = answer.display
            if display.isEmpty { lines.append(ShareLine(text)); continue }
            let error = answer.error != nil
            // Host text may use any line-break form; the snapshot keeps one.
            let explanation = error ? nil : bound(replaceLineEndings(clean(explain(answer))).netTrimEnd, maxExplanation)
            lines.append(ShareLine(text, bound(clean(display), maxResult), error: error, explanation: explanation?.isEmpty == false ? explanation : nil,
                                   figure: error ? nil : try figure(answer.value)))
        }
        let name = bound(clean(title).netTrim, maxTitle)
        return ShareSnapshot(title: name.isEmpty ? "Sheet" : name, theme: dark ? .dark : .light, date: date, lines: lines)
    }

    /// Plain steps, assumptions and dependencies. Hosts with richer explanation text pass their own formatter.
    static func defaultExplanation(_ answer: LineResult) -> String {
        var text = ""
        for step in answer.explanation {
            text += step.operation + "(" + step.operands.joined(separator: ", ") + ") = " + step.result + "\n"
            if let assumption = step.assumption { text += assumption + "\n" }
        }
        if !answer.dependencies.isEmpty { text += "Uses " + answer.dependencies.prefix(16).map { "L" + String($0 + 1) }.joined(separator: ", ") }
        return text.netTrimEnd
    }

    /// `string.ReplaceLineEndings("\n")`: CR LF, CR, LF, NEL, LS, PS and FF each become LF.
    static func replaceLineEndings(_ text: String) -> String {
        let units = Array(text.utf16); var out: [UInt16] = []; out.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == 13 { out.append(10); if i + 1 < units.count && units[i + 1] == 10 { i += 1 } }
            else if c == 10 || c == 0x85 || c == 0x2028 || c == 0x2029 || c == 0x0C { out.append(10) }
            else { out.append(c) }
            i += 1
        }
        return String(units: out)
    }

    private static func figure(_ value: SheetValue?) throws -> ShareFigure? {
        if let value, value.kind == .chart {
            let c = try value.chart
            let kind: ShareFigureKind = c.kind == .bar ? .bar : c.kind == .pie ? .pie : .trend
            if c.items.count > maxItems { return nil }
            var figure = ShareFigure(kind, bound(clean(c.description), maxDescription))
            figure.items = try c.items.map { ShareChartItem(label: bound(clean($0.label), maxLabel), magnitude: try finite($0.magnitude), display: bound(clean($0.display), maxLabel)) }
            figure.total = c.kind == .trend ? nil : bound(clean(c.total), maxLabel)
            return figure
        }
        if let value, value.kind == .plot {
            let p = try value.plot
            if p.x.count > maxPoints || !(p.upper > p.lower) || !(p.yUpper > p.yLower) { return nil }
            // (int)Math.Clamp(Math.Round(…)): banker's rounding; .NET's saturating conversion turns NaN into 0.
            func grid(_ v: Double, _ low: Double, _ high: Double) -> Int {
                let rounded = NetMath.round((v - low) / (high - low) * Double(plotGrid))
                return rounded.isNaN ? 0 : Int(min(max(rounded, Double(-plotGrid)), Double(2 * plotGrid)))
            }
            let points = (0..<p.x.count).map { ShareFigure.Point(grid(p.x[$0], p.lower, p.upper), grid(p.y[$0], p.yLower, p.yUpper)) }
            var figure = ShareFigure(.plot, bound(clean(p.description), maxDescription))
            figure.frame = [PlotValue.number(p.lower), PlotValue.number(p.upper), PlotValue.number(p.yLower), PlotValue.number(p.yUpper)]
            figure.points = points
            figure.segments = Array(Set(p.segmentStarts.filter { $0 >= 0 && $0 < points.count })).sorted()
            return figure
        }
        return nil
    }
    private static func finite(_ value: Double) throws -> Double { if value.isFinite { return value }; throw fail("Chart value cannot be shared") }

    /// Unpaired UTF-16 surrogates cannot be UTF-8 encoded; C# turns them into U+FFFD here. A Swift string cannot hold an unpaired
    /// surrogate (decoding already replaced it with U+FFFD), so the text is kept exactly.
    private static func clean(_ text: String) -> String { text }
    private static func bound(_ text: String, _ limit: Int) -> String {
        let units = Array(text.utf16)
        if units.count <= limit { return text }
        var cut = limit - 1
        if NetChar.isHighSurrogate(units[cut - 1]) { cut -= 1 }
        return String(units: units[..<cut]) + "…"
    }

    /// Canonical JSON: fixed property order, absent values omitted, no whitespace. Strings escape only '"', '\' and
    /// U+0000–U+001F (\b \f \n \r \t, otherwise \u00xx); every other character is literal UTF-8. Numbers use the shortest round-trip invariant form.
    static func serialize(_ snapshot: ShareSnapshot) throws -> [UInt8] {
        try validate(snapshot)
        var json: [UInt16] = []
        func append(_ s: String) { json.append(contentsOf: s.utf16) }
        func quote(_ value: String) {
            json.append(0x22)
            for c in value.utf16 {
                switch c {
                case 0x22: append("\\\"")
                case 0x5C: append("\\\\")
                case 0x08: append("\\b")
                case 0x0C: append("\\f")
                case 0x0A: append("\\n")
                case 0x0D: append("\\r")
                case 0x09: append("\\t")
                case ..<0x20: append("\\u" + String(format: "%04x", Int(c)))
                default: json.append(c)
                }
            }
            json.append(0x22)
        }
        func field(_ name: String, _ value: String) { append(",\"" + name + "\":"); quote(value) }
        append("{\"v\":" + String(version))
        field("title", snapshot.title)
        field("theme", snapshot.theme == .dark ? "dark" : "light")
        if let date = snapshot.date { field("date", date.description) }
        append(",\"lines\":[")
        for (i, line) in snapshot.lines.enumerated() {
            append(i > 0 ? ",{\"s\":" : "{\"s\":"); quote(line.source)
            if let result = line.result { field("r", result) }
            if line.error { append(",\"err\":true") }
            if let explanation = line.explanation { field("x", explanation) }
            if let figure = line.figure {
                append(",\"fig\":{\"kind\":")
                quote(figure.kind == .bar ? "bar" : figure.kind == .pie ? "pie" : figure.kind == .trend ? "trend" : "plot")
                field("desc", figure.description)
                if figure.kind == .plot {
                    append(",\"frame\":[")
                    for (k, text) in figure.frame.enumerated() { if k > 0 { append(",") }; quote(text) }
                    append("],\"pts\":[")
                    for (k, point) in figure.points.enumerated() { append((k > 0 ? ",[" : "[") + String(point.x) + "," + String(point.y) + "]") }
                    append("],\"seg\":[" + figure.segments.map(String.init).joined(separator: ",") + "]")
                } else {
                    if let total = figure.total { field("total", total) }
                    append(",\"items\":[")
                    for (k, item) in figure.items.enumerated() {
                        append(k > 0 ? ",[" : "["); quote(item.label)
                        append("," + NetFormat.double(item.magnitude, "R") + ",")
                        quote(item.display); append("]")
                    }
                    append("]")
                }
                append("}")
            }
            append("}")
        }
        append("]}")
        let bytes = Array(String(decoding: json, as: UTF16.self).utf8)
        if bytes.count > maxPayloadBytes { throw fail("Sheet too large to share as a link") }
        return bytes
    }

    /// The fragment text, without '#'.
    static func encodeFragment(_ snapshot: ShareSnapshot) throws -> String {
        let fragment = prefix + base64Url(try deflate(try serialize(snapshot)))
        if fragment.netLength > maxFragmentCharacters { throw fail("Sheet too large to share as a link") }
        return fragment
    }

    /// Viewer URL plus the fragment. The viewer address is the only part that reaches a server when the link is opened.
    static func create(_ viewer: URL, _ snapshot: ShareSnapshot) throws -> String {
        try ShareViewerAddress.validate(viewer).absoluteString + "#" + (try encodeFragment(snapshot))
    }

    /// Strict decoder with the same limits as the browser viewer: a full URL, "#fragment" or bare fragment.
    static func decode(_ link: String) throws -> ShareSnapshot {
        let hash = link.netIndexOf("#")
        let fragment = hash >= 0 ? link.netSubstring(hash + 1) : link
        if fragment.netLength > maxFragmentCharacters { throw fail("Link too large") }
        if !fragment.hasPrefix(prefix) { throw fail("Unsupported link version") }
        let json = try inflate(try fromBase64Url(fragment.netSubstring(prefix.netLength)))
        guard let text = String(bytes: json, encoding: .utf8) else { throw fail("Damaged link") }
        let root: JSONNode
        do { try NetJSON.validate(json); root = try JSONNode.parse(text, maxDepth: 8) } catch { throw fail("Damaged link") }
        let snapshot = try read(root)
        try validate(snapshot, "Damaged link")
        return snapshot
    }

    /// Raw DEFLATE at zlib's best compression (.NET CompressionLevel.SmallestSize). The compressed bytes need not match .NET's;
    /// both decoders read either.
    private static func deflate(_ data: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw fail("Sheet text cannot be shared")
        }
        defer { deflateEnd(&stream) }
        var input = data
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))) + 16)
        let status = input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer -> Int32 in
                stream.next_in = inBuffer.baseAddress; stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress; stream.avail_out = uInt(outBuffer.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw fail("Sheet text cannot be shared") }
        return Array(output[..<Int(stream.total_out)])
    }

    /// Inflates at most `maxPayloadBytes`. Data after the final block is ignored and a stream that ends early yields what it held,
    /// as .NET's DeflateStream does; malformed blocks are a damaged link.
    private static func inflate(_ bytes: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw fail("Damaged link") }
        defer { inflateEnd(&stream) }
        var input = bytes
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16_384)
        return try input.withUnsafeMutableBufferPointer { inBuffer -> [UInt8] in
            stream.next_in = inBuffer.baseAddress; stream.avail_in = uInt(inBuffer.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { out -> (Int32, Int) in
                    stream.next_out = out.baseAddress; stream.avail_out = uInt(out.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return (status, out.count - Int(stream.avail_out))
                }
                if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR { throw fail("Damaged link") }
                if produced > 0 {
                    if output.count + produced > maxPayloadBytes { throw fail("Link expands beyond the size limit") }
                    output.append(contentsOf: chunk[..<produced])
                }
                if status == Z_STREAM_END || produced == 0 && (stream.avail_in == 0 || status == Z_BUF_ERROR) { return output }
            }
        }
    }

    private static func read(_ root: JSONNode) throws -> ShareSnapshot {
        try keys(root, ["v", "title", "theme", "date", "lines"], ["v", "title", "theme", "lines"])
        if try int(root.property("v")) != version { throw fail("Unsupported link version") }
        let theme: ShareTheme
        switch try str(root.property("theme")) { case "light": theme = .light; case "dark": theme = .dark; default: throw fail("Damaged link") }
        var date: DateOnly?
        if let d = root.optionalProperty("date") { date = try parseDate(try str(d)) }
        guard case .array(let items) = try root.property("lines") else { throw fail("Damaged link") }
        var lines: [ShareLine] = []
        for line in items {
            if lines.count == maxLines { throw fail("Damaged link") }
            try keys(line, ["s", "r", "err", "x", "fig"], ["s"])
            var error = false
            if let e = line.optionalProperty("err") { guard case .bool(true) = e else { throw fail("Damaged link") }; error = true }
            lines.append(ShareLine(try text(line, "s")!, try text(line, "r"), error: error, explanation: try text(line, "x"),
                                   figure: try line.optionalProperty("fig").map(readFigure)))
        }
        return ShareSnapshot(title: try text(root, "title")!, theme: theme, date: date, lines: lines)
    }
    private static func readFigure(_ figure: JSONNode) throws -> ShareFigure {
        guard case .object = figure, let k = figure.optionalProperty("kind") else { throw fail("Damaged link") }
        let kind: ShareFigureKind
        switch try str(k) { case "bar": kind = .bar; case "pie": kind = .pie; case "trend": kind = .trend; case "plot": kind = .plot; default: throw fail("Damaged link") }
        if kind == .plot {
            try keys(figure, ["kind", "desc", "frame", "pts", "seg"], ["kind", "desc", "frame", "pts", "seg"])
            var result = ShareFigure(kind, try text(figure, "desc")!)
            result.points = try array(figure.property("pts")).map { point in
                let pair = try array(point)
                guard pair.count == 2 else { throw fail("Damaged link") }
                return ShareFigure.Point(try int(pair[0]), try int(pair[1]))
            }
            result.frame = try array(figure.property("frame")).map(str)
            result.segments = try array(figure.property("seg")).map(int)
            return result
        }
        try keys(figure, ["kind", "desc", "total", "items"], ["kind", "desc", "items"])
        var result = ShareFigure(kind, try text(figure, "desc")!)
        result.total = try text(figure, "total")
        result.items = try array(figure.property("items")).map { item in
            let parts = try array(item)
            guard parts.count == 3, case .number = parts[1] else { throw fail("Damaged link") }
            return ShareChartItem(label: try str(parts[0]), magnitude: try double(parts[1]), display: try str(parts[2]))
        }
        return result
    }
    private static func keys(_ element: JSONNode, _ allowed: [String], _ required: [String]) throws {
        guard case .object(let properties) = element else { throw fail("Damaged link") }
        var seen: [String] = []
        for (name, _) in properties {
            if !allowed.contains(where: { $0.ordinalEquals(name) }) || seen.contains(where: { $0.ordinalEquals(name) }) { throw fail("Damaged link") }
            seen.append(name)
        }
        if required.contains(where: { name in !seen.contains { $0.ordinalEquals(name) } }) { throw fail("Damaged link") }
    }
    private static func text(_ element: JSONNode, _ name: String) throws -> String? { try element.optionalProperty(name).map(str) }
    private static func str(_ value: JSONNode) throws -> String { guard case .string(let s) = value else { throw fail("Damaged link") }; return s }
    private static func array(_ value: JSONNode) throws -> [JSONNode] { guard case .array(let a) = value else { throw fail("Damaged link") }; return a }
    /// JsonElement.GetInt32: a number token that is an Int32 (no fraction or exponent).
    private static func int(_ value: JSONNode) throws -> Int { do { return try value.int() } catch { throw fail("Damaged link") } }
    /// JsonElement.GetDouble: a finite number.
    private static func double(_ value: JSONNode) throws -> Double { do { return try value.double() } catch { throw fail("Damaged link") } }
    /// `DateOnly.ParseExact(text, "yyyy-MM-dd")`.
    private static func parseDate(_ text: String) throws -> DateOnly {
        let u = Array(text.utf8)
        guard u.count == 10, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ u[$0] >= 48 && u[$0] <= 57 }) else { throw fail("Damaged link") }
        let year = Int(text.prefix(4))!, month = Int(text.dropFirst(5).prefix(2))!, day = Int(text.suffix(2))!
        guard year >= 1, (1...12).contains(month), day >= 1, day <= DateOnly.daysInMonth(year, month), let date = DateOnly.parseISO(text) else { throw fail("Damaged link") }
        return date
    }

    private static func validate(_ snapshot: ShareSnapshot, _ failure: String = "Sheet too large to share as a link") throws {
        func require(_ condition: Bool) throws { if !condition { throw fail(failure) } }
        try require((1...maxTitle).contains(snapshot.title.netLength) && (1...maxLines).contains(snapshot.lines.count))
        var source = 0
        for line in snapshot.lines {
            source += line.source.netLength
            try require(!line.source.utf16.contains(13) && !line.source.utf16.contains(10) && (line.result?.netLength ?? 0) <= maxResult &&
                        (line.explanation?.netLength ?? 0) <= maxExplanation)
            try require(!(line.error && (line.result == nil || line.explanation != nil || line.figure != nil)) &&
                        (line.result != nil || line.explanation == nil && line.figure == nil))
            guard let figure = line.figure else { continue }
            try require(figure.description.netLength <= maxDescription)
            let gridRange = -plotGrid...(2 * plotGrid)
            if figure.kind == .plot {
                try require(figure.frame.count == 4 && figure.frame.allSatisfy { $0.netLength <= maxLabel } && (1...maxPoints).contains(figure.points.count) &&
                            figure.points.allSatisfy { gridRange.contains($0.x) && gridRange.contains($0.y) } &&
                            figure.segments.count <= maxPoints && figure.segments.allSatisfy { $0 >= 0 && $0 < figure.points.count } &&
                            zip(figure.segments, figure.segments.dropFirst()).allSatisfy { $0 < $1 } && figure.items.isEmpty && figure.total == nil)
            } else {
                try require((1...maxItems).contains(figure.items.count) &&
                            figure.items.allSatisfy { $0.label.netLength <= maxLabel && $0.display.netLength <= maxLabel && $0.magnitude.isFinite } &&
                            (figure.total?.netLength ?? 0) <= maxLabel && figure.points.isEmpty && figure.frame.isEmpty && figure.segments.isEmpty)
            }
        }
        try require(source <= maxSourceCharacters)
    }

    private static func base64Url(_ bytes: [UInt8]) -> String {
        var text = Data(bytes).base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    private static func fromBase64Url(_ text: String) throws -> [UInt8] {
        let u = Array(text.utf8)
        if u.isEmpty || u.count % 4 == 1 || u.contains(where: { !(($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95) }) {
            throw fail("Damaged link")
        }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - u.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw fail("Damaged link") }
        return Array(data)
    }
}
