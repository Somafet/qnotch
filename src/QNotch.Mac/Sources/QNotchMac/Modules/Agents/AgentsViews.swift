import AppKit
import QNotchMacCore

/// Status dot and "api needs you" / "2 working" in the right wing; hidden while nothing runs.
final class AgentPillView: NSStackView {
    private let dot = FillView(fill: Palette.accent, radius: 3.5)
    private let text = line("", size: 12, weight: .semibold, color: Palette.textPrimary)
    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 5
        size(dot, width: 7, height: 7)
        text.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
        [dot, text].forEach(addArrangedSubview)
        identifier = NSUserInterfaceItemIdentifier("agents-segment")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(text value: String?, needsYou: Bool) {
        isHidden = value == nil
        text.stringValue = value ?? ""
        text.textColor = needsYou ? .systemOrange : Palette.textPrimary
        dot.fill = needsYou ? .systemOrange : Palette.accent
        setAccessibilityLabel(value.map { "Agents: \($0)" })
    }
}

final class AgentsTabView: NSView {
    private weak var module: AgentsModule?
    private let list = NSStackView()
    private let header = line("", size: 11, color: Palette.textTertiary)
    private let emptyView: NSView

    init(module: AgentsModule) {
        self.module = module
        emptyView = placeholder(symbol: "sparkles", title: "No agents running", detail: "Connect Claude Code or Codex in Settings, Agents.",
                                action: ("Open Settings", { [weak module] in module?.contextShell?.openSettings(section: "agents") }))
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        header.toolTip = "Today's tokens at API list prices, from Claude Code transcripts. Subscriptions are not billed this way."
        let scroll = NSScrollView()
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(list, in: document, inset: 0)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let stack = column([header, scroll], spacing: 8)
        embed(stack, in: self, inset: 0, fill: true)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        list.widthAnchor.constraint(equalTo: document.widthAnchor).isActive = true
        embed(emptyView, in: self, inset: 0, fill: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyView.isHidden = !module.board.sessions.isEmpty
        let today = module.today
        header.stringValue = today.tokens > 0 ? "Today: \(today.text) at API prices" : ""
        header.isHidden = today.tokens == 0
        for session in module.board.sessions {
            let row = SessionRow(session: session, module: module)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SessionRow: FillView {
    init(session: AgentSession, module: AgentsModule) {
        let color: NSColor = switch session.status {
        case .needsYou: .systemOrange
        case .working: Palette.accent
        case .done: .systemGreen
        case .ready: Palette.textTertiary
        }
        super.init(fill: session.status == .needsYou ? NSColor.systemOrange.withAlphaComponent(0.08) : Palette.card,
                   stroke: session.status == .needsYou ? NSColor.systemOrange.withAlphaComponent(0.4) : Palette.stroke, radius: 10)
        let dot = FillView(fill: color, radius: 4)
        size(dot, width: 8, height: 8)
        let title = line(session.displayTitle, size: 13, weight: .semibold, color: Palette.textPrimary)
        let meta = line(AgentsModule.meta(session), size: 11, color: session.status == .needsYou ? .systemOrange : Palette.textTertiary)
        var subtitle = [meta]
        if !session.title.isEmpty { subtitle.insert(line(session.name + " ·", size: 11, color: Palette.textTertiary), at: 0) }
        let text = column([title, row(subtitle, spacing: 4)], spacing: 2)
        var buttons: [NSView] = []
        if let usage = module.usage[session.id]?.today, usage.tokens > 0 {
            let cost = line(usage.costText, size: 12, weight: .medium, color: Palette.textPrimary)
            let tokens = line("\(AgentUsage.tokens(usage.tokens)) tokens", size: 10, color: Palette.textTertiary)
            cost.alignment = .right; tokens.alignment = .right
            buttons.append(column([cost, tokens], spacing: 0, alignment: .trailing))
        }
        if session.pid != nil || session.link != nil {
            buttons.append(HoverButton(session.link != nil ? "Open" : "Show", style: session.status == .needsYou ? .accent : .plain) { [weak module] in module?.show(session) })
        }
        if session.status == .done || session.status == .ready {
            buttons.append(HoverButton(symbol: "xmark", style: .icon, symbolSize: 10, label: "Clear") { [weak module] in module?.dismiss(session) })
        }
        let layout = row([dot, text, spacer()] + buttons, spacing: 10)
        embed(layout, in: self, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 8), fill: true)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(session.displayTitle). \(AgentsModule.meta(session))")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension AgentsModule {
    func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let rows = connections.map { connection -> NSView in
            let status = status(connection)
            let detail: String
            var buttons: [NSView] = []
            switch status {
            case .connected:
                detail = connection.connectedHint
                buttons.append(button("Disconnect") { [weak self] in self?.toggle(connection, false) })
            case .otherCopy(let path):
                detail = "Connected to another copy of QNotch: \(path)"
                buttons.append(button("Use This Copy") { [weak self] in self?.toggle(connection, true) })
                buttons.append(button("Disconnect") { [weak self] in self?.toggle(connection, false) })
            case .notInstalled:
                detail = "Adds hooks to \(connection.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Your own hooks stay; a backup is kept."
                buttons.append(button("Connect") { [weak self] in self?.toggle(connection, true) })
            case .error(let message):
                detail = "\(connection.fileName) could not be read: \(message)"
            }
            return settingsRow(connection.title, detail: detail, control: row(buttons, spacing: 6), width: width)
        }
        let needs = ActionSwitch("Sound when an agent needs you", value: settings.soundNeedsYou) { [weak self] value in self?.set { $0.soundNeedsYou = value } }
        let done = ActionSwitch("Sound when an agent finishes", value: settings.soundDone) { [weak self] value in self?.set { $0.soundDone = value } }
        return column([
            settingsGroup(rows.isEmpty ? [settingsRow("No agents found", detail: "Install Claude Code or Codex, then come back here.", width: width)] : rows,
                          header: "Connections",
                          footer: "Connect adds QNotch's hooks to the agent's settings. Each event runs QNotch agent, which tells the notch what the session is doing. Nothing is sent anywhere else.",
                          width: width),
            settingsGroup([
                settingsRow("Sound when an agent needs you", detail: "Not during calls. Pick the sound in Settings, Sounds.", control: needs, width: width),
                settingsRow("Sound when an agent finishes", detail: "Only for a finished turn, not when you interrupt it.", control: done, width: width)
            ], header: "Alerts", width: width)
        ], spacing: 22)
    }

    private func toggle(_ connection: Connection, _ on: Bool) {
        do { try setConnected(connection, on) } catch {
            let alert = NSAlert()
            alert.messageText = on ? "QNotch could not connect \(connection.title)." : "QNotch could not disconnect \(connection.title)."
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        contextShell?.openSettings(section: "agents")
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let target = ClosureTarget(action)
        let button = NSButton(title: title, target: target, action: #selector(ClosureTarget.run))
        button.bezelStyle = .rounded
        button.controlSize = .small
        objc_setAssociatedObject(button, "action", target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }
}
