import AppKit
import QNotchMacCore

protocol NotificationsDisplay: AnyObject { func reload() }

/// Bell and unread count in the right wing; the manual mute glyph stays even with no unread items.
final class BellSegmentView: NSStackView {
    private let bell = symbol("bell.fill", size: 11, weight: .semibold, color: Palette.accent)
    private let count = line("", size: 12, weight: .semibold, color: Palette.textPrimary)
    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        count.font = .rounded(12, weight: .semibold, monospacedDigits: true)
        [bell, count].forEach(addArrangedSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        identifier = NSUserInterfaceItemIdentifier("notifications-segment")
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(unread: Int, muted: Bool) {
        bell.image = NSImage(systemSymbolName: muted ? "bell.slash.fill" : "bell.fill", accessibilityDescription: nil)
        bell.contentTintColor = muted ? .systemOrange : Palette.accent
        count.isHidden = unread == 0
        count.stringValue = unread > 99 ? "99+" : "\(unread)"
        isHidden = unread == 0 && !muted
        toolTip = muted ? "Notifications muted" : nil
        setAccessibilityLabel((muted ? "Notifications muted. " : "") + (unread == 1 ? "1 unread notification" : "\(unread) unread notifications"))
    }
}

// MARK: - Home card

final class NotificationsCardView: NSView, NotificationsDisplay {
    private weak var module: NotificationsModule?
    private let list = NSStackView()
    private let empty = line("No notifications", size: 12, color: Palette.textTertiary)

    init(module: NotificationsModule) {
        self.module = module
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let stack = column([row([spacer(), module.makeMuteButton()]), list, empty], spacing: 4)
        embed(stack, in: self, inset: 0)
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for view in [list, empty] { view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openTab))) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Notifications. Click a notification to open the Notifications tab.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openTab() { module?.contextShell?.selectTab("notifications") }

    func reload() {
        guard let module else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for note in module.items.prefix(3) {
            let title = line(note.title, size: 12, weight: note.read ? .regular : .semibold, color: note.read ? Palette.textSecondary : Palette.textPrimary)
            let entry = row([symbol(note.symbol, size: 11, weight: .semibold, color: note.tint), title], spacing: 7)
            list.addArrangedSubview(entry)
            entry.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor).isActive = true
        }
        empty.isHidden = !module.items.isEmpty
    }
}

// MARK: - Notifications tab

final class NotificationsTabView: NSView, NotificationsDisplay, TabHeaderProviding {
    private(set) var tabHeaderActions: NSView = NSView()
    private weak var module: NotificationsModule?
    private let scroll = NSScrollView()
    private let list = FlippedList()
    private let count = line("", size: 11, color: Palette.textTertiary)
    private let quiet = line("", size: 11, color: .systemOrange)
    private let clear: HoverButton
    private let emptyView: NSView
    private var tracking: NSTrackingArea?

    init(module: NotificationsModule) {
        self.module = module
        clear = HoverButton("Clear", symbol: "trash", style: .plain, symbolSize: 11) { [weak module] in module?.clear() }
        emptyView = placeholder(symbol: "bell.slash", title: "No notifications", detail: "Apps and scripts can post here with QNotch notify.")
        super.init(frame: .zero)
        tabHeaderActions = row([module.makeMuteButton(), clear], spacing: 8)
        let header = row([count, quiet, spacer()], spacing: 8)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let stack = column([header, scroll], spacing: 10)
        embed(stack, in: self, inset: 0, fill: true)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        embed(emptyView, in: self, inset: NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0), fill: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    /// Hovering the list marks notifications read (Windows does the same).
    override func mouseEntered(with event: NSEvent) { module?.seen() }
    override func mouseMoved(with event: NSEvent) { module?.seen() }

    func reload() {
        guard let module else { return }
        let items = module.items
        let unread = module.unread
        count.stringValue = items.isEmpty ? "" : unread > 0 ? "\(unread) unread" : "\(items.count)"
        quiet.stringValue = module.quietStatus
        quiet.isHidden = quiet.stringValue.isEmpty
        clear.isHidden = !items.contains { !$0.pending }
        emptyView.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for note in items {
            let row = NoteRow(note: note, module: module)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

private final class FlippedList: NSStackView {
    override var isFlipped: Bool { true }
}

private final class NoteRow: FillView {
    init(note: NotificationsModule.Note, module: NotificationsModule) {
        super.init(fill: note.pending ? Palette.accentSoft.withAlphaComponent(0.12) : Palette.card, stroke: note.pending ? Palette.accent.withAlphaComponent(0.5) : Palette.stroke, radius: 10)
        let icon: NSView
        if let image = note.image {
            let view = NSImageView(image: image)
            size(view, width: 26, height: 26)
            icon = view
        } else {
            let tile = FillView(fill: note.tint.withAlphaComponent(0.18), radius: 7)
            size(tile, width: 26, height: 26)
            let glyph = symbol(note.symbol, size: 12, weight: .semibold, color: note.tint)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(glyph)
            NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
            icon = tile
        }
        let title = line(note.title, size: 13, weight: note.read ? .medium : .semibold, color: Palette.textPrimary)
        var text: [NSView] = [title]
        if !note.body.isEmpty {
            let body = label(note.body, size: 12, color: Palette.textSecondary)
            body.maximumNumberOfLines = 3
            body.preferredMaxLayoutWidth = 520
            text.append(body)
        }
        text.append(line(note.meta(), size: 10, color: Palette.textTertiary))
        if !note.actions.isEmpty {
            let buttons = note.actions.enumerated().map { index, action in
                HoverButton(action.label, style: index == 0 && note.pending ? .accent : .plain) { [weak module, weak note] in
                    guard let note else { return }
                    module?.invoke(action, on: note)
                }
            }
            text.append(row(buttons, spacing: 6))
        }
        let content = column(text, spacing: 3)
        content.setCustomSpacing(8, after: text[text.count - (note.actions.isEmpty ? 1 : 2)])
        let dismiss = HoverButton(symbol: "xmark", style: .icon, symbolSize: 10, label: "Dismiss") { [weak module, weak note] in
            guard let note else { return }
            module?.dismiss(note)
        }
        let layout = row([icon, content, spacer(), dismiss], spacing: 10)
        layout.alignment = .top
        embed(layout, in: self, inset: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 6), fill: true)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(note.title). \(note.body) \(note.meta())")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
