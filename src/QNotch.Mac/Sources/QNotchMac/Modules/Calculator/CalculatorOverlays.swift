import AppKit

/// The surface every in-panel card shares: a raised solid fill (never a translucent one over the notch), a
/// hairline and a soft shadow. Cards replace Windows' overlays, anchored to what opened them.
class OverlayCard: FillView {
    init(id: String, label: String) {
        super.init(fill: Palette.rgb(0x222228), stroke: CalculatorContrast.strongStroke, radius: 12)
        identifier = NSUserInterfaceItemIdentifier(id)
        CalculatorContrast.shadow(layer, opacity: 0.5, radius: 14, y: -6)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    static func title(_ text: String) -> NSTextField { line(text, size: 14, weight: .semibold, color: Palette.textPrimary) }

    /// A dark single-line field in the Search field's style.
    static func field(placeholder: String, id: String, label: String) -> (box: FillView, field: NSTextField) {
        let box = FillView(fill: Palette.control, stroke: Palette.stroke, radius: 8)
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Palette.textPrimary
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: Palette.textTertiary, .font: NSFont.systemFont(ofSize: 13)])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.setAccessibilityLabel(label)
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 30)
        ])
        return (box, field)
    }
}

/// The calculation steps of one result (Windows ShowExplanation), selectable, with Close.
final class ExplanationCard: OverlayCard {
    let text = OverlayTextView()
    let close = HoverButton(CalculatorText.close, style: .plain, label: CalculatorText.close) {}
    var escape: (() -> Void)? { didSet { text.escape = escape } }

    init(text value: String, title heading: String = CalculatorText.explanation, id: String = "calculator-explanation-card") {
        super.init(id: id, label: heading)
        let title = Self.title(heading)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = Palette.textPrimary
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.string = value
        text.identifier = NSUserInterfaceItemIdentifier("calculator-explanation")
        text.setAccessibilityLabel(CalculatorText.calculationSteps)
        scroll.documentView = text
        close.identifier = NSUserInterfaceItemIdentifier("calculator-explanation-close")
        close.padding = NSSize(width: 14, height: 4)
        let buttons = row([spacer(), close], spacing: 8)
        let stack = column([title, scroll, buttons], spacing: 10)
        embed(stack, in: self, inset: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14), fill: true)
        for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // The steps fit up to 196 points, then scroll.
        text.frame = NSRect(x: 0, y: 0, width: 372, height: 10)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let needed = ceil(text.layoutManager?.usedRect(for: text.textContainer!).height ?? 40)
        scroll.heightAnchor.constraint(equalToConstant: min(196, max(18, needed))).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A read-only or plain text view whose Escape closes its card.
final class OverlayTextView: NSTextView {
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { if let escape { escape() } else { super.cancelOperation(sender) } }
}

/// Renames a sheet under its tab (Windows RenameSheet), or a variable under its name in the sheet (Windows SheetEditor.Rename).
final class RenameCard: OverlayCard, NSTextFieldDelegate {
    enum Subject {
        case sheet, variable
        var title: String { self == .sheet ? CalculatorText.renameSheet : CalculatorText.renameVariable }
        var fieldLabel: String { self == .sheet ? CalculatorText.sheetName : CalculatorText.variableName }
        var fieldID: String { self == .sheet ? "calculator-sheet-name" : "calculator-rename-variable" }
        var cardID: String { self == .sheet ? "calculator-rename" : "calculator-rename-variable-card" }
    }
    let field: NSTextField
    private let problem = label("", size: 11, color: .systemRed)
    var commit: ((String) -> Void)?
    var cancel: (() -> Void)?

    init(name: String, subject: Subject = .sheet) {
        let input = Self.field(placeholder: subject.fieldLabel, id: subject.fieldID, label: subject.fieldLabel)
        field = input.field
        super.init(id: subject.cardID, label: subject.title)
        field.stringValue = name
        field.delegate = self
        problem.isHidden = true
        problem.preferredMaxLayoutWidth = 270
        let cancelButton = HoverButton(CalculatorText.cancel, style: .plain, label: CalculatorText.cancel) { [weak self] in self?.cancel?() }
        let save = HoverButton(CalculatorText.rename, style: .accent, label: CalculatorText.rename) { [weak self] in
            guard let self else { return }
            self.commit?(self.field.stringValue)
        }
        save.identifier = NSUserInterfaceItemIdentifier(subject.fieldID + "-save")
        for button in [cancelButton, save] { button.padding = NSSize(width: 14, height: 4) }
        let buttons = row([spacer(), cancelButton, save], spacing: 8)
        let stack = column([Self.title(subject.title), input.box, problem, buttons], spacing: 10)
        stack.setCustomSpacing(6, after: input.box)
        embed(stack, in: self, inset: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14), fill: true)
        for view in [input.box, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(problem text: String) {
        problem.stringValue = text
        problem.isHidden = false
        NSAccessibility.post(element: problem, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) { problem.isHidden = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit?(field.stringValue); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel?(); return true
        default: return false
        }
    }
}

/// Every sheet, filterable (Windows ShowAllSheets): type to narrow, arrows to move, Return or a click to open.
final class AllSheetsCard: OverlayCard, NSTextFieldDelegate {
    let filter: NSTextField
    private let tabs: [CalculatorTab]
    private let current: UUID
    private let list = FlippedView()
    private let scroll = NSScrollView()
    private var shown: [CalculatorTab] = []
    private var rows: [(background: FillView, button: HoverButton)] = []
    private(set) var selected: Int?
    private var heightConstraint: NSLayoutConstraint?
    var open: ((UUID) -> Void)?
    var escape: (() -> Void)?

    init(tabs: [CalculatorTab], current: UUID) {
        self.tabs = tabs
        self.current = current
        let input = Self.field(placeholder: CalculatorText.filterSheets, id: "calculator-tabs-filter", label: CalculatorText.filterSheets)
        filter = input.field
        super.init(id: "calculator-all-sheets", label: CalculatorText.allSheets)
        filter.delegate = self
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.identifier = NSUserInterfaceItemIdentifier("calculator-tabs-list")
        scroll.setAccessibilityLabel(CalculatorText.allSheets)
        let stack = column([input.box, scroll], spacing: 8)
        embed(stack, in: self, inset: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), fill: true)
        for view in [input.box, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 30)
        heightConstraint?.isActive = true
        refill()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refill() {
        let query = filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = query.isEmpty ? tabs : tabs.filter { $0.name.localizedCaseInsensitiveContains(query) }
        rows.forEach { $0.background.removeFromSuperview() }
        rows.removeAll()
        let width: CGFloat = 260
        for (index, tab) in shown.enumerated() {
            let background = FillView(fill: nil, radius: 7)
            let button = HoverButton("", style: .row, label: tab.name) { [weak self] in self?.open?(tab.id) }
            button.refusesFirstResponder = true
            button.identifier = NSUserInterfaceItemIdentifier("calculator-tabs-list-\(index)")
            let mark = symbol("checkmark", size: 10, weight: .semibold, color: Palette.accent)
            mark.isHidden = tab.id != current
            let name = line(tab.name, size: 12, color: Palette.textPrimary)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let content = row([mark, name], spacing: 8)
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
                content.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -8),
                content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                mark.widthAnchor.constraint(equalToConstant: 12)
            ])
            button.frame = NSRect(x: 0, y: 0, width: width, height: 26)
            button.autoresizingMask = [.width]
            background.addSubview(button)
            background.frame = NSRect(x: 0, y: CGFloat(index) * 26, width: width, height: 26)
            list.addSubview(background)
            rows.append((background, button))
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(26, CGFloat(shown.count) * 26))
        heightConstraint?.constant = min(214, max(26, CGFloat(shown.count) * 26))
        select(shown.firstIndex { $0.id == current } ?? (shown.isEmpty ? nil : 0))
    }

    private func select(_ index: Int?) {
        selected = index
        for (offset, row) in rows.enumerated() {
            let on = offset == index
            row.background.fill = on ? Palette.accentSoft : nil
            row.button.isSelectedLook = on
        }
        if let index, rows.indices.contains(index) { rows[index].background.scrollToVisible(rows[index].background.bounds) }
    }

    private func move(_ by: Int) {
        guard !shown.isEmpty else { return }
        select(min(shown.count - 1, max(0, (selected ?? 0) + by)))
    }

    func controlTextDidChange(_ notification: Notification) { refill() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-8)
        case #selector(NSResponder.insertNewline(_:)):
            if let selected, shown.indices.contains(selected) { open?(shown[selected].id) }
        case #selector(NSResponder.cancelOperation(_:)): escape?()
        default: return false
        }
        return true
    }
}

/// The rates button's menu (Windows FillCurrencyMenu), anchored under the button: what the sheet converts with, the
/// last problem, the downloads, the automatic download and the source. Rows behave like menu items: the pointer or the
/// arrow keys choose, a click, Return or Space runs one and the menu closes. It follows a download while it is open.
final class RatesMenuCard: OverlayCard {
    struct Entry: Equatable {
        enum Kind: Equatable { case note, warning, action, check(Bool), link }
        let id: String
        let title: String
        var tip: String?
        let kind: Kind
        var enabled = true
        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id && a.title == b.title && a.tip == b.tip && a.kind == b.kind && a.enabled == b.enabled }
    }

    static let width: CGFloat = 300
    private let stack = NSStackView()
    private(set) var entries: [Entry] = []
    private var rows: [(entry: Entry, background: FillView, button: HoverButton?)] = []
    private(set) var selected: Int?
    /// Runs the chosen entry (by id).
    var run: ((String) -> Void)?
    var escape: (() -> Void)?

    init(entries: [Entry]) {
        super.init(id: "calculator-rates-menu", label: CalculatorText.currencyRates)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        embed(stack, in: self, inset: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6), fill: true)
        show(entries)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    /// Rebuilds the rows when what they say changed, keeping the chosen one.
    func show(_ next: [Entry]) {
        guard next != entries else { return }
        let chosen = selected.flatMap { rows.indices.contains($0) ? rows[$0].entry.id : nil }
        entries = next
        rows.forEach { $0.background.removeFromSuperview() }
        rows.removeAll()
        for (index, entry) in next.enumerated() {
            let background = FillView(fill: nil, radius: 6)
            background.translatesAutoresizingMaskIntoConstraints = false
            var button: HoverButton?
            switch entry.kind {
            case .note, .warning:
                let text = line(entry.title, size: 12, weight: entry.kind == .note ? .semibold : .regular,
                                color: entry.kind == .note ? Palette.textSecondary : .systemOrange)
                text.lineBreakMode = .byTruncatingTail
                text.toolTip = entry.title
                text.identifier = NSUserInterfaceItemIdentifier(entry.id)
                text.translatesAutoresizingMaskIntoConstraints = false
                background.addSubview(text)
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -10),
                    text.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                    background.heightAnchor.constraint(equalToConstant: 24)
                ])
            case .action, .check, .link:
                let made = HoverButton("", style: .row, label: entry.title) { [weak self] in self?.choose(index) }
                made.refusesFirstResponder = true
                made.isEnabled = entry.enabled
                made.toolTip = entry.tip
                made.identifier = NSUserInterfaceItemIdentifier(entry.id)
                made.translatesAutoresizingMaskIntoConstraints = false
                if entry.tip != nil { made.setAccessibilityHelp(entry.tip) }
                if case .check(let on) = entry.kind {
                    made.setAccessibilityRole(.checkBox)
                    made.setAccessibilityValue(NSNumber(value: on ? 1 : 0))
                }
                let mark: NSImageView
                switch entry.kind {
                case .check(let on):
                    mark = symbol("checkmark", size: 10, weight: .semibold, color: Palette.accent)
                    mark.isHidden = !on
                case .link: mark = symbol("arrow.up.right", size: 9, weight: .semibold, color: Palette.textSecondary)
                default: mark = symbol("checkmark", size: 10, weight: .semibold, color: .clear); mark.isHidden = true
                }
                let title = line(entry.title, size: 12, color: entry.enabled ? Palette.textPrimary : Palette.textTertiary)
                title.lineBreakMode = .byTruncatingTail
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let content = row([mark, title], spacing: 8)
                content.translatesAutoresizingMaskIntoConstraints = false
                made.addSubview(content)
                background.addSubview(made)
                NSLayoutConstraint.activate([
                    mark.widthAnchor.constraint(equalToConstant: 12),
                    content.leadingAnchor.constraint(equalTo: made.leadingAnchor, constant: 8),
                    content.trailingAnchor.constraint(lessThanOrEqualTo: made.trailingAnchor, constant: -8),
                    content.centerYAnchor.constraint(equalTo: made.centerYAnchor),
                    made.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                    made.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                    made.topAnchor.constraint(equalTo: background.topAnchor),
                    made.bottomAnchor.constraint(equalTo: background.bottomAnchor),
                    background.heightAnchor.constraint(equalToConstant: 26)
                ])
                button = made
            }
            stack.addArrangedSubview(background)
            background.widthAnchor.constraint(equalToConstant: Self.width - 12).isActive = true
            if index > 0, entry.kind != .warning, next[index - 1].kind == .note || next[index - 1].kind == .warning, entry.kind != .note {
                stack.setCustomSpacing(4, after: rows[index - 1].background)
            }
            rows.append((entry, background, button))
        }
        select(chosen.flatMap { id in rows.firstIndex { $0.entry.id == id } })
    }

    private var choosable: [Int] { rows.indices.filter { rows[$0].button != nil && rows[$0].entry.enabled } }

    private func select(_ index: Int?) {
        selected = index
        for (offset, row) in rows.enumerated() {
            row.background.fill = offset == index ? Palette.accentSoft : nil
            row.button?.isSelectedLook = offset == index
        }
    }

    private func move(_ by: Int) {
        let options = choosable
        guard !options.isEmpty else { return }
        guard let current = selected, let at = options.firstIndex(of: current) else { return select(by > 0 ? options.first : options.last) }
        select(options[max(0, min(options.count - 1, at + by))])
    }

    private func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].entry.enabled, rows[index].button != nil else { return }
        run?(rows[index].entry.id)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)                                   // Down
        case 126: move(-1)                                  // Up
        case 36, 76, 49: if let selected { choose(selected) } // Return, Enter, Space
        case 53: escape?()
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { escape?() }
}
