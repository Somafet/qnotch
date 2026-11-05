import AppKit
import QNotchMacCore

protocol TaildropDisplay: AnyObject { func reload() }

private func resultColor(_ result: TaildropResult) -> NSColor { result.success ? .systemGreen : .systemRed }

// MARK: - Device tile

/// One device: click to choose files (dragged files go through the notch's drop screen).
/// Offline devices, and every other device while a send runs, are disabled. A native control, so focus, Space/Return and
/// VoiceOver's press work like a button.
final class TaildropTile: NSControl, OutlineRoleProviding {
    let device: TaildropTarget
    private weak var module: TaildropModule?
    private let compact: Bool
    private let status: NSTextField
    private var hovering = false { didSet { refreshLook() } }
    private var pressing = false { didSet { refreshLook() } }
    private var tracking: NSTrackingArea?
    /// Stored here: a cell-less NSControl keeps no enabled state of its own.
    private var enabledState = true
    override var isEnabled: Bool {
        get { enabledState }
        set { enabledState = newValue; if !newValue { pressing = false } }
    }

    init(target: TaildropTarget, module: TaildropModule, compact: Bool) {
        self.device = target
        self.module = module
        self.compact = compact
        status = line("", size: 11, color: Palette.textTertiary)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = compact ? 8 : 12
        focusRingType = .exterior
        let icon = symbol(NSImage(systemSymbolName: target.symbol, accessibilityDescription: nil) == nil ? "desktopcomputer" : target.symbol,
                          size: compact ? 12 : 18, color: Palette.textSecondary)
        size(icon, width: compact ? 18 : 28)
        let name = line(target.name, size: compact ? 12 : 13, weight: compact ? .medium : .semibold, color: Palette.textPrimary)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let layout: NSStackView
        if compact {
            status.setContentHuggingPriority(.required, for: .horizontal)
            layout = row([icon, name, spacer(), status], spacing: 6)
            embed(layout, in: self, inset: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8), fill: true)
            heightAnchor.constraint(equalToConstant: 24).isActive = true
        } else {
            layout = row([icon, column([name, status], spacing: 2), spacer()], spacing: 8)
            embed(layout, in: self, inset: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), fill: true)
            heightAnchor.constraint(equalToConstant: 58).isActive = true
        }
        identifier = NSUserInterfaceItemIdentifier("taildrop-device")
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var outlineRole: Outline.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { press(); return true }

    func reload() {
        guard let module else { return }
        let sending = module.transfer?.deviceID == device.id ? module.transfer : nil
        isEnabled = device.online && module.transfer == nil && module.state.availability == .ready
        let text: String
        if let sending {
            text = sending.tileText
            status.textColor = Palette.accent
        } else {
            text = compact ? (device.online ? device.osLabel : "Offline") : device.online ? "\(device.osLabel) · Online" : "Offline"
            status.textColor = Palette.textTertiary
        }
        status.stringValue = text
        alphaValue = device.online ? 1 : 0.45
        setAccessibilityLabel(device.online ? "\(device.name), \(text). Choose files to send." : "\(device.name), offline.")
        toolTip = device.online ? "Send files to \(device.name)" : "\(device.name) is offline"
        refreshLook()
    }

    private func refreshLook() {
        let fill: NSColor?
        if pressing { fill = Palette.controlPressed }
        else if hovering && isEnabled { fill = Palette.controlHover }
        else { fill = compact ? nil : Palette.control }
        layer?.backgroundColor = fill?.cgColor
        layer?.borderWidth = compact ? 0 : 1
        layer?.borderColor = Palette.stroke.cgColor
    }

    private func press() {
        guard isEnabled, let module else { return }
        module.chooseFiles(for: device)
    }

    // Pointer and keyboard

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressing = true } }
    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override func keyDown(with event: NSEvent) {
        if [" ", "\r"].contains(event.charactersIgnoringModifiers) { press() } else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: layer?.cornerRadius ?? 8, yRadius: layer?.cornerRadius ?? 8).fill() }
}

// MARK: - Footer

/// "Sending x to y · 2 of 3" with a thin bar and Cancel, or the last result (Show after a save).
private final class TaildropFooter: NSView {
    private weak var module: TaildropModule?
    private let text = line("", size: 11, color: Palette.textSecondary)
    private let bar = ProgressBar()
    private let cancel: HoverButton
    private let show: HoverButton

    init(module: TaildropModule) {
        self.module = module
        cancel = HoverButton("Cancel", style: .plain) { [weak module] in module?.cancelSend() }
        show = HoverButton("Show", style: .plain) { [weak module] in
            if let url = module?.result?.reveal { module?.reveal(url) }
        }
        super.init(frame: .zero)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        size(bar, width: 120)
        embed(row([text, spacer(), bar, cancel, show], spacing: 8), in: self, inset: 0, fill: true)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Returns whether there is anything to show.
    @discardableResult
    func reload() -> Bool {
        guard let module else { return false }
        if let transfer = module.transfer {
            text.stringValue = transfer.text
            text.textColor = Palette.textSecondary
            bar.set(progress: transfer.fraction, animated: true)
            bar.isHidden = false
            cancel.isHidden = false
            show.isHidden = true
            return true
        }
        bar.isHidden = true
        cancel.isHidden = true
        if let result = module.result {
            text.stringValue = result.text
            text.textColor = resultColor(result)
            show.isHidden = result.reveal == nil
            return true
        }
        show.isHidden = true
        text.stringValue = module.saving ? "Saving to Downloads…" : ""
        text.textColor = Palette.textSecondary
        return module.saving
    }
}

// MARK: - Taildrop tab

final class TaildropTabView: NSView, TaildropDisplay, TabHeaderProviding {
    private(set) var tabHeaderActions: NSView = NSView()
    private weak var module: TaildropModule?
    private let banner = FillView(fill: Palette.accentSoft, radius: 10)
    private let bannerText = line("", size: 12, weight: .medium, color: Palette.textPrimary)
    private let saveButton: HoverButton
    private let message = line("", size: 11, color: .systemRed)
    private let grid = NSStackView()
    private let scroll = NSScrollView()
    private let noticeHost = NSView()
    private let footer: TaildropFooter
    private var shownTargets: [TaildropTarget] = []
    private var tiles: [TaildropTile] = []
    private var shownNotice: TaildropAvailability.Notice?
    private static let columns = 4

    init(module: TaildropModule) {
        self.module = module
        saveButton = HoverButton("Save to Downloads", style: .accent) { [weak module] in module?.saveWaiting() }
        footer = TaildropFooter(module: module)
        super.init(frame: .zero)
        let refresh = HoverButton(symbol: "arrow.clockwise", style: .icon, symbolSize: 11, label: "Refresh devices") { [weak module] in module?.refresh() }
        tabHeaderActions = row([refresh], spacing: 8)

        bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        embed(row([symbol("tray.and.arrow.down.fill", size: 13, color: Palette.accent), bannerText, spacer(), saveButton], spacing: 8),
              in: banner, inset: NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 6), fill: true)

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(grid, in: document, inset: NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0), fill: true)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])

        let stack = column([banner, message, scroll, noticeHost, footer], spacing: 10)
        for view in [scroll, noticeHost] {
            view.setContentHuggingPriority(.init(1), for: .vertical)
            view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        }
        embed(stack, in: self, inset: 0, fill: true)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        let state = module.state
        let notice = state.availability.notice(hasTargets: !state.targets.isEmpty)
        if let text = state.waitingText, state.availability == .ready {
            bannerText.stringValue = text
            saveButton.isEnabled = !module.saving
            banner.isHidden = false
        } else {
            banner.isHidden = true
        }
        message.stringValue = state.message ?? ""
        message.isHidden = state.message == nil
        scroll.isHidden = notice != nil
        noticeHost.isHidden = notice == nil
        if notice != shownNotice {
            shownNotice = notice
            noticeHost.subviews.forEach { $0.removeFromSuperview() }
            if let notice {
                let action = notice.action.map { action -> (title: String, run: () -> Void) in
                    (title: notice.actionTitle ?? "", run: { [weak module] in module?.perform(action) })
                }
                embed(placeholder(symbol: notice.symbol, title: notice.title, detail: notice.detail, action: action), in: noticeHost, inset: 0, fill: true)
            }
        }
        if state.targets != shownTargets { rebuildGrid(state.targets, module: module) }
        tiles.forEach { $0.reload() }
        footer.isHidden = !footer.reload()
    }

    private func rebuildGrid(_ targets: [TaildropTarget], module: TaildropModule) {
        shownTargets = targets
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = targets.map { TaildropTile(target: $0, module: module, compact: false) }
        for start in stride(from: 0, to: tiles.count, by: Self.columns) {
            var cells: [NSView] = Array(tiles[start..<min(start + Self.columns, tiles.count)])
            while cells.count < Self.columns { cells.append(NSView()) }
            let cellRow = row(cells, spacing: 8)
            cellRow.distribution = .fillEqually
            grid.addArrangedSubview(cellRow)
            cellRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
    }
}

// MARK: - Home card

/// Up to three online devices to click, and one status line.
final class TaildropCardView: NSView, TaildropDisplay, NSGestureRecognizerDelegate {
    private weak var module: TaildropModule?
    private let list = NSStackView()
    private let status = line("", size: 11, color: Palette.textTertiary)
    private let action = HoverButton("", style: .plain) {}
    private var shownTargets: [TaildropTarget] = []
    private var tiles: [TaildropTile] = []

    init(module: TaildropModule) {
        self.module = module
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = column([list, status, action], spacing: 4)
        embed(stack, in: self, inset: 0)
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        let open = NSClickGestureRecognizer(target: self, action: #selector(openTab))
        open.delegate = self
        addGestureRecognizer(open)
        toolTip = "Open the Taildrop tab"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openTab() { module?.contextShell?.selectTab("taildrop") }

    /// Clicks on a device or a button are theirs, not the card's.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        var view = hitTest(convert(event.locationInWindow, from: nil))
        while let current = view, current !== self {
            if current is NSControl, !(current is NSTextField) { return false }
            view = current.superview
        }
        return true
    }

    func reload() {
        guard let module else { return }
        let state = module.state
        let online = Array(state.onlineTargets.prefix(3))
        if online != shownTargets {
            shownTargets = online
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            tiles = online.map { TaildropTile(target: $0, module: module, compact: true) }
            for tile in tiles {
                list.addArrangedSubview(tile)
                tile.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        tiles.forEach { $0.reload() }
        let notice = state.availability.notice(hasTargets: !state.targets.isEmpty)
        list.isHidden = notice != nil || online.isEmpty
        action.isHidden = true
        if let transfer = module.transfer {
            status.stringValue = "Sending to \(transfer.deviceName) · \(transfer.percent)%"
            status.textColor = Palette.accent
        } else if let result = module.result {
            status.stringValue = result.text
            status.textColor = resultColor(result)
        } else if let notice {
            status.stringValue = state.availability.shortText
            status.textColor = Palette.textSecondary
            if let kind = notice.action, let title = notice.actionTitle {
                action.text = title
                action.setAccessibilityLabel(title)
                action.handler = { [weak module] in module?.perform(kind) }
                action.isHidden = false
            }
        } else if let message = state.message {
            status.stringValue = message
            status.textColor = .systemRed
        } else if let waiting = state.waitingText {
            status.stringValue = waiting
            status.textColor = Palette.textSecondary
        } else {
            let offline = state.targets.count - state.onlineTargets.count
            status.stringValue = online.isEmpty ? "No devices are online" : offline > 0 ? "\(state.onlineTargets.count) online · \(offline) offline" : "\(state.onlineTargets.count) online"
            status.textColor = Palette.textTertiary
        }
        status.toolTip = status.stringValue
    }
}
