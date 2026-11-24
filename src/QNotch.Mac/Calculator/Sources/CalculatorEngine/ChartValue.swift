import Foundation

enum ChartKind { case bar, pie, trend }

/// One chart entry: its label, the magnitude drawn, and the source's own formatted value.
struct ChartItem: Hashable {
    let label: String
    let magnitude: Double
    let display: String
    init(_ label: String, _ magnitude: Double, _ display: String) { self.label = label; self.magnitude = magnitude; self.display = display }
    // A C# record compares strings by code units.
    static func == (a: ChartItem, b: ChartItem) -> Bool { a.label.ordinalEquals(b.label) && a.magnitude == b.magnitude && a.display.ordinalEquals(b.display) }
    func hash(into hasher: inout Hasher) { hasher.combine(Array(label.utf16)); hasher.combine(magnitude); hasher.combine(Array(display.utf16)) }
}

/// Immutable chart data: labelled magnitudes in one unit or currency, with the source's own formatted values.
final class ChartValue: Hashable {
    static let maxBars = 64, maxTrendPoints = 512, maxLabel = 32
    let kind: ChartKind
    let items: [ChartItem]
    let total: String
    let isApproximate: Bool
    private let hash: Int

    init(_ kind: ChartKind, _ data: [ChartItem], _ total: String, _ approximate: Bool) {
        self.kind = kind; items = data; self.total = total; isApproximate = approximate
        var code = Hasher(); code.combine(kind); code.combine(Array(total.utf16)); code.combine(data)
        hash = code.finalize()
    }
    private var word: String { kind == .bar ? "Bar chart" : kind == .pie ? "Pie chart" : "Trend chart" }
    // MinBy/MaxBy keep the first of equal magnitudes.
    private var lowest: ChartItem { var best = items[0]; for item in items.dropFirst() where item.magnitude < best.magnitude { best = item }; return best }
    private var highest: ChartItem { var best = items[0]; for item in items.dropFirst() where item.magnitude > best.magnitude { best = item }; return best }
    var display: String { kind == .trend ? "\(items.count) points" : total }
    var copyText: String { kind == .trend ? "[" + items.map(\.display).joined(separator: ", ") + "]" : items.map { $0.label + ": " + $0.display }.joined(separator: ", ") }
    var summary: String {
        word + " of \(items.count) values" + (kind == .trend ? " in source order, evenly spaced" : ", total " + total) + "\nFrom " + lowest.display + " to " + highest.display
    }
    var details: String {
        summary + "\n" + items.prefix(16).map { $0.label + ": " + $0.display }.joined(separator: "\n") + (items.count > 16 ? "\n… \(items.count - 16) more" : "") +
            "\nValues keep the first entry's unit or currency; nothing is extrapolated"
    }
    /// The accessibility description (C# Description; ToString is Display).
    var description: String { word + " of \(items.count) values, from " + lowest.label + " " + lowest.display + " to " + highest.label + " " + highest.display }

    static func == (a: ChartValue, b: ChartValue) -> Bool { a === b || a.hash == b.hash && a.kind == b.kind && a.total.ordinalEquals(b.total) && a.items == b.items }
    func hash(into hasher: inout Hasher) { hasher.combine(hash) }
}

final class ChartArithmetic {
    private let math: ExactArithmetic
    private let budget: ExecutionBudget
    private let token: CancellationToken
    private let money: MoneyArithmetic
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {
        self.math = math; self.budget = budget; self.token = token; self.money = money
    }
    /// Labels longer than 32 UTF-16 units keep 31 and an ellipsis.
    private static func bounded(_ text: String) -> String { text.netLength <= ChartValue.maxLabel ? text : text.netSubstring(0, ChartValue.maxLabel - 1) + "…" }

    func build(_ kind: ChartKind, _ data: SheetValue?, _ lines: [SheetValue], _ lineLabels: [String]?) throws -> (value: SheetValue, assumption: String) {
        var values: [SheetValue], labels: [String]
        if let argument = data {
            guard case .list(let list) = argument else { throw CalcError.arithmetic("A chart needs a list, a named list or a table column") }
            values = list.values
            labels = list.labels ?? values.indices.map { String($0 + 1) }
        } else {
            let kept = lines.indices.filter { !ExpressionEvaluation.excludedFromAggregate(lines[$0]) }
            values = kept.map { lines[$0] }; labels = kept.map { lineLabels?[$0] ?? "" }
        }
        let trend = kind == .trend, limit = trend ? ChartValue.maxTrendPoints : ChartValue.maxBars
        if values.isEmpty { throw CalcError.arithmetic(data == nil ? "No preceding lines to chart in this block" : "A chart needs at least one value") }
        if values.count > limit { throw CalcError.arithmetic((trend ? "A trend chart shows at most " : "A chart shows at most ") + "\(limit) values") }
        if trend && values.count < 2 { throw CalcError.arithmetic("A trend chart needs at least two values") }
        if values.contains(where: { $0.kind != .number && $0.kind != .money }) { throw CalcError.arithmetic("Charts require numeric or monetary values") }
        let list = try SheetList(values)
        // Statistics owns unit, percentage, quantity-kind and currency compatibility, so a chart refuses exactly what sum refuses.
        let total = try StatisticsArithmetic(math, budget, token, money).function(trend ? "max" : "sum", [.list(list)])
        let quantities = QuantityArithmetic(math); var items: [ChartItem] = []; items.reserveCapacity(values.count)
        for i in values.indices {
            try budget.step(token)
            let exact: ExactNumber, display: String
            if values[0].kind == .money {
                let converted = try money.convert(try values[i].money, try values[0].money.currency); exact = converted.magnitude.exact; display = try converted.display
            } else {
                let converted = try values[0].unit.map { try quantities.convert(try values[i].number, $0) } ?? values[i].number
                exact = try quantities.displayMagnitude(converted); display = try converted.display
            }
            if try kind == .pie && math.sign(exact) < 0 { throw CalcError.arithmetic("A pie chart cannot show negative values") }
            let magnitude = FormulaNumbers.toDouble(exact)
            if !magnitude.isFinite { throw CalcError.arithmetic("Chart value is too large to draw") }
            items.append(ChartItem(ChartArithmetic.bounded(labels[i]), magnitude, ChartArithmetic.bounded(display)))
        }
        if kind == .pie && items.allSatisfy({ $0.magnitude == 0 }) { throw CalcError.arithmetic("A pie chart needs a nonzero total") }
        let value = ChartValue(kind, items, try total.value.display, list.isApproximate)
        return (.chart(value), value.summary.netReplace("\n", "; ") + (money.provenance.map { "; " + $0 } ?? ""))
    }
}
