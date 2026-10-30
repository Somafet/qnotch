import AppKit
import QNotchMacCore
import UniformTypeIdentifiers

protocol AiDisplay: AnyObject { func reload() }

private func usageColor(_ percent: Double) -> NSColor { percent >= 90 ? .systemRed : percent >= 75 ? .systemOrange : Palette.accent }

/// Thin bar that turns orange, then red, as usage climbs (Windows UsageBar).
private final class UsageBar: FillView {
    private let bar = FillView(radius: 2.5)
    private let percent: Double

    init(percent: Double) {
        self.percent = min(100, max(0, percent))
        super.init(fill: Palette.controlHover, radius: 2.5)
        bar.fill = usageColor(self.percent)
        addSubview(bar)
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityValue("\(Int(self.percent.rounded())) percent used")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        bar.isHidden = percent <= 0
        bar.frame = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * percent / 100), height: bounds.height)
    }
}

/// The Claude row's account choice, drawn as text with a chevron (Windows AccountPicker): click for
/// a menu of the signed-in accounts.
private final class AccountPicker: NSButton {
    private let prefix: String
    private let size: CGFloat
    private let names: [String]
    private let selected: Int
    private let changed: (Int) -> Void
    private weak var shell: ModuleShell?
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(prefix: String = "", names: [String], selected: Int, size: CGFloat, shell: ModuleShell?, changed: @escaping (Int) -> Void) {
        self.prefix = prefix
        self.size = size
        self.names = names
        self.selected = selected
        self.changed = changed
        self.shell = shell
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .noImage
        focusRingType = .exterior
        target = self
        action = #selector(open)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("Claude account: \(names[selected])")
        toolTip = "Account"
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    private func refresh() {
        let color = hovering ? Palette.textPrimary : Palette.textSecondary
        let text = NSMutableAttributedString(string: prefix + names[selected], attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: size, weight: .regular)])
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size - 4, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            attachment.bounds = NSRect(x: 0, y: 1, width: chevron.size.width, height: chevron.size.height)
            text.append(NSAttributedString(string: " "))
            text.append(NSAttributedString(attachment: attachment))
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
        }
        attributedTitle = text
        contentTintColor = color
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    @objc private func open() {
        let menu = NSMenu()
        for (index, name) in names.enumerated() {
            let item = ClosureMenuItem(title: name) { [changed] in changed(index) }
            item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        // The menu tracks synchronously; the hold keeps the panel open while the pointer is in it.
        let hold = shell?.holdOpen()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        withExtendedLifetime(hold) {}
    }
}

private extension AiModule {
    /// The account picker for the Claude row, or nil with fewer than two accounts.
    func accountPicker(for provider: Provider, prefix: String, size: CGFloat) -> NSView? {
        guard provider.id == "claude", accounts.count > 1, let shown = shownAccount else { return nil }
        let list = accounts
        return AccountPicker(prefix: prefix, names: list.map(name(of:)), selected: list.firstIndex(of: shown) ?? 0, size: size, shell: contextShell) { [weak self] index in
            self?.showAccount(list[index])
        }
    }
}

/// The Home card (Windows AiUsageCard): per provider its name or account, the first window's
/// percentage and bar, then the second window and the reset. Unavailable never shows a number.
final class AiUsageCardView: NSView, AiDisplay, NSGestureRecognizerDelegate {
    private weak var module: AiModule?
    private let list = NSStackView()
    private let empty = label("No usage providers enabled.\nTurn them on in Settings.", size: 11, color: Palette.textTertiary)

    init(module: AiModule) {
        self.module = module
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        embed(list, in: self, inset: 0)
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)])
        let click = NSClickGestureRecognizer(target: self, action: #selector(open))
        click.delegate = self
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func open() { module?.contextShell?.selectTab("ai") }

    /// A click on the account picker chooses an account; anywhere else opens the AI tab.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        !(hitTest(convert(event.locationInWindow, from: nil)) is AccountPicker)
    }

    func reload() {
        guard let module else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let providers = module.providers
        empty.isHidden = !providers.isEmpty
        for provider in providers {
            let view = summary(provider, module: module)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func summary(_ provider: AiModule.Provider, module: AiModule) -> NSView {
        let (headlineText, percent, subText) = AiFormat.summary(provider.result)
        let title = module.accountPicker(for: provider, prefix: "Claude: ", size: 11) ?? line(provider.name, size: 11, color: Palette.textSecondary)
        let ok = percent != nil
        let headline = line(headlineText, size: 12, weight: ok ? .semibold : .regular, color: ok ? Palette.textPrimary : Palette.textTertiary)
        if ok { headline.font = .rounded(12, weight: .semibold, monospacedDigits: true) }
        headline.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = row([title, spacer(), headline], spacing: 8)
        var views: [NSView] = [top]
        if let percent { views.append(UsageBar(percent: percent)) }
        if !subText.isEmpty {
            let sub = line(subText, size: 11, color: Palette.textTertiary)
            sub.lineBreakMode = .byTruncatingTail
            sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(sub)
        }
        let stack = column(views, spacing: 0)
        if views.count > 1 { stack.setCustomSpacing(4, after: top) }
        if let bar = views.dropFirst().first as? UsageBar, views.count > 2 { stack.setCustomSpacing(3, after: bar) }
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.toolTip = {
            switch provider.result {
            case .ok(_, _, let asOf, _)?: return "Updated " + AiTabView.when(asOf)
            case .unavailable(let reason)?: return reason
            case nil: return "Waiting for the first reading"
            }
        }()
        return stack
    }
}

/// App tiles: icon and slot number; click opens the app.
final class AiAppsView: NSView, AiDisplay {
    private weak var module: AiModule?
    private let compact: Bool
    private let tiles = NSStackView()
    private let empty = line("No AI apps found. Add one in Settings, AI.", size: 12, color: Palette.textTertiary)

    init(module: AiModule, compact: Bool) {
        self.module = module
        self.compact = compact
        super.init(frame: .zero)
        tiles.orientation = .horizontal
        tiles.spacing = compact ? 6 : 10
        embed(column([tiles, empty], spacing: 0), in: self, inset: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var shown: [(AiModule.App, Int?)] = (1...6).compactMap { slot in module.app(inSlot: slot).map { ($0, slot) } }
        for app in module.apps where !shown.contains(where: { $0.0 == app }) { shown.append((app, nil)) }
        for (app, slot) in shown.prefix(compact ? 4 : 8) {
            tiles.addArrangedSubview(AppTile(app: app, slot: slot, compact: compact) { [weak module] in module?.launch(app) })
        }
        empty.isHidden = !shown.isEmpty
    }
}

private final class AppTile: FillView {
    private let action: () -> Void
    private var tracking: NSTrackingArea?
    init(app: AiModule.App, slot: Int?, compact: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(fill: nil, radius: 10)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: app.url.path))
        size(icon, width: compact ? 34 : 40, height: compact ? 34 : 40)
        var views: [NSView] = [icon]
        if !compact { views.append(line(app.name, size: 11, color: Palette.textSecondary)) }
        let stack = column(views, spacing: 4, alignment: .centerX)
        embed(stack, in: self, inset: 6)
        if let slot {
            let badge = line("\(slot)", size: 9, weight: .bold, color: Palette.onAccent)
            let pill = FillView(fill: Palette.accent, radius: 7)
            size(pill, width: 14, height: 14)
            badge.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(badge)
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
            NSLayoutConstraint.activate([badge.centerXAnchor.constraint(equalTo: pill.centerXAnchor), badge.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                                         pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), pill.topAnchor.constraint(equalTo: topAnchor, constant: 2)])
        }
        let hotkey = slot.map { " (⌃⌥\($0))" } ?? ""
        toolTip = app.name + hotkey
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(app.name)\(hotkey)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { setFill(Palette.control, animated: true) }
    override func mouseExited(with event: NSEvent) { setFill(nil, animated: true) }
}

/// The AI tab (Windows AiTab): a card per provider with every usage window, then the apps.
final class AiTabView: NSView, AiDisplay, TabHeaderProviding {
    private(set) var tabHeaderActions: NSView = NSView()
    private weak var module: AiModule?
    private let usage = NSStackView()
    private let status = line("", size: 11, color: Palette.textTertiary)
    private let refreshButton: HoverButton
    private let apps: AiAppsView

    /// "14:05" today, "Mon 14:05" on another day (Windows AiFormat.When).
    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "EEEjmm")
        return formatter.string(from: date)
    }

    init(module: AiModule) {
        self.module = module
        apps = AiAppsView(module: module, compact: false)
        refreshButton = HoverButton(symbol: "arrow.clockwise", style: .icon, symbolSize: 11, label: "Refresh now") { [weak module] in Analytics.record("ai", "refresh"); module?.refresh() }
        super.init(frame: .zero)
        usage.orientation = .vertical
        usage.alignment = .leading
        usage.spacing = 10
        let settings = HoverButton(symbol: "gearshape", style: .icon, symbolSize: 12, label: "AI settings") { [weak module] in module?.contextShell?.openSettings(section: "ai") }
        tabHeaderActions = row([refreshButton, settings], spacing: 4)
        let header = row([line("Usage", size: 14, weight: .semibold, color: Palette.textPrimary), spacer(), status], spacing: 8)
        let appsHeader = row([line("Apps", size: 14, weight: .semibold, color: Palette.textPrimary), spacer(),
                              line("Numbered apps open with ⌃⌥1 to ⌃⌥6 (Settings, Hotkeys)", size: 11, color: Palette.textTertiary),
                              HoverButton(symbol: "arrow.clockwise", style: .icon, symbolSize: 11, label: "Scan for AI apps") { [weak module] in Analytics.record("ai", "scan"); module?.scan() }], spacing: 8)
        let stack = column([header, usage, appsHeader, apps], spacing: 8)
        stack.setCustomSpacing(16, after: usage)
        // Several windows per provider can outgrow the panel: the tab scrolls.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(stack, in: document, inset: NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0), fill: true)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        embed(scroll, in: self, inset: 0, fill: true)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        for view in [header, usage, appsHeader] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        status.stringValue = module.refreshing ? "Checking…" : module.checked.map { "Checked " + Self.when($0) } ?? ""
        refreshButton.isEnabled = !module.refreshing
        usage.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let providers = module.providers
        if providers.isEmpty {
            let open = HoverButton("Open Settings", style: .plain) { [weak module] in module?.contextShell?.openSettings(section: "ai") }
            let empty = column([line("No usage providers enabled", size: 14, weight: .semibold, color: Palette.textPrimary),
                                line("Turn on Claude Code or Codex in the AI settings.", size: 11, color: Palette.textTertiary), open], spacing: 6, alignment: .centerX)
            empty.setCustomSpacing(10, after: empty.arrangedSubviews[1])
            usage.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: usage.widthAnchor).isActive = true
        }
        // Two cards to a row, as on Windows; an odd last card keeps its half width.
        var index = 0
        while index < providers.count {
            let pair = providers[index..<min(index + 2, providers.count)].map { card($0, module: module) as NSView }
            let line = row(pair.count == 2 ? pair : pair + [NSView()], spacing: 10)
            line.distribution = .fillEqually
            line.alignment = .top
            usage.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: usage.widthAnchor).isActive = true
            index += 2
        }
        apps.reload()
    }

    private func card(_ provider: AiModule.Provider, module: AiModule) -> NSView {
        let name = line(provider.name, size: 14, weight: .semibold, color: Palette.textPrimary)
        var header: [NSView] = [name]
        if let picker = module.accountPicker(for: provider, prefix: "", size: 12) { header.append(picker) }
        var rows: [NSView] = []
        switch provider.result {
        case .ok(let windows, let plan, let asOf, let banked)?:
            let updated = line("Updated " + Self.when(asOf), size: 11, color: Palette.textTertiary)
            updated.lineBreakMode = .byTruncatingTail
            updated.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            header.append(updated)
            header.append(spacer())
            if let plan, !plan.isEmpty { header.append(Self.chip(plan)) }
            for window in windows { rows.append(Self.window(window)) }
            if let banked {
                let text = line(banked.text(), size: 11, color: Palette.textTertiary)
                let expiry = banked.expiresAt.map { "Expires " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Does not expire"
                text.toolTip = banked.label.map { $0.isEmpty ? expiry : "\($0)\n\(expiry)" } ?? expiry
                rows.append(text)
            }
        case .unavailable(let reason)?:
            header.append(spacer())
            let icon = symbol("exclamationmark.triangle.fill", size: 13, weight: .medium, color: .systemOrange)
            let detail = label(reason, size: 11, color: Palette.textSecondary)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = column([line("Unavailable", size: 13, weight: .semibold, color: Palette.textPrimary), detail], spacing: 2)
            let block = row([icon, text], spacing: 8)
            block.alignment = .top
            rows.append(block)
        case nil:
            header.append(spacer())
            rows.append(line("Checking…", size: 11, color: Palette.textTertiary))
        }
        let top = row(header, spacing: 8)
        let stack = column([top] + rows, spacing: 10)
        stack.setCustomSpacing(12, after: top)
        ([top] + rows).forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 14)
        embed(stack, in: card, inset: NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16), fill: true)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(provider.name)
        return card
    }

    /// "5-hour   Resets in 2h 5m" on the left, "38% used   62% left" on the right, the bar below.
    private static func window(_ window: UsageWindow) -> NSView {
        let left = NSMutableAttributedString(string: window.label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.textPrimary])
        let reset = window.resetText()
        if !reset.isEmpty {
            left.append(NSAttributedString(string: "   " + reset, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.textTertiary]))
        }
        let right = NSMutableAttributedString(string: window.usedText, attributes: [.font: NSFont.rounded(13, weight: .semibold, monospacedDigits: true), .foregroundColor: Palette.textPrimary])
        right.append(NSAttributedString(string: " used", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.textTertiary]))
        right.append(NSAttributedString(string: "   " + window.leftText, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.textSecondary]))
        let leftField = NSTextField(labelWithAttributedString: left)
        leftField.lineBreakMode = .byTruncatingTail
        leftField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rightField = NSTextField(labelWithAttributedString: right)
        rightField.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = row([leftField, spacer(), rightField], spacing: 8)
        top.alignment = .lastBaseline
        let bar = UsageBar(percent: window.usedPercent)
        let block = column([top, bar], spacing: 6)
        [top, bar].forEach { $0.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
        if let at = window.resetsAt { block.toolTip = "Resets " + when(at) }
        return block
    }

    /// The plan in an accent chip ("Max 20x").
    private static func chip(_ text: String) -> NSView {
        let chip = FillView(fill: Palette.accentSoft, radius: 6)
        let title = line(text, size: 11, weight: .semibold, color: Palette.accent)
        embed(title, in: chip, inset: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8), fill: true)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        return chip
    }
}

extension AiModule {
    func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let claudeSwitch = ActionSwitch("Claude Code", value: settings.claude) { [weak self] value in Analytics.setting("ai_claude", enabled: value); self?.set { $0.claude = value } }
        let codexSwitch = ActionSwitch("Codex", value: settings.codex) { [weak self] value in Analytics.setting("ai_codex", enabled: value); self?.set { $0.codex = value } }
        let every = ActionPopUp("Refresh every", items: AiSettings.refreshChoices.map { "\($0) minutes" },
                                selected: AiSettings.refreshChoices.firstIndex(of: settings.refreshMinutes) ?? 1) { [weak self] index in
            Analytics.setting("ai_refresh_minutes"); self?.set { $0.refreshMinutes = AiSettings.refreshChoices[index] }
        }
        var usageRows = [
            settingsRow("Claude Code", detail: "Asks Claude Code's own command line tool for your plan usage, as T3 Code does. For banked resets, QNotch reads Claude Code's sign-in the way Claude Code does (no macOS prompt) and sends it only to Anthropic. Every signed-in ~/.claude-* folder is an account; pick one on the usage row.", control: claudeSwitch, width: width),
            settingsRow("Codex", detail: "Reads the rate limits Codex writes to its session files. Nothing is sent anywhere.", control: codexSwitch, width: width),
            settingsRow("Refresh every", control: every, width: width)
        ]
        // With several Claude Code accounts, each can be given a name for the usage row's picker.
        if accounts.count > 1 {
            let rows = accounts.map { account -> NSView in
                let field = NSTextField(string: name(of: account))
                field.placeholderString = account.folderName
                field.widthAnchor.constraint(equalToConstant: 170).isActive = true
                field.cell?.sendsActionOnEndEditing = true
                field.setAccessibilityLabel("Name of the Claude account in \(account.path)")
                field.onAction { [weak self, weak field] in
                    guard let self, let field else { return }
                    self.renameAccount(account, to: field.stringValue)
                    field.stringValue = self.name(of: account)
                }
                return settingsRow("Claude account name", detail: account.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), control: field, width: width)
            }
            usageRows.insert(contentsOf: rows, at: 1)
        }
        let choices: [(String?, String)] = [(nil, "None")] + apps.map { ($0.id, $0.name) }
        let slotRows = (1...6).map { slot -> NSView in
            let picker = ActionPopUp("Slot \(slot)", items: choices.map(\.1), selected: choices.firstIndex { $0.0 == settings.slots[slot - 1] } ?? 0) { [weak self] index in
                self?.setSlot(slot, choices[index].0)
            }
            return settingsRow("⌃⌥\(slot)", control: picker, width: width)
        }
        let add = actionButton("Add App…", size: .regular) { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.message = "Choose an app to add"
            if panel.runModal() == .OK, let url = panel.url { self?.addCustom(url) }
            self?.contextShell?.openSettings(section: "ai")
        }
        var customRows: [NSView] = apps.filter(\.custom).map { app in
            let remove = actionButton("Remove") { [weak self] in self?.removeCustom(app); self?.contextShell?.openSettings(section: "ai") }
            return settingsRow(app.name, detail: app.url.path, control: remove, width: width)
        }
        customRows.append(settingsRow("Other apps", detail: "Found: ChatGPT, Claude, Codex, Cursor and Antigravity when installed. Add any other app here.", control: add, width: width))
        return column([
            settingsGroup(usageRows, header: "Usage", width: width),
            settingsGroup(slotRows, header: "App shortcuts", footer: "Change the keys in Settings, Hotkeys.", width: width),
            settingsGroup(customRows, header: "Apps", width: width)
        ], spacing: 22)
    }
}
