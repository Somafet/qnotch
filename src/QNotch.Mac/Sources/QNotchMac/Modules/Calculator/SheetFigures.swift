import AppKit
import CalculatorEngine

/// One inline plot or chart under its line (Windows FigureView). Drawn once per value, size or accent change into its
/// layer: scrolling moves the layer and never redraws it. There is no timer, animation or background work. Pointer
/// events pass through to the sheet; VoiceOver reads it as an image with the engine's description and details.
final class FigureView: NSView {
    private static let labelSize: CGFloat = 11, labelRow: CGFloat = 16, valueRow: CGFloat = 16
    private static let maxBar: CGFloat = 24, maxSlot: CGFloat = 72, barRadius: CGFloat = 4
    private static let maxSlices = 8, legendRows = 7

    private(set) var figure: CalculatorFigure?
    /// Draw passes so far (tests check that moving a figure does not redraw it).
    private(set) var renderCount = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        identifier = NSUserInterfaceItemIdentifier("calculator-figure")
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ next: CalculatorFigure) {
        guard next != figure else { return }
        figure = next
        needsDisplay = true
        setAccessibilityLabel(next.accessibilityDescription)
        setAccessibilityHelp(next.details)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Colours (Windows: accent ink, warning accent, secondary text, stroke rules)

    private var ink: NSColor { Palette.accent }
    private var second: NSColor { .systemOrange }
    private var muted: NSColor { Palette.textSecondary }
    private var rule: NSColor { CalculatorContrast.stroke }

    private func series(_ index: Int) -> NSColor {
        let source = [ink, second, muted][index % 3]
        let strength: CGFloat = [1, 0.55, 0.3][min(index / 3, 2)]
        return strength == 1 ? source : source.withAlphaComponent(strength)
    }

    // MARK: Text

    private static let font = NSFont.systemFont(ofSize: labelSize)
    private static var textHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
    }

    /// One line of muted text, cut with an ellipsis past `limit`.
    private func draw(_ text: String, at point: NSPoint, limit: CGFloat = .greatestFiniteMagnitude, color: NSColor? = nil) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color ?? muted, .paragraphStyle: style]
        let shown = max(1, min(width(text), limit))
        (text as NSString).draw(with: NSRect(x: point.x, y: point.y, width: shown, height: Self.textHeight),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        renderCount += 1
        guard let figure, bounds.width >= 80, bounds.height >= 40 else { return }
        switch figure {
        case .plot(let plot): drawPlot(plot)
        case .chart(let chart):
            guard !chart.items.isEmpty else { return }
            switch chart.kind {
            case .bar: drawBars(chart)
            case .pie: drawPie(chart)
            case .trend: drawTrend(chart)
            }
        case .table: break
        }
    }

    /// A plot area with its extremes in muted text: the value range at the left, the position range underneath.
    private func frame(high: String, low: String, start: String, end: String) -> NSRect {
        let left = max(width(high), width(low)) + 8
        let area = NSRect(x: left, y: 4, width: max(1, bounds.width - left - 2), height: bounds.height - Self.labelRow - 4)
        draw(high, at: NSPoint(x: left - 8 - width(high), y: area.minY - 2))
        draw(low, at: NSPoint(x: left - 8 - width(low), y: area.maxY - Self.textHeight + 2))
        let half = area.width / 2 - 4
        draw(start, at: NSPoint(x: area.minX, y: area.maxY + 3), limit: half)
        draw(end, at: NSPoint(x: area.maxX - min(width(end), half), y: area.maxY + 3), limit: half)
        return area
    }

    private func linePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        return path
    }

    private func dot(_ center: NSPoint, radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }

    private func horizontalRule(at y: CGFloat, from left: CGFloat, to right: CGFloat) {
        rule.setFill()
        NSRect(x: left, y: y, width: right - left, height: 1).fill()
    }

    private func drawPlot(_ plot: CalculatorPlot) {
        guard plot.upper > plot.lower, plot.yUpper > plot.yLower else { return }
        let area = frame(high: CalculatorPlot.number(plot.yUpper), low: CalculatorPlot.number(plot.yLower),
                         start: CalculatorPlot.number(plot.lower), end: CalculatorPlot.number(plot.upper))
        func x(_ value: Double) -> CGFloat { area.minX + CGFloat((value - plot.lower) / (plot.upper - plot.lower)) * area.width }
        func y(_ value: Double) -> CGFloat { area.maxY - CGFloat((value - plot.yLower) / (plot.yUpper - plot.yLower)) * area.height }
        if plot.yLower < 0, plot.yUpper > 0 { horizontalRule(at: y(0).rounded(), from: area.minX, to: area.maxX) }
        let upper = area.minY - 2, lower = area.maxY + 2
        let xs = plot.x, ys = plot.y
        let curve = linePath()
        for segment in plot.segments where !segment.isEmpty {
            let first = segment.lowerBound, last = segment.upperBound - 1
            if first == last {
                let point = NSPoint(x: x(xs[first]), y: y(ys[first]))
                if point.y >= upper, point.y <= lower { dot(point, radius: 1.5, ink) }
                continue
            }
            var open = false
            var reached = NSPoint.zero
            for index in (first + 1)...last {
                let a = NSPoint(x: x(xs[index - 1]), y: y(ys[index - 1])), b = NSPoint(x: x(xs[index]), y: y(ys[index]))
                // Each step is cut at the band, so a pole's huge values never reach the renderer and the visible slope stays true.
                if a.y < upper && b.y < upper || a.y > lower && b.y > lower { open = false; continue }
                func cut(_ from: NSPoint, _ to: NSPoint) -> NSPoint {
                    if from.y >= upper && from.y <= lower { return from }
                    let edge = from.y < upper ? upper : lower
                    return NSPoint(x: from.x + (to.x - from.x) * (edge - from.y) / (to.y - from.y), y: edge)
                }
                let start = cut(a, b), end = cut(b, a)
                if !open || start != reached { curve.move(to: start); open = true }
                curve.line(to: end)
                reached = end
            }
        }
        ink.setStroke()
        curve.stroke()
    }

    private func drawTrend(_ chart: CalculatorChart) {
        let items = chart.items
        guard let low = items.min(by: { $0.magnitude < $1.magnitude }), let high = items.max(by: { $0.magnitude < $1.magnitude }) else { return }
        var area = frame(high: high.display, low: low.display, start: items[0].label, end: items[items.count - 1].label)
        let span = high.magnitude > low.magnitude ? high.magnitude - low.magnitude : 1
        area.size.width = max(1, area.width - 6)
        func at(_ index: Int) -> NSPoint {
            let step = items.count > 1 ? area.width / CGFloat(items.count - 1) : 0
            return NSPoint(x: area.minX + CGFloat(index) * step, y: area.maxY - CGFloat((items[index].magnitude - low.magnitude) / span) * area.height)
        }
        let line = linePath()
        line.move(to: at(0))
        for index in items.indices.dropFirst() { line.line(to: at(index)) }
        ink.setStroke()
        line.stroke()
        dot(at(items.count - 1), radius: 3.5, ink)
    }

    private func drawBars(_ chart: CalculatorChart) {
        let items = chart.items
        let low = min(0, items.map(\.magnitude).min() ?? 0), high = max(0, items.map(\.magnitude).max() ?? 0)
        let span = high > low ? high - low : 1
        let slot = min(bounds.width / CGFloat(items.count), Self.maxSlot)
        let bar = min(max(slot * 0.6, 2), Self.maxBar)
        // Negative bars keep a value row below them too, so their amounts never meet the label row.
        let top = Self.valueRow, bottom = bounds.height - Self.labelRow - (low < 0 ? Self.valueRow : 0)
        let zero = (bottom - CGFloat((0 - low) / span) * (bottom - top)).rounded()
        let labelled = slot >= 28
        for (index, item) in items.enumerated() {
            let center = slot * (CGFloat(index) + 0.5)
            let height = CGFloat(abs(item.magnitude) / span) * (bottom - top)
            if height >= 0.5 { fillBar(left: center - bar / 2, zero: zero, width: bar, height: height, up: item.magnitude >= 0) }
            guard labelled else { continue }
            draw(item.label, at: NSPoint(x: center - min(width(item.label), slot - 4) / 2, y: bounds.height - Self.labelRow + 3), limit: slot - 4)
            let amount = width(item.display)
            if amount <= slot - 4 {
                let y = item.magnitude >= 0 ? zero - height - Self.textHeight - 1 : zero + height + 1
                draw(item.display, at: NSPoint(x: center - amount / 2, y: y))
            }
        }
        if !labelled, let largest = items.max(by: { abs($0.magnitude) < abs($1.magnitude) }) {
            // Too narrow for every label: the largest magnitude above, the first and last labels below.
            draw(largest.display, at: .zero, limit: bounds.width)
            let half = bounds.width / 2 - 4
            draw(items[0].label, at: NSPoint(x: 0, y: bounds.height - Self.labelRow + 3), limit: half)
            let last = items[items.count - 1].label
            draw(last, at: NSPoint(x: slot * CGFloat(items.count) - min(width(last), half), y: bounds.height - Self.labelRow + 3), limit: half)
        }
        horizontalRule(at: zero, from: 0, to: slot * CGFloat(items.count))
    }

    /// Rounded at the data end, square at the baseline.
    private func fillBar(left: CGFloat, zero: CGFloat, width: CGFloat, height: CGFloat, up: Bool) {
        let radius = min(Self.barRadius, min(width / 2, height))
        let rect = NSRect(x: left, y: up ? zero - height : zero, width: width, height: height)
        ink.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSRect(x: left, y: up ? zero - radius : zero, width: width, height: radius).fill()
    }

    private func drawPie(_ chart: CalculatorChart) {
        let total = chart.items.reduce(0) { $0 + $1.magnitude }
        guard total > 0 else { return }
        // Beyond eight slices hues stop being distinguishable: the smallest fold into Other, in the legend as well as the pie.
        var slices = chart.items.filter { $0.magnitude > 0 }.map { (label: $0.label, magnitude: $0.magnitude) }
        if slices.count > Self.maxSlices {
            let kept = Set(slices.indices.sorted { slices[$0].magnitude > slices[$1].magnitude }.prefix(Self.maxSlices - 1))
            let other = slices.indices.filter { !kept.contains($0) }.reduce(0) { $0 + slices[$1].magnitude }
            slices = slices.indices.filter(kept.contains).map { slices[$0] } + [(label: CalculatorText.other, magnitude: other)]
        }
        let radius = (bounds.height - 4) / 2
        let center = NSPoint(x: radius + 2, y: bounds.height / 2)
        var angle = -Double.pi / 2
        for (index, slice) in slices.enumerated() {
            let sweep = slice.magnitude / total * 2 * .pi
            let middle = angle + sweep / 2
            series(index).setFill()
            if slices.count == 1 {
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            } else {
                // Each slice steps out along its own bisector, which leaves an even gap with no surface colour to match.
                let origin = NSPoint(x: center.x + CGFloat(cos(middle)), y: center.y + CGFloat(sin(middle)))
                let path = NSBezierPath()
                path.move(to: origin)
                let steps = max(2, Int(sweep / (Double.pi / 90)))
                for step in 0...steps {
                    let at = angle + sweep * Double(step) / Double(steps)
                    path.line(to: NSPoint(x: origin.x + radius * CGFloat(cos(at)), y: origin.y + radius * CGFloat(sin(at))))
                }
                path.close()
                path.fill()
            }
            angle += sweep
        }
        let left = center.x + radius + 20, room = bounds.width - left
        guard room >= 60 else { return }
        let rows = min(slices.count, Self.legendRows)
        var y = max(0, (bounds.height - CGFloat(rows) * Self.labelRow) / 2)
        for index in 0..<rows {
            let more = index == Self.legendRows - 1 && slices.count > Self.legendRows
            if !more { dot(NSPoint(x: left + 4, y: y + Self.labelRow / 2), radius: 4, series(index)) }
            let share = Int((slices[index].magnitude / total * 100).rounded())
            let text = more ? CalculatorText.moreSlices(slices.count - index) : "\(slices[index].label)  \(share)%"
            draw(text, at: NSPoint(x: left + 14, y: y + (Self.labelRow - Self.textHeight) / 2), limit: room - 16)
            y += Self.labelRow
        }
    }
}
