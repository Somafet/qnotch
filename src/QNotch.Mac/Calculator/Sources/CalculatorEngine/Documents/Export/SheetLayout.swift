import Foundation

enum LayoutStyle { case source, heading, result, total, error }

/// Geometry in caller units (points for images, print and PDF). A continuous layout has an infinite page height and stops at `maxHeight`.
struct LayoutOptions {
    let width: Double, pageHeight: Double, margin: Double, lineHeight: Double
    var figureHeight = 120.0
    var figureGap = 10.0
    var columnGap = 24.0
    /// Continuous layouts only: rows past this height are omitted and counted.
    var maxHeight = 12_000.0
    var maxPages = 2_000
    init(_ width: Double, _ pageHeight: Double, _ margin: Double, _ lineHeight: Double) {
        self.width = width; self.pageHeight = pageHeight; self.margin = margin; self.lineHeight = lineHeight
    }
    var continuous: Bool { pageHeight == .infinity }
}

struct LayoutRun: Equatable { var x: Double, top: Double, text: String, style: LayoutStyle, line: Int }
struct LayoutFigure { var x: Double, top: Double, width: Double, height: Double, line: Int, value: SheetValue }
struct LayoutPage { let number: Int, runs: [LayoutRun], figures: [LayoutFigure], height: Double }
struct SheetLayout { let pages: [LayoutPage], width: Double, options: LayoutOptions, omittedLines: Int }

/// Places an export's rows the way the sheet reads: source on the left, results right-aligned in one column, worksheet cells on column stops,
/// figures under their line. Text measurement is supplied by the renderer so positions match its font exactly. Widths are additive per word,
/// which keeps very long lines linear in their length.
enum SheetLayoutComposer {
    typealias Measure = (String, LayoutStyle) -> Double
    private struct Row { var runs: [LayoutRun]; let height: Double; var figure: LayoutFigure? }

    static func compose(_ export: SheetExport, _ options: LayoutOptions, _ measure: @escaping Measure) throws -> SheetLayout {
        if !(options.width > options.margin * 2 + 40) || !(options.lineHeight > 0) || !(options.pageHeight > options.margin * 2 + options.lineHeight) && !options.continuous {
            throw CalcError.argument("Invalid export geometry")
        }
        let content = options.width - options.margin * 2
        let left = options.margin, right = options.margin + content
        let clamped: Measure = { text, style in text.isEmpty ? 0 : max(0, measure(text, style)) }
        let calculated = export.lines.filter { $0.kind == .result || $0.kind == .error }
        let resultColumn = min(content * 0.45, calculated.map { clamped($0.result, style($0)) }.max() ?? 0)
        let sourceWidth = resultColumn > 0 ? content - resultColumn - options.columnGap : content
        let stops = tableStops(export, measure, options.columnGap, sourceWidth)

        var pages: [LayoutPage] = [], runs: [LayoutRun] = [], figures: [LayoutFigure] = []
        var top = options.margin, omitted = 0
        let bottom = options.continuous ? options.maxHeight - options.margin : options.pageHeight - options.margin
        func newPage() throws {
            pages.append(LayoutPage(number: pages.count + 1, runs: runs, figures: figures, height: options.continuous ? top + options.margin : options.pageHeight))
            if pages.count >= options.maxPages { throw CalcError.argument("Export exceeds the page limit") }
            runs = []; figures = []; top = options.margin
        }
        func place(_ row: Row) {
            for var run in row.runs { run.top = top + run.top; runs.append(run) }
            if var figure = row.figure { figure.top = top + figure.top; figures.append(figure) }
            top += row.height
        }
        for (index, line) in export.lines.enumerated() {
            let rows = self.rows(line, stops[index], options, content, sourceWidth, resultColumn, left, right, clamped)
            let height = rows.reduce(0) { $0 + $1.height }
            if options.continuous {
                if top + height > bottom && top > options.margin { omitted = export.lines.count - index; break }
                rows.forEach(place); continue
            }
            if top + height > bottom && top > options.margin && height <= bottom - options.margin { try newPage() }
            for row in rows {
                if top + row.height > bottom && top > options.margin { try newPage() }
                place(row)
            }
        }
        pages.append(LayoutPage(number: pages.count + 1, runs: runs, figures: figures, height: options.continuous ? top + options.margin : options.pageHeight))
        return SheetLayout(pages: pages, width: options.width, options: options, omittedLines: omitted)
    }

    private static func style(_ line: ExportLine) -> LayoutStyle { line.kind == .error ? .error : line.isTotal ? .total : .result }

    private static func rows(_ line: ExportLine, _ stops: [Double]?, _ options: LayoutOptions, _ content: Double, _ sourceWidth: Double, _ resultColumn: Double,
                             _ left: Double, _ right: Double, _ measure: Measure) -> [Row] {
        var rows: [Row] = []
        let lineHeight = options.lineHeight
        switch line.kind {
        case .blank: rows.append(Row(runs: [], height: lineHeight))
        case .heading,
             .text where stops == nil:
            let style: LayoutStyle = line.kind == .heading ? .heading : .source
            for text in wrap(line.source.netReplace("\t", " "), content, style, measure) {
                rows.append(Row(runs: [LayoutRun(x: left, top: 0, text: text, style: style, line: line.number)], height: lineHeight))
            }
        default:
            var sourceRuns: [LayoutRun] = []
            if let stops {
                let cells = line.source.netSplit("\t")
                for (i, cell) in cells.enumerated() where !cell.netTrim.isEmpty {
                    sourceRuns.append(LayoutRun(x: left + stops[i], top: 0, text: cell.netTrim, style: .source, line: line.number))
                }
            } else {
                sourceRuns = wrap(line.source.netReplace("\t", " "), sourceWidth, .source, measure).enumerated()
                    .map { LayoutRun(x: left, top: Double($0.offset) * lineHeight, text: $0.element, style: .source, line: line.number) }
            }
            let resultStyle = style(line)
            let results = line.result.isEmpty ? [] : wrap(line.result, max(resultColumn, 1), resultStyle, measure).enumerated()
                .map { LayoutRun(x: right - measure($0.element, resultStyle), top: Double($0.offset) * lineHeight, text: $0.element, style: resultStyle, line: line.number) }
            let count = max(1, max(stops != nil ? 1 : sourceRuns.count, results.count))
            for i in 0..<count {
                let rowTop = Double(i) * lineHeight
                let rowRuns = (sourceRuns.filter { stops != nil ? i == 0 : $0.top == rowTop } + results.filter { $0.top == rowTop }).map { run -> LayoutRun in
                    var copy = run; copy.top = 0; return copy
                }
                rows.append(Row(runs: rowRuns, height: lineHeight))
            }
            if let figure = line.figure {
                rows.append(Row(runs: [], height: options.figureHeight + options.figureGap,
                                figure: LayoutFigure(x: left, top: 0, width: content, height: options.figureHeight, line: line.number, value: figure)))
            }
        }
        return rows
    }

    /// Column stops for each run of consecutive tab-separated rows, measured from their own cells. A run too wide for the source column wraps as text instead.
    private static func tableStops(_ export: SheetExport, _ measure: Measure, _ gap: Double, _ width: Double) -> [Int: [Double]] {
        var stops: [Int: [Double]] = [:]
        var start = 0
        let lines = export.lines
        while start < lines.count {
            if !lines[start].isTableRow || lines[start].kind == .heading { start += 1; continue }
            var end = start
            while end < lines.count && lines[end].isTableRow && lines[end].kind != .heading { end += 1 }
            var widths: [Double] = []
            for i in start..<end {
                for (c, cell) in lines[i].source.netSplit("\t").enumerated() {
                    let w = cell.netTrim.isEmpty ? 0 : measure(cell.netTrim, .source)
                    if c == widths.count { widths.append(w) } else { widths[c] = max(widths[c], w) }
                }
            }
            var positions: [Double] = [], x = 0.0
            for w in widths { positions.append(x); x += w + gap }
            if x - gap <= width { for i in start..<end { stops[i] = positions } }
            start = end
        }
        return stops
    }

    /// Greedy word wrap that keeps leading indentation. Words wider than the line break between text elements (grapheme clusters),
    /// never inside a surrogate pair or combining sequence.
    static func wrap(_ text: String, _ width: Double, _ style: LayoutStyle, _ measure: Measure) -> [String] {
        if text.isEmpty { return [""] }
        var lines: [String] = [], current = "", used = 0.0, content = false
        func push() { lines.append(current.netTrimEnd); current = ""; used = 0; content = false }
        func append(_ part: String, _ w: Double) { current += part; used += w; content = content || !part.netTrim.isEmpty }
        for whole in tokens(text) {
            var token = whole, w = measure(token, style)
            if used + w <= width { append(token, w); continue }
            if content {
                push(); token = token.netTrimStart; w = measure(token, style)
                if w <= width { append(token, w); continue }
            }
            for character in token {
                let element = String(character), ew = measure(element, style)
                if used + ew > width && content { push(); if element.netTrim.isEmpty { continue } }
                append(element, ew)
            }
        }
        if !current.isEmpty || lines.isEmpty { push() }
        return lines
    }

    // Each token is a word with the spaces before it, so indentation stays attached to the first word.
    private static func tokens(_ text: String) -> [String] {
        let u = Array(text.utf16)
        var result: [String] = [], start = 0
        for i in u.indices where u[i] == 0x20 && i != start && u[i - 1] != 0x20 {
            result.append(String(units: u[start..<i])); start = i
        }
        if start < u.count { result.append(String(units: u[start...])) }
        return result
    }
}
