import AppKit

/// Expanded panel body (below the camera band): profile, icon tabs and actions over the active tab.
/// Layout follows the Windows panel; controls, focus and accessibility are AppKit.
final class PanelView: NSView {
    struct Tab { let id: String; let symbol: String; let title: String }

    let tabBar: TabBar
    private let host = NSView()
    private let tabs: [Tab]
    private weak var current: NSView?

    private var pin: HoverButton!
    private var edit: HoverButton!

    init(tabs: [Tab], selected: String, profile: (name: String, image: NSImage?), pinned: Bool,
         select: @escaping (String) -> Void, togglePin: @escaping () -> Void, openSettings: @escaping () -> Void,
         toggleEdit: @escaping () -> Void, reorderTabs: @escaping ([String]) -> Void) {
        self.tabs = tabs
        tabBar = TabBar(items: tabs.map { ($0.id, $0.symbol, $0.title) }, selected: tabs.firstIndex { $0.id == selected } ?? 0) { index in
            select(tabs[index].id)
        }
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("panel")

        let name = profile.name
        let avatar = FillView(fill: Palette.accentSoft, stroke: Palette.stroke, radius: 15)
        size(avatar, width: 30, height: 30)
        if let image = profile.image {
            let photo = NSImageView(image: image)
            photo.imageScaling = .scaleProportionallyUpOrDown
            photo.wantsLayer = true
            photo.layer?.cornerRadius = 15
            photo.layer?.masksToBounds = true
            photo.setAccessibilityElement(false)
            embed(photo, in: avatar, inset: 0, fill: true)
        } else {
            let initial = line(String(name.prefix(1)).uppercased(), size: 13, weight: .semibold, color: Palette.accent)
            initial.translatesAutoresizingMaskIntoConstraints = false
            avatar.addSubview(initial)
            NSLayoutConstraint.activate([initial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor), initial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)])
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        let greeting = column([line(name, size: 13, weight: .semibold, color: Palette.textPrimary),
                               line(formatter.string(from: Date()), size: 11, color: Palette.textTertiary)], spacing: 1)
        let profile = row([avatar, greeting], spacing: 9)
        profile.setAccessibilityElement(false)

        let settings = HoverButton(symbol: "gearshape", style: .icon, symbolSize: 14, label: "Settings", action: openSettings)
        settings.identifier = NSUserInterfaceItemIdentifier("open-settings")
        pin = HoverButton(symbol: "pin", style: .icon, symbolSize: 13, label: "Keep panel open", action: togglePin)
        pin.identifier = NSUserInterfaceItemIdentifier("panel-pin")
        edit = HoverButton(symbol: "pencil", style: .icon, symbolSize: 13, label: "Edit layout", action: toggleEdit)
        edit.identifier = NSUserInterfaceItemIdentifier("panel-edit")
        let actions = row([edit, pin, settings], spacing: 2)
        for view in [profile, tabBar, actions, host] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            profile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            profile.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            profile.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.leadingAnchor, constant: -8),
            tabBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            host.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        host.wantsLayer = true
        setPinned(pinned)
        let fixed = tabs.prefix { $0.id == "home" || $0.id == "search" }.count
        tabBar.fixed = fixed
        tabBar.reordered = { order in reorderTabs(order.dropFirst(fixed).map { tabs[$0].id }) }
        edit.isHidden = selected != "home"
    }

    func setEditing(_ editing: Bool, onHome: Bool) {
        tabBar.editing = editing
        edit.isHidden = !onHome && !editing
        edit.setSymbol(editing ? "checkmark" : "pencil", size: 13, label: editing ? "Done editing" : "Edit layout")
        edit.tint = editing ? Palette.accent : nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPinned(_ pinned: Bool) {
        pin.setSymbol(pinned ? "pin.fill" : "pin", size: 13, label: pinned ? "Unpin panel" : "Keep panel open")
        pin.tint = pinned ? Palette.accent : nil
        pin.setAccessibilityValue(pinned ? "on" : "off")
    }

    func select(_ id: String, animated: Bool) {
        tabBar.select(tabs.firstIndex { $0.id == id } ?? 0, animated: animated)
    }

    /// Shows `content` in the body, sliding in from the side of the newly selected tab. Content
    /// still on its way out turns around from where it is.
    func show(_ content: NSView, direction: Int, animated: Bool) {
        guard content !== current else { return }
        let previous = current
        current = content
        let leaving = content.superview === host
        if leaving, animated {
            Motion.resume(content, duration: 0.2)
        } else {
            content.layer?.removeAllAnimations()
            if !leaving {
                content.removeFromSuperview()
                embed(content, in: host, inset: 0, fill: true)
            }
        }
        guard let previous else { return }
        if animated, Motion.fades {
            let offset = CGFloat(direction) * 14
            if !leaving { Motion.enter(content, delay: 0.05, duration: 0.26, dx: offset) }
            Motion.leave(previous, duration: 0.12, dx: -offset) { [weak self, weak previous] in
                guard let previous, previous !== self?.current else { return }
                previous.removeFromSuperview()
                previous.layer?.removeAllAnimations()
            }
        } else {
            previous.removeFromSuperview()
        }
    }
}

/// Search tab: a fixed field over a bounded results viewport. Keyboard selection keeps the caret in the field.
final class SearchView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let results = SearchResultsColumn()
    private let scroll = NSScrollView()
    private var rows: [(background: FillView, button: HoverButton)] = []
    private var selectedIndex: Int?
    private let find: (String) -> [SearchHit]
    private var hits: [SearchHit] = []

    init(find: @escaping (String) -> [SearchHit]) {
        self.find = find
        super.init(frame: .zero)
        wantsLayer = true
        let box = FillView(fill: Palette.control, stroke: Palette.stroke, radius: 10)
        size(box, height: 36)
        let glass = symbol("magnifyingglass", size: 13, weight: .medium, color: Palette.textTertiary)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = Palette.textPrimary
        field.placeholderAttributedString = NSAttributedString(string: "Search QNotch", attributes: [
            .foregroundColor: Palette.textTertiary, .font: NSFont.systemFont(ofSize: 14)
        ])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Search QNotch")
        field.identifier = NSUserInterfaceItemIdentifier("search-field")
        let inner = row([glass, field], spacing: 8)
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 2
        results.translatesAutoresizingMaskIntoConstraints = false
        results.identifier = NSUserInterfaceItemIdentifier("search-results")
        scroll.identifier = NSUserInterfaceItemIdentifier("search-viewport")
        scroll.documentView = results
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        for child in [box, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            results.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            results.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            results.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Focuses the field, optionally appending text typed before the tab was shown.
    func focus(appending text: String) {
        field.stringValue += text
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        reload()
    }

    func clear() { field.stringValue = ""; reload() }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(offset: 1)
        case #selector(NSResponder.moveUp(_:)):
            select(offset: -1)
        case #selector(NSResponder.insertNewline(_:)):
            Analytics.record("search", "submit")
            if let selectedIndex, hits.indices.contains(selectedIndex) { Analytics.record("search", "run_result"); hits[selectedIndex].run() }
        default:
            return false
        }
        return true
    }

    private func reload() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = query.isEmpty ? [] : Array(find(query).prefix(6))
        selectedIndex = hits.isEmpty ? nil : 0
        rows.removeAll()
        results.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if query.isEmpty {
            results.addArrangedSubview(hint("Type to find modules and actions.", symbol: "sparkle.magnifyingglass"))
        } else if hits.isEmpty {
            results.addArrangedSubview(hint("No results for “\(query)”", symbol: "questionmark.circle"))
        } else {
            for (index, hit) in hits.enumerated() {
                let background = FillView(fill: nil, radius: 8)
                let button = HoverButton("", style: .row, label: hit.title) { Analytics.record("search", "run_result"); hit.run() }
                button.identifier = NSUserInterfaceItemIdentifier("search-result-\(index)")
                button.refusesFirstResponder = true
                embed(button, in: background, inset: 0, fill: true)
                let icon = symbol(hit.symbol, size: 14, weight: .medium, color: Palette.accent)
                size(icon, width: 18)
                let title = line(hit.title, size: 13, weight: .medium, color: Palette.textPrimary)
                let detail = line(hit.detail, size: 11, color: Palette.textTertiary)
                let text = column([title, detail], spacing: 1)
                for label in [title, detail] {
                    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
                }
                let content = row([icon, text], spacing: 10)
                content.distribution = .fill
                content.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(content)
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
                    content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
                    content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    button.heightAnchor.constraint(equalToConstant: 44)
                ])
                results.addArrangedSubview(background)
                rows.append((background, button))
            }
        }
        for row in results.arrangedSubviews { row.widthAnchor.constraint(equalTo: results.widthAnchor).isActive = true }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        revealSelection()
    }

    private func select(offset: Int) {
        guard !hits.isEmpty else { return }
        selectedIndex = min(hits.count - 1, max(0, (selectedIndex ?? 0) + offset))
        revealSelection()
    }

    private func revealSelection() {
        for (index, row) in rows.enumerated() {
            let selected = index == selectedIndex
            row.button.isSelectedLook = selected
            row.background.fill = selected ? Palette.accentSoft : nil
        }
        if let selectedIndex, rows.indices.contains(selectedIndex) {
            layoutSubtreeIfNeeded()
            let row = rows[selectedIndex].background
            row.scrollToVisible(row.bounds)
        }
    }

    private func hint(_ text: String, symbol name: String) -> NSView {
        let message = line(text, size: 12, color: Palette.textTertiary)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let view = row([symbol(name, size: 13, color: Palette.textTertiary), message], spacing: 8)
        let wrap = NSView()
        embed(view, in: wrap, inset: NSEdgeInsets(top: 10, left: 10, bottom: 4, right: 10), fill: true)
        return wrap
    }
}

private final class SearchResultsColumn: NSStackView {
    override var isFlipped: Bool { true }
}

/// Centered glyph, title, subtitle and an optional action (Windows Placeholder).
func placeholder(symbol name: String, title: String, detail: String, action: (title: String, run: () -> Void)? = nil) -> NSView {
    var views: [NSView] = [
        symbol(name, size: 26, weight: .light, color: Palette.textTertiary),
        line(title, size: 14, weight: .semibold, color: Palette.textPrimary),
        line(detail, size: 12, color: Palette.textSecondary)
    ]
    if let action { views.append(HoverButton(action.title, style: .plain, action: action.run)) }
    let stack = column(views, spacing: 8, alignment: .centerX)
    stack.setCustomSpacing(12, after: views[0])
    if views.count > 3 { stack.setCustomSpacing(16, after: views[2]) }
    let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: card.centerXAnchor), stack.centerYAnchor.constraint(equalTo: card.centerYAnchor)])
    return card
}
