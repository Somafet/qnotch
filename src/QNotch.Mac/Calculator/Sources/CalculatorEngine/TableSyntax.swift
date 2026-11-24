import Foundation

final class TableExpression: Expression { let value: TableValue; init(_ value: TableValue) { self.value = value } }

struct TableBlock {
    /// The block's first line: its name line when it has one, otherwise its first row.
    let first: Int
    /// The first table row (the header when there is one).
    let start: Int
    let rows: Int, columns: Int
    let name: String
    /// Named tableN because no valid name line precedes it.
    let automatic: Bool
    init(_ first: Int, _ start: Int, _ rows: Int, _ columns: Int, _ name: String, _ automatic: Bool) {
        self.first = first; self.start = start; self.rows = rows; self.columns = columns; self.name = name; self.automatic = automatic
    }
}

/// Where the tables are in one source snapshot. A table's cache key covers its whole block, so a cell edit re-parses that table and nothing else.
final class TableLayout {
    private static let quiet = ParsedLine("", nil, [], false, nil, nil)
    private let owners: [TableBlock?]?
    let blocks: [TableBlock]
    let keys: [String]

    init(_ lines: [String], _ blocks: [TableBlock]) {
        self.blocks = blocks
        if blocks.isEmpty { owners = nil; keys = lines; return }
        var owners = [TableBlock?](repeating: nil, count: lines.count), keys = lines
        for block in blocks {
            // Source lines never contain a newline, so these keys cannot match ordinary text.
            for i in block.first..<(block.start + block.rows) { owners[i] = block; keys[i] = "\n" }
            keys[block.start] = "\n" + block.name + "\n" + lines[block.start..<(block.start + block.rows)].joined(separator: "\n")
        }
        self.owners = owners; self.keys = keys
    }
    func owns(_ line: Int) -> Bool { owners?[line] != nil }
    func scan(_ line: Int, _ lines: [String], _ token: CancellationToken) throws -> ParsedLine? {
        guard let block = owners?[line] else { return nil }
        if line != block.start { return TableLayout.quiet }
        if block.columns > TableValue.maxColumns { return TableLayout.quiet.with { $0.error = "Table exceeds 64 columns" } }
        var rows: [[TableCell]] = []; rows.reserveCapacity(block.rows)
        for i in 0..<block.rows {
            try token.throwIfCancellationRequested()
            rows.append(try lines[block.start + i].netSplit("\t").map { try TableSyntax.cell($0.netTrim, token) })
        }
        let header = rows[0].contains { $0.value == nil && !$0.text.isEmpty }
        if rows.count - (header ? 1 : 0) > TableValue.maxRows { return TableLayout.quiet.with { $0.error = "Table exceeds 1024 rows" } }
        let table = TableValue(Array(rows.dropFirst(header ? 1 : 0)), header ? rows[0].map(\.text) : nil, block.columns)
        return TableLayout.quiet.with { $0.text = lines[line]; $0.assignment = block.name; $0.expression = TableExpression(table) }
    }
}

/// Plain-text table recognition and CSV paste normalization. Pure: no clipboard, file or host access.
enum TableSyntax {
    private static let maxCellCharacters = 64
    private static let tab: UInt16 = 0x09, cr: UInt16 = 0x0D, lf: UInt16 = 0x0A, quote: UInt16 = 0x22, comma: UInt16 = 0x2C

    private static func columns(_ line: String) -> Int {
        let u = line.units
        if !u.contains(tab) { return 0 }
        let trimmed = line.netTrimStart.utf16
        // Ordinal StartsWith: compare code units, not Characters.
        return trimmed.isEmpty || trimmed.starts(with: "# ".utf16) || trimmed.starts(with: "//".utf16) ? 0 : u.filter { $0 == tab }.count + 1
    }
    // Two filled cells on the first row keep indented lines and stray trailing tabs ordinary source.
    private static func opens(_ line: String) -> Bool { line.netSplit("\t").filter { !$0.netTrim.isEmpty }.count >= 2 }

    static func layout(_ lines: [String], _ token: CancellationToken) throws -> TableLayout {
        var blocks: [TableBlock] = [], unnamed = 0
        var i = 0
        while i < lines.count {
            try token.throwIfCancellationRequested()
            let columns = columns(lines[i]); var end = i + 1
            if columns >= 2 { while end < lines.count && TableSyntax.columns(lines[end]) == columns { end += 1 } }
            if end - i >= 2 && opens(lines[i]) {
                let label = i > 0 ? lines[i - 1].netTrim : ""
                let labelUnits = label.units
                let name = labelUnits.last == 0x3A ? SheetSyntax.normalizeName(String(units: labelUnits.dropLast())) : ""
                let named = SheetSyntax.validName(name)
                if try named || !labelList(lines, i, end, token) {
                    if !named { unnamed += 1 }
                    blocks.append(TableBlock(named ? i - 1 : i, i, end - i, columns, named ? name : "table\(unnamed)", !named))
                }
            }
            i = end
        }
        return TableLayout(lines, blocks)
    }
    // Unnamed `label<TAB>amount` lines with no header evaluated as labelled numbers before tables existed; they stay ordinary lines.
    private static func labelList(_ lines: [String], _ start: Int, _ end: Int, _ token: CancellationToken) throws -> Bool {
        for i in start..<end {
            try token.throwIfCancellationRequested(); let cells = lines[i].netSplit("\t")
            if cells.count != 2 { return false }
            let label = cells[0].netTrim
            if try label.isEmpty || literal(label, token) != nil || literal(cells[1].netTrim, token) == nil { return false }
        }
        return true
    }
    static func cell(_ text: String, _ token: CancellationToken) throws -> TableCell { TableCell(text, try literal(text, token)) }

    /// C# `(?<=\d),(?=\d{3}(?!\d))` with .NET's \d (Unicode decimal digits): drops each comma that groups thousands.
    private static func removeGroupSeparators(_ u: [UInt16]) -> String {
        var result: [UInt16] = []; result.reserveCapacity(u.count)
        for i in u.indices {
            if u[i] == comma && i > 0 && NetChar.isDigit(u[i - 1]) && i + 3 < u.count && NetChar.isDigit(u[i + 1]) && NetChar.isDigit(u[i + 2]) && NetChar.isDigit(u[i + 3]) &&
                (i + 4 == u.count || !NetChar.isDigit(u[i + 4])) { continue }
            result.append(u[i])
        }
        return String(units: result)
    }
    private static func literal(_ text: String, _ token: CancellationToken) throws -> SheetValue? {
        let u = text.units
        if u.isEmpty || u.count > maxCellCharacters || !u.contains(where: NetChar.isAsciiDigit) || u.contains(0x28) { return nil }
        if u.allSatisfy({ NetChar.isAsciiDigit($0) || $0 == 0x2E }) && u.filter({ $0 == 0x2E }).count <= 1 { return SheetValue(try Rational.parse(text)) }
        do {
            let source = u.contains(comma) ? removeGroupSeparators(u) : text
            let node = try ExpressionParser(try ExpressionParser.tokenize(source, token), token).parse()
            if !ExpressionEvaluation.walk(node).allSatisfy(isLiteralNode) { return nil }
            let value = try ExpressionEvaluation.evaluate(node, { _ in throw CalcError.format("Table cells cannot refer to names") }, [], token).value
            return value.kind == .number || value.kind == .money ? value : nil
        } catch let e as CalcError where e.isFormatOrArithmetic { return nil }
    }
    private static func isLiteralNode(_ node: Expression) -> Bool {
        if node is LiteralExpression || node is ScaleExpression || node is CurrencyAttachExpression { return true }
        if let unit = node as? UnitExpressionNode { return !unit.conversion }
        if let unary = node as? UnaryExpression { return unary.operation == "-" || unary.operation == "+" || unary.operation == "%" }
        return false
    }

    /// Converts RFC 4180 CSV or semicolon separated text into TSV, or returns the same text when it is not unmistakably a table.
    static func tryNormalizePaste(_ text: String) throws -> String {
        let u = text.units
        var trimmedEnd = u.count
        while trimmedEnd > 0 && (u[trimmedEnd - 1] == cr || u[trimmedEnd - 1] == lf) { trimmedEnd -= 1 }
        if u.contains(tab) || !u[..<trimmedEnd].contains(where: { $0 == cr || $0 == lf }) { return text }
        // Semicolon first: where it separates cells, a comma is usually the decimal mark.
        for delimiter: UInt16 in [0x3B, comma] {
            guard let (rows, digitComma) = fields(u, delimiter) else { continue }
            if try tabular(rows), try !digitComma || !rows[0].contains(where: numeric), try !rows.allSatisfy(labelRow) {
                return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + (u.last == lf || u.last == cr ? "\n" : "")
            }
        }
        return text
    }
    private static func tabular(_ rows: [[String]]) throws -> Bool {
        if rows.count < 2 || rows.count > TableValue.maxRows + 1 { return false }
        let columns = rows[0].count
        if columns < 2 || columns > TableValue.maxColumns || rows.contains(where: { $0.count != columns }) || rows[0].filter({ !$0.isEmpty }).count < 2 { return false }
        // Expressions and prose also contain commas; a table has balanced cells and at least one number, in either decimal notation.
        if rows.contains(where: { $0.contains(where: code) }) { return false }
        return try rows.contains { row in try row.contains { try literal($0.netReplace(",", "."), .none) != nil } }
    }
    // A comma between two digits may be a group separator (1,200) or a decimal mark (3,5); without a text header row it is not a field separator.
    private static func numeric(_ cell: String) throws -> Bool { try literal(cell, .none) != nil }
    // Headerless label, amount rows would not form a table after conversion, so the paste keeps its own text.
    private static func labelRow(_ row: [String]) throws -> Bool { try row.count == 2 && !row[0].isEmpty && !numeric(row[0]) && numeric(row[1]) }
    private static func code(_ cell: String) -> Bool {
        let u = cell.units
        func count(_ c: UInt16) -> Int { u.filter { $0 == c }.count }
        return u.contains(0x3D) || count(0x28) != count(0x29) || count(0x5B) != count(0x5D)
    }
    /// RFC 4180 fields over UTF-16 units (a CRLF pair is two units here, as in C#). Nil when quoting is malformed.
    private static func fields(_ text: [UInt16], _ delimiter: UInt16) -> (rows: [[String]], digitComma: Bool)? {
        var digitComma = false
        var rows: [[String]] = [], row: [String] = [], field: [UInt16] = []
        var quoted = false, closed = false, wasQuoted = false
        func endField() { row.append(wasQuoted ? String(units: field) : String(units: field).netTrim); field.removeAll(); closed = false; wasQuoted = false }
        func endRow() { endField(); rows.append(row); row.removeAll() }
        var i = 0
        while i < text.count {
            defer { i += 1 }
            let c = text[i]
            if quoted {
                if c != quote { field.append(c == cr || c == lf ? 0x20 : c) }
                else if i + 1 < text.count && text[i + 1] == quote { field.append(quote); i += 1 }
                else { quoted = false; closed = true }
            } else if c == delimiter {
                digitComma = digitComma || c == comma && i > 0 && i + 1 < text.count && NetChar.isAsciiDigit(text[i - 1]) && NetChar.isAsciiDigit(text[i + 1])
                endField()
            } else if c == cr || c == lf {
                if c == cr && i + 1 < text.count && text[i + 1] == lf { i += 1 }
                endRow()
            } else if closed {
                if !NetChar.isWhiteSpace(c) { return nil }
            } else if c == quote {
                if !String(units: field).netTrim.isEmpty { return nil }
                field.removeAll(); quoted = true; wasQuoted = true
            } else { field.append(c) }
        }
        if quoted { return nil }
        if !field.isEmpty || !row.isEmpty || wasQuoted { endRow() }
        return (rows, digitComma)
    }
}

/// column(table, "name" | n) and row(table, n) select one line of a table as a labelled list.
enum TableArithmetic {
    static func isFunction(_ name: String) -> Bool { ["column", "row"].contains(name.netLower) }
    static func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, assumption: String) {
        if args.count != 2 { throw CalcError.format(name + " expects (table, position)") }
        guard case .table(let table) = args[0] else { throw CalcError.arithmetic(name + " expects a table") }
        let column = name.equalsIgnoreCase("column")
        let index: Int
        if column, case .text(let text) = args[1] { index = try table.columnIndex(text.value) }
        else { index = try position(args[1], column ? table.columnCount : table.rowCount, column ? "Column" : "Row") }
        let (list, skipped) = column ? try table.column(index) : try table.row(index)
        return (.list(list), "\(list.values.count) numeric cells; \(skipped) text or blank cells skipped; header excluded")
    }
    private static func position(_ value: SheetValue, _ limit: Int, _ role: String) throws -> Int {
        guard case .number(let number) = value, number.unit == nil, number.isRational, !number.isPercentage else {
            throw CalcError.arithmetic(role + " must be a whole number or a header name")
        }
        let position = try number.scalar
        if !position.denominator.isOne || position.numerator < 1 || position.numerator > BigInt(limit) {
            throw CalcError.arithmetic(role + " must be a whole number from 1 to \(limit)")
        }
        return position.numerator.intValue! - 1 // 1…limit, so it fits
    }
}
