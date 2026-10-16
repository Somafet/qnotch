import AppKit
import QNotchMacCore

final class ShellController: NSObject, ModuleShell, NSWindowDelegate {
    let panel: NotchPanel
    let surface = NotchSurfaceView()
    let store: SettingsStore
    let registries = ModuleRegistries()
    let sounds: SoundRegistry
    let shortcuts: ShortcutRegistry
    private(set) var general: GeneralSettings
    private(set) var state = ShellState()
    private(set) var activeTab = "home"
    private(set) var modules: [NotchModule] = []
    private(set) var displayMessage = ""
    private(set) var surfaceRevision = 0
    /// Width of each status wing beside the camera, or the floating pill's content width.
    private(set) var wing: CGFloat = 0
    private var hoverTask: DispatchWorkItem?
    private var leaveTask: DispatchWorkItem?
    private var globalClick: Any?
    private var localClick: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var settingsController: SettingsController?
    private var contentCache: [String: NSView] = [:]
    private var panelView: PanelView?
    private var closingPanel: PanelView?
    private var searchView: SearchView?
    private var leading = NSStackView()
    private var trailing = NSStackView()
    private var pill = NSStackView()
    private var pillIdle = NSView()
    private var screen: NSScreen?
    var statusChanged: (() -> Void)?

    init(store: SettingsStore) {
        self.store = store
        general = store.load("general", default: GeneralSettings())
        Motion.userReduced = general.reduceMotion
        sounds = SoundRegistry(store: store)
        shortcuts = ShortcutRegistry(store: store)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.appearance = Palette.dark
        panel.delegate = self
        panel.title = "QNotch"
        panel.setAccessibilityLabel("QNotch panel")
        panel.contentView = surface
        surface.entered = { [weak self] in self?.pointerEntered() }
        surface.exited = { [weak self] in self?.pointerLeft() }
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityLabel("QNotch. Hover or click to open the panel, or use the menu-bar item.")
        panel.clicked = { [weak self] in
            guard let self else { return false }
            let opening = !self.state.expanded
            if !self.state.acceptsKeyboard { self.open(keyboard: true) }
            return opening
        }
        panel.escaped = { [weak self] in self?.close() }
        panel.typed = { [weak self] text in self?.typeToSearch(text) }
        shortcuts.add("toggle", title: "Toggle panel", hint: "Opens or closes the panel, ready for typing.", gesture: "ctrl+opt+n", order: 0) { [weak self] in
            self?.toggleFromKeyboard()
        }
        shortcuts.add("search", title: "Open search", hint: "Opens the Search tab with the cursor in the box.", gesture: "ctrl+opt+f", order: 20) { [weak self] in
            self?.summonSearch()
        }
        shortcuts.changed = { [weak self] in self?.settingsController?.refreshShortcuts() }
        composeModules()
        store.problemChanged = { [weak self] in
            self?.settingsController?.refreshIssue()
            self?.statusChanged?()
        }
        resolveDisplay()
        rebuildSurface()
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.close(restoreFocus: false)
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.close(restoreFocus: false) }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resolveDisplay(); self?.rebuildSurface(); self?.updateVisibility(); self?.settingsController?.refreshDisplays()
        })
        observers.append(center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.accentChanged()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.present(.none)
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close(restoreFocus: false)
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close(restoreFocus: false)
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close(restoreFocus: false); self?.resolveDisplay(); self?.rebuildSurface()
        })
        observers.append(center.addObserver(forName: Notification.Name("NSSystemClockDidChangeNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        })
    }

    func start() { if screen != nil { panel.orderFrontRegardless() } }

    func stop() {
        hoverTask?.cancel(); leaveTask?.cancel()
        modules.forEach { $0.stop() }
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        panel.orderOut(nil)
    }

    // MARK: Modules and settings

    private func composeModules() {
        modules.forEach { $0.stop() }
        registries.removeAll()
        contentCache.removeAll()
        searchView = nil
        sounds.removeAll()
        shortcuts.remove { !Self.shellShortcuts.contains($0.id) }
        modules = ModuleList.make(disabled: general.disabledModules)
        let context = ModuleContext(settings: store, registries: registries, shell: self, sounds: sounds, shortcuts: shortcuts)
        modules.forEach { $0.initialize(context) }
        registerShellSearch()
        if !tabs.contains(where: { $0.id == activeTab }) { activeTab = "home" }
        buildStatus()
    }

    func updateGeneral(_ change: (inout GeneralSettings) -> Void) {
        let disabled = general.disabledModules
        change(&general)
        store.save("general", general)
        Motion.userReduced = general.reduceMotion
        if disabled != general.disabledModules {
            composeModules()
            if let panelView { panelView.removeFromSuperview(); self.panelView = nil }
        }
        resolveDisplay()
        rebuildSurface()
        updateVisibility()
        statusChanged?()
    }

    func openSettings() { openSettings(page: nil) }
    func openSettings(section: String) { openSettings(page: "module." + section) }

    func openSettings(page: String?) {
        close(restoreFocus: false)
        if settingsController == nil { settingsController = SettingsController(shell: self) }
        settingsController?.show(page: page)
    }

    var settings: SettingsController? { settingsController }

    // MARK: Display

    static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func resolveDisplay() {
        let displays = NSScreen.screens
        let selected = general.displayID.flatMap { wanted in displays.first { Self.displayID($0) == wanted } }
        // The first NSScreen is the menu-bar display; NSScreen.main follows keyboard focus.
        screen = selected ?? displays.first
        displayMessage = screen == nil ? "No display available. The panel is hidden." :
            general.displayID != nil && selected == nil ? "Selected display unavailable. Using the main display." : ""
        if let layout, layout.hasCameraHousing, !layout.integratesCameraHousing {
            displayMessage += (displayMessage.isEmpty ? "" : " ") + "Camera geometry unavailable. Using a pill below the safe area."
        }
        if screen == nil { state.close(); panel.orderOut(nil); updateVisibility() }
        statusChanged?()
    }

    var layout: DisplayLayout? {
        guard let screen else { return nil }
        let gap: CGRect?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                         width: max(0, right.minX - left.maxX), height: screen.safeAreaInsets.top)
        } else { gap = nil }
        return DisplayLayout(frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, cameraGap: gap)
    }

    /// The settled window frame for the current presentation.
    var expectedFrame: CGRect? { layout?.surface(expanded: state.expanded, wing: wing) }

    // MARK: Hover, open and close

    func pointerEntered() {
        leaveTask?.cancel()
        guard !state.expanded else { return }
        hoverTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.open(keyboard: false)
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    func pointerLeft() {
        hoverTask?.cancel()
        leaveTask?.cancel()
        guard state.presentation == .hover else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.state.pointerLeft()
            self.present(.close)
            self.updateVisibility()
        }
        leaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    func open(keyboard: Bool) {
        guard screen != nil else { return }
        hoverTask?.cancel(); leaveTask?.cancel()
        let wasExpanded = state.expanded
        if keyboard, !state.acceptsKeyboard { previousApp = NSWorkspace.shared.frontmostApplication }
        state.open(keyboard: keyboard)
        panel.keyboardAllowed = state.acceptsKeyboard
        if !wasExpanded { present(.open) }
        updateVisibility()
        if keyboard {
            panel.makeKeyAndOrderFront(nil)
            if activeTab == "search" { searchView?.focus(appending: "") } else { panel.makeFirstResponder(nil) }
        } else { panel.orderFrontRegardless() }
    }

    func close(restoreFocus: Bool = true) {
        hoverTask?.cancel(); leaveTask?.cancel()
        guard state.expanded else { return }
        let restore = restoreFocus && panel.isKeyWindow
        state.close()
        panel.keyboardAllowed = false
        panel.resignKey()
        searchView?.clear()
        present(.close)
        updateVisibility()
        if restore, let previousApp, !previousApp.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if state.acceptsKeyboard { close(restoreFocus: false) }
    }

    // MARK: Tabs and search

    private var tabs: [PanelView.Tab] {
        [PanelView.Tab(id: "home", symbol: "house", title: "Home"),
         PanelView.Tab(id: "search", symbol: "magnifyingglass", title: "Search")] +
        registries.tabs.items.map { PanelView.Tab(id: $0.id, symbol: $0.symbol, title: $0.title) }
    }

    func selectTab(_ id: String) {
        let ids = tabs.map(\.id)
        guard let next = ids.firstIndex(of: id) else { return }
        let previous = ids.firstIndex(of: activeTab) ?? 0
        guard id != activeTab else {
            if id == "search", state.acceptsKeyboard { searchView?.focus(appending: "") }
            return
        }
        activeTab = id
        panelView?.select(id, animated: true)
        showBody(direction: next > previous ? 1 : -1, animated: true)
        updateVisibility()
        if id == "search", state.acceptsKeyboard { searchView?.focus(appending: "") }
        else if state.acceptsKeyboard, panel.firstResponder is NSTextView { panel.makeFirstResponder(nil) }
    }

    private func typeToSearch(_ text: String) {
        guard state.acceptsKeyboard else { return }
        selectTab("search")
        searchView?.focus(appending: text)
    }

    private func search(_ query: String) -> [SearchHit] {
        registries.searchSources.items.flatMap { Array($0.find(query).prefix(5)) }
    }

    /// Tabs (order 80) and Settings pages (order 90), as on Windows.
    private func registerShellSearch() {
        registries.searchSources.register(SearchSource(id: "tabs", order: 80) { [weak self] query in
            guard let self else { return [] }
            return self.tabs.filter { $0.id != "search" && $0.title.localizedCaseInsensitiveContains(query) }.map { tab in
                SearchHit(title: tab.title, detail: "Tab · opens it", symbol: tab.symbol) { [weak self] in self?.selectTab(tab.id) }
            }
        })
        registries.searchSources.register(SearchSource(id: "settings", order: 90) { [weak self] query in
            guard let self else { return [] }
            let pages = SettingsController.appPages.map { ($0.id, $0.title, $0.keywords) } +
                self.registries.settingsSections.items.map { ("module." + $0.id, $0.title, "") }
            return pages.filter { "\($0.1) \($0.2)".localizedCaseInsensitiveContains(query) }.map { page in
                SearchHit(title: page.1, detail: "Settings · opens this page", symbol: "gearshape") { [weak self] in self?.openSettings(page: page.0) }
            }
        })
    }

    static let shellShortcuts: Set<String> = ["toggle", "search"]

    /// ⌃⌥N: opens the panel for typing, or closes it when it already has the keyboard.
    func toggleFromKeyboard() {
        if state.acceptsKeyboard { close() } else { open(keyboard: true) }
    }

    /// ⌃⌥F: opens Search with the cursor in the box; pressed again there, it closes the panel.
    func summonSearch() {
        if state.acceptsKeyboard, activeTab == "search" { close(); return }
        open(keyboard: true)
        selectTab("search")
        searchView?.focus(appending: "")
    }

    private func updateVisibility() {
        modules.forEach { $0.setVisibility(panel: state.expanded, activeTab: activeTab) }
    }

    private func showBody(direction: Int = 0, animated: Bool = false) {
        guard let panelView else { return }
        let content: NSView
        switch activeTab {
        case "search":
            let view = searchView ?? SearchView { [weak self] in self?.search($0) ?? [] }
            searchView = view
            content = view
        case "home":
            content = cached("home") { [unowned self] in self.makeHome() }
        default:
            if let tab = registries.tabs.items.first(where: { $0.id == activeTab }) {
                content = cached("tab." + tab.id, tab.makeView)
            } else {
                content = placeholder(symbol: "exclamationmark.triangle", title: "Unavailable", detail: "This module is not available.")
            }
        }
        panelView.show(content, direction: direction, animated: animated)
    }

    private func makeHome() -> NSView {
        let cards = registries.cards.items
        guard !cards.isEmpty else {
            return placeholder(symbol: "square.grid.2x2", title: "No cards on Home", detail: "Turn on features in Settings to add their cards here.",
                               action: ("Open Settings", { [weak self] in self?.openSettings(page: "features") }))
        }
        return HomeView(cards: cards.map { ($0, cached("card." + $0.id, $0.makeView)) })
    }

    private func cached(_ id: String, _ factory: () -> NSView) -> NSView {
        if let view = contentCache[id] { return view }
        let view = factory()
        contentCache[id] = view
        return view
    }

    // MARK: Status segments

    private func buildStatus() {
        for view in [leading, trailing, pill] { view.removeFromSuperview() }
        let segments = registries.segments.items
        leading = row(segments.filter { $0.slot == .leading }.map { $0.makeView() }, spacing: 6)
        trailing = row(segments.filter { $0.slot == .trailing }.map { $0.makeView() }, spacing: 6)
        leading.identifier = NSUserInterfaceItemIdentifier("notch-left-wing")
        trailing.identifier = NSUserInterfaceItemIdentifier("notch-right-wing")
        let glyph = symbol("circle.lefthalf.filled", size: 13, weight: .medium, color: Palette.textSecondary)
        pillIdle = row([glyph, line("QNotch", size: 12, weight: .semibold, color: Palette.textSecondary)], spacing: 6)
        pill = NSStackView()
        pill.orientation = .horizontal
        pill.spacing = 8
        for view in [leading, trailing, pill] { view.detachesHiddenViews = true; view.wantsLayer = true }
        wing = measureWing()
    }

    private func visibleWidth(_ stack: NSStackView) -> CGFloat {
        stack.arrangedSubviews.contains { !$0.isHidden } ? stack.fittingSize.width : 0
    }

    private func measureWing() -> CGFloat {
        let left = visibleWidth(leading), right = visibleWidth(trailing)
        guard left > 0 || right > 0 else { return 0 }
        if layout?.integratesCameraHousing == true {
            // Symmetric wings; rounded so a one-character change does not resize the notch.
            return min(100, ceil((max(left, right) + 24) / 8) * 8)
        }
        return min(300, left + right + (left > 0 && right > 0 ? 8 : 0))
    }

    func segmentsChanged() {
        let next = measureWing()
        guard next != wing else { layoutStatus(); return }
        let appearing = wing == 0
        wing = next
        if state.expanded { layoutStatus() } else { present(.nudge) }
        if appearing, !state.expanded {
            for view in [leading, trailing, pill] { Motion.reveal(view, delay: 0.08, duration: 0.28) }
        }
    }

    /// Places status content. With a camera housing it sits in the side wings (also while expanded,
    /// so nothing jumps); a floating pill shows it centered and hides it under the open panel.
    private func layoutStatus() {
        guard let layout else { return }
        let active = wing > 0
        if let wings = layout.wings(expanded: false, wing: wing) {
            pill.isHidden = true
            for (stack, area) in [(leading, wings.left), (trailing, wings.right)] {
                stack.isHidden = !active
                let size = stack.fittingSize
                surface.place(stack, at: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
            }
        } else {
            if pill.arrangedSubviews.isEmpty { [pillIdle, leading, trailing].forEach(pill.addArrangedSubview) }
            pillIdle.isHidden = active
            leading.isHidden = !active || visibleWidth(leading) == 0
            trailing.isHidden = !active || visibleWidth(trailing) == 0
            pill.isHidden = state.expanded
            let rect = layout.surface(expanded: false, wing: wing)
            let size = pill.fittingSize
            surface.place(pill, at: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    // MARK: Surface

    private func accentChanged() {
        contentCache.removeAll()
        searchView = nil
        buildStatus()
        if let panelView { panelView.removeFromSuperview(); self.panelView = nil }
        rebuildSurface()
    }

    /// Full rebuild for a display, module, or accent change. No animation.
    private func rebuildSurface() {
        guard let layout else { return }
        surface.configure(world: layout.surface(expanded: true).union(layout.surface(expanded: false, wing: 120)).insetBy(dx: -40, dy: -40),
                          integrated: layout.integratesCameraHousing, band: layout.topBandHeight)
        panel.level = layout.integratesCameraHousing ? .statusBar : .floating
        wing = measureWing()
        if let panelView { surface.place(panelView, at: layout.panelBody) }
        present(.none)
    }

    /// Morphs the surface to the current presentation. While animating, the window temporarily
    /// covers both shapes plus overshoot room; it returns to the exact surface when settled.
    private func present(_ style: NotchSurfaceView.Morph) {
        guard let layout else { return }
        surfaceRevision += 1
        let expanded = state.expanded
        let target = layout.surface(expanded: expanded, wing: wing)
        let animated = style != .none && Motion.enabled && panel.isVisible
        if expanded, panelView == nil {
            closingPanel?.removeFromSuperview()
            closingPanel = nil
            let view = PanelView(tabs: tabs, selected: activeTab, select: { [weak self] in self?.selectTab($0) },
                                 openSettings: { [weak self] in self?.openSettings() })
            panelView = view
            surface.place(view, at: layout.panelBody)
            view.layoutSubtreeIfNeeded()
            showBody()
            if animated { Motion.reveal(view, delay: 0.07, duration: 0.3, dy: 10) }
        } else if !expanded, let view = panelView {
            panelView = nil
            closingPanel = view
            if animated {
                Motion.conceal(view, duration: 0.12, dy: 8) { [weak self, weak view] in
                    guard let self, let view, self.closingPanel === view else { return }
                    view.isHidden = true
                }
            } else { view.removeFromSuperview(); closingPanel = nil }
        }
        let integrated = layout.integratesCameraHousing
        let bottom: CGFloat = expanded ? 22 : integrated ? 11 : 16
        let window = animated ? surface.visibleShapeBounds.union(target).insetBy(dx: -28, dy: -28).intersection(layout.frame) : target
        setFrame(window)
        let wasHidden = pill.isHidden
        layoutStatus()
        if animated, !integrated, wasHidden, !pill.isHidden { Motion.reveal(pill, delay: 0.1, duration: 0.24) }
        surface.morph(to: target, bottom: bottom, top: expanded ? 20 : 16, outlined: expanded, style: animated ? style : .none) { [weak self] in
            self?.settle()
        }
    }

    private func settle() {
        guard let frame = expectedFrame else { return }
        setFrame(frame)
        if !state.expanded, let closingPanel {
            closingPanel.removeFromSuperview()
            closingPanel.layer?.removeAllAnimations()
            self.closingPanel = nil
        }
    }

    private func setFrame(_ rect: CGRect) {
        if panel.frame != rect {
            panel.disableScreenUpdatesUntilFlush()
            panel.setFrame(rect, display: true)
        }
        surface.syncToWindow()
        if !panel.isVisible, screen != nil { panel.orderFrontRegardless() }
    }

    private func systemDidWake() {
        resolveDisplay(); rebuildSurface()
        modules.forEach { $0.systemDidWake() }
    }

    // MARK: Diagnostics

    func snapshot(to url: URL) throws {
        guard let view = panel.contentView else { throw CocoaError(.fileWriteUnknown) }
        try Self.snapshot(view: view, to: url)
    }

    func accessibilityReport(to url: URL) throws {
        var lines: [String] = []
        func walk(_ view: NSView) throws {
            guard !view.isHidden else { return }
            if let control = view as? NSControl {
                let name = control.accessibilityLabel() ?? (control as? NSButton)?.title ?? (control as? NSTextField)?.stringValue ?? ""
                if control is NSButton || control.acceptsFirstResponder, name.isEmpty {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                lines.append("\(type(of: control)): \(name)")
            }
            for child in view.subviews { try walk(child) }
        }
        if let view = panel.contentView { try walk(view) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    static func snapshot(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
