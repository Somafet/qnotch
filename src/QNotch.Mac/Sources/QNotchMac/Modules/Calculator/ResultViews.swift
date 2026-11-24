import AppKit
import CalculatorEngine

/// What a result pill asks of its page.
protocol ResultPillHost: AnyObject {
    func pillCopy(_ pill: ResultPill)
    func pillExplain(_ pill: ResultPill)
    func pillHover(_ pill: ResultPill, inside: Bool)
    func pillFocus(_ pill: ResultPill, focused: Bool)
    func pillMenu(_ pill: ResultPill, event: NSEvent)
    /// Typing on a focused result goes back to the sheet.
    func pillTyped(_ event: NSEvent)
}

/// One result beside its line (Windows SheetResult button): the value right-aligned in monospaced digits, a
/// pill that marks the value on hover, a press that shrinks it, a check mark after copying, and a dotted
/// underline when it has an explanation. Feedback starts on mouse-down; the copy happens on release inside.
final class ResultPill: NSView, OutlineRoleProviding {
    weak var host: ResultPillHost?
    private(set) var result: CalculatorLineResult
    private let fontSize: CGFloat
    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?
    private let mark = NSImageView()
    private var markTask: DispatchWorkItem?
    static let insetX: CGFloat = 7
    static let markWidth: CGFloat = 21

    init(result: CalculatorLineResult, fontSize: CGFloat) {
        self.result = result
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        mark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        mark.contentTintColor = color
        mark.isHidden = true
        mark.setAccessibilityElement(false)
        addSubview(mark)
        identifier = NSUserInterfaceItemIdentifier("calculator-result-\(result.line + 1)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(CalculatorResultText.accessibilityName(result))
        if CalculatorResultText.copies(result) {
            let explanation = CalculatorResultText.explanation(result)
            setAccessibilityHelp((explanation.isEmpty ? "" : explanation + "\n") + CalculatorText.resultHelp)
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: CalculatorText.explainMenu) { [weak self] in
                guard let self else { return false }
                self.host?.pillExplain(self)
                return true
            }])
        }
        toolTip = nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var outlineRole: Outline.Role? { .button }

    var copies: Bool { CalculatorResultText.copies(result) }
    private var muted: Bool { result.error != nil || result.pending != nil }
    private var color: NSColor { muted ? Palette.textSecondary : Palette.accent }
    private var font: NSFont {
        muted ? .systemFont(ofSize: min(13, fontSize)) : .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
    }
    var text: String { CalculatorResultText.shown(result) }
    private var underlined: Bool { result.error == nil && CalculatorResultText.card(result) != nil }

    /// Width the value needs, with the pill's inset on both sides and room for the copied mark.
    var naturalWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + Self.insetX * 2 + Self.markWidth
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The value's pill: only as wide as the value, right-aligned, a little past the line on every side.
    private var surface: NSRect {
        let width = min(bounds.width - Self.markWidth, ceil((text as NSString).size(withAttributes: [.font: font]).width) + Self.insetX * 2)
        return NSRect(x: bounds.width - width, y: 1, width: width, height: max(0, bounds.height - 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = surface
        let path = NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6)
        if copies, pressing { Palette.controlPressed.setFill(); path.fill() }
        else if copies, hovering { Palette.controlHover.setFill(); path.fill() }
        if window?.firstResponder === self {
            Palette.accent.setStroke()
            let ring = NSBezierPath(roundedRect: pill.insetBy(dx: 0.75, dy: 0.75), xRadius: 5.5, yRadius: 5.5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let size = (text as NSString).size(withAttributes: attributes)
        let textRect = NSRect(x: pill.minX + Self.insetX, y: (bounds.height - size.height) / 2, width: pill.width - Self.insetX * 2, height: size.height)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        if underlined {
            // A dotted rule under the value: there is more one hover away.
            let rule = NSBezierPath()
            let y = textRect.maxY - 1.5
            let width = min(textRect.width, size.width)
            rule.move(to: NSPoint(x: textRect.maxX - width, y: y))
            rule.line(to: NSPoint(x: textRect.maxX, y: y))
            rule.lineWidth = 1
            rule.setLineDash([1, 2.5], count: 2, phase: 0)
            color.withAlphaComponent(0.7).setStroke()
            rule.stroke()
        }
    }

    override func layout() {
        super.layout()
        let pill = surface
        mark.frame = NSRect(x: pill.minX - Self.markWidth + 4, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { (copies ? NSCursor.pointingHand : NSCursor.arrow).set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; host?.pillHover(self, inside: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; host?.pillHover(self, inside: false) }

    override func mouseDown(with event: NSEvent) {
        guard copies else { return super.mouseDown(with: event) }
        pressing = true
        needsDisplay = true
        Motion.press(self, down: true, scale: 0.97)
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            inside = bounds.contains(point)
            if pressing != inside { pressing = inside; needsDisplay = true }
            if next.type == .leftMouseUp { break }
        }
        pressing = false
        needsDisplay = true
        Motion.press(self, down: false, scale: 0.97)
        // A mouse copy must not strand typing on the result: the page gives the sheet its caret back.
        if inside { host?.pillCopy(self) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard copies else { return super.rightMouseDown(with: event) }
        host?.pillMenu(self, event: event)
    }

    // MARK: Keyboard

    override func becomeFirstResponder() -> Bool { needsDisplay = true; host?.pillFocus(self, focused: true); return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; host?.pillFocus(self, focused: false); return true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.isEmpty, [36, 76, 49].contains(event.keyCode) { host?.pillCopy(self); return }   // Return, Enter, Space
        if modifiers.isEmpty, event.keyCode == 122 { host?.pillExplain(self); return }                // F1
        if event.keyCode != 48, modifiers.isEmpty || modifiers == .shift, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            host?.pillTyped(event)
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘C on a focused result.
    @objc func copy(_ sender: Any?) { host?.pillCopy(self) }

    override func accessibilityPerformPress() -> Bool {
        host?.pillCopy(self)
        return true
    }

    // MARK: Copied

    /// The check mark lands where the user clicked: at once, then it leaves quickly so the value stays the focus.
    func confirmCopy() {
        markTask?.cancel()
        mark.layer?.removeAllAnimations()
        mark.alphaValue = 1
        mark.isHidden = false
        needsLayout = true
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Motion.fades {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = Motion.moves ? 0.18 : Motion.crossfadeDuration
                    context.timingFunction = Motion.easeIn
                    self.mark.animator().alphaValue = 0
                }, completionHandler: { [weak self] in self?.mark.isHidden = true })
            } else {
                self.mark.isHidden = true
            }
        }
        markTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: task)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: CalculatorText.copied, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    var showsCopied: Bool { !mark.isHidden }
}

/// The hover card under a result (Windows ResultCard): the exact value when the row shows something else,
/// where the value came from, its kind and the lines it uses. Passive: it never takes the pointer.
final class ResultCardView: FillView {
    static let maxWidth: CGFloat = 340
    let card: CalculatorResultText.Card
    private let stack: NSStackView

    init(card: CalculatorResultText.Card) {
        self.card = card
        var views: [NSView] = []
        switch card {
        case .problem(let message):
            let icon = symbol("exclamationmark.triangle.fill", size: 13, weight: .medium, color: .systemOrange)
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let text = Self.wrapping(message, size: 13, weight: .regular, color: Palette.textPrimary)
            let line = NSStackView(views: [icon, text])
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 9
            views.append(line)
        case let .explain(headline, note, sources, kind):
            if let headline {
                let field = Self.wrapping(headline, size: 13, weight: .semibold, color: Palette.textPrimary)
                field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                views.append(field)
            }
            if !note.isEmpty { views.append(Self.wrapping(note, size: 13, weight: .regular, color: Palette.textPrimary)) }
            let muted = [kind ?? "", sources].filter { !$0.isEmpty }.joined(separator: " · ")
            if !muted.isEmpty { views.append(Self.wrapping(muted, size: 12, weight: .regular, color: Palette.textSecondary)) }
        }
        stack = column(views, spacing: 4)
        super.init(fill: Palette.rgb(0x222228), stroke: Palette.strokeStrong, radius: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        identifier = NSUserInterfaceItemIdentifier("calculator-result-card")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(card.text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fits the text up to the maximum width.
    func fittedSize() -> NSSize {
        for case let field as NSTextField in allFields { field.preferredMaxLayoutWidth = Self.maxWidth - 24 - (card.isProblem ? 22 : 0) }
        let size = fittingSize
        return NSSize(width: min(Self.maxWidth, ceil(size.width)), height: ceil(size.height))
    }

    private var allFields: [NSView] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(stack).filter { $0 is NSTextField }
    }

    /// Keeps digit groups ("34 946 044") and slash units ("x/year") on one line.
    static func unbroken(_ text: String) -> String {
        let noBreak = text.replacingOccurrences(of: #"(?<=\d) (?=\d{3}\b)"#, with: "\u{00A0}", options: .regularExpression)
        return noBreak.replacingOccurrences(of: "/", with: "/\u{2060}")
    }

    private static func wrapping(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = label(unbroken(text), size: size, weight: weight, color: color)
        field.maximumNumberOfLines = 8
        field.lineBreakMode = .byWordWrapping
        field.setAccessibilityElement(false)
        return field
    }
}

private extension CalculatorResultText.Card {
    var isProblem: Bool { if case .problem = self { true } else { false } }
}
