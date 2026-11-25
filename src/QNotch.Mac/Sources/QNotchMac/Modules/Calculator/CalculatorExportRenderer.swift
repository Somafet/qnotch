import AppKit
import CalculatorEngine

/// Draws an export's page layout (Windows ExportRenderer) with AppKit: PNG images, PDF pages and printed pages all come from the
/// engine's SheetLayout, so every format places the same rows. Work happens on demand on the main thread; nothing is kept.
enum CalculatorExportRenderer {
    struct Theme {
        var fontSize: CGFloat
        var lineHeight: CGFloat
        var background: NSColor
        var source: NSColor
        var result: NSColor
        var error: NSColor
        var accent: NSColor
        var divider: NSColor

        /// The sheet's own colours (images).
        static func sheet(fontSize: CGFloat) -> Theme {
            Theme(fontSize: fontSize, lineHeight: (fontSize * SheetTextView.lineSpacing).rounded(), background: Palette.card, source: Palette.textPrimary,
                  result: Palette.accent, error: Palette.textSecondary, accent: Palette.accent, divider: Palette.stroke)
        }
        /// Ink on paper (PDF and print): the Windows PDF colours.
        static func paper(fontSize: CGFloat, lineHeight: CGFloat) -> Theme {
            Theme(fontSize: fontSize, lineHeight: lineHeight, background: .white, source: Palette.rgb(0x2B2D2A), result: Palette.rgb(0x06717D),
                  error: Palette.rgb(0x696C67), accent: Palette.rgb(0x06717D), divider: Palette.rgb(0xD5D7D3))
        }
    }

    /// One image's pixel budget (Windows MaxImagePixels): a large sheet renders at a lower scale before rows are left out.
    static let maxImagePixels: CGFloat = 24_000_000
    static let maxImageHeight: Double = 12_000

    static func font(_ style: CalculatorExportLayout.Style, _ theme: Theme) -> NSFont {
        let size = style == .heading ? theme.fontSize * CGFloat(CalculatorExportLayout.headingScale) : theme.fontSize
        return style.isBold ? .monospacedDigitSystemFont(ofSize: size, weight: .semibold) : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private static func ink(_ style: CalculatorExportLayout.Style, _ theme: Theme) -> NSColor {
        switch style {
        case .source, .heading: theme.source
        case .result, .total: theme.result
        case .error: theme.error
        }
    }

    static func measure(_ theme: Theme) -> (String, CalculatorExportLayout.Style) -> Double {
        { text, style in Double((text as NSString).size(withAttributes: [.font: font(style, theme)]).width) }
    }

    /// Draws one page into the current (flipped) graphics context.
    static func draw(_ page: CalculatorExportLayout.Page, layout: CalculatorExportLayout, theme: Theme, opaque: Bool) {
        if opaque {
            theme.background.setFill()
            NSRect(x: 0, y: 0, width: layout.width, height: page.height).fill()
        }
        for run in page.runs {
            let font = font(run.style, theme)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink(run.style, theme)]
            let height = font.ascender - font.descender
            (run.text as NSString).draw(at: NSPoint(x: CGFloat(run.x), y: CGFloat(run.top) + (theme.lineHeight - height) / 2), withAttributes: attributes)
        }
        for figure in page.figures { drawFigure(figure, theme: theme) }
    }

    /// Plots as their curve, charts as bars or a trend line, inside a hairline frame.
    private static func drawFigure(_ item: CalculatorExportLayout.Figure, theme: Theme) {
        let box = NSRect(x: item.x, y: item.top, width: item.width, height: item.height)
        theme.divider.setStroke()
        let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        frame.lineWidth = 1
        frame.stroke()
        let inner = box.insetBy(dx: 10, dy: 10)
        theme.accent.setStroke()
        theme.accent.setFill()
        switch item.figure {
        case .plot(let plot):
            let width = plot.upper - plot.lower, height = plot.yUpper - plot.yLower
            guard width > 0, height > 0 else { return }
            for segment in plot.segments {
                let path = NSBezierPath()
                for i in segment {
                    let point = NSPoint(x: inner.minX + (plot.x[i] - plot.lower) / width * inner.width, y: inner.maxY - (plot.y[i] - plot.yLower) / height * inner.height)
                    if i == segment.lowerBound { path.move(to: point) } else { path.line(to: point) }
                }
                path.lineWidth = 1.5
                path.stroke()
            }
        case .chart(let chart):
            let items = chart.items.prefix(64)
            guard let top = items.map({ abs($0.magnitude) }).max(), top > 0, !items.isEmpty else { return }
            if chart.kind == .trend {
                let path = NSBezierPath()
                for (index, entry) in items.enumerated() {
                    let x = inner.minX + (items.count == 1 ? inner.width / 2 : CGFloat(index) / CGFloat(items.count - 1) * inner.width)
                    let point = NSPoint(x: x, y: inner.maxY - abs(entry.magnitude) / top * inner.height)
                    if index == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                path.lineWidth = 1.5
                path.stroke()
            } else {
                let slot = inner.width / CGFloat(items.count)
                for (index, entry) in items.enumerated() {
                    let height = abs(entry.magnitude) / top * inner.height
                    NSBezierPath(roundedRect: NSRect(x: inner.minX + CGFloat(index) * slot + slot * 0.15, y: inner.maxY - height, width: slot * 0.7, height: height),
                                 xRadius: 2, yRadius: 2).fill()
                }
            }
        case .table, nil:
            break
        }
    }

    // MARK: Images

    /// One continuous image of the sheet: PNG data and the lines left out past the height limit.
    static func png(_ export: CalculatorExport, width: CGFloat, theme: Theme, transparent: Bool) throws -> (data: Data, image: NSImage, omitted: Int) {
        let layout = try export.layout(width: Double(width), pageHeight: .infinity, margin: 28, lineHeight: Double(theme.lineHeight),
                                       maxHeight: maxImageHeight, measure: measure(theme))
        let page = layout.pages[0]
        let scale = min(2, sqrt(maxImagePixels / (width * CGFloat(page.height))))
        let pixelsWide = Int(ceil(width * scale)), pixelsHigh = Int(ceil(CGFloat(page.height) * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CalculatorDocumentsErrorMessage(CalculatorText.exportFailed) }
        bitmap.size = NSSize(width: width, height: CGFloat(page.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        draw(page, layout: layout, theme: theme, opaque: !transparent)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CalculatorDocumentsErrorMessage(CalculatorText.exportFailed) }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return (data, image, layout.omittedLines)
    }

    // MARK: PDF and print

    /// A4, or US Letter where that is the regional paper size (Windows Pdf).
    static var paperSize: NSSize {
        let letter = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "CR", "PR"].contains(Locale.current.region?.identifier ?? "")
        return letter ? NSSize(width: 612, height: 792) : NSSize(width: 595.276, height: 841.89)
    }

    /// The sheet as PDF pages with the system fonts embedded by Core Graphics.
    static func pdf(_ export: CalculatorExport) throws -> Data {
        let theme = Theme.paper(fontSize: 10.5, lineHeight: 16)
        let paper = paperSize
        let layout = try export.layout(width: Double(paper.width), pageHeight: Double(paper.height), margin: 54, lineHeight: 16, figureHeight: 96, figureGap: 8,
                                       columnGap: 18, measure: measure(theme))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: export.title, kCGPDFContextCreator as String: "QNotch"] as CFDictionary)
        else { throw CalculatorDocumentsErrorMessage(CalculatorText.exportFailed) }
        for page in layout.pages {
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(page, layout: layout, theme: theme, opaque: false)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Pages for printing, laid out for the printer's paper (Windows Paginator: 14-point text on 22-point lines, 48-point margins).
    final class PrintView: NSView {
        private let layout: CalculatorExportLayout
        private let theme = Theme.paper(fontSize: 12, lineHeight: 19)

        init(_ export: CalculatorExport, paper: NSSize) throws {
            layout = try export.layout(width: Double(paper.width), pageHeight: Double(paper.height), margin: 48, lineHeight: 19, figureHeight: 128,
                                       measure: CalculatorExportRenderer.measure(theme))
            super.init(frame: NSRect(x: 0, y: 0, width: paper.width, height: paper.height * CGFloat(max(1, layout.pages.count))))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        var pageCount: Int { layout.pages.count }
        private var pageHeight: CGFloat { bounds.height / CGFloat(max(1, layout.pages.count)) }

        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            range.pointee = NSRange(location: 1, length: layout.pages.count)
            return true
        }
        override func rectForPage(_ page: Int) -> NSRect { NSRect(x: 0, y: CGFloat(page - 1) * pageHeight, width: bounds.width, height: pageHeight) }

        override func draw(_ dirtyRect: NSRect) {
            for (index, page) in layout.pages.enumerated() {
                let origin = CGFloat(index) * pageHeight
                guard dirtyRect.intersects(NSRect(x: 0, y: origin, width: bounds.width, height: pageHeight)) else { continue }
                NSGraphicsContext.saveGraphicsState()
                let shift = NSAffineTransform()
                shift.translateX(by: 0, yBy: origin)
                shift.concat()
                CalculatorExportRenderer.draw(page, layout: layout, theme: theme, opaque: false)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
