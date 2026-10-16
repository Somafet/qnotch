import AppKit
import QNotchMacCore
import UniformTypeIdentifiers

protocol AiDisplay: AnyObject { func reload() }

private func usageColor(_ percent: Double) -> NSColor { percent >= 90 ? .systemRed : percent >= 75 ? .systemOrange : Palette.accent }

/// One provider in compact form: name and plan, the first window's bar, a sub line.
private func providerSummary(_ provider: AiModule.Provider, now: Date = Date()) -> NSView {
    let name = line(provider.name, size: 12, weight: .semibold, color: Palette.textPrimary)
    guard case .ok(let windows, let plan, _, _)? = provider.result, let first = windows.first else {
        let reason: String
        if case .unavailable(let text)? = provider.result { reason = text } else { reason = "Checking…" }
        let detail = line(reason, size: 11, color: Palette.textTertiary)
        detail.toolTip = reason
        return column([row([name, spacer()], spacing: 4), detail], spacing: 3)
    }
    let headline = line(first.usedText, size: 12, weight: .semibold, color: usageColor(first.usedPercent))
    headline.font = .rounded(12, weight: .semibold, monospacedDigits: true)
    let planLabel = line(plan ?? "", size: 10, weight: .medium, color: Palette.textTertiary)
    let bar = ProgressBar()
    bar.set(progress: first.usedPercent / 100, animated: false)
    let reset = first.resetText(now: now)
    let sub = windows.count > 1 ? "\(windows[1].label) \(windows[1].usedText)  ·  \(reset.isEmpty ? first.label : reset.lowercased())" : (reset.isEmpty ? first.label : reset.lowercased())
    let stack = column([row([name, planLabel, spacer(), headline], spacing: 5), bar, line(sub, size: 10, color: Palette.textTertiary)], spacing: 4)
    bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return stack
}

final class AiUsageCardView: NSView, AiDisplay {
    private weak var module: AiModule?
    private let list = NSStackView()
    init(module: AiModule) {
        self.module = module
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        embed(list, in: self, inset: 0)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(open)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func open() { module?.contextShell?.selectTab("ai") }

    func reload() {
        guard let module else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let providers = module.providers
        if providers.isEmpty { list.addArrangedSubview(line("Usage providers are off in Settings, AI.", size: 12, color: Palette.textTertiary)) }
        for provider in providers {
            let view = providerSummary(provider)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
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

/// The AI tab: each provider's windows with bars and resets, then the apps.
final class AiTabView: NSView, AiDisplay {
    private weak var module: AiModule?
    private let usage = NSStackView()
    private let status = line("", size: 11, color: Palette.textTertiary)
    private let apps: AiAppsView

    init(module: AiModule) {
        self.module = module
        apps = AiAppsView(module: module, compact: false)
        super.init(frame: .zero)
        usage.orientation = .vertical
        usage.alignment = .leading
        usage.spacing = 12
        let refresh = HoverButton(symbol: "arrow.clockwise", style: .icon, symbolSize: 11, label: "Refresh usage") { [weak module] in module?.refresh() }
        let settings = HoverButton(symbol: "slider.horizontal.3", style: .icon, symbolSize: 11, label: "AI settings") { [weak module] in module?.contextShell?.openSettings(section: "ai") }
        let header = row([line("Usage", size: 13, weight: .semibold, color: Palette.textPrimary), status, spacer(), refresh, settings], spacing: 6)
        let appsHeader = row([line("Apps", size: 13, weight: .semibold, color: Palette.textPrimary), line("⌃⌥1 to ⌃⌥6 open numbered apps", size: 11, color: Palette.textTertiary)], spacing: 8)
        let stack = column([header, usage, appsHeader, apps], spacing: 10)
        stack.setCustomSpacing(18, after: usage)
        // Several windows per provider can outgrow the panel: the tab scrolls.
        let document = AiFlippedView()
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
        for view in [header, usage] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        status.stringValue = module.refreshing ? "Checking…" : module.checked.map { "Checked " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
        usage.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for provider in module.providers {
            let view = providerDetail(provider)
            usage.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: usage.widthAnchor).isActive = true
        }
        apps.reload()
    }

    private func providerDetail(_ provider: AiModule.Provider) -> NSView {
        let name = line(provider.name, size: 12, weight: .semibold, color: Palette.textPrimary)
        guard case .ok(let windows, let plan, let asOf, let banked)? = provider.result else {
            let reason: String
            if case .unavailable(let text)? = provider.result { reason = text } else { reason = "Checking…" }
            return column([name, label(reason, size: 11, color: Palette.textTertiary)], spacing: 3)
        }
        var rows: [NSView] = [row([name, line(plan ?? "", size: 11, weight: .medium, color: Palette.textTertiary), spacer(),
                                   line("Updated " + DateFormatter.localizedString(from: asOf, dateStyle: .none, timeStyle: .short), size: 10, color: Palette.textTertiary)], spacing: 6)]
        for window in windows {
            let bar = ProgressBar()
            bar.set(progress: window.usedPercent / 100, animated: false)
            let used = line("\(window.usedText) used", size: 11, weight: .semibold, color: usageColor(window.usedPercent))
            let top = row([line(window.label, size: 11, weight: .medium, color: Palette.textSecondary), spacer(), used,
                           line("· \(window.leftText)", size: 11, color: Palette.textTertiary)], spacing: 4)
            let block = column([top, bar, line(window.resetText(), size: 10, color: Palette.textTertiary)], spacing: 3)
            for view in [top, bar] { view.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
            rows.append(block)
        }
        if let banked { rows.append(line(banked.text(), size: 11, color: Palette.accent)) }
        let stack = column(rows, spacing: 6)
        rows.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
}

extension AiModule {
    func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let claudeSwitch = ActionSwitch("Claude Code", value: settings.claude) { [weak self] value in self?.set { $0.claude = value } }
        let codexSwitch = ActionSwitch("Codex", value: settings.codex) { [weak self] value in self?.set { $0.codex = value } }
        let every = ActionPopUp("Refresh every", items: AiSettings.refreshChoices.map { "\($0) minutes" },
                                selected: AiSettings.refreshChoices.firstIndex(of: settings.refreshMinutes) ?? 1) { [weak self] index in
            self?.set { $0.refreshMinutes = AiSettings.refreshChoices[index] }
        }
        var usageRows = [
            settingsRow("Claude Code", detail: "Reads the sign-in Claude Code keeps in your Keychain (macOS asks once) and asks Anthropic for your plan usage.", control: claudeSwitch, width: width),
            settingsRow("Codex", detail: "Reads the rate limits Codex writes to its session files. Nothing is sent anywhere.", control: codexSwitch, width: width),
            settingsRow("Refresh every", control: every, width: width)
        ]
        let accounts = claudeAccounts
        if accounts.count > 1 {
            let picker = ActionPopUp("Claude account", items: accounts.map(\.name), selected: accounts.firstIndex { $0.path == settings.claudeAccount } ?? 0) { [weak self] index in
                self?.set { $0.claudeAccount = accounts[index].path }
            }
            usageRows.insert(settingsRow("Claude account", detail: "Which Claude Code config folder to show.", control: picker, width: width), at: 1)
        }
        let choices: [(String?, String)] = [(nil, "None")] + apps.map { ($0.id, $0.name) }
        let slotRows = (1...6).map { slot -> NSView in
            let picker = ActionPopUp("Slot \(slot)", items: choices.map(\.1), selected: choices.firstIndex { $0.0 == settings.slots[slot - 1] } ?? 0) { [weak self] index in
                self?.setSlot(slot, choices[index].0)
            }
            return settingsRow("⌃⌥\(slot)", control: picker, width: width)
        }
        let addTarget = ClosureTarget { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.message = "Choose an app to add"
            if panel.runModal() == .OK, let url = panel.url { self?.addCustom(url) }
            self?.contextShell?.openSettings(section: "ai")
        }
        let add = NSButton(title: "Add App…", target: addTarget, action: #selector(ClosureTarget.run))
        add.bezelStyle = .rounded
        objc_setAssociatedObject(add, "action", addTarget, .OBJC_ASSOCIATION_RETAIN)
        var customRows: [NSView] = apps.filter(\.custom).map { app in
            let target = ClosureTarget { [weak self] in self?.removeCustom(app); self?.contextShell?.openSettings(section: "ai") }
            let remove = NSButton(title: "Remove", target: target, action: #selector(ClosureTarget.run))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            objc_setAssociatedObject(remove, "action", target, .OBJC_ASSOCIATION_RETAIN)
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

private final class AiFlippedView: NSView {
    override var isFlipped: Bool { true }
}
