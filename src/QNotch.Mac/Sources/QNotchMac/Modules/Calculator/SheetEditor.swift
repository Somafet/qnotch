import AppKit
import CalculatorEngine

/// What the sheet editor asks of its page.
protocol SheetEditorHost: AnyObject {
    /// Escape: an open overlay closes; false lets the panel close.
    func editorEscape() -> Bool
    func editorCycleSheet(_ direction: Int)
    func editorRename()
    func editorFocusResult()
    func editorTextChanged(_ editor: SheetTextView)
    /// Before a change of `range`: true starts a new undo step for it (it moves lines holding UUIDs or rolls).
    func editorWillChange(_ editor: SheetTextView, range: NSRange) -> Bool
    /// A dice line was submitted: Return on it (`again` false) or ⌘Return (`again` true). Zero-based line.
    func editorRoll(_ editor: SheetTextView, line: Int, again: Bool)
    /// Marked text was committed or dropped without changing the string, so no text change reports the end of composition.
    func editorCompositionEnded(_ editor: SheetTextView)
}

extension SheetEditorHost {
    func editorWillChange(_ editor: SheetTextView, range: NSRange) -> Bool { false }
    func editorRoll(_ editor: SheetTextView, line: Int, again: Bool) {}
    func editorCompositionEnded(_ editor: SheetTextView) {}
}

extension NSAttributedString.Key {
    /// A line's worksheet layout (figure room, table columns). Display only: the source never holds it.
    static let calculatorLayout = NSAttributedString.Key("dev.qnotch.calculator.layout")
}

/// What a line draws besides its text (Windows SheetFigures and TableColumns): room for a figure under it, or a
/// table's column stops measured from its own cells. Kept as a text attribute so it moves with its line while an
/// edit is still being evaluated, as Windows anchors it to the document line.
final class SheetLineLayout: NSObject {
    let figure: Bool
    /// Column starts from the line's left edge; the first is 0.
    let stops: [CGFloat]
    init(figure: Bool = false, stops: [CGFloat] = []) {
        self.figure = figure
        self.stops = stops
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SheetLineLayout else { return false }
        return figure == other.figure && stops == other.stops
    }
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(figure)
        hasher.combine(stops)
        return hasher.finalize()
    }
}

/// Selection highlights skip a figure's room, so a selection stays on the source text (Windows clips its selection layer).
final class SheetLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let view = firstTextView as? SheetTextView, case let rooms = view.figureRooms(in: charRange), !rooms.isEmpty else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: view.bounds.insetBy(dx: -1, dy: -1))
        // One extra point, so a fractional row edge cannot leave an antialiased line of selection.
        for room in rooms { clip.appendRect(NSRect(x: room.minX - 1, y: room.minY, width: room.width + 2, height: room.height + 1)) }
        clip.windingRule = .evenOdd
        clip.addClip()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The sheet's native text view (Windows SheetEditor over AvalonEdit): plain text with IME, its own undo stack,
/// find, VoiceOver and no automatic substitutions or spelling. Text wraps before the results column, which
/// the page draws beside it. TextKit 1, so line geometry is exact and cheap.
final class SheetTextView: NSTextView, NSTextViewDelegate, NSTextStorageDelegate, NSLayoutManagerDelegate {
    static let lineSpacing: CGFloat = 1.6
    static let headingScale: CGFloat = 1.25
    /// A plot or chart's height and the gap under it (Windows SheetFigures).
    static let figureHeight: CGFloat = 120
    static let figureGap: CGFloat = 10
    static var figureSpace: CGFloat { figureHeight + figureGap }
    /// Space between table columns, and the least a long cell leaves (Windows TableColumns).
    static let columnGap: CGFloat = 24
    static let measuredTableRows = 128
    /// Marks a whole-line copy on the pasteboard (Windows MSDEVLineSelect).
    static let wholeLineType = NSPasteboard.PasteboardType("dev.qnotch.calculator.whole-line")
    /// The last whole line copied from any sheet: clipboard tools that drop the marker still paste it as a line.
    private static var lastWholeLine: String?

    weak var host: SheetEditorHost?

    override func unmarkText() {
        let composing = hasMarkedText()
        super.unmarkText()
        if composing, !hasMarkedText() { host?.editorCompositionEnded(self) }
    }
    let sheetID: UUID
    let ownUndo = UndoManager()
    /// Width kept free on the right for the results column.
    var reserved: CGFloat = 220 { didSet { if oldValue != reserved { updateContainer() } } }
    var fontSize: CGFloat { didSet { if oldValue != fontSize { restyle(NSRange(location: 0, length: textStorage?.length ?? 0)) } } }
    /// The change being made (range of the old text, inserted length) until the host takes it in `editorTextChanged`.
    private(set) var pendingChange: (range: NSRange, length: Int)?
    /// UTF-16 offsets of each line start; rebuilt on every change.
    private(set) var lineStarts: [Int] = [0]

    init(sheetID: UUID, text: String, fontSize: CGFloat) {
        self.sheetID = sheetID
        self.fontSize = fontSize
        let storage = NSTextStorage()
        let layout = SheetLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = false
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        ownUndo.levelsOfUndo = 100
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        insertionPointColor = Palette.textPrimary
        selectedTextAttributes = [.backgroundColor: Palette.accent.withAlphaComponent(0.32)]
        textContainerInset = NSSize(width: 0, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = .width
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        delegate = self
        storage.delegate = self
        layout.delegate = self
        identifier = NSUserInterfaceItemIdentifier("calculator-sheet")
        setAccessibilityLabel(CalculatorText.sheetExpressions)
        typingAttributes = baseAttributes(heading: false)
        string = text
        restyle(NSRange(location: 0, length: storage.length))
        rebuildLineStarts()
        ownUndo.removeAllActions()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Geometry

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // The view sizes itself to the text's used area, which leaves out a last-line figure's room.
        if isVerticallyResizable, let bottom = lastLineFigureBottom { size.height = max(size.height, bottom) }
        super.setFrameSize(size)
        updateContainer()
    }

    /// True when the last line holds a figure and no line break follows it.
    private var lastLineHoldsFigure: Bool {
        guard let storage = textStorage, storage.length > 0, (storage.string as NSString).character(at: storage.length - 1) != 0x0A else { return false }
        return (storage.attribute(.calculatorLayout, at: storage.length - 1, effectiveRange: nil) as? SheetLineLayout)?.figure == true
    }

    private var lastLineFigureBottom: CGFloat? {
        guard lastLineHoldsFigure, let layoutManager, layoutManager.numberOfGlyphs > 0 else { return nil }
        let rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil, withoutAdditionalLayout: true)
        return rect.height > 0 ? rect.maxY + textContainerOrigin.y + textContainerInset.height : nil
    }

    /// TextKit adds no paragraph spacing after the last paragraph, so a figure on the last line grows its row here instead.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, NSMaxRange(glyphRange) == layoutManager.numberOfGlyphs, lastLineHoldsFigure else { return false }
        lineFragmentRect.pointee.size.height += Self.figureSpace
        return true
    }

    private func updateContainer() {
        let width = max(40, bounds.width - reserved)
        guard let textContainer, abs(textContainer.containerSize.width - width) > 0.5 else { return }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    private func rebuildLineStarts() {
        let text = string.utf16
        var starts = [0]
        starts.reserveCapacity(64)
        var offset = 0, previous: UInt16 = 0
        // Line breaks as the engine's SourceLineMap counts them: CRLF, CR or LF (sheets written on Windows can hold CRLF).
        for unit in text {
            offset += 1
            if unit == 0x0A && previous == 0x0D { starts[starts.count - 1] = offset }
            else if unit == 0x0A || unit == 0x0D { starts.append(offset) }
            previous = unit
        }
        lineStarts = starts
    }

    /// Line breaks in `text`, counted as the line index counts them (CRLF, CR or LF).
    static func lineBreaks(_ text: String) -> Int {
        var breaks = 0, previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 0x0D || (unit == 0x0A && previous != 0x0D) { breaks += 1 }
            previous = unit
        }
        return breaks
    }

    /// The UTF-16 offset where the line's text ends, before its line break (one or two units).
    func contentEnd(ofLine index: Int) -> Int {
        // The storage's own string: bridging `string` per call could copy the whole sheet once per line in the restyle loops.
        guard let text = textStorage?.mutableString else { return lineStarts[index] }
        let start = lineStarts[index]
        var end = index + 1 < lineStarts.count ? lineStarts[index + 1] : text.length
        while end > start, text.character(at: end - 1) == 0x0A || text.character(at: end - 1) == 0x0D { end -= 1 }
        return end
    }

    /// The zero-based line holding the UTF-16 offset.
    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The first visual row of a logical line, in this view's (flipped) coordinates.
    func rowRect(ofLine index: Int) -> NSRect? {
        guard let layoutManager, let textContainer, lineStarts.indices.contains(index) else { return nil }
        let length = textStorage?.length ?? 0
        let start = lineStarts[index]
        if start >= length {
            // The empty last line after a final newline.
            guard start == length, length > 0 else { return start == 0 ? NSRect(x: 0, y: textContainerOrigin.y, width: 1, height: emptyLineHeight) : nil }
            let extra = layoutManager.extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            return extra.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: start)
        var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // A figure's room hangs below its text: the row is the part the text uses.
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        if used.height > 0 { rect.size.height = min(rect.height, used.height) }
        _ = textContainer
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private var emptyLineHeight: CGFloat { (fontSize * Self.lineSpacing).rounded() }

    /// The lines with a row inside `rect` (view coordinates).
    func lines(in rect: NSRect) -> ClosedRange<Int>? {
        guard let layoutManager, let textContainer, (textStorage?.length ?? 0) > 0 else { return lineStarts.isEmpty ? nil : 0...0 }
        var area = rect
        area.origin.y -= textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = line(at: characters.location)
        let last = min(lineStarts.count - 1, line(at: max(characters.location, NSMaxRange(characters))) + 1)
        return max(0, first - 1)...max(first, last)
    }

    // MARK: Styling (display only: the source is never changed)

    private static let accents = try? NSRegularExpression(pattern:
        #"(?<comment>//.*$)|(?<quoted>"(?:\\.|[^"\\])*(?:"|$))|(?<tag>#[\p{L}_][\p{L}\p{M}\p{N}_]*)|(?<reference>\bL[1-9][0-9]*\b|\bprev\b)|(?<keyword>\b(?:in|to|until|sum|total|average)\b)|(?<operator>(?<=\s)[-+*/×÷^](?=\s))"#,
        options: [.caseInsensitive, .anchorsMatchLines])

    private func paragraphStyle(heading: Bool, layout: SheetLineLayout? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = (fontSize * (heading ? Self.headingScale : 1) * Self.lineSpacing).rounded()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineBreakMode = .byWordWrapping
        if let layout {
            if layout.figure { style.paragraphSpacing = Self.figureSpace }
            if layout.stops.count > 1 {
                style.tabStops = layout.stops.dropFirst().map { NSTextTab(textAlignment: .left, location: $0) }
                style.defaultTabInterval = Self.columnGap
            }
        }
        return style
    }

    private func font(heading: Bool) -> NSFont {
        heading ? .systemFont(ofSize: fontSize * Self.headingScale, weight: .semibold) : .systemFont(ofSize: fontSize)
    }

    /// The glyphs sit in the middle of the taller row rather than on its floor.
    private func baselineOffset(heading: Bool) -> CGFloat {
        let font = font(heading: heading)
        let natural = font.ascender - font.descender + font.leading
        let height = (fontSize * (heading ? Self.headingScale : 1) * Self.lineSpacing).rounded()
        return max(0, (height - natural) / 2).rounded()
    }

    private func baseAttributes(heading: Bool, layout: SheetLineLayout? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(heading: heading), .foregroundColor: Palette.textPrimary,
                                                         .paragraphStyle: paragraphStyle(heading: heading, layout: layout),
                                                         .baselineOffset: baselineOffset(heading: heading)]
        if let layout { attributes[.calculatorLayout] = layout }
        return attributes
    }

    /// The layout a line keeps through an edit: any of its characters but its line break (so a line split off the
    /// end of a figure line does not inherit its room).
    private func existingLayout(_ storage: NSTextStorage, _ lineRange: NSRange) -> SheetLineLayout? {
        guard lineRange.length > 0 else { return nil }
        var found: SheetLineLayout?
        storage.enumerateAttribute(.calculatorLayout, in: lineRange) { value, _, stop in
            if let value = value as? SheetLineLayout { found = value; stop.pointee = true }
        }
        return found
    }


    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        restyle(editedRange, batch: false)
    }

    /// Restyles the paragraphs touching `range`. Very long lines keep plain text: highlighting never dominates editing.
    private func restyle(_ range: NSRange, batch: Bool = true) {
        guard let storage = textStorage else { return }
        let full = storage.string
        let text = full as NSString
        let paragraphs = text.paragraphRange(for: NSRange(location: min(range.location, text.length), length: min(range.length, text.length - min(range.location, text.length))))
        if batch { storage.beginEditing() }
        text.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, lineRange, enclosing, _ in
            self.style(storage, full: full, lineRange: lineRange, enclosing: enclosing, layout: self.existingLayout(storage, lineRange))
        }
        if batch { storage.endEditing() }
    }

    /// Styles one line: its font, row height, accents and worksheet layout.
    private func style(_ storage: NSTextStorage, full: String, lineRange: NSRange, enclosing: NSRange, layout: SheetLineLayout?) {
        let text = full as NSString
        let line = text.substring(with: lineRange)
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let heading = trimmed.hasPrefix("# ")
        storage.setAttributes(self.baseAttributes(heading: heading, layout: heading ? nil : layout), range: enclosing)
        guard lineRange.length <= 4096 else { return }
        if heading {
            let marker = lineRange.location + (line.utf16.count - trimmed.utf16.count)
            storage.addAttribute(.foregroundColor, value: Palette.textSecondary, range: NSRange(location: marker, length: 1))
            return
        }
        for match in Self.accents?.matches(in: full, range: lineRange) ?? [] {
            let tag = match.range(withName: "tag")
            if tag.location != NSNotFound, Self.isColourLiteral(text.substring(with: tag)) { continue }
            let color: NSColor
            if match.range(withName: "comment").location != NSNotFound || match.range(withName: "operator").location != NSNotFound { color = Palette.textSecondary }
            else if tag.location != NSNotFound { color = .systemOrange }
            else if match.range(withName: "quoted").location != NSNotFound { color = Palette.textPrimary }
            else { color = Palette.accent }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    /// "#fff" and "#3cc8d9" are colours, not tags.
    static func isColourLiteral(_ tag: String) -> Bool {
        let digits = tag.dropFirst()
        return [3, 4, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
    }

    /// The accent changed: accents and figures follow it.
    func recolor() {
        selectedTextAttributes = [.backgroundColor: Palette.accent.withAlphaComponent(0.32)]
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
        for figure in subviews where figure is FigureView { figure.needsDisplay = true }
    }

    // MARK: Figures and table columns (Windows SheetFigures, TableColumns)

    /// Results arrived for exactly this text: figure lines get their room and table lines their columns. Only lines
    /// whose layout differs are restyled, so an unchanged sheet does no layout work.
    func showWorksheet(_ layouts: [Int: SheetLineLayout]) {
        guard let storage = textStorage else { return }
        var current: [Int: SheetLineLayout] = [:]
        storage.enumerateAttribute(.calculatorLayout, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let layout = value as? SheetLineLayout else { return }
            for index in line(at: range.location)...line(at: max(range.location, NSMaxRange(range) - 1)) { current[index] = layout }
        }
        let changed = Set(current.keys).union(layouts.keys).filter { current[$0] != layouts[$0] }.sorted()
        guard !changed.isEmpty else { return }
        let full = storage.string
        let text = full as NSString
        storage.beginEditing()
        for index in changed where lineStarts.indices.contains(index) {
            let start = lineStarts[index]
            let end = contentEnd(ofLine: index)
            guard start <= end, end <= text.length else { continue }
            let enclosing = NSRange(location: start, length: (index + 1 < lineStarts.count ? lineStarts[index + 1] : text.length) - start)
            style(storage, full: full, lineRange: NSRange(location: start, length: end - start), enclosing: enclosing, layout: layouts[index])
        }
        storage.endEditing()
        // A last-line figure's room is outside the used area the view sizes itself by.
        if changed.last == lineStarts.count - 1, let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
            sizeToFit()
        }
    }

    func layout(ofLine index: Int) -> SheetLineLayout? {
        guard lineStarts.indices.contains(index), let storage = textStorage, lineStarts[index] < storage.length else { return nil }
        return storage.attribute(.calculatorLayout, at: lineStarts[index], effectiveRange: nil) as? SheetLineLayout
    }

    /// The room under a figure line (its whole spacing band), in this view's coordinates.
    func figureRoom(ofLine index: Int) -> NSRect? {
        guard layout(ofLine: index)?.figure == true, let layoutManager, let length = textStorage?.length, length > 0 else { return nil }
        let end = contentEnd(ofLine: index)
        let character = min(max(lineStarts[index], end), length - 1)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: character), effectiveRange: nil)
        guard fragment.height > Self.figureSpace else { return nil }
        return NSRect(x: 0, y: fragment.maxY + textContainerOrigin.y - Self.figureSpace, width: bounds.width, height: Self.figureSpace)
    }

    /// The rooms of the figure lines inside a character range (for clipping selection).
    func figureRooms(in range: NSRange) -> [NSRect] {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        var rooms: [NSRect] = []
        storage.enumerateAttribute(.calculatorLayout, in: range) { value, run, _ in
            guard (value as? SheetLineLayout)?.figure == true else { return }
            for index in line(at: run.location)...line(at: max(run.location, NSMaxRange(run) - 1)) {
                if let room = figureRoom(ofLine: index) { rooms.append(room) }
            }
        }
        return rooms
    }

    /// Column starts for a table whose source rows begin at `start`, measured from the first 128 rows' cells; nil
    /// unless every row has the table's cell count (an alias such as `copy = table1` answers with the table too).
    func tableStops(firstLine start: Int, rows: Int, columns: Int) -> [CGFloat]? {
        guard columns > 1, rows > 0, start >= 0, start + rows <= lineStarts.count else { return nil }
        let text = string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font(heading: false)]
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in 0..<rows {
            let index = start + row
            let end = contentEnd(ofLine: index)
            let cells = text.substring(with: NSRange(location: lineStarts[index], length: end - lineStarts[index])).components(separatedBy: "\t")
            guard cells.count == columns else { return nil }
            guard row < Self.measuredTableRows else { continue }
            for (column, cell) in cells.enumerated() where !cell.isEmpty {
                widths[column] = max(widths[column], ceil((cell as NSString).size(withAttributes: attributes).width))
            }
        }
        var stops: [CGFloat] = [0]
        for column in 1..<columns { stops.append(stops[column - 1] + widths[column - 1] + Self.columnGap) }
        return stops
    }

    /// Figures are images inside the sheet for VoiceOver.
    override func accessibilityChildren() -> [Any]? {
        let figures = subviews.filter { $0 is FigureView }
        return figures.isEmpty ? super.accessibilityChildren() : (super.accessibilityChildren() ?? []) + figures
    }

    // MARK: Variable rename (Windows SheetEditor.Rename)

    /// The sheet variable at the caret, or exactly covered by the selection.
    var variableTarget: CalculatorRename.Target? { CalculatorRename.find(in: string, selection: selectedRange()) }

    /// Replaces every definition and use of `target` with `newName` in one undo step, keeping the caret inside the
    /// renamed name. False when nothing changed (no occurrence, the same name, or the sheet would grow past its limit).
    @discardableResult
    func renameVariable(_ target: CalculatorRename.Target, to newName: String) -> Bool {
        let replacement = CalculatorRename.normalize(newName)
        let ranges = CalculatorRename.occurrences(of: target.name, in: string)
        guard !ranges.isEmpty, replacement != target.name, let storage = textStorage else { return false }
        let size = replacement.utf16.count
        guard storage.length + ranges.reduce(0, { $0 + size - $1.length }) <= CalculatorSheet.maxCharacters else { NSSound.beep(); return false }
        let caret = min(max(selectedRange().location - target.range.location, 0), target.range.length)
        let shift = ranges.filter { $0.location < target.range.location }.reduce(0) { $0 + size - $1.length }
        // One replacement of the span from the first to the last occurrence, rebuilt with every name renamed: the same text as
        // replacing each range, but a single change the host can follow exactly, in an undo group of its own.
        let span = NSRange(location: ranges[0].location, length: NSMaxRange(ranges[ranges.count - 1]) - ranges[0].location)
        let original = storage.string as NSString
        var rebuilt = "", cursor = span.location
        for range in ranges {
            rebuilt += original.substring(with: NSRange(location: cursor, length: range.location - cursor)) + replacement
            cursor = NSMaxRange(range)
        }
        breakUndoCoalescing()
        ownUndo.beginUndoGrouping()
        defer { ownUndo.endUndoGrouping(); breakUndoCoalescing() }
        guard shouldChangeText(in: span, replacementString: rebuilt) else { return false }
        storage.replaceCharacters(in: span, with: rebuilt)
        didChangeText()
        ownUndo.setActionName(CalculatorText.renameVariable)
        setSelectedRange(NSRange(location: target.range.location + shift + min(caret, size), length: 0))
        return true
    }

    // MARK: Whole-line copy and paste (Windows SheetEditor.LineCopy)

    /// ⌘C with no selection copies the caret's line with its line break, marked as a whole line.
    @discardableResult
    func copyWholeLine() -> Bool {
        let text = string as NSString
        let index = line(at: selectedRange().location)
        let end = contentEnd(ofLine: index)
        let copied = text.substring(with: NSRange(location: lineStarts[index], length: end - lineStarts[index])) + "\n"
        let board = CalculatorClipboard.board
        board.declareTypes([.string, Self.wholeLineType], owner: nil)
        guard board.setString(copied, forType: .string) else { return false }
        board.setData(Data([1]), forType: Self.wholeLineType)
        Self.lastWholeLine = copied
        return true
    }

    /// Deletes the caret's line with its line break (the one before it for the last line), keeping the caret's column where it fits.
    func removeCaretLine() {
        let length = (string as NSString).length
        let caret = selectedRange().location
        let index = line(at: caret)
        let column = caret - lineStarts[index]
        var start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : length
        if index + 1 == lineStarts.count, index > 0 { start = contentEnd(ofLine: index - 1) }
        let range = NSRange(location: start, length: end - start)
        guard range.length > 0 else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        breakUndoCoalescing()
        // The caret lands on the following line, or on the previous one when the last line went.
        let target = line(at: start)
        let targetEnd = contentEnd(ofLine: target)
        setSelectedRange(NSRange(location: lineStarts[target] + min(column, targetEnd - lineStarts[target]), length: 0))
    }

    /// Pastes as plain text with Unix line breaks, CSV that is clearly a table as tab-separated rows, and a whole-line
    /// copy (with no selection) as a line above the caret's, so copy then paste duplicates a line.
    func pasteText(_ raw: String, wholeLine marked: Bool) {
        guard raw.utf16.count <= CalculatorSheet.maxCharacters * 2 else { NSSound.beep(); return }
        var text = CalculatorPaste.normalize(Self.unixLineBreaks(raw))
        let selection = selectedRange()
        guard selection.length == 0, !text.isEmpty, marked || Self.unixLineBreaks(raw) == Self.lastWholeLine.map(Self.unixLineBreaks) else {
            breakUndoCoalescing()
            insertText(text, replacementRange: selection)
            breakUndoCoalescing()
            return
        }
        if !text.hasSuffix("\n") { text += "\n" }
        let at = NSRange(location: lineStarts[line(at: selection.location)], length: 0)
        breakUndoCoalescing()
        guard shouldChangeText(in: at, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: at, with: text)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: selection.location + text.utf16.count, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private static func unixLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    override func copy(_ sender: Any?) {
        if selectedRange().length == 0 { copyWholeLine() } else { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length == 0 else { return super.cut(sender) }
        // A line goes only once it is safely on the clipboard.
        if isEditable, copyWholeLine() { removeCaretLine() }
    }

    override func paste(_ sender: Any?) {
        let board = CalculatorClipboard.board
        guard isEditable, let raw = board.string(forType: .string) else { return super.paste(sender) }
        pasteText(raw, wholeLine: board.types?.contains(Self.wholeLineType) == true)
    }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if selectedRange().length == 0, item.action == #selector(copy(_:)) { return true }
        if selectedRange().length == 0, item.action == #selector(cut(_:)) { return isEditable }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Editing

    func undoManager(for view: NSTextView) -> UndoManager? { ownUndo }

    /// Typing never carries a figure's room or a table's columns to another line; each edit restyles its lines.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        guard newTypingAttributes[.calculatorLayout] != nil else { return newTypingAttributes }
        var attributes = newTypingAttributes
        attributes[.calculatorLayout] = nil
        attributes[.paragraphStyle] = paragraphStyle(heading: false)
        return attributes
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let length = (textStorage?.length ?? 0) - affectedCharRange.length + (replacementString?.utf16.count ?? 0)
        if length > CalculatorSheet.maxCharacters { NSSound.beep(); return false }
        // Past 10,000 lines the engine refuses to evaluate or save the sheet, so an edit that would get there is refused like one past the character limit.
        if let replacementString, Self.lineBreaks(replacementString) > 0,
           lineStarts.count - Self.lineBreaks((string as NSString).substring(with: affectedCharRange)) + Self.lineBreaks(replacementString) > CalculatorSheet.maxLines {
            NSSound.beep(); return false
        }
        if host?.editorWillChange(self, range: affectedCharRange) == true { breakUndoCoalescing() }
        pendingChange = (affectedCharRange, replacementString?.utf16.count ?? 0)
        return true
    }

    func textDidChange(_ notification: Notification) {
        rebuildLineStarts()
        host?.editorTextChanged(self)
        pendingChange = nil
    }

    /// Replaces the whole text as one undo step (a restored version).
    func replaceAllUndoably(with text: String) {
        let all = NSRange(location: 0, length: textStorage?.length ?? 0)
        breakUndoCoalescing()
        guard shouldChangeText(in: all, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: all, with: text)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollToBeginningOfDocument(nil)
    }

    /// Return keeps inserting its line break; the line the caret just left is then submitted (Windows SheetEditor.Dice).
    override func insertNewline(_ sender: Any?) {
        let before = textStorage?.length ?? 0
        super.insertNewline(sender)
        guard textStorage?.length ?? 0 != before else { return } // Refused (a sheet limit): nothing was submitted.
        let current = line(at: selectedRange().location)
        if current > 0, !hasMarkedText() { host?.editorRoll(self, line: current - 1, again: false) }
    }

    func replaceAll(with text: String) {
        string = text
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
        rebuildLineStarts()
    }

    /// Typing that replaces the whole sheet as the user would (undoable; smoke checks use it).
    func type(_ text: String) {
        selectAll(nil)
        insertText(text, replacementRange: selectedRange())
    }

    override func cancelOperation(_ sender: Any?) {
        if host?.editorEscape() == true { return }
        window?.cancelOperation(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            host?.editorRoll(self, line: line(at: selectedRange().location), again: true) // ⌘Return rolls again.
            return true
        }
        if modifiers == [.command, .shift], key == "z" { if ownUndo.canRedo { ownUndo.redo() } else { NSSound.beep() }; return true }
        if modifiers == .command, key == "f" { performTextFinderAction(menuItem(.showFindInterface)); return true }
        // Whole-line copy, cut and every paste go through this view, whichever menu is in front.
        if modifiers == .command, key == "c", selectedRange().length == 0 { copy(nil); return true }
        if modifiers == .command, key == "x", selectedRange().length == 0 { cut(nil); return true }
        if modifiers == .command, key == "v" { paste(nil); return true }
        if modifiers == .command, key == "g" { performTextFinderAction(menuItem(.nextMatch)); return true }
        if modifiers == [.command, .shift], key == "g" { performTextFinderAction(menuItem(.previousMatch)); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func menuItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 48, modifiers == .control { host?.editorCycleSheet(1); return }
        if event.keyCode == 48, modifiers == [.control, .shift] { host?.editorCycleSheet(-1); return }
        if event.keyCode == 120, modifiers.isEmpty { host?.editorRename(); return } // F2
        if event.keyCode == 48, modifiers == .option { host?.editorFocusResult(); return }
        super.keyDown(with: event)
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font(heading: false), .foregroundColor: Palette.textTertiary,
                                                         .paragraphStyle: paragraphStyle(heading: false), .baselineOffset: baselineOffset(heading: false)]
        (CalculatorText.placeholder as NSString).draw(with: NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: max(40, bounds.width - reserved), height: emptyLineHeight),
                                                      options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        if string.utf16.count <= 1 { needsDisplay = true }
    }
}
