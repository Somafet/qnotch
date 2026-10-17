import AppKit
import QNotchMacCore

protocol ClipboardDisplay: AnyObject { func reload() }

// MARK: - Home card

final class ClipboardCardView: NSView, ClipboardDisplay {
    private weak var module: ClipboardModule?
    private let list = NSStackView()
    private let empty = line("Nothing copied yet.", size: 12, color: Palette.textTertiary)

    init(module: ClipboardModule) {
        self.module = module
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let stack = column([list, empty], spacing: 4)
        embed(stack, in: self, inset: 0)
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = Array(module.history.entries.prefix(3))
        empty.stringValue = module.denied ? "Clipboard access is denied in System Settings." : "Nothing copied yet."
        empty.isHidden = !entries.isEmpty
        for entry in entries {
            let button = CopyRow(entry: entry, compact: true, module: module)
            list.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

// MARK: - Clipboard tab

final class ClipboardTabView: NSView, ClipboardDisplay {
    private weak var module: ClipboardModule?
    private let chips: ChipPicker
    private let count = line("", size: 11, color: Palette.textTertiary)
    private let clear: HoverButton
    private let scroll = NSScrollView()
    private let list = FlippedColumn()
    private let empty = line("", size: 12, color: Palette.textTertiary)
    private static let filters: [ClipKind?] = [nil, .text, .code, .image]

    init(module: ClipboardModule) {
        self.module = module
        let titles = ["All", "Text", "Code", "Images"]
        chips = ChipPicker(values: [0, 1, 2, 3], format: { titles[$0] }, label: { "Show \(titles[$0])" }) { [weak module] index in
            module?.filter = Self.filters[index]
        }
        clear = HoverButton("Clear all", symbol: "trash", style: .plain, symbolSize: 11) { [weak module] in module?.clear() }
        super.init(frame: .zero)
        clear.toolTip = "Pinned entries stay"
        let header = row([chips, count, spacer(), clear], spacing: 10)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let stack = column([header, scroll, empty], spacing: 10)
        embed(stack, in: self, inset: 0, fill: true)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        chips.select(Self.filters.firstIndex(of: module.filter) ?? 0)
        let all = module.history.entries
        let shown = all.filter { entry in
            guard let filter = module.filter else { return true }
            return filter == .text ? entry.kind == .text || entry.kind == .link : entry.kind == filter
        }
        count.stringValue = all.isEmpty ? "" : all.count == 1 ? "1 entry" : "\(all.count) entries"
        clear.isHidden = !all.contains { !$0.pinned }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in shown {
            let row = CopyRow(entry: entry, compact: false, module: module)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        scroll.isHidden = shown.isEmpty
        empty.isHidden = !shown.isEmpty
        empty.stringValue = module.denied ? "macOS denies QNotch clipboard access. Allow it in System Settings, Privacy & Security, Paste from Other Apps."
            : all.isEmpty ? "Nothing copied yet. Text and images you copy show up here." : "No \(["", "text", "code", "images"][Self.filters.firstIndex(of: module.filter) ?? 0]) yet."
    }
}

private final class FlippedColumn: NSStackView {
    override var isFlipped: Bool { true }
}

/// One entry: click copies it again (a check flashes), hover reveals pin, copy and remove.
private final class CopyRow: FillView {
    private let entry: ClipEntry
    private weak var module: ClipboardModule?
    private let actions: NSStackView
    private let pinMark: NSImageView
    private let glyph: NSImageView
    private var tracking: NSTrackingArea?

    init(entry: ClipEntry, compact: Bool, module: ClipboardModule) {
        self.entry = entry
        self.module = module
        glyph = symbol(ClipboardModule.symbol(entry.kind), size: 11, weight: .semibold, color: Palette.textSecondary)
        pinMark = symbol("pin.fill", size: 10, weight: .semibold, color: Palette.accent)
        let pin = HoverButton(symbol: entry.pinned ? "pin.slash" : "pin", style: .icon, symbolSize: 11, label: entry.pinned ? "Unpin" : "Pin") { [weak module] in module?.togglePin(entry) }
        let copy = HoverButton(symbol: "doc.on.doc", style: .icon, symbolSize: 11, label: "Copy again") { [weak module] in module?.copyAgain(entry) }
        let remove = HoverButton(symbol: "xmark", style: .icon, symbolSize: 10, label: "Remove") { [weak module] in module?.remove(entry) }
        actions = row(compact ? [] : [pin, copy, remove], spacing: 0)
        super.init(fill: nil, radius: 8)
        let tile = FillView(fill: Palette.control, radius: 6)
        size(tile, width: compact ? 22 : 30, height: compact ? 22 : 30)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        var body: [NSView] = []
        if entry.kind == .image, !compact, let image = ClipboardImages.shared.image(entry) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyDown
            view.imageAlignment = .alignLeft
            size(view, width: 160, height: 52)
            body.append(view)
        } else {
            let text = compact ? line(entry.line, size: 12, color: Palette.textPrimary) : label(entry.preview.isEmpty ? entry.line : entry.preview, size: 12, color: entry.kind == .link ? Palette.accent : Palette.textPrimary)
            if entry.kind == .code { text.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
            if !compact {
                text.maximumNumberOfLines = entry.kind == .code ? 2 : 3
                text.lineBreakMode = .byTruncatingTail
                text.preferredMaxLayoutWidth = 520
            }
            body.append(text)
        }
        if !compact { body.append(line("\(entry.meta) · \(ClipText.age(entry.created))", size: 10, color: Palette.textTertiary)) }
        let content = column(body, spacing: 2)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pinMark.isHidden = !entry.pinned
        actions.isHidden = true
        let layout = row([tile, content, spacer(), pinMark, actions], spacing: compact ? 8 : 10)
        layout.alignment = compact ? .centerY : .top
        embed(layout, in: self, inset: NSEdgeInsets(top: compact ? 4 : 8, left: compact ? 4 : 8, bottom: compact ? 4 : 8, right: 6), fill: true)
        toolTip = "Click to copy again"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(entry.line). \(entry.meta). Copies it again.")
        if compact {
            let item = ClosureMenuItem(title: "Delete") { [weak module] in module?.remove(entry) }
            menu = NSMenu()
            menu?.addItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityPerformPress() -> Bool { copyEntry(); return true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        setFill(Palette.control, animated: true)
        if !actions.arrangedSubviews.isEmpty { actions.isHidden = false; pinMark.isHidden = true }
    }
    override func mouseExited(with event: NSEvent) {
        setFill(nil, animated: true)
        actions.isHidden = true
        pinMark.isHidden = !entry.pinned
    }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        copyEntry()
    }

    private func copyEntry() {
        module?.copyAgain(entry)
        // The module reloads the list; flash on the replacement isn't needed, a short HUD-like check is enough.
        glyph.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        glyph.contentTintColor = .systemGreen
    }
}
