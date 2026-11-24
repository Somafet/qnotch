import Foundation

/// Immutable flat numeric/monetary data. The result preview never limits the stored values.
final class SheetList: Hashable {
    static let maxItems = 1024
    let values: [SheetValue]
    let isApproximate: Bool
    let hasMoney: Bool
    /// Optional per-value labels, kept by table selections for charts.
    let labels: [String]?
    init(_ items: [SheetValue], labels: [String]? = nil) throws {
        var approximate = false, money = false
        for (index, item) in items.enumerated() {
            if index == SheetList.maxItems { throw CalcError.arithmetic("List exceeds 1024 values") }
            if item.kind != .number && item.kind != .money { throw CalcError.arithmetic("Lists require flat numeric or monetary values; use rectangular numeric rows for matrices") }
            let itemApproximate = item.kind == .money ? try item.money.magnitude.isApproximate : try item.number.isApproximate
            approximate = approximate || itemApproximate
            money = money || item.kind == .money
        }
        values = items; isApproximate = approximate; hasMoney = money
        if let labels, labels.count != items.count { throw CalcError.arithmetic("List labels do not match its values") }
        self.labels = labels
    }
    var display: String {
        get throws {
            var text = "["; var textLength = 1; var displayed = 0
            for item in values {
                if displayed == 16 { break }
                let next = try item.display
                if textLength + next.netLength > 512 { break }
                if displayed > 0 { text += ", "; textLength += 2 }
                displayed += 1
                text += next; textLength += next.netLength
            }
            if displayed < values.count { text += displayed > 0 ? ", …" : "…" }
            return text + "]"
        }
    }
    /// Complete formatted values, including approximation markers.
    var copyText: String { get throws { "[" + (try values.map { try $0.display }).joined(separator: ", ") + "]" } }
    static func == (a: SheetList, b: SheetList) -> Bool { a === b || a.values == b.values && (a.labels ?? []) == (b.labels ?? []) }
    func hash(into hasher: inout Hasher) { hasher.combine(values) }
}

/// Immutable rectangular real matrix. A flat list remains a vector/statistical sample.
final class SheetMatrix: Hashable {
    static let maxDimension = 12
    let rows: [SheetList]
    let columnCount: Int
    let isApproximate: Bool
    var rowCount: Int { rows.count }
    subscript(row: Int, column: Int) -> NumericValue { try! rows[row].values[column].number }
    init(_ source: [SheetList]) throws {
        var first: NumericValue?; var kind = ""; var columns = 0; var approximate = false
        for (index, row) in source.enumerated() {
            if index == SheetMatrix.maxDimension { throw CalcError.arithmetic("Matrix exceeds 12 rows") }
            if row.values.count < 1 || row.values.count > SheetMatrix.maxDimension { throw CalcError.arithmetic("Matrix requires 1–12 columns") }
            if index == 0 { columns = row.values.count } else if row.values.count != columns { throw CalcError.arithmetic("Matrix rows must have equal lengths") }
            for value in row.values {
                if value.kind != .number { throw CalcError.arithmetic("Matrices require real numeric quantities, not money or dates") }
                let number = try value.number
                try SheetMatrix.validateEntry(number, first); if first == nil { first = number }
                if !kind.isEmpty && !number.quantityKind.isEmpty && kind != number.quantityKind { throw CalcError.arithmetic("Matrix contains incompatible quantity kinds") }
                if kind.isEmpty { kind = number.quantityKind }
            }
            approximate = approximate || row.isApproximate
        }
        if source.isEmpty { throw CalcError.arithmetic("Matrix requires at least one row") }
        rows = source; columnCount = columns; isApproximate = approximate
    }
    static func validateEntry(_ value: NumericValue, _ first: NumericValue?) throws {
        if value.isPercentage || value.unit?.isTemperaturePoint == true { throw CalcError.arithmetic("Linear algebra requires real linear quantities; use ratios or temperature differences") }
        if let other = first, value.unit?.dimension != other.unit?.dimension || !value.quantityKind.isEmpty && !other.quantityKind.isEmpty && value.quantityKind != other.quantityKind {
            throw CalcError.arithmetic("Matrix/vector entries require compatible dimensions and quantity kinds")
        }
    }
    var display: String {
        get throws {
            var text = "["; var textLength = 1; var shown = 0
            for row in rows {
                let next = try row.display
                if textLength + next.netLength > 512 { break }
                if shown > 0 { text += ", "; textLength += 2 }
                shown += 1
                text += next; textLength += next.netLength
            }
            if shown < rows.count { text += shown > 0 ? ", …" : "…" }
            return text + "]"
        }
    }
    var copyText: String { get throws { "[" + (try rows.map { try $0.copyText }).joined(separator: ", ") + "]" } }
    static func == (a: SheetMatrix, b: SheetMatrix) -> Bool { a === b || a.rows == b.rows }
    func hash(into hasher: inout Hasher) { hasher.combine(rows) }
}
