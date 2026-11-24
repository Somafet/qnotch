import Foundation

/// One source cell: the trimmed text, and its value when the cell is a numeric, percentage, money or unit literal.
struct TableCell {
    let text: String
    let value: SheetValue?
    init(_ text: String, _ value: SheetValue?) { self.text = text; self.value = value }
}

/// Immutable rectangular table parsed from plain source lines. Text and blank cells stay in place and numeric selections skip them.
final class TableValue: Hashable {
    static let maxColumns = 64, maxRows = 1024
    private let rows: [[TableCell]]
    private let hash: Int
    let header: [String]?
    var rowCount: Int { rows.count }
    let columnCount: Int
    /// Document lines the table occupies, header included.
    var sourceRows: Int { rows.count + (header == nil ? 0 : 1) }

    init(_ data: [[TableCell]], _ header: [String]?, _ columns: Int) {
        rows = data; self.header = header; columnCount = columns
        var code = Hasher(); code.combine(columns)
        for cell in data.joined() {
            if let value = cell.value { code.combine(value) } else { code.combine(Array(cell.text.utf16)) }
        }
        for name in header ?? [] { code.combine(Array(name.utf16)) }
        hash = code.finalize()
    }
    subscript(row: Int, column: Int) -> TableCell { rows[row][column] }
    var display: String { "\(rowCount)×\(columnCount) table" }
    var copyText: String {
        guard let header else { return display }
        let names = header.joined(separator: ", ")
        return display + ": " + (names.netLength <= 256 ? names : names.netSubstring(0, 256) + "…")
    }
    private var numericCells: Int { rows.reduce(0) { $0 + $1.filter { $0.value != nil }.count } }
    var summary: String {
        "\(rowCount) rows, \(columnCount) columns" + (header == nil ? ", no header" : ", first line is the header") + "\n\(numericCells) numeric cells; text and blank cells are skipped"
    }
    var details: String { summary + "\nThe source stays plain text in the sheet. Refer to it with column(table, \"name\"), column(table, n) and row(table, n)." }

    func columnIndex(_ name: String) throws -> Int {
        guard let header else { throw CalcError.arithmetic("This table has no header; use a column number") }
        let matches = header.indices.filter { header[$0].equalsIgnoreCase(name) }
        if matches.count == 1 { return matches[0] }
        throw CalcError.arithmetic(matches.isEmpty ? "Unknown column: " + name : "More than one column is named " + name + "; use a column number")
    }
    /// A column made only of text labels the values of the other columns.
    private func labelColumn(_ selected: Int) -> Int {
        for column in 0..<columnCount where column != selected && rows.allSatisfy({ $0[column].value == nil }) && rows.contains(where: { !$0[column].text.isEmpty }) { return column }
        return -1
    }
    private static func select(_ count: Int, _ cell: (Int) -> TableCell, _ label: (Int) -> String, _ empty: String) throws -> (list: SheetList, skipped: Int) {
        var values: [SheetValue] = [], labels: [String] = []
        for i in 0..<count { if let value = cell(i).value { values.append(value); labels.append(label(i)) } }
        if values.isEmpty { throw CalcError.arithmetic(empty) }
        return (try SheetList(values, labels: labels), count - values.count)
    }
    private static func ordinal(_ index: Int) -> String { String(index + 1) }
    func column(_ index: Int) throws -> (list: SheetList, skipped: Int) {
        let labels = labelColumn(index)
        return try TableValue.select(rowCount, { self.rows[$0][index] }, { labels >= 0 ? self.rows[$0][labels].text : TableValue.ordinal($0) }, "Column " + TableValue.ordinal(index) + " has no numeric cells")
    }
    func row(_ index: Int) throws -> (list: SheetList, skipped: Int) {
        try TableValue.select(columnCount, { self.rows[index][$0] }, { self.header?[$0] ?? TableValue.ordinal($0) }, "Row " + TableValue.ordinal(index) + " has no numeric cells")
    }
    // Numeric cells compare by value, so reformatting 5 as 5.0 leaves dependents reusable; text cells compare by text.
    static func == (a: TableValue, b: TableValue) -> Bool {
        if a === b { return true }
        guard a.hash == b.hash, a.rowCount == b.rowCount, a.columnCount == b.columnCount else { return false }
        let left = a.header ?? [], right = b.header ?? []
        guard left.count == right.count, zip(left, right).allSatisfy({ $0.ordinalEquals($1) }) else { return false }
        return zip(a.rows, b.rows).allSatisfy { pair in
            zip(pair.0, pair.1).allSatisfy { $0.value == $1.value && ($0.value != nil || $0.text.ordinalEquals($1.text)) }
        }
    }
    func hash(into hasher: inout Hasher) { hasher.combine(hash) }
}
