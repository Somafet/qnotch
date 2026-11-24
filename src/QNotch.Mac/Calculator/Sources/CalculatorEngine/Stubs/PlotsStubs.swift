// Stub for the plots area: plots, charts, tables (TableSyntax, TableValue, TableArithmetic) and WorksheetSyntax.

enum ChartKind { case bar, pie, trend }
final class PlotExpression: Expression {
    let body: FormulaTerm, text: String, inputs: [Expression], hasDomain: Bool
    init(_ body: FormulaTerm, _ text: String, _ inputs: [Expression], _ hasDomain: Bool) { self.body = body; self.text = text; self.inputs = inputs; self.hasDomain = hasDomain }
    var children: [Expression] { inputs }
}
final class ChartExpression: Expression {
    let kind: ChartKind, data: Expression?
    var tag: String?
    init(_ kind: ChartKind, _ data: Expression?, tag: String? = nil) { self.kind = kind; self.data = data; self.tag = tag }
    func with(tag: String?) -> ChartExpression { ChartExpression(kind, data, tag: tag) }
    var children: [Expression] { data.map { [$0] } ?? [] }
}
final class TableValue: IdentityHashable {
    var summary: String { "" }
    var display: String { get throws { throw notPorted("tables") } }
    var copyText: String { get throws { try display } }
}
final class TableExpression: Expression { let value: TableValue; init(_ value: TableValue) { self.value = value } }
/// A sampled plot. Without the plots port no plot is ever built; the members are what share links and exports read.
final class PlotValue: IdentityHashable {
    static let maxPoints = 512
    var display: String { get throws { throw notPorted("plots") } }
    var copyText: String { get throws { try display } }
    var lower: Double { 0 }
    var upper: Double { 0 }
    var yLower: Double { 0 }
    var yUpper: Double { 0 }
    var x: [Double] { [] }
    var y: [Double] { [] }
    var segmentStarts: [Int] { [] }
    var description: String { "" }
    /// C# `PlotValue.Number`: four significant digits, tiny values shown as 0.
    static func number(_ value: Double) -> String { NetFormat.double(abs(value) < 1e-12 ? 0 : value, "G4") }
}
struct ChartItem: Hashable { let label: String; let magnitude: Double; let display: String }
/// A chart. Without the plots port no chart is ever built; the members are what share links and exports read.
final class ChartValue: IdentityHashable {
    var isApproximate: Bool { false }
    var display: String { get throws { throw notPorted("charts") } }
    var copyText: String { get throws { try display } }
    var kind: ChartKind { .bar }
    var items: [ChartItem] { [] }
    var total: String { "" }
    var description: String { "" }
}
enum PlotArithmetic {
    static func plot(_ expression: PlotExpression, _ inputs: [SheetValue], _ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) throws -> (value: SheetValue, assumption: String) { throw notPorted("plots") }
}
final class ChartArithmetic {
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken, _ money: MoneyArithmetic) {}
    func build(_ kind: ChartKind, _ data: SheetValue?, _ aggregate: [SheetValue], _ labels: [String]?) throws -> (value: SheetValue, assumption: String) { throw notPorted("charts") }
}
enum TableArithmetic {
    static func isFunction(_ name: String) -> Bool { ["column", "row"].contains(name.netLower) }
    static func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, assumption: String) { throw notPorted("table selections") }
}
enum WorksheetSyntax {
    static func tryParse(_ tokens: [Token], _ names: NetHashSet<String>, _ token: CancellationToken) throws -> Expression? { nil }
    static func label(_ line: ParsedLine, _ source: String, _ index: Int, _ token: CancellationToken) throws -> String { "" }
}
struct TableBlock { let first: Int, start: Int, rows: Int, columns: Int, name: String, automatic: Bool }
/// The sheet's table blocks. Without the tables port, no line belongs to a table.
final class TableLayout {
    let blocks: [TableBlock]
    let keys: [String]
    init(_ lines: [String], _ blocks: [TableBlock]) { self.blocks = blocks; keys = lines }
    func owns(_ line: Int) -> Bool { false }
    func scan(_ line: Int, _ lines: [String], _ token: CancellationToken) throws -> ParsedLine? { nil }
}
enum TableSyntax {
    static func layout(_ lines: [String], _ token: CancellationToken) throws -> TableLayout { TableLayout(lines, []) }
}
