import Foundation

enum ExportLineKind { case blank, heading, text, result, error }

/// One logical source line and what the sheet shows beside it. `result` is the visible text;
/// `value` is the complete copy text (full digits, complete lists) when it differs or spans lines.
struct ExportLine {
    let number: Int
    let source: String
    let kind: ExportLineKind
    let result: String
    let value: String?
    let isTotal: Bool
    /// Plot or chart retained for renderers that can draw it; text formats keep its textual result.
    var figure: SheetValue?
    var isTableRow: Bool { source.utf16.contains(9) }
}

/// UTF-16 text built for an export, so the output bound counts what C#'s StringBuilder counts.
private struct ExportText {
    var units: [UInt16] = []
    mutating func append(_ text: String) { units.append(contentsOf: text.utf16) }
    mutating func append(_ unit: UInt16, count: Int = 1) { if count > 0 { units.append(contentsOf: repeatElement(unit, count: count)) } }
    var string: String { String(decoding: units, as: UTF16.self) }
    func guarded() throws { if units.count > SheetExport.maxOutputCharacters { throw CalcError.argument("Export exceeds the output limit") } }
}

/// Immutable, bounded snapshot of a sheet's source and results. Every export, copy and image consumes the same rows,
/// so text, Markdown, CSV, PDF, print and PNG agree on content. No evaluation happens here.
final class SheetExport {
    /// Upper bound on any serialized export, in UTF-16 characters. A full sheet with complete copy values stays well inside it.
    static let maxOutputCharacters = 8_000_000
    let title: String
    let lines: [ExportLine]

    private init(_ title: String, _ lines: [ExportLine]) { self.title = title; self.lines = lines }

    /// Builds the snapshot. Results are matched by line index; lines without a matching result export as source only.
    /// Results read as the sheet shows them: the number style/decimals in `format` and any default-currency
    /// conversion (`LineResult.shown`), so every export matches the gutter and click-copy.
    static func create(_ title: String, _ source: String, _ results: [LineResult], _ format: ResultFormat? = nil) throws -> SheetExport {
        let format = format ?? .default
        if source.netLength > SheetStore.maxCharacters { throw CalcError.argument("Sheet exceeds the export limit") }
        let map = try SourceLineMap(source)
        if map.count > SheetEvaluator.maxLines { throw CalcError.argument("Sheet exceeds the export line limit") }
        var lines: [ExportLine] = []
        for i in 0..<map.count {
            let text = map.text(i)
            let answer = i < results.count && results[i].line == i ? results[i] : nil
            let trimmed = text.netTrim
            var kind: ExportLineKind, shown = "", value: String?, figure: SheetValue?
            if trimmed.isEmpty { kind = .blank }
            else if trimmed.ordinalEquals("#") || trimmed.utf16.starts(with: [0x23, 0x20]) { kind = .heading }
            else if let answer, let error = answer.error { kind = .error; shown = oneLine(error) }
            else if let answer, let result = answer.value, !answer.display.isEmpty {
                kind = .result; shown = oneLine(try ResultFormatter.format(answer, format))
                let copy = try (answer.shown ?? result).copyText
                if !copy.ordinalEquals(shown) { value = copy }
                if result.kind == .plot || result.kind == .chart { figure = result }
            } else { kind = .text }
            lines.append(ExportLine(number: i + 1, source: text, kind: kind, result: shown, value: value, isTotal: kind == .result && answer!.isAggregate, figure: figure))
        }
        let name = title.netTrim
        return SheetExport(name.isEmpty ? "Sheet" : name, lines)
    }

    private static func oneLine(_ text: String) -> String {
        let units = Array(text.utf16)
        guard units.contains(10) || units.contains(13) else { return text }
        return units.split(whereSeparator: { $0 == 10 || $0 == 13 }).map { String(units: $0) }.joined(separator: " ")
    }

    /// The last `sum`/`average` line, which is the sheet's own total. Nil when the sheet declares none.
    var total: ExportLine? { lines.last { $0.isTotal } }
    var totalText: String? { total.map { $0.value ?? $0.result } }
    var hasResults: Bool { lines.contains { $0.kind == .result } }

    /// Results only, one row per source line so a paste lines up with the source; errors and prose leave empty rows.
    /// Single-line complete values replace abbreviated displays.
    func resultsText() throws -> String {
        var rows = lines.map { line -> String in
            if line.kind != .result { return "" }
            if let value = line.value, !value.utf16.contains(10), !value.utf16.contains(13) { return value }
            return line.result
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return try SheetExport.bounded(rows.joined(separator: "\r\n"))
    }

    /// Source and visible result columns. Results right-align in one column; a long source pushes only its own result.
    func plainText() throws -> String {
        let maxSourceColumn = 56
        let calculated = lines.filter { ($0.kind == .result || $0.kind == .error) && !$0.isTableRow }
        let sourceColumn = min(maxSourceColumn, calculated.map { SheetExport.displayWidth($0.source.netTrimEnd) }.max() ?? 0)
        let resultColumn = calculated.map { SheetExport.displayWidth($0.result) }.max() ?? 0
        var text = ExportText()
        for line in lines {
            let source = line.source.netTrimEnd
            if (line.kind == .result || line.kind == .error) && !line.result.isEmpty {
                let width = SheetExport.displayWidth(source)
                text.append(source)
                if line.isTableRow { text.append(9); text.append(line.result) }
                else {
                    text.append(0x20, count: max(2, sourceColumn - width + 2))
                    text.append(0x20, count: max(0, resultColumn - SheetExport.displayWidth(line.result)))
                    text.append(line.result)
                }
            } else { text.append(source) }
            text.append("\r\n")
            try text.guarded()
        }
        return text.string
    }

    /// GitHub-flavoured Markdown. Headings stay headings; each calculation block becomes a two-column table (empty header cells,
    /// results right-aligned); a block of tab-separated worksheet rows becomes its own table; prose stays prose.
    func markdown() throws -> String {
        var text = ExportText(); var block: [ExportLine] = []
        func separate() { if !text.units.isEmpty { text.append("\r\n") } }
        func flush() throws {
            if block.isEmpty { return }
            separate()
            if block.allSatisfy(\.isTableRow) {
                var cells = block.map { $0.source.netSplit("\t").map { SheetExport.escape($0.netTrim) } }
                let columns = cells.map(\.count).max()!
                for i in cells.indices { while cells[i].count < columns { cells[i].append("") } }
                text.append("| " + cells[0].joined(separator: " | ") + " |\r\n|" + String(repeating: " --- |", count: columns) + "\r\n")
                for row in cells.dropFirst() { text.append("| " + row.joined(separator: " | ") + " |\r\n") }
            } else if block.contains(where: { $0.kind == .result || $0.kind == .error }) {
                text.append("| | |\r\n| --- | ---: |\r\n")
                for line in block {
                    let result = line.kind == .error ? "*" + SheetExport.escape(line.result) + "*" : line.isTotal ? "**" + SheetExport.escape(line.result) + "**" : SheetExport.escape(line.result)
                    text.append("| " + SheetExport.escape(line.source.netReplace("\t", " ").netTrim) + " | " + result + " |\r\n")
                }
            } else { text.append(block.map { SheetExport.escapeProse($0.source.netTrim) }.joined(separator: "  \r\n") + "\r\n") }
            block.removeAll(); try text.guarded()
        }
        for line in lines {
            if line.kind == .blank { try flush(); continue }
            if line.kind == .heading {
                try flush()
                let heading = line.source.netTrim.netTrimStart("#").netTrim
                if !heading.isEmpty { separate(); text.append("# " + SheetExport.escapeProse(heading) + "\r\n") }
                continue
            }
            if let last = block.last, last.isTableRow != line.isTableRow { try flush() }
            block.append(line)
        }
        try flush()
        return text.string
    }

    /// RFC 4180 CSV with a header row. Result is the visible text; Value holds the complete copy when it differs.
    /// Cells that a spreadsheet would execute as a formula are prefixed with an apostrophe; plain signed numbers are left intact.
    func csv() throws -> String {
        var text = ExportText(); text.append("Line,Source,Result,Value,Error\r\n")
        for line in lines where line.kind != .blank {
            let result = line.kind == .result ? line.result : ""
            let value = line.kind == .result ? line.value ?? line.result : ""
            let error = line.kind == .error ? line.result : ""
            text.append(String(line.number) + "," + SheetExport.csvCell(line.source) + "," + SheetExport.csvCell(result) + "," +
                        SheetExport.csvCell(value) + "," + SheetExport.csvCell(error) + "\r\n")
            try text.guarded()
        }
        return text.string
    }

    /// Rows for a pasted table: worksheet tab cells stay cells and the visible result is the last cell. Blank lines are omitted.
    func tableRows() -> [[String]] {
        lines.filter { $0.kind != .blank }.map { line in
            line.source.netSplit("\t").map(\.netTrim) + (!line.result.isEmpty && line.kind == .result ? [line.result] : [])
        }
    }

    func tableTsv() throws -> String {
        try SheetExport.bounded(tableRows().map { $0.map { $0.netReplace("\t", " ") }.joined(separator: "\t") }.joined(separator: "\r\n"))
    }

    func tableHtml() throws -> String {
        var html = ExportText(); html.append("<table>")
        for row in tableRows() {
            html.append("<tr>")
            for cell in row { html.append("<td>" + SheetExport.htmlEncode(cell) + "</td>") }
            html.append("</tr>"); try html.guarded()
        }
        html.append("</table>")
        return html.string
    }

    /// `System.Net.WebUtility.HtmlEncode`: the five HTML-sensitive characters, U+00A0–U+00FF and characters outside the BMP become
    /// entities; an unpaired surrogate becomes U+FFFD.
    static func htmlEncode(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "&": out += "&amp;"
            default:
                if (160..<256).contains(scalar.value) || scalar.value >= 0x10000 { out += "&#" + String(scalar.value) + ";" }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    static func csvCell(_ cell: String) -> String {
        var cell = cell
        if let first = cell.utf16.first, [0x3D, 0x2B, 0x40, 0x09, 0x0D].contains(first) || first == 0x2D && !isPlainNumber(cell) { cell = "'" + cell }
        let units = cell.utf16
        return units.contains(0x2C) || units.contains(0x22) || units.contains(0x0D) || units.contains(0x0A) ? "\"" + cell.netReplace("\"", "\"\"") + "\"" : cell
    }
    /// `decimal.TryParse(cell, AllowLeadingSign | AllowDecimalPoint, InvariantCulture)`: an optional sign, digits and at most one
    /// point, within decimal's range.
    private static func isPlainNumber(_ cell: String) -> Bool {
        var u = Array(cell.utf8)
        if let first = u.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") { u.removeFirst() }
        let parts = u.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.contains(where: { !$0.isEmpty }), parts.allSatisfy({ $0.allSatisfy { $0 >= 48 && $0 <= 57 } }) else { return false }
        let integer = String(decoding: parts[0].drop { $0 == 48 }, as: UTF8.self)
        let maximum = "79228162514264337593543950335"
        return integer.count < maximum.count || integer.count == maximum.count && integer <= maximum
    }

    private static func escape(_ cell: String) -> String {
        var text = ""
        for c in cell.unicodeScalars {
            if "\\|`*_[]<>~#".unicodeScalars.contains(c) { text += "\\" }
            text.unicodeScalars.append(c)
        }
        return text
    }
    // Prose escapes the same inline marks; a leading list/quote/number marker would otherwise turn a line into structure.
    private static func escapeProse(_ line: String) -> String {
        var escaped = Array(escape(line).utf16)
        let digits = escaped.prefix { NetChar.isAsciiDigit($0) }.count
        if let first = escaped.first, first == 0x2D || first == 0x2B || escaped.count > 1 && NetChar.isAsciiDigit(first) && digits < escaped.count && (escaped[digits] == 0x2E || escaped[digits] == 0x29) {
            let at = first == 0x2D || first == 0x2B ? 0 : digits
            escaped.insert(0x5C, at: at)
        }
        return String(units: escaped)
    }

    /// Monospace column width: combining/format marks take none, East Asian wide and emoji take two.
    static func displayWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory { case .nonspacingMark, .enclosingMark, .format: continue; default: break }
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) ||
                (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) ||
                (0x20000...0x3FFFD).contains(v)
            width += wide ? 2 : 1
        }
        return width
    }
    private static func bounded(_ text: String) throws -> String {
        if text.netLength > maxOutputCharacters { throw CalcError.argument("Export exceeds the output limit") }
        return text
    }
}
