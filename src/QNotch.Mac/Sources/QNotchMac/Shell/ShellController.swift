import AppKit
import QNotchMacCore

final class ShellController: NSObject, ModuleShell, NSWindowDelegate, NSSearchFieldDelegate {
    let panel: NotchPanel
    let store: SettingsStore
    let registries = ModuleRegistries()
    private(set) var general: GeneralSettings
    private(set) var state = ShellState()
    private(set) var activeTab = "home"
    private(set) var modules: [NotchModule] = []
    private(set) var displayMessage = ""
    private(set) var surfaceRevision = 0
    private var hoverTask: DispatchWorkItem?
    private var leaveTask: DispatchWorkItem?
    private var globalClick: Any?
    private var localClick: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var settingsController: SettingsController?
    private var contentCache: [String: NSView] = [:]
    private var bodyHost: NSView?
    private var navigation: NSSegmentedControl?
    private var search: NSSearchField?
    private var searchQuery = ""
    private var screen: NSScreen?
    var statusChanged: (() -> Void)?

    init(store: SettingsStore) {
        self.store = store
        general = store.load("general", default: GeneralSettings())
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.title = "QNotch"
        panel.setAccessibilityLabel("QNotch panel")
        panel.clicked = { [weak self] in
            guard let self else { return false }
            let opening = !self.state.expanded
            if !self.state.acceptsKeyboard { self.open(keyboard: true) }
            return opening
        }
        panel.escaped = { [weak self] in self?.close() }
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
            self?.resolveDisplay(); self?.reposition(); self?.settingsController?.refreshDisplays()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.panel.animations = [:]
            self?.panel.alphaValue = 1
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
            self?.close(restoreFocus: false); self?.resolveDisplay(); self?.reposition()
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

    private func composeModules() {
        modules.forEach { $0.stop() }
        registries.removeAll()
        contentCache.removeAll()
        modules = ModuleList.make(timerEnabled: general.timerEnabled)
        let context = ModuleContext(settings: store, registries: registries, shell: self)
        modules.forEach { $0.initialize(context) }
        if activeTab != "home", !registries.tabs.items.contains(where: { $0.id == activeTab }) { activeTab = "home" }
    }

    func updateGeneral(_ change: (inout GeneralSettings) -> Void) {
        let enabled = general.timerEnabled
        change(&general)
        store.save("general", general)
        if enabled != general.timerEnabled { composeModules() }
        resolveDisplay()
        rebuildSurface()
        updateVisibility()
        statusChanged?()
    }

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

    private func reposition() {
        guard let layout else { return }
        panel.setFrame(layout.surface(expanded: state.expanded), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

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
            self.rebuildSurface()
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
        if !wasExpanded { rebuildSurface() }
        updateVisibility()
        if keyboard {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(search)
        } else { panel.orderFrontRegardless() }
        if !wasExpanded, !general.reduceMotion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0.8
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func close(restoreFocus: Bool = true) {
        hoverTask?.cancel(); leaveTask?.cancel()
        guard state.expanded else { return }
        let restore = restoreFocus && panel.isKeyWindow
        state.close()
        panel.keyboardAllowed = false
        panel.resignKey()
        searchQuery = ""
        rebuildSurface()
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

    func selectTab(_ id: String) {
        guard id == "home" || registries.tabs.items.contains(where: { $0.id == id }) else { return }
        activeTab = id
        searchQuery = ""
        search?.stringValue = ""
        showBody()
        updateVisibility()
    }

    private func updateVisibility() {
        modules.forEach { $0.setVisibility(panel: state.expanded && searchQuery.isEmpty, activeTab: activeTab) }
    }

    private func rebuildSurface() {
        surfaceRevision += 1
        let surface = TrackingSurface()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = state.expanded ? 18 : 14
        surface.layer?.masksToBounds = true
        surface.entered = { [weak self] in self?.pointerEntered() }
        surface.exited = { [weak self] in self?.pointerLeft() }
        panel.contentView = surface
        bodyHost = nil; navigation = nil; search = nil
        if state.expanded {
            // The material exists only while expanded. Collapsed idle has no backdrop effect.
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(material)
            NSLayoutConstraint.activate([
                material.leadingAnchor.constraint(equalTo: surface.leadingAnchor), material.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                material.topAnchor.constraint(equalTo: surface.topAnchor), material.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
            let header = label("QNotch", size: 13)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            let settings = ActionButton("Settings…", symbol: "gearshape") { [weak self] in self?.openSettings() }
            settings.controlSize = .small
            let heading = row([header, NSView(), settings])
            let field = NSSearchField()
            field.placeholderString = "Search QNotch"
            field.setAccessibilityLabel("Search QNotch")
            field.delegate = self
            search = field
            let tabs = NSSegmentedControl(labels: ["Home"] + registries.tabs.items.map(\.title), trackingMode: .selectOne, target: self, action: #selector(tabChanged))
            tabs.setAccessibilityLabel("Panel tabs")
            navigation = tabs
            let body = NSView()
            bodyHost = body
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 208).isActive = true
            let stack = column([heading, field, tabs, body], spacing: 12)
            embed(stack, in: surface)
            for view in [heading, field, tabs, body] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            showBody()
        } else {
            let pill = PillView()
            pill.pressed = { [weak self] in self?.open(keyboard: true) }
            pill.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: surface.leadingAnchor), pill.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                pill.topAnchor.constraint(equalTo: surface.topAnchor), pill.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
            let icon = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "QNotch")!)
            icon.contentTintColor = .white
            let name = label("QNotch", size: 12, color: .white)
            let items = [icon, name] + registries.segments.items.map { $0.makeView() }
            let stack = row(items)
            stack.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: pill.centerXAnchor), stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor)])
            pill.setAccessibilityElement(true)
            pill.setAccessibilityLabel("QNotch. Click to open panel, or use the menu-bar item.")
            pill.setAccessibilityRole(.button)
        }
        panel.alphaValue = 1
        reposition()
        surface.layoutSubtreeIfNeeded()
    }

    @objc private func tabChanged() {
        guard let navigation else { return }
        selectTab((["home"] + registries.tabs.items.map(\.id))[navigation.selectedSegment])
    }

    func controlTextDidChange(_ notification: Notification) {
        searchQuery = search?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showBody()
        updateVisibility()
    }

    private func showBody() {
        guard let bodyHost else { return }
        bodyHost.subviews.forEach { $0.removeFromSuperview() }
        navigation?.selectedSegment = (["home"] + registries.tabs.items.map(\.id)).firstIndex(of: activeTab) ?? 0
        let content: NSView
        if !searchQuery.isEmpty {
            let hits = registries.searchSources.items.flatMap { Array($0.find(searchQuery).prefix(5)) }.prefix(10)
            content = column(hits.isEmpty ? [label("No results", color: .secondaryLabelColor)] : hits.map { hit in
                ActionButton(hit.title) { hit.run() }
            })
        } else if activeTab == "home" {
            let cards: [NSView] = registries.cards.items.map { item in
                let title = label(item.title, size: 11, color: .secondaryLabelColor)
                return column([title, cached("card." + item.id, item.makeView)], spacing: 6)
            }
            content = cards.isEmpty ? column([label("Timer is turned off", size: 17), label("Enable Countdown in Settings to use this panel.", color: .secondaryLabelColor), ActionButton("Open Settings…") { [weak self] in self?.openSettings() }]) : column(cards)
        } else if let tab = registries.tabs.items.first(where: { $0.id == activeTab }) {
            content = cached("tab." + tab.id, tab.makeView)
        } else { content = label("This module is unavailable.") }
        embed(content, in: bodyHost, inset: 0)
        content.widthAnchor.constraint(equalTo: bodyHost.widthAnchor).isActive = true
    }

    private func cached(_ id: String, _ factory: () -> NSView) -> NSView {
        if let view = contentCache[id] { return view }
        let view = factory()
        contentCache[id] = view
        return view
    }

    func openSettings() {
        close(restoreFocus: false)
        if settingsController == nil { settingsController = SettingsController(shell: self) }
        settingsController?.show()
    }

    private func systemDidWake() {
        resolveDisplay(); reposition()
        modules.forEach { $0.systemDidWake() }
    }

    func snapshot(to url: URL) throws {
        guard let view = panel.contentView else { throw CocoaError(.fileWriteUnknown) }
        try snapshot(view: view, to: url)
    }

    func snapshotSettings(to url: URL) throws {
        guard let view = settingsController?.window.contentView else { throw CocoaError(.fileWriteUnknown) }
        settingsController?.window.displayIfNeeded()
        try snapshot(view: view, to: url)
        settingsController?.window.close()
    }

    func accessibilityReport(to url: URL) throws {
        var lines: [String] = []
        func walk(_ view: NSView) throws {
            guard !view.isHidden else { return }
            if let control = view as? NSControl {
                let name = control.accessibilityLabel() ?? (control as? NSButton)?.title ?? (control as? NSTextField)?.stringValue ?? ""
                if (control is NSButton || control is NSSearchField || control is NSSegmentedControl), name.isEmpty {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                lines.append("\(type(of: control)): \(name)")
            }
            for child in view.subviews { try walk(child) }
        }
        if let view = panel.contentView { try walk(view) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func snapshot(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
