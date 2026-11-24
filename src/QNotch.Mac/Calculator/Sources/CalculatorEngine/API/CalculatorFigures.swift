import Foundation

/// What a line draws besides its answer (Windows SheetFigures, FigureView and TableColumns): a plot or a chart under the
/// line, or a table whose tab-separated source lines are laid out as columns. The wrappers hold the engine's immutable
/// values and expose only what drawing, accessibility and copying need.
public enum CalculatorFigure: Hashable, Sendable {
    case plot(CalculatorPlot)
    case chart(CalculatorChart)
    case table(CalculatorTable)

    init?(_ value: SheetValue) {
        switch value {
        case .plot(let plot): self = .plot(CalculatorPlot(plot))
        case .chart(let chart): self = .chart(CalculatorChart(chart))
        case .table(let table): self = .table(CalculatorTable(table))
        default: return nil
        }
    }

    /// Plots and charts take room under their line; tables stay in the source.
    public var isDrawn: Bool { if case .table = self { false } else { true } }
    /// The hover card's note (C# Summary).
    public var summary: String {
        switch self {
        case .plot(let plot): plot.summary
        case .chart(let chart): chart.summary
        case .table(let table): table.summary
        }
    }
    /// The accessibility description of a drawn figure (C# Description).
    public var accessibilityDescription: String {
        switch self {
        case .plot(let plot): plot.accessibilityDescription
        case .chart(let chart): chart.accessibilityDescription
        case .table(let table): table.display
        }
    }
    /// The longer evidence (C# Details), as the explanation shows it.
    public var details: String {
        switch self {
        case .plot(let plot): plot.details
        case .chart(let chart): chart.details
        case .table(let table): table.details
        }
    }
}

/// A sampled curve (C# PlotValue): finite points in x order, split into segments at undefined samples and jumps.
public final class CalculatorPlot: Hashable, @unchecked Sendable {
    let value: PlotValue
    init(_ value: PlotValue) { self.value = value }

    public var formula: String { value.formula }
    /// The x domain.
    public var lower: Double { value.lower }
    public var upper: Double { value.upper }
    /// The y band shown; values outside it are cut at the band.
    public var yLower: Double { value.yLower }
    public var yUpper: Double { value.yUpper }
    public var x: [Double] { value.x }
    public var y: [Double] { value.y }
    /// Index of the first point of each drawn segment.
    public var segmentStarts: [Int] { value.segmentStarts }
    /// Each segment's point indices.
    public var segments: [Range<Int>] {
        let starts = value.segmentStarts
        return starts.indices.map { starts[$0]..<(($0 + 1 < starts.count) ? starts[$0 + 1] : value.x.count) }
    }
    public var summary: String { value.summary }
    public var details: String { value.details }
    public var accessibilityDescription: String { value.description }
    /// Axis numbers: four significant digits, values within 1e-12 of zero as 0.
    public static func number(_ value: Double) -> String { PlotValue.number(value) }

    public static func == (a: CalculatorPlot, b: CalculatorPlot) -> Bool { a.value == b.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

/// Labelled magnitudes in one unit or currency (C# ChartValue).
public final class CalculatorChart: Hashable, @unchecked Sendable {
    public enum Kind: Sendable { case bar, pie, trend }
    public struct Item: Hashable, Sendable {
        public let label: String
        /// The magnitude drawn.
        public let magnitude: Double
        /// The source's own formatted value.
        public let display: String
    }
    let value: ChartValue
    public let items: [Item]
    init(_ value: ChartValue) {
        self.value = value
        items = value.items.map { Item(label: $0.label, magnitude: $0.magnitude, display: $0.display) }
    }

    public var kind: Kind {
        switch value.kind {
        case .bar: .bar
        case .pie: .pie
        case .trend: .trend
        }
    }
    public var total: String { value.total }
    public var isApproximate: Bool { value.isApproximate }
    public var summary: String { value.summary }
    public var details: String { value.details }
    public var accessibilityDescription: String { value.description }

    public static func == (a: CalculatorChart, b: CalculatorChart) -> Bool { a.value == b.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

/// A rectangular table parsed from tab-separated source lines (C# TableValue).
public final class CalculatorTable: Hashable, @unchecked Sendable {
    let value: TableValue
    init(_ value: TableValue) { self.value = value }

    public var rowCount: Int { value.rowCount }
    public var columnCount: Int { value.columnCount }
    /// The header line's names, when the first line is a header.
    public var header: [String]? { value.header }
    /// Source lines the table occupies, header included.
    public var sourceRows: Int { value.sourceRows }
    /// A body cell's trimmed text.
    public func text(row: Int, column: Int) -> String { value[row, column].text }
    /// Whether a body cell holds a number, percentage, amount of money or quantity.
    public func isNumeric(row: Int, column: Int) -> Bool { value[row, column].value != nil }
    public var display: String { value.display }
    public var summary: String { value.summary }
    public var details: String { value.details }

    public static func == (a: CalculatorTable, b: CalculatorTable) -> Bool { a.value == b.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(value) }
}
