import AppKit
import QNotchMacCore

final class ShellController: NSObject, ModuleShell, NSWindowDelegate {
    let panel: NotchPanel
    let surface = NotchSurfaceView()
    let store: SettingsStore
    let registries = ModuleRegistries()
    let sounds: SoundRegistry
    let shortcuts: ShortcutRegistry
    let capture = CaptureWatch()
    private(set) var gameMode: GameModeController!
    var gameActive: Bool { gameMode?.active == true }
    private(set) var general: GeneralSettings
    private(set) var state = ShellState()
    private(set) var activeTab = "home"
    private var loaded: [(id: String, module: NotchModule)] = []
    var modules: [NotchModule] { loaded.map(\.module) }
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
    /// Each wing's own segment slots, in contribution order, wherever they are shown now.
    private var leadingSlots: [SegmentSlotView] = [], trailingSlots: [SegmentSlotView] = []
    private var pill = NSStackView()
    private var pillIdle = NSView()
    private var screen: NSScreen?
    var statusChanged: (() -> Void)?

    init(store: SettingsStore) {
        self.store = store
        general = store.load("general", default: GeneralSettings())
        Motion.userReduced = general.reduceMotion
        Palette.accentOverride = general.accent.flatMap(Palette.hex)
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
        surface.fileDragEntered = { [weak self] in self?.fileDragEntered() }
        surface.fileDragExited = { [weak self] in self?.pointerLeft() }
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
        panel.canNudge = { [weak self] in
            guard let self, let layout = self.layout else { return false }
            return !layout.integratesCameraHousing && !self.state.expanded && !self.gameActive
        }
        panel.nudged = { [weak self] dx in self?.nudge(by: dx) }
        panel.nudgeEnded = { [weak self] doubleClick in self?.endNudge(center: doubleClick) }
        panel.typed = { [weak self] text in self?.typeToSearch(text) }
        registerShellSearch()
        shortcuts.add("toggle", title: "Toggle panel", hint: "Opens or closes the panel, ready for typing.", gesture: "ctrl+opt+n", order: 0) { [weak self] in
            self?.toggleFromKeyboard()
        }
        shortcuts.add("search", title: "Open search", hint: "Opens the Search tab with the cursor in the box.", gesture: "ctrl+opt+f", order: 20) { [weak self] in
            self?.summonSearch()
        }
        shortcuts.add("gamemode", title: "Cycle game mode", hint: "Automatic, then forced on, then forced off.", gesture: "ctrl+opt+g", order: 10) { [weak self] in
            self?.gameMode.cycle()
        }
        gameMode = GameModeController(store: store)
        gameMode.display = { [weak self] in
            guard let screen = self?.screen else { return nil }
            return CGDisplayBounds(Self.displayID(screen))
        }
        gameMode.changed = { [weak self] in self?.applyGameMode() }
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
            self.clickedOutside()
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.clickedOutside() }
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

    func start() {
        guard screen != nil else { return }
        panel.orderFrontRegardless()
        if general.pinned { DispatchQueue.main.async { [weak self] in self?.open(keyboard: false) } }
    }

    /// A pinned panel stays open; it only gives the keyboard back.
    private func clickedOutside() {
        guard holds == 0 else { return }
        if general.pinned { releaseKeyboard() } else { close(restoreFocus: false) }
    }

    private func releaseKeyboard() {
        guard state.acceptsKeyboard else { return }
        state.releaseKeyboard()
        panel.keyboardAllowed = false
        panel.resignKey()
    }

    func togglePin() {
        updateGeneral { $0.pinned.toggle() }
        panelView?.setPinned(general.pinned)
        if !general.pinned, state.presentation == .hover, !panel.frame.contains(NSEvent.mouseLocation) { pointerLeft() }
    }

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

    /// Stops modules that were turned off and constructs those turned on. Modules that stay on
    /// keep running untouched (a running countdown survives turning Note off).
    private func composeModules() {
        let wanted = ModuleList.all.filter { general.isEnabled($0.id) }
        for (id, module) in loaded where !wanted.contains(where: { $0.id == id }) {
            module.stop()
            if fileDropOwner == id {
                fileDropOwner = nil; fileDropEntered = nil
                surface.filesDropped = nil
                surface.acceptFiles(false)
            }
            registries.removeAll(owner: id)
            sounds.removeAll(owner: id)
            shortcuts.remove { $0.owner == id }
        }
        loaded = wanted.map { info in
            if let existing = loaded.first(where: { $0.id == info.id }) { return existing }
            let module = info.make()
            registries.owner = info.id; sounds.owner = info.id; shortcuts.owner = info.id
            module.initialize(ModuleContext(settings: store, registries: registries, shell: self, sounds: sounds, shortcuts: shortcuts, capture: capture))
            registries.owner = nil; sounds.owner = nil; shortcuts.owner = nil
            return (info.id, module)
        }
        // Card and tab views of removed modules go; kept modules keep their (cached) views.
        let live = Set(registries.cards.items.map { "card." + $0.id } + registries.tabs.items.map { "tab." + $0.id })
        contentCache = contentCache.filter { live.contains($0.key) }
        searchView = nil
        if !tabs.contains(where: { $0.id == activeTab }) { activeTab = "home" }
        buildStatus()
    }

    func updateGeneral(_ change: (inout GeneralSettings) -> Void) {
        let previous = general
        let disabled = general.disabledModules
        change(&general)
        store.save("general", general)
        Motion.userReduced = general.reduceMotion
        Palette.accentOverride = general.accent.flatMap(Palette.hex)
        if previous.accent != general.accent || previous.profileName != general.profileName || previous.hiddenCards != general.hiddenCards {
            accentChanged()
        }
        if disabled != general.disabledModules {
            composeModules()
            if let panelView { panelView.removeFromSuperview(); self.panelView = nil }
        }
        resolveDisplay()
        rebuildSurface()
        updateVisibility()
        statusChanged?()
    }

    func closePanel() { close() }
    func dismissPanel() { close(restoreFocus: false) }

    private var lingerTask: DispatchWorkItem?

    // MARK: Holds and file drops

    private var holds = 0
    private final class Hold {
        weak var shell: ShellController?
        init(_ shell: ShellController) { self.shell = shell; shell.holds += 1 }
        deinit {
            guard let shell else { return }
            let release = {
                shell.holds -= 1
                // Released while the pointer is elsewhere: close after the usual leave delay.
                if shell.holds == 0 { DispatchQueue.main.async { if !shell.panel.frame.contains(NSEvent.mouseLocation) { shell.pointerLeft() } } }
            }
            if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
        }
    }
    var isHeld: Bool { holds > 0 }
    func holdOpen() -> AnyObject { Hold(self) }

    private var fileDropEntered: (() -> Void)?
    private var fileDropOwner: String?

    func acceptFileDrops(entered: @escaping () -> Void, dropped: @escaping ([URL]) -> Void) {
        fileDropEntered = entered
        fileDropOwner = registries.owner
        surface.filesDropped = { urls in dropped(urls); return true }
        surface.acceptFiles(true)
    }

    private func fileDragEntered() {
        leaveTask?.cancel()
        guard !gameActive else { return }
        if !state.expanded { open(keyboard: false) }
        fileDropEntered?()
    }
    @discardableResult
    func tryOpenPanel(tab: String, linger: TimeInterval) -> Bool {
        guard screen != nil, !gameActive else { return false }
        guard !state.expanded else { return true }
        if tabs.contains(where: { $0.id == tab }) { activeTab = tab }
        open(keyboard: false)
        lingerTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.state.presentation == .hover, !self.general.pinned,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.close(restoreFocus: false)
        }
        lingerTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(linger, Double(general.closeDelayMs) / 1000), execute: task)
        return true
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
        var layout = DisplayLayout(frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, cameraGap: gap)
        layout.offset = nudgeStart.map { $0 + nudgeDelta } ?? CGFloat(general.pillOffsets[String(Self.displayID(screen))] ?? 0)
        return layout
    }

    /// The settled window frame for the current presentation.
    var expectedFrame: CGRect? { layout?.surface(expanded: state.expanded, wing: wing) }

    // MARK: Hover, open and close

    /// After an explicit close (Escape, Settings, Show, a pick) with the pointer still on the
    /// notch, hover stays off until the pointer leaves, so the panel does not spring back open.
    private var hoverSuppressed = false

    func pointerEntered() {
        leaveTask?.cancel()
        guard !gameActive else { return }
        guard !state.expanded else { return }
        if hoverSuppressed {
            guard !(expectedFrame?.contains(NSEvent.mouseLocation) ?? false) else { return }
            hoverSuppressed = false
        }
        hoverTask?.cancel()
        // The settled shape, not the window: while a close morph runs, the window still covers
        // the panel's old area, and a pointer there must not reopen it.
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.hoverSuppressed, self.expectedFrame?.contains(NSEvent.mouseLocation) == true else { return }
            self.open(keyboard: false)
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(general.hoverDelayMs), execute: task)
    }

    func pointerLeft() {
        hoverTask?.cancel()
        leaveTask?.cancel()
        hoverSuppressed = false
        guard state.presentation == .hover, !general.pinned, holds == 0 else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.general.pinned, self.holds == 0, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.state.pointerLeft()
            self.present(.close)
            self.updateVisibility()
        }
        leaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(general.closeDelayMs), execute: task)
    }

    func open(keyboard: Bool) {
        guard screen != nil, !gameActive else { return }
        hoverTask?.cancel(); leaveTask?.cancel()
        let wasExpanded = state.expanded
        if keyboard, !state.acceptsKeyboard { previousApp = NSWorkspace.shared.frontmostApplication }
        state.open(keyboard: keyboard)
        peekHandle?.end()
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
        hoverSuppressed = panel.frame.contains(NSEvent.mouseLocation)
        setEditing(false)
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
        guard state.acceptsKeyboard, holds == 0 else { return }
        if general.pinned { releaseKeyboard() } else { close(restoreFocus: false) }
    }

    // MARK: Tabs and search

    private var tabs: [PanelView.Tab] {
        let items = registries.tabs.items
        let order = LayoutOrder.apply(saved: general.tabOrder, defaults: items.map(\.id))
        return [PanelView.Tab(id: "home", symbol: "house", title: "Home"),
                PanelView.Tab(id: "search", symbol: "magnifyingglass", title: "Search")] +
            order.compactMap { id in items.first { $0.id == id } }.map { PanelView.Tab(id: $0.id, symbol: $0.symbol, title: $0.title) }
    }

    // MARK: Edit mode

    private(set) var editing = false
    private var editHold: AnyObject?
    private weak var homeView: HomeView?

    /// Jiggle and drag cards and tabs (Windows EditMode). The panel never auto-closes meanwhile.
    func toggleEditing() { setEditing(!editing) }

    func setEditing(_ value: Bool) {
        guard editing != value else { return }
        editing = value
        editHold = value ? holdOpen() : nil
        homeView?.editing = value
        panelView?.setEditing(value, onHome: activeTab == "home")
    }

    func selectTab(_ id: String) {
        let ids = tabs.map(\.id)
        guard let next = ids.firstIndex(of: id) else { return }
        let previous = ids.firstIndex(of: activeTab) ?? 0
        guard id != activeTab else {
            if id == "search", state.acceptsKeyboard { searchView?.focus(appending: "") }
            return
        }
        if editing, id != "home" { setEditing(false) }
        activeTab = id
        panelView?.select(id, animated: true)
        panelView?.setEditing(editing, onHome: id == "home")
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

    static let shellShortcuts: Set<String> = ["toggle", "search", "gamemode"]

    // MARK: Game mode

    /// The notch steps aside: the panel cannot open, the surface ignores the mouse, peeks are off,
    /// and the wings show only the segments chosen for game mode, at the chosen opacity.
    private func applyGameMode() {
        let active = gameActive
        if active { close(restoreFocus: false); peekHandle?.end() }
        panel.ignoresMouseEvents = active
        for stack in [leading, trailing, pill] { stack.alphaValue = active ? CGFloat(gameMode.settings.opacity) / 100 : 1 }
        segmentsChanged()
        statusChanged?()
        settingsController?.refreshGameMode()
    }

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
        let cards = registries.cards.items.filter { general.isCardVisible($0.id) }
        guard !cards.isEmpty else {
            return placeholder(symbol: "square.grid.2x2", title: "No cards on Home", detail: "Turn on features in Settings to add their cards here.",
                               action: ("Open Settings", { [weak self] in self?.openSettings(page: "features") }))
        }
        let order = LayoutOrder.apply(saved: general.cardOrder, defaults: cards.map(\.id))
        let ordered = order.compactMap { id in cards.first { $0.id == id } }
        let home = HomeView(cards: ordered.map { ($0, cached("card." + $0.id, $0.makeView)) })
        home.reordered = { [weak self] ids in self?.updateGeneral { $0.cardOrder = LayoutOrder.reorder(ids, saved: $0.cardOrder) } }
        home.editing = editing
        homeView = home
        return home
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
        func stack(_ slot: SegmentSlot) -> NSStackView {
            // Each segment sits in a shell-owned slot, so a full wing can drop whole segments
            // (farthest from the camera first) without touching the module's own visibility.
            let slots = segments.filter { $0.slot == slot }.map { item -> SegmentSlotView in
                let container = SegmentSlotView()
                container.owner = registries.segments.owner(of: item.id)
                embed(item.makeView(), in: container, inset: 0, fill: true)
                return container
            }
            if slot == .leading { leadingSlots = slots } else { trailingSlots = slots }
            return row(slots, spacing: 6)
        }
        leading = stack(.leading)
        trailing = stack(.trailing)
        leading.identifier = NSUserInterfaceItemIdentifier("notch-left-wing")
        trailing.identifier = NSUserInterfaceItemIdentifier("notch-right-wing")
        let glyph = symbol("circle.lefthalf.filled", size: 13, weight: .medium, color: Palette.textSecondary)
        pillIdle = row([glyph, line("QNotch", size: 12, weight: .semibold, color: Palette.textSecondary)], spacing: 6)
        pill = NSStackView()
        pill.orientation = .horizontal
        pill.spacing = 8
        for view in [leading, trailing, pill] {
            view.detachesHiddenViews = true
            view.wantsLayer = true
            if gameActive { view.alphaValue = CGFloat(gameMode.settings.opacity) / 100 }
        }
        wing = measureWing()
    }

    // MARK: Peek

    private var peekHandle: PeekHandle?
    private var peekLeft = NSStackView(), peekRight = NSStackView()
    private var peekShown: Bool { peekHandle != nil && !state.expanded }

    @discardableResult
    func peek(symbol name: String, tint: NSColor, leading: String, trailing: String, seconds: TimeInterval?) -> PeekHandle? {
        guard screen != nil, !state.expanded, !gameActive else { return nil }
        peekHandle?.end()
        let handle = PeekHandle { [weak self] handle in
            guard let self, self.peekHandle === handle else { return }
            self.peekHandle = nil
            self.peekLeft.removeFromSuperview(); self.peekRight.removeFromSuperview()
            self.segmentsChanged()
        }
        peekHandle = handle
        peekLeft.removeFromSuperview(); peekRight.removeFromSuperview()
        let icon = symbol(name, size: 12, weight: .semibold, color: tint)
        let left = line(leading, size: 12, weight: .semibold, color: tint)
        let right = line(trailing, size: 12, weight: .medium, color: Palette.textPrimary)
        left.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        right.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        peekLeft = row([icon, left], spacing: 5)
        peekRight = row([right], spacing: 0)
        for view in [peekLeft, peekRight] {
            view.wantsLayer = true
            view.identifier = NSUserInterfaceItemIdentifier(view === peekLeft ? "notch-left-wing" : "notch-right-wing")
        }
        peekLeft.setAccessibilityElement(true)
        peekLeft.setAccessibilityRole(.staticText)
        peekLeft.setAccessibilityLabel("\(leading): \(trailing)")
        segmentsChanged()
        for view in [peekLeft, peekRight] { Motion.reveal(view, delay: 0.05, duration: 0.18) }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(10, max(1, seconds))) { [weak handle] in handle?.end() }
        }
        return handle
    }

    private final class SegmentSlotView: NSView { var owner: String? }

    private func visibleWidth(_ stack: NSStackView) -> CGFloat {
        stack.arrangedSubviews.contains { !$0.isHidden } ? stack.fittingSize.width : 0
    }

    /// Shows each wing's visible segments while they fit, spilling over to the other wing (WingFit).
    private func fitWings(maxWidth: CGFloat) {
        let hidden = gameActive ? Set(gameMode.settings.hiddenModules) : []
        func widths(_ slots: [SegmentSlotView]) -> [(ObjectIdentifier, Double?)] {
            slots.map { slot in
                guard let segment = slot.subviews.first, !segment.isHidden, !hidden.contains(slot.owner ?? "") else { return (ObjectIdentifier(slot), nil) }
                return (ObjectIdentifier(slot), Double(segment.fittingSize.width))
            }
        }
        let shown = WingFit.fit(leading: widths(leadingSlots), trailing: widths(trailingSlots), maxWidth: Double(maxWidth), spacing: Double(leading.spacing))
        let all = leadingSlots + trailingSlots
        func slots(_ ids: [ObjectIdentifier]) -> [SegmentSlotView] { ids.compactMap { id in all.first { ObjectIdentifier($0) == id } } }
        let left = slots(shown.leading), right = slots(shown.trailing)
        // Hidden slots stay in their own wing; spilled ones sit at the other wing's outer end.
        let leftOrder = left.filter { !leadingSlots.contains($0) } + leadingSlots.filter { !right.contains($0) }
        let rightOrder = trailingSlots.filter { !left.contains($0) } + right.filter { !trailingSlots.contains($0) }
        for (stack, order, visible) in [(leading, leftOrder, left), (trailing, rightOrder, right)] {
            if !stack.arrangedSubviews.elementsEqual(order, by: ===) {
                stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
                order.forEach(stack.addArrangedSubview)
            }
            for slot in order { slot.isHidden = !visible.contains(slot) }
        }
    }

    private func measureWing() -> CGFloat {
        let integrated = layout?.integratesCameraHousing == true
        // The wing grows to at most 170 points (content plus 24 of margin); a pill to 300.
        fitWings(maxWidth: integrated ? 146 : 150)
        let left = peekShown ? peekLeft.fittingSize.width : visibleWidth(leading)
        let right = peekShown ? peekRight.fittingSize.width : visibleWidth(trailing)
        guard left > 0 || right > 0 else { return 0 }
        if layout?.integratesCameraHousing == true {
            // Symmetric wings; rounded so a one-character change does not resize the notch.
            return min(peekShown ? 180 : 170, ceil((max(left, right) + 24) / 8) * 8)
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
        let peeking = peekShown
        if let wings = layout.wings(expanded: false, wing: wing) {
            pill.isHidden = true
            peekLeft.isHidden = !peeking; peekRight.isHidden = !peeking
            for (stack, area) in [(leading, wings.left), (trailing, wings.right), (peekLeft, wings.left), (peekRight, wings.right)] {
                if stack === leading || stack === trailing { stack.isHidden = !active || peeking }
                guard !stack.isHidden else { continue }
                let size = stack.fittingSize
                surface.place(stack, at: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
            }
        } else {
            if pill.arrangedSubviews.isEmpty { [pillIdle, leading, trailing].forEach(pill.addArrangedSubview) }
            if peeking, peekLeft.superview !== pill { [peekLeft, peekRight].forEach(pill.addArrangedSubview) }
            peekLeft.isHidden = !peeking; peekRight.isHidden = !peeking
            pillIdle.isHidden = active
            leading.isHidden = !active || peeking || visibleWidth(leading) == 0
            trailing.isHidden = !active || peeking || visibleWidth(trailing) == 0
            pill.isHidden = state.expanded
            let rect = layout.surface(expanded: false, wing: wing)
            let size = pill.fittingSize
            surface.place(pill, at: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    // MARK: Nudge (floating pill only)

    private var nudgeStart: CGFloat?
    private var nudgeDelta: CGFloat = 0

    private func nudge(by dx: CGFloat) {
        if nudgeStart == nil, let screen { nudgeStart = CGFloat(general.pillOffsets[String(Self.displayID(screen))] ?? 0) }
        nudgeDelta = dx
        present(.none)
    }

    /// Settles the pill at the center or an edge when close to one, and remembers the spot per display.
    private func endNudge(center: Bool) {
        guard let screen, let layout else { return }
        let width = layout.surface(expanded: false, wing: wing).width
        let target = center ? 0 : layout.snapped(offset: layout.offset, width: width)
        nudgeStart = nil
        nudgeDelta = 0
        updateGeneral { $0.pillOffsets[String(Self.displayID(screen))] = target == 0 ? nil : Double(target) }
        present(.nudge)
    }

    // MARK: Profile

    var profileImageURL: URL { store.directory.appendingPathComponent("profile.png") }
    private var profileImage: NSImage?
    private var profileImageLoaded = false

    var profile: (name: String, image: NSImage?) {
        if !profileImageLoaded {
            profileImageLoaded = true
            profileImage = NSImage(contentsOf: profileImageURL)
        }
        return (GeneralSettings.displayName(chosen: general.profileName, fullUserName: NSFullUserName()), profileImage)
    }

    /// Saves a 96-pixel square copy, so moving or deleting the original never breaks the header.
    func setProfileImage(from url: URL?) -> Bool {
        defer { profileImageLoaded = false; accentChanged() }
        guard let url else { try? FileManager.default.removeItem(at: profileImageURL); return true }
        guard let source = NSImage(contentsOf: url), let png = Self.squarePNG(source, pixels: 96) else { return false }
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try png.write(to: profileImageURL, options: .atomic)
            return true
        } catch { return false }
    }

    private static func squarePNG(_ image: NSImage, pixels: Int) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        guard side > 0, let crop = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
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
            let view = PanelView(tabs: tabs, selected: activeTab, profile: profile, pinned: general.pinned,
                                 select: { [weak self] in self?.selectTab($0) },
                                 togglePin: { [weak self] in self?.togglePin() },
                                 openSettings: { [weak self] in self?.openSettings() },
                                 toggleEdit: { [weak self] in self?.toggleEditing() },
                                 reorderTabs: { [weak self] ids in self?.updateGeneral { $0.tabOrder = LayoutOrder.reorder(ids, saved: $0.tabOrder) } })
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
        // The pointer may have been left outside the shrunken window without an exit event.
        if hoverSuppressed, !frame.contains(NSEvent.mouseLocation) { hoverSuppressed = false }
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
