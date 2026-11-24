import Foundation

enum ImportFormat { case text, numi, soulver }
/// Something the import changed, could not translate or Calc cannot evaluate. Line is 1-based; 0 means the whole file.
struct ImportNotice: Equatable { let line: Int; let message: String; init(_ line: Int, _ message: String) { self.line = line; self.message = message } }
struct ImportedSheet { let name: String; let source: String; let format: ImportFormat; let notices: [ImportNotice] }

/// Reads Numi (.numi), Soulver (.slvr) and plain text (.txt) files into new-sheet sources.
/// Pure data transformation: no file is written, nothing from the content is executed, and no provider or network is involved.
/// A rejected file throws `DocumentError.importRejected` (C# ImportRejectedException): nothing was created and the file was only read.
enum SheetImport {
    static let maxTextBytes = 1_000_000
    static let maxSoulverBytes = 4_000_000
    static let maxFiles = 32
    static let maxNotices = 200
    static let maxJsonDepth = 64
    static let maxJsonNodes = 200_000
    /// Seconds.
    static let evaluationCheckLimit = 5.0
    private static let textKeys = ["expression", "text", "input", "string", "content", "line", "value"]
    private static let bodyKeys = ["text", "content", "body", "source", "sheet", "string"]
    private static let idKeys = ["id", "uuid", "identifier", "lineid", "lineidentifier", "lineuuid"]
    private static let guidToken = try! NSRegularExpression(pattern: "[\\[{<⟨]?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}[\\]}>⟩]?")

    private static func reject(_ message: String) -> DocumentError { .importRejected(message) }

    /// `Path.GetExtension(path).ToLowerInvariant()`.
    static func formatFor(_ path: String) -> ImportFormat? {
        let name = (path as NSString).lastPathComponent
        let dot = name.netLastIndexOf(".")
        switch dot >= 0 ? name.netSubstring(dot).netLower : "" {
        case ".numi": return .numi
        case ".slvr": return .soulver
        case ".txt": return .text
        default: return nil
        }
    }
    static func isSupported(_ path: String) -> Bool { formatFor(path) != nil }

    /// Reads at most the bounded size, then parses. The file is opened read-only and shared for reading.
    static func readFile(_ path: String, _ cancellationToken: CancellationToken = .none) throws -> ImportedSheet {
        guard let format = formatFor(path) else { throw reject("Unsupported file type; use .numi, .slvr or .txt") }
        let limit = format == .soulver ? maxSoulverBytes : maxTextBytes
        if !NetFile.fileExists(path) { throw reject("File not found") }
        let bytes = try NetFile.readAll(path, limit: Int64(limit), tooLarge: reject("File exceeds \(n0(limit)) bytes; nothing imported"),
                                        changed: reject("File changed while reading; nothing imported"))
        return try parse((path as NSString).lastPathComponent, bytes, cancellationToken)
    }

    static func parse(_ fileName: String, _ bytes: [UInt8], _ cancellationToken: CancellationToken = .none) throws -> ImportedSheet {
        guard let format = formatFor(fileName) else { throw reject("Unsupported file type; use .numi, .slvr or .txt") }
        let limit = format == .soulver ? maxSoulverBytes : maxTextBytes
        if bytes.count > limit { throw reject("File exceeds \(n0(limit)) bytes; nothing imported") }
        var notices: [ImportNotice] = []
        let source: String
        if format != .soulver { source = normalize(try decode(bytes)) }
        else {
            let text = try decode(bytes)
            let start = text.netTrimStart
            source = start.utf16.first == 0x7B || start.utf16.first == 0x5B
                ? try soulver(text, &notices, cancellationToken)
                : translateLineWords(normalize(text), &notices) // Assumption: a non-JSON .slvr is Soulver plain text.
        }
        try checkBounds(source)
        try checkEvaluation(source, &notices, cancellationToken)
        if notices.count > maxNotices {
            let hidden = notices.count - maxNotices
            notices.removeSubrange(maxNotices...); notices.append(ImportNotice(0, "\(n0(hidden)) more notes not shown"))
        }
        return ImportedSheet(name: sheetName(fileName), source: source, format: format, notices: notices)
    }

    /// A valid, unused sheet name derived from the file name.
    static func uniqueName(_ name: String, _ existing: [String]) -> String {
        let taken = NetHashSet.ignoringCase(existing)
        if !taken.contains(name) { return name }
        var n = 2
        while true {
            let suffix = " \(n)"
            let candidate = truncate(name, WorkspaceStore.maxNameLength - suffix.netLength).netTrimEnd + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    static func sheetName(_ fileName: String) -> String {
        let file = (fileName as NSString).lastPathComponent
        let dot = file.netLastIndexOf(".")
        let stem = dot >= 0 ? file.netSubstring(0, dot) : file
        let spaced = String(units: stem.utf16.map { NetChar.isControl($0) ? 0x20 : $0 })
        let name = truncate(spaced.netSplit(" ").filter { !$0.isEmpty }.joined(separator: " "), WorkspaceStore.maxNameLength).netTrim
        return name.isEmpty ? "Imported" : name
    }
    private static func truncate(_ value: String, _ length: Int) -> String {
        let units = Array(value.utf16)
        if units.count <= length { return value }
        var length = length
        if length > 0 && NetChar.isHighSurrogate(units[length - 1]) { length -= 1 }
        return String(units: units[..<length])
    }
    /// `{n:N0}`: invariant thousands separators.
    private static func n0(_ value: Int) -> String {
        let digits = Array(String(value))
        var out = ""
        for (i, d) in digits.enumerated() { if i > 0 && (digits.count - i) % 3 == 0 { out += "," }; out.append(d) }
        return out
    }

    /// Strict UTF-8 (optional BOM) or BOM-marked UTF-16. Binary content and control characters other than tab/newlines reject the file.
    static func decode(_ bytes: [UInt8]) throws -> String {
        let units: [UInt16]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { units = try utf8(Array(bytes[3...])) }
        else if bytes.starts(with: [0xFF, 0xFE]) { units = try utf16(Array(bytes[2...]), bigEndian: false) }
        else if bytes.starts(with: [0xFE, 0xFF]) { units = try utf16(Array(bytes[2...]), bigEndian: true) }
        else { units = try utf8(bytes) }
        var line = 1
        for c in units {
            if c == 10 { line += 1 }
            else if c != 9 && c != 13 && NetChar.isControl(c) {
                throw reject(c == 0 ? "Binary content; nothing imported" : "Control character U+\(String(format: "%04X", Int(c))) on line \(line); nothing imported")
            }
        }
        return String(units: units)
    }
    private static func utf8(_ bytes: [UInt8]) throws -> [UInt16] {
        guard let text = bytes.isEmpty ? "" : String(bytes: bytes, encoding: .utf8) else { throw reject("Not valid UTF-8 or UTF-16 text; nothing imported") }
        return Array(text.utf16)
    }
    private static func utf16(_ bytes: [UInt8], bigEndian: Bool) throws -> [UInt16] {
        if bytes.count % 2 != 0 { throw reject("Not valid UTF-8 or UTF-16 text; nothing imported") }
        let units = stride(from: 0, to: bytes.count, by: 2).map { bigEndian ? UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) : UInt16(bytes[$0 + 1]) << 8 | UInt16(bytes[$0]) }
        var i = 0
        while i < units.count {
            if NetChar.isHighSurrogate(units[i]) {
                guard i + 1 < units.count, NetChar.isLowSurrogate(units[i + 1]) else { throw reject("Not valid UTF-8 or UTF-16 text; nothing imported") }
                i += 2; continue
            }
            if NetChar.isLowSurrogate(units[i]) { throw reject("Not valid UTF-8 or UTF-16 text; nothing imported") }
            i += 1
        }
        return units
    }
    private static func normalize(_ text: String) -> String { text.netReplace("\r\n", "\n").netReplace("\r", "\n") }
    private static func checkBounds(_ source: String) throws {
        if source.netLength > SheetStore.maxCharacters { throw reject("Sheet would exceed \(n0(SheetStore.maxCharacters)) characters; nothing imported") }
        if source.utf16.filter({ $0 == 10 }).count + 1 > SheetEvaluator.maxLines { throw reject("Sheet would exceed \(n0(SheetEvaluator.maxLines)) lines; nothing imported") }
    }

    /// Lines Calc cannot evaluate stay exactly as written; each one is reported. A line without a result is reported
    /// when it looks like a calculation (digits/operators) or is a Numi/Soulver aggregate keyword; plain prose labels are not.
    private static func checkEvaluation(_ source: String, _ notices: inout [ImportNotice], _ cancellationToken: CancellationToken) throws {
        // A token cancelled by the time limit or by the caller's token (C#'s linked CancellationTokenSource with CancelAfter).
        let limit = CancellationToken()
        let deadline = DispatchTime.now() + evaluationCheckLimit
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.setEventHandler { if cancellationToken.isCancellationRequested || DispatchTime.now() >= deadline { limit.cancel() } }
        timer.resume()
        defer { timer.cancel() }
        let lines = source.netSplit("\n")
        do {
            for result in try SheetEvaluator.evaluate(source, limit) {
                if let error = result.error { notices.append(ImportNotice(result.line + 1, "The calculator cannot evaluate this line (\(error)); kept as written")) }
                else if result.value == nil && !result.isDeclaration && result.line < lines.count && looksCalculated(lines[result.line]) {
                    notices.append(ImportNotice(result.line + 1, "No result; kept as written"))
                }
            }
        } catch CalcError.cancelled where !cancellationToken.isCancellationRequested {
            notices.append(ImportNotice(0, "Evaluation check stopped at its time limit; every line is kept as written"))
        }
        NetListSort.sort(&notices) { $0.line < $1.line ? -1 : $0.line > $1.line ? 1 : 0 }
    }
    private static let sourceKeywords = ["total", "subtotal", "grand total", "ans"]
    private static func looksCalculated(_ line: String) -> Bool {
        let comment = line.netIndexOf("//")
        let trimmed = (comment >= 0 ? line.netSubstring(0, comment) : line).netTrim
        if trimmed.isEmpty || trimmed.utf16.first == 0x23 || line.utf16.contains(9) { return false } // Tab rows belong to tables.
        let operators: Set<UInt16> = Set("+-*/^%=×÷".utf16)
        return trimmed.utf16.contains { NetChar.isAsciiDigit($0) || operators.contains($0) } ||
            sourceKeywords.contains(trimmed.netTrimEnd(":").netLower)
    }

    /// Soulver's documented plain-text reference form "line3" becomes the calculator's "L3". Physical numbering is preserved because
    /// the import never adds or removes lines. Headings, // comments and quoted text are left alone.
    static func translateLineWords(_ source: String, _ notices: inout [ImportNotice]) -> String {
        var lines = source.netSplit("\n")
        for i in lines.indices { lines[i] = translateLineWords(lines[i], i + 1, lines.count, &notices) }
        return lines.joined(separator: "\n")
    }
    private static func translateLineWords(_ line: String, _ number: Int, _ count: Int, _ notices: inout [ImportNotice]) -> String {
        if line.netTrimStart.utf16.first == 0x23 || line.netUpper.netIndexOf("LINE") < 0 { return line }
        let u = Array(line.utf16)
        var output: [UInt16] = []; output.reserveCapacity(u.count)
        var quoted = false
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 0x22 { quoted.toggle() }
            if !quoted && c == 0x2F && i + 1 < u.count && u[i + 1] == 0x2F { output += u[i...]; break }
            if !quoted && (i == 0 || !word(u[i - 1])) && i + 4 < u.count && String(units: u[i..<(i + 4)]).equalsIgnoreCase("line") && NetChar.isAsciiDigit(u[i + 4]) {
                var end = i + 4
                while end < u.count && NetChar.isAsciiDigit(u[end]) { end += 1 }
                if end == u.count || !word(u[end]) {
                    let digits = String(units: u[(i + 4)..<end])
                    if let target = Int32(digits).map(Int.init), target >= 1, target <= count, target != number {
                        output += Array(("L" + String(target)).utf16); i = end; continue
                    }
                    notices.append(ImportNotice(number, "“\(String(units: u[i..<end]))” does not name another line; kept as written"))
                    output += u[i..<end]; i = end; continue
                }
            }
            output.append(c)
            i += 1
        }
        return String(units: output)
    }
    private static func word(_ c: UInt16) -> Bool { NetChar.isLetterOrDigit(c) || c == 0x5F }

    private struct Candidate {
        var key: String?, path: [String], lines: [String]?, ids: [String?]?, textKey: String?, idKey: String?, body: String?
    }

    /// Assumed JSON layout (the schema is not published): either an array of line objects that each carry a text field
    /// and optionally an identifier, or a single text body. Identifier tokens of at least 8 characters inside another line's
    /// text become Calc line references. Every other field is reported, never silently dropped; the original file is untouched.
    private static func soulver(_ json: String, _ notices: inout [ImportNotice], _ cancellationToken: CancellationToken) throws -> String {
        let document: JSONNode
        do { try NetJSON.validate(Array(json.utf8)); document = try JSONNode.parse(json, maxDepth: maxJsonDepth) }
        catch { throw reject("Corrupt Soulver file (\(error.netMessage)); nothing imported") }
        var nodes = 0
        var candidates: [Candidate] = []
        try find(document, nil, [], &candidates, &nodes, cancellationToken)
        let lineCandidates = candidates.filter { $0.lines != nil }
        guard let chosen = lineCandidates.first(where: { ($0.key?.netUpper.netIndexOf("LINE") ?? -1) >= 0 })
            ?? lineCandidates.stableSorted(by: { $0.lines!.count > $1.lines!.count }).first
            ?? candidates.filter({ $0.body != nil }).stableSorted(by: { a, b in
                a.path.count != b.path.count ? a.path.count < b.path.count : a.body!.netLength > b.body!.netLength }).first
        else { throw reject("Unrecognized Soulver file structure; nothing imported") }
        var consumed = Set(chosen.path.map(OrdinalString.init))
        if let key = chosen.textKey { consumed.insert(OrdinalString(key)) }
        if let key = chosen.idKey { consumed.insert(OrdinalString(key)) }
        var ignored: [String] = []
        collectKeys(document, consumed, &ignored)
        let sortedIgnored = Array(Set(ignored.map(OrdinalString.init))).map { String(units: $0.units) }.sorted { String.ordinalCompare($0, $1) < 0 }
        if !sortedIgnored.isEmpty {
            notices.append(ImportNotice(0, "Not imported (kept in the original file): " + sortedIgnored.prefix(16).joined(separator: ", ") +
                                        (sortedIgnored.count > 16 ? " and \(sortedIgnored.count - 16) more" : "")))
        }
        if let body = chosen.body { return translateLineWords(normalize(body), &notices) }
        var text = chosen.lines!
        for i in text.indices where text[i].utf16.contains(10) || text[i].utf16.contains(13) {
            text[i] = normalize(text[i]).netSplit("\n").joined(separator: " ")
            notices.append(ImportNotice(i + 1, "Line contained line breaks; joined with spaces to keep line numbers"))
        }
        if let ids = chosen.ids { translateIdentifiers(&text, ids, &notices) }
        for i in text.indices { text[i] = translateLineWords(text[i], i + 1, text.count, &notices) }
        return text.joined(separator: "\n")
    }

    private static func find(_ element: JSONNode, _ key: String?, _ path: [String], _ candidates: inout [Candidate], _ nodes: inout Int, _ token: CancellationToken) throws {
        nodes += 1
        if nodes > maxJsonNodes { throw reject("Soulver file is too complex; nothing imported") }
        if nodes & 1023 == 0 { try token.throwIfCancellationRequested() }
        switch element {
        case .object(let properties):
            for (name, value) in properties {
                if case .string(let body) = value, bodyKeys.contains(name.netLower), body.utf16.contains(10) || path.isEmpty {
                    candidates.append(Candidate(key: name, path: path, lines: nil, ids: nil, textKey: name, idKey: nil, body: body))
                }
                try find(value, name, path + [name], &candidates, &nodes, token)
            }
        case .array(let items):
            if var found = lineArray(items) { found.key = key; found.path = path; candidates.append(found) }
            for item in items { try find(item, key, path, &candidates, &nodes, token) }
        default: break
        }
    }

    private static func lineArray(_ items: [JSONNode]) -> Candidate? {
        guard !items.isEmpty, items.allSatisfy({ if case .object = $0 { return true }; return false }) else { return nil }
        func every(_ name: String, _ accept: (JSONNode) -> Bool) -> Bool { items.allSatisfy { $0.optionalProperty(name).map(accept) ?? false } }
        let textKey = textKeys.lazy.compactMap { property(items[0], $0) }.first { name in every(name) { if case .string = $0 { return true }; return false } }
        guard let textKey else { return nil }
        let idKey = idKeys.lazy.compactMap { property(items[0], $0) }.first { name in
            every(name) { switch $0 { case .string, .number: return true; default: return false } }
        }
        let lines = items.map { $0.optionalProperty(textKey)!.stringValue! }
        let ids: [String?]? = idKey.map { key in items.map { item -> String? in
            switch item.optionalProperty(key)! { case .string(let s): return s; case .number(let n): return n; default: return nil }
        } }
        return Candidate(key: nil, path: [], lines: lines, ids: ids, textKey: textKey, idKey: idKey, body: nil)
    }
    /// The first property whose name matches ignoring case (its own spelling).
    private static func property(_ element: JSONNode, _ name: String) -> String? { element.properties.first { $0.0.equalsIgnoreCase(name) }?.0 }
    private static func collectKeys(_ element: JSONNode, _ consumed: Set<OrdinalString>, _ ignored: inout [String]) {
        switch element {
        case .object(let properties):
            for (name, value) in properties {
                if !consumed.contains(OrdinalString(name)) { ignored.append(name) }
                collectKeys(value, consumed, &ignored)
            }
        case .array(let items): for item in items { collectKeys(item, consumed, &ignored) }
        default: break
        }
    }

    /// Replaces another line's identifier (optionally bracketed) with L{n}. Short identifiers are not translated because
    /// they cannot be told apart from numbers or list syntax. GUID-shaped tokens that match no line are kept and reported.
    private static func translateIdentifiers(_ lines: inout [String], _ ids: [String?], _ notices: inout [ImportNotice]) {
        var index = NetDictionary<String, Int>.ignoringCase()
        for (i, id) in ids.enumerated() {
            guard let id, id.netLength >= 8 else { continue }
            if !index.tryAdd(id, i) { index.set(id, -1) } // Duplicate identifiers are ambiguous.
        }
        if index.isEmpty { return }
        for i in lines.indices {
            var line = lines[i]
            for (id, target) in index {
                if target == i || line.netUpper.netIndexOf(id.netUpper) < 0 { continue }
                if target < 0 { notices.append(ImportNotice(i + 1, "Reference “\(id)” is ambiguous; kept as written")); continue }
                let pattern = "(\\[|\\{|<|⟨)?(?<![0-9A-Za-z_-])" + NSRegularExpression.escapedPattern(for: id) + "(?![0-9A-Za-z_-])(\\]|\\}|>|⟩)?"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let text = line as NSString
                var result = ""; var last = 0
                for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
                    result += text.substring(with: NSRange(location: last, length: match.range.location - last))
                    let open = match.range(at: 1), close = match.range(at: 2)
                    let replacement = "L" + String(target + 1)
                    if (open.location != NSNotFound) == (close.location != NSNotFound) { result += replacement }
                    else { result += (open.location != NSNotFound ? text.substring(with: open) : "") + replacement + (close.location != NSNotFound ? text.substring(with: close) : "") }
                    last = match.range.location + match.range.length
                }
                line = result + text.substring(from: last)
            }
            let text = line as NSString
            for match in guidToken.matches(in: line, range: NSRange(location: 0, length: text.length)) {
                notices.append(ImportNotice(i + 1, "Reference “\(text.substring(with: match.range))” matches no line in this file; kept as written"))
            }
            lines[i] = line
        }
    }
}

/// `List<T>.Sort(Comparison<T>)`: .NET's introspective sort, which is not stable. Elements that compare equal keep the order
/// .NET would leave them in, so lists sorted by one key read the same on both systems.
enum NetListSort {
    static func sort<T>(_ keys: inout [T], _ compare: (T, T) -> Int) {
        if keys.count > 1 { introSort(&keys, 0, keys.count, 2 * (log2(keys.count) + 1), compare) }
    }
    private static func log2(_ n: Int) -> Int { Int.bitWidth - 1 - n.leadingZeroBitCount }
    private static func swapIfGreater<T>(_ keys: inout [T], _ i: Int, _ j: Int, _ compare: (T, T) -> Int) {
        if compare(keys[i], keys[j]) > 0 { keys.swapAt(i, j) }
    }
    private static func introSort<T>(_ keys: inout [T], _ lo: Int, _ length: Int, _ depthLimit: Int, _ compare: (T, T) -> Int) {
        var partitionSize = length, depthLimit = depthLimit
        while partitionSize > 1 {
            if partitionSize <= 16 {
                if partitionSize == 2 { swapIfGreater(&keys, lo, lo + 1, compare); return }
                if partitionSize == 3 {
                    swapIfGreater(&keys, lo, lo + 1, compare); swapIfGreater(&keys, lo, lo + 2, compare); swapIfGreater(&keys, lo + 1, lo + 2, compare); return
                }
                insertionSort(&keys, lo, partitionSize, compare); return
            }
            if depthLimit == 0 { heapSort(&keys, lo, partitionSize, compare); return }
            depthLimit -= 1
            let p = pickPivotAndPartition(&keys, lo, partitionSize, compare)
            introSort(&keys, lo + p + 1, partitionSize - (p + 1), depthLimit, compare)
            partitionSize = p
        }
    }
    private static func pickPivotAndPartition<T>(_ keys: inout [T], _ lo: Int, _ length: Int, _ compare: (T, T) -> Int) -> Int {
        let hi = length - 1, middle = hi >> 1
        swapIfGreater(&keys, lo, lo + middle, compare); swapIfGreater(&keys, lo, lo + hi, compare); swapIfGreater(&keys, lo + middle, lo + hi, compare)
        let pivot = keys[lo + middle]
        keys.swapAt(lo + middle, lo + hi - 1)
        var left = 0, right = hi - 1
        while left < right {
            repeat { left += 1 } while compare(keys[lo + left], pivot) < 0
            repeat { right -= 1 } while compare(pivot, keys[lo + right]) < 0
            if left >= right { break }
            keys.swapAt(lo + left, lo + right)
        }
        if left != hi - 1 { keys.swapAt(lo + left, lo + hi - 1) }
        return left
    }
    private static func insertionSort<T>(_ keys: inout [T], _ lo: Int, _ length: Int, _ compare: (T, T) -> Int) {
        for i in 0..<(length - 1) {
            let t = keys[lo + i + 1]
            var j = i
            while j >= 0 && compare(t, keys[lo + j]) < 0 { keys[lo + j + 1] = keys[lo + j]; j -= 1 }
            keys[lo + j + 1] = t
        }
    }
    private static func heapSort<T>(_ keys: inout [T], _ lo: Int, _ n: Int, _ compare: (T, T) -> Int) {
        var i = n >> 1
        while i >= 1 { downHeap(&keys, lo, i, n, compare); i -= 1 }
        i = n
        while i > 1 { keys.swapAt(lo, lo + i - 1); downHeap(&keys, lo, 1, i - 1, compare); i -= 1 }
    }
    private static func downHeap<T>(_ keys: inout [T], _ lo: Int, _ start: Int, _ n: Int, _ compare: (T, T) -> Int) {
        var i = start
        let d = keys[lo + i - 1]
        while i <= n >> 1 {
            var child = 2 * i
            if child < n && compare(keys[lo + child - 1], keys[lo + child]) < 0 { child += 1 }
            if !(compare(d, keys[lo + child - 1]) < 0) { break }
            keys[lo + i - 1] = keys[lo + child - 1]
            i = child
        }
        keys[lo + i - 1] = d
    }
}
