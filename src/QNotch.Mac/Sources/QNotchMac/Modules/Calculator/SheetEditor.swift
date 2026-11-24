import AppKit
import CalculatorEngine

/// What the sheet editor asks of its page.
protocol SheetEditorHost: AnyObject {
    /// Escape: an open overlay closes; false lets the panel close.
    func editorEscape() -> Bool
    func editorCycleSheet(_ direction: Int)
    func editorRename()
    func editorTextChanged(_ editor: SheetTextView)
}

/// The sheet's native text view (Windows SheetEditor over AvalonEdit): plain text with IME, its own undo stack,
/// find, VoiceOver and no automatic substitutions or spelling. Text wraps before the results column, which
/// the page draws beside it. TextKit 1, so line geometry is exact and cheap.
final class SheetTextView: NSTextView, NSTextViewDelegate, NSTextStorageDelegate {
    static let lineSpacing: CGFloat = 1.6
    static let headingScale: CGFloat = 1.25

    weak var host: SheetEditorHost?
    let sheetID: UUID
    let ownUndo = UndoManager()
    /// Width kept free on the right for the results column.
    var reserved: CGFloat = 220 { didSet { if oldValue != reserved { updateContainer() } } }
    var fontSize: CGFloat { didSet { if oldValue != fontSize { restyle(NSRange(location: 0, length: textStorage?.length ?? 0)) } } }
    /// UTF-16 offsets of each line start; rebuilt on every change.
    private(set) var lineStarts: [Int] = [0]

    init(sheetID: UUID, text: String, fontSize: CGFloat) {
        self.sheetID = sheetID
        self.fontSize = fontSize
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
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
        super.setFrameSize(newSize)
        updateContainer()
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
        var offset = 0
        for unit in text {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
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

    private func paragraphStyle(heading: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = (fontSize * (heading ? Self.headingScale : 1) * Self.lineSpacing).rounded()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineBreakMode = .byWordWrapping
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

    private func baseAttributes(heading: Bool) -> [NSAttributedString.Key: Any] {
        [.font: font(heading: heading), .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraphStyle(heading: heading),
         .baselineOffset: baselineOffset(heading: heading)]
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
            let line = text.substring(with: lineRange)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let heading = trimmed.hasPrefix("# ")
            storage.setAttributes(self.baseAttributes(heading: heading), range: enclosing)
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
        if batch { storage.endEditing() }
    }

    /// "#fff" and "#3cc8d9" are colours, not tags.
    static func isColourLiteral(_ tag: String) -> Bool {
        let digits = tag.dropFirst()
        return [3, 4, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
    }

    /// The accent changed: accents follow it.
    func recolor() {
        selectedTextAttributes = [.backgroundColor: Palette.accent.withAlphaComponent(0.32)]
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    // MARK: Editing

    func undoManager(for view: NSTextView) -> UndoManager? { ownUndo }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let length = (textStorage?.length ?? 0) - affectedCharRange.length + (replacementString?.utf16.count ?? 0)
        if length > CalculatorSheet.maxCharacters { NSSound.beep(); return false }
        return true
    }

    func textDidChange(_ notification: Notification) {
        rebuildLineStarts()
        host?.editorTextChanged(self)
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
        if modifiers == [.command, .shift], key == "z" { if ownUndo.canRedo { ownUndo.redo() } else { NSSound.beep() }; return true }
        if modifiers == .command, key == "f" { performTextFinderAction(menuItem(.showFindInterface)); return true }
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
