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
    /// Opt-in native smoke trace; nil in normal operation, with no scheduled work of its own.
    var hoverTrace: ((String) -> Void)?
    private func traceHover(_ event: String) {
        guard let hoverTrace else { return }
        let point = NSEvent.mouseLocation
        hoverTrace("t=\(ProcessInfo.processInfo.systemUptime) \(event) pointer=\(point) expected=\(String(describing: expectedFrame)) segment=\(segmentID(at: point) ?? "none") suppressed=\(hoverSuppressed) state=\(state.presentation) task_cancelled=\(String(describing: hoverTask?.isCancelled))")
    }
    private var hoverTask: DispatchWorkItem?
    private var leaveTask: DispatchWorkItem?
    private var globalClick: Any?
    private var localClick: Any?
    private var globalMenuPointer: Any?
    private var localMenuPointer: Any?
    private(set) var menuBarRevealed = false
    static let attachedLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var settingsController: SettingsController?
    private var contentCache: [String: NSView] = [:]
    private var transientDetail: (cardID: String, view: NSView)?
    private var emphasizedCardID: String?
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
    /// Native diagnostics can exercise an external display without requiring that hardware.
    private var diagnosticLayout: DisplayLayout?
    var statusChanged: (() -> Void)?
    /// Sparkle updates; nil in development, diagnostic and isolated runs.
    var updater: Updater?
    /// A fresh install: no module is constructed until the welcome tour ends, so its feature
    /// choices apply directly.
    private(set) var modulesDeferred: Bool
    private(set) var onboarding: OnboardingController?
    /// `--snapshot`: the notch is drawn for the PNGs only. Its window stays transparent and lets the
    /// pointer through, and outside clicks do not close it.
    var renderOnly = false {
        didSet { panel.alphaValue = renderOnly ? 0 : 1; panel.ignoresMouseEvents = renderOnly || gameActive }
    }

    init(store: SettingsStore, deferModules: Bool = false, renderOnly: Bool = false) {
        self.renderOnly = renderOnly
        self.store = store
        modulesDeferred = deferModules
        general = store.load("general", default: GeneralSettings())
        Motion.userReduced = general.reduceMotion
        Palette.accentOverride = general.accent.flatMap(Palette.hex)
        sounds = SoundRegistry(store: store)
        shortcuts = ShortcutRegistry(store: store)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.alphaValue = renderOnly ? 0 : 1
        panel.ignoresMouseEvents = renderOnly
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
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
        surface.identifier = NSUserInterfaceItemIdentifier("pill")
        panel.clicked = { [weak self] in
            guard let self else { return false }
            let opening = !self.state.expanded
            let target = opening ? self.segmentID(at: NSEvent.mouseLocation) : nil
            if !self.state.acceptsKeyboard { self.open(keyboard: true) }
            if let target { self.routeSegment(target) }
            return opening
        }
        panel.escaped = { [weak self] in self?.close() }
        panel.canNudge = { [weak self] in
            guard let self, let layout = self.layout else { return false }
            return !layout.integratesCameraHousing && !self.state.expanded && !self.gameActive
        }
        panel.nudged = { [weak self] dx in self?.nudge(by: dx) }
        panel.nudgeEnded = { [weak self] doubleClick, velocity in self?.endNudge(center: doubleClick, velocity: velocity) }
        panel.typed = { [weak self] text in self?.typeToSearch(text) }
        registerShellSearch()
        shortcuts.add("toggle", title: "Toggle panel", hint: "Opens or closes the panel, ready for typing.", gesture: "ctrl+opt+n", order: 0) { [weak self] in
            self?.toggleFromKeyboard()
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
            guard let self, !self.panel.frame.containsPointer(NSEvent.mouseLocation) else { return }
            self.clickedOutside()
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.clickedOutside() }
            return event
        }
        // Event-driven: no polling while the pointer is stationary. Entering the menu bar
        // outside QNotch yields its whole band, including icons underneath our wings.
        globalMenuPointer = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateMenuBarAccess(at: NSEvent.mouseLocation)
        }
        localMenuPointer = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMenuBarAccess(at: NSEvent.mouseLocation)
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
        guard holds == 0, !renderOnly else { return }
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
        if !general.pinned, state.presentation == .hover, !panel.frame.containsPointer(NSEvent.mouseLocation) { pointerLeft() }
    }

    func actionsChanged() { statusChanged?() }

    func stop() {
        hoverTask?.cancel(); leaveTask?.cancel()
        modules.forEach { $0.stop() }
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let globalMenuPointer { NSEvent.removeMonitor(globalMenuPointer) }
        if let localMenuPointer { NSEvent.removeMonitor(localMenuPointer) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        panel.orderOut(nil)
    }

    // MARK: Modules and settings

    /// Stops modules that were turned off and constructs those turned on. Modules that stay on
    /// keep running untouched (a running countdown survives turning Note off).
    private func composeModules() {
        let wanted = modulesDeferred ? [] : ModuleList.all.filter { general.isEnabled($0.id) }
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
        contentCache["tab.search"] = nil
        searchView = nil
        if !tabs.contains(where: { $0.id == activeTab }) {
            activeTab = "home"
            if state.acceptsKeyboard { panel.makeFirstResponder(nil) }
        }
        buildStatus()
    }

    func updateGeneral(_ change: (inout GeneralSettings) -> Void) {
        let previous = general
        let disabled = general.disabledModules
        change(&general)
        // Materialize the full order before anything disappears, including never-dragged defaults.
        // Later drags replace only shown slots, so hidden/off contributions keep their place.
        if previous.hiddenCards != general.hiddenCards || previous.disabledModules != general.disabledModules {
            general.cardOrder = LayoutOrder.remember(saved: general.cardOrder, defaults: registries.cards.items.map(\.id))
        }
        if previous.hiddenTabs != general.hiddenTabs || previous.disabledModules != general.disabledModules {
            general.tabOrder = LayoutOrder.remember(saved: general.tabOrder, defaults: registries.tabs.items.filter { $0.id != "search" }.map(\.id))
        }
        if previous.disabledModules != general.disabledModules || previous.hiddenCards != general.hiddenCards || previous.hiddenTabs != general.hiddenTabs {
            clearSegmentDetail()
        }
        store.save("general", general)
        if previous.cardSizes != general.cardSizes { homeView?.applySizes(general.cardSizes) }
        Motion.userReduced = general.reduceMotion
        Palette.accentOverride = general.accent.flatMap(Palette.hex)
        if previous.accent != general.accent || previous.profileName != general.profileName {
            accentChanged()
        }
        if disabled != general.disabledModules || previous.enabledOptionalModules != general.enabledOptionalModules {
            composeModules()
            contentCache["home"] = nil
            discardPanel()
        } else if previous.hiddenCards != general.hiddenCards || previous.hiddenTabs != general.hiddenTabs {
            if previous.hiddenCards != general.hiddenCards {
                contentCache["home"] = nil
                if activeTab == "home", state.acceptsKeyboard { panel.makeFirstResponder(nil) }
            }
            if !general.isTabVisible(activeTab), previous.isTabVisible(activeTab) {
                activeTab = "home"
                if state.acceptsKeyboard { panel.makeFirstResponder(nil) }
            }
            discardPanel()
        }
        resolveDisplay()
        rebuildSurface()
        updateVisibility()
        statusChanged?()
    }

    /// Ends the first-run deferral: constructs the chosen modules and shows their status.
    func startModules() {
        guard modulesDeferred else { return }
        modulesDeferred = false
        composeModules()
        discardPanel()
        resolveDisplay()
        rebuildSurface()
        updateVisibility()
        statusChanged?()
        start()
    }

    /// A running module by id, nil when it is off (or not constructed yet).
    func module(_ id: String) -> NotchModule? { loaded.first { $0.id == id }?.module }

    // MARK: Welcome tour

    /// Opens the welcome tour, or brings it forward. `firstRun`: the fresh-install tour, before any
    /// module is constructed; the modules start when it ends.
    @discardableResult
    func showOnboarding(firstRun: Bool = false, isolated: Bool = false) -> OnboardingController {
        if let onboarding {
            onboarding.show()
            return onboarding
        }
        close(restoreFocus: false)
        // Recorded as pending, so a tour that never ends shows again at the next launch.
        if firstRun { updateGeneral { $0.onboardingDone = false } }
        let controller = OnboardingController(shell: self, firstRun: firstRun, isolated: isolated)
        controller.ended = { [weak self] in self?.onboardingEnded() }
        onboarding = controller
        controller.show()
        return controller
    }

    /// Finished, skipped or closed: never shown automatically again.
    private func onboardingEnded() {
        onboarding = nil
        if general.onboardingDone != true { updateGeneral { $0.onboardingDone = true } }
        startModules()
    }

    /// The tour's Open QNotch: the panel on Home, ready for typing.
    func openHome() {
        if activeTab != "home" { selectTab("home") }
        open(keyboard: true)
        // Opening during a notification peek moves to Notifications; Open QNotch means Home.
        if activeTab != "home" { selectTab("home") }
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
                if shell.holds == 0 { DispatchQueue.main.async { if !shell.panel.frame.containsPointer(NSEvent.mouseLocation) { shell.pointerLeft() } } }
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
        selectTab(tab)
        open(keyboard: false)
        lingerTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.state.presentation == .hover, !self.general.pinned,
                  !self.panel.frame.containsPointer(NSEvent.mouseLocation) else { return }
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
        if screen == nil { clearSegmentDetail(); state.close(); panel.orderOut(nil); updateVisibility() }
        statusChanged?()
    }

    var layout: DisplayLayout? {
        guard let screen else { return nil }
        let gap: CGRect?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                         width: max(0, right.minX - left.maxX), height: screen.safeAreaInsets.top)
        } else { gap = nil }
        var layout = diagnosticLayout ?? DisplayLayout(frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, cameraGap: gap)
        layout.offset = nudgeOffset ?? CGFloat(general.pillOffsets[String(Self.displayID(screen))] ?? 0)
        if nudgeOffset != nil { layout.edgeStretch = 8 }
        return layout
    }

    /// Render synthetic display geometry through the real shell, invisibly and with isolated
    /// diagnostic data. The selected physical display and its saved offsets are not changed.
    func withDiagnosticLayout(_ layout: DisplayLayout, perform: () throws -> Void) rethrows {
        let previous = diagnosticLayout
        let wasRenderOnly = renderOnly
        diagnosticLayout = layout
        renderOnly = true
        rebuildSurface()
        defer {
            diagnosticLayout = previous
            rebuildSurface()
            renderOnly = wasRenderOnly
        }
        try perform()
    }

    /// The settled window frame for the current presentation.
    var expectedFrame: CGRect? { layout.map(surfaceRect) }

    /// The settled surface: the layout's, swollen a little while the pointer rests on the collapsed
    /// notch, so hovering answers at once, before the hover delay opens the panel.
    private func surfaceRect(_ layout: DisplayLayout) -> CGRect {
        let rect = layout.surface(expanded: state.expanded, wing: wing)
        guard hovering, !state.expanded, Motion.moves else { return rect }
        // Attached to the bezel it grows sideways and down; a floating pill grows all round.
        let swell: CGFloat = 2
        return layout.integratesTopBand ? CGRect(x: rect.minX - swell, y: rect.minY - swell, width: rect.width + swell * 2, height: rect.height + swell)
                                              : rect.insetBy(dx: -swell, dy: -swell / 2)
    }

    /// Keep the menu bar in front while traversing it, even across QNotch's footprint.
    /// Approaching QNotch directly from below preserves its normal hover/click behavior.
    func updateMenuBarAccess(at point: CGPoint) {
        guard !renderOnly, !gameActive, let layout, layout.integratesTopBand else { return }
        let band = CGRect(x: layout.frame.minX, y: layout.frame.maxY - layout.topBandHeight,
                          width: layout.frame.width, height: layout.topBandHeight)
        let reveal = band.containsPointer(point) && (menuBarRevealed || !(expectedFrame?.containsPointer(point) ?? false))
        guard reveal != menuBarRevealed else { return }
        menuBarRevealed = reveal
        if reveal {
            hoverTask?.cancel()
            hovering = false
        }
        panel.level = reveal ? .floating : Self.attachedLevel
    }

    // MARK: Hover, open and close

    /// After an explicit close (Escape, Settings, Show, a pick) with the pointer still on the
    /// notch, hover stays off until the pointer leaves, so the panel does not spring back open.
    private var hoverSuppressed = false
    /// The pointer rests on the collapsed notch (see `surfaceRect`).
    private var hovering = false

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        if !state.expanded, Motion.moves { present(.hover) }
    }

    func pointerEntered() {
        traceHover("entered")
        leaveTask?.cancel()
        guard !gameActive, !menuBarRevealed else { return }
        guard !state.expanded else { return }
        if hoverSuppressed {
            guard !(expectedFrame?.containsPointer(NSEvent.mouseLocation) ?? false) else { return }
            hoverSuppressed = false
        }
        setHovering(true)
        hoverTask?.cancel()
        // The settled shape, not the window: while a close morph runs, the window still covers
        // the panel's old area, and a pointer there must not reopen it.
        let task = DispatchWorkItem { [weak self] in
            self?.traceHover("dwell-fired")
            guard let self, !self.hoverSuppressed, self.expectedFrame?.containsPointer(NSEvent.mouseLocation) == true else { return }
            self.completeHover(at: NSEvent.mouseLocation)
        }
        hoverTask = task
        traceHover("scheduled delay_ms=\(general.hoverDelayMs) deadline=\(ProcessInfo.processInfo.systemUptime + Double(general.hoverDelayMs) / 1000)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(general.hoverDelayMs), execute: task)
    }

    /// Resolve at the dwell deadline, in screen coordinates, before expansion changes the geometry.
    /// Already-expanded openings are latched: crossing another segment never navigates.
    func completeHover(at point: NSPoint) {
        traceHover("completeHover requested=\(point)")
        guard !state.expanded, !hoverSuppressed, !gameActive,
              expectedFrame?.containsPointer(point) == true else { return }
        let target = general.hoverOpensSegment ? segmentID(at: point) : nil
        open(keyboard: false)
        if let target, state.expanded { routeSegment(target) }
    }

    /// Live AppKit conversions account for negative display origins, world offsets and spill wings.
    func segmentID(at point: NSPoint) -> String? {
        guard !peekShown, !gameActive else { return nil }
        let local = panel.convertPoint(fromScreen: point)
        return (leadingSlots + trailingSlots).first { slot in
            slot.activate != nil && !slot.isHiddenOrHasHiddenAncestor && slot.subviews.first?.isHidden == false &&
                slot.bounds.contains(slot.convert(local, from: nil))
        }?.segmentID
    }

    /// Explicit clicks and accessibility/keyboard presses route regardless of the hover preference.
    func activateSegment(_ id: String) {
        guard !gameActive else { return }
        open(keyboard: true)
        if state.expanded { routeSegment(id) }
    }

    private func clearSegmentDetail() {
        if let id = emphasizedCardID { (contentCache["card." + id] as? SegmentDetailContent)?.emphasize(nil) }
        emphasizedCardID = nil
        transientDetail?.view.removeFromSuperview()
        transientDetail?.view.layer?.removeAllAnimations()
        transientDetail = nil
    }

    private func routeSegment(_ id: String) {
        guard let item = registries.segments.items.first(where: { $0.id == id }), let destination = item.destination else {
            selectTab("home")
            return
        }
        switch destination {
        case .tab(let tab):
            let available = general.isTabVisible(tab) && registries.tabs.items.contains { $0.id == tab }
            selectTab(available ? tab : "home")
        case .card(let id, let emphasis, let allowsHiddenDetail):
            selectTab("home")
            guard let card = registries.cards.items.first(where: { $0.id == id }) else { return }
            let visible = general.isCardVisible(id)
            guard visible || allowsHiddenDetail else { return }
            let content = visible ? cached("card." + id, card.makeView) : card.makeView()
            if let emphasis {
                guard let details = content as? SegmentDetailContent, details.emphasize(emphasis) else { return }
                if visible { emphasizedCardID = id }
            }
            if visible {
                homeView?.revealCard(id)
            } else {
                // A temporary surface, never a new tab or a change to the saved Home layout.
                let back = actionButton("Back to Home") { [weak self] in self?.selectTab("home") }
                back.identifier = NSUserInterfaceItemIdentifier("segment-detail-home")
                let header = row([line(card.title + " details", size: 15, weight: .semibold, color: Palette.textPrimary), spacer(), back], spacing: 8)
                let host = NSView()
                let stack = column([header, content, spacer()], spacing: 18)
                embed(stack, in: host, inset: 12, fill: true)
                for view in [header, content] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
                host.identifier = NSUserInterfaceItemIdentifier("segment-detail-" + id)
                transientDetail = (id, host)
                showBody()
                updateVisibility()
            }
        }
    }

    func pointerLeft() {
        traceHover("left; cancelling dwell")
        hoverTask?.cancel()
        leaveTask?.cancel()
        hoverSuppressed = false
        if !panel.frame.containsPointer(NSEvent.mouseLocation) { setHovering(false) }
        guard state.presentation == .hover, !general.pinned, holds == 0 else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.general.pinned, self.holds == 0, !self.panel.frame.containsPointer(NSEvent.mouseLocation) else { return }
            self.clearSegmentDetail()
            self.state.pointerLeft()
            self.present(.close)
            self.updateVisibility()
        }
        leaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(general.closeDelayMs), execute: task)
    }

    func open(keyboard: Bool) {
        // During the first-run tour there is nothing to show yet.
        guard screen != nil, !gameActive, !modulesDeferred else { return }
        hoverTask?.cancel(); leaveTask?.cancel()
        let wasExpanded = state.expanded
        hovering = false
        if keyboard, !state.acceptsKeyboard { previousApp = NSWorkspace.shared.frontmostApplication }
        state.open(keyboard: keyboard)
        peekHandle?.end()
        panel.keyboardAllowed = state.acceptsKeyboard
        if !wasExpanded { present(.open) }
        updateVisibility()
        if keyboard {
            if !renderOnly { panel.makeKeyAndOrderFront(nil) }
            if activeTab == "search" { searchView?.focus(appending: "") }
            else if let input = contentCache["tab." + activeTab] as? PanelKeyboardContent { input.focusKeyboard() }
            else { panel.makeFirstResponder(nil) }
        } else { panel.orderFrontRegardless() }
    }

    func close(restoreFocus: Bool = true) {
        hoverTask?.cancel(); leaveTask?.cancel()
        guard state.expanded else { return }
        let restore = restoreFocus && panel.isKeyWindow
        hoverSuppressed = panel.frame.containsPointer(NSEvent.mouseLocation)
        hovering = false
        setEditing(false)
        clearSegmentDetail()
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
        let visible = registries.tabs.items.filter { general.isTabVisible($0.id) || $0.id == activeTab }
        let search = visible.filter { $0.id == "search" }
        let items = visible.filter { $0.id != "search" }
        let order = LayoutOrder.apply(saved: general.tabOrder, defaults: items.map(\.id))
        return [PanelView.Tab(id: "home", symbol: "house", title: "Home")] +
            search.map { PanelView.Tab(id: $0.id, symbol: $0.symbol, title: $0.title) } +
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
        let hadDetail = transientDetail != nil
        clearSegmentDetail()
        if hadDetail { showBody(); updateVisibility() }
        // Hidden tabs remain action/shortcut destinations. Show a temporary selected tab while
        // active, then remove it on leaving; Home and enabled Search retain their fixed positions.
        let ids = ["home"] + registries.tabs.items.filter { $0.id == "search" }.map(\.id) +
            LayoutOrder.apply(saved: general.tabOrder, defaults: registries.tabs.items.filter { $0.id != "search" }.map(\.id))
        guard let next = ids.firstIndex(of: id) else { return }
        let previous = ids.firstIndex(of: activeTab) ?? 0
        let stripChanges = !general.isTabVisible(activeTab) || !general.isTabVisible(id)
        guard id != activeTab else {
            if id == "search", state.acceptsKeyboard { searchView?.focus(appending: "") }
            else if state.acceptsKeyboard { (contentCache["tab." + id] as? PanelKeyboardContent)?.focusKeyboard() }
            return
        }
        if editing, id != "home" { setEditing(false) }
        activeTab = id
        if stripChanges {
            discardPanel()
            present(.none)
        }
        panelView?.select(id, animated: true)
        panelView?.setEditing(editing, onHome: id == "home")
        showBody(direction: next > previous ? 1 : -1, animated: true)
        updateVisibility()
        if id == "search", state.acceptsKeyboard { searchView?.focus(appending: "") }
        else if state.acceptsKeyboard {
            if let input = contentCache["tab." + id] as? PanelKeyboardContent { input.focusKeyboard() }
            else { panel.makeFirstResponder(nil) }
        }
    }

    private func typeToSearch(_ text: String) {
        guard searchAvailable, state.acceptsKeyboard else { return }
        selectTab("search")
        searchView?.focus(appending: text)
    }

    private var searchAvailable: Bool { !modulesDeferred && general.isEnabled("search") }

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
                self.registries.settingsSections.items.map { ("module." + $0.id, $0.title, "") } +
                [("about", "About", "version updates check for updates beta welcome tour onboarding")]
            return pages.filter { "\($0.1) \($0.2)".localizedCaseInsensitiveContains(query) }.map { page in
                SearchHit(title: page.1, detail: "Settings · opens this page", symbol: "gearshape") { [weak self] in self?.openSettings(page: page.0) }
            }
        })
    }

    static let shellShortcuts: Set<String> = ["toggle", "gamemode"]

    // MARK: Game mode

    /// The notch steps aside: the panel cannot open, the surface ignores the mouse, peeks are off,
    /// and the wings show only the segments chosen for game mode, at the chosen opacity.
    private func applyGameMode() {
        let active = gameActive
        if active { close(restoreFocus: false); peekHandle?.end() }
        panel.ignoresMouseEvents = active || renderOnly
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
        guard searchAvailable else { return }
        if state.acceptsKeyboard, activeTab == "search" { close(); return }
        open(keyboard: true)
        selectTab("search")
        searchView?.focus(appending: "")
    }

    private func updateVisibility() {
        for (id, module) in loaded {
            let visible = transientDetail.map { registries.cards.owner(of: $0.cardID) == id } ?? (activeTab == "home"
                ? registries.cards.ids(owner: id).contains(where: general.isCardVisible)
                : registries.tabs.owner(of: activeTab) == id)
            module.setVisibility(panel: state.expanded && visible, activeTab: activeTab)
        }
    }

    private func showBody(direction: Int = 0, animated: Bool = false) {
        guard let panelView else { return }
        let content: NSView
        if let detail = transientDetail {
            panelView.show(detail.view, direction: direction, animated: animated)
            return
        }
        switch activeTab {
        case "home":
            content = cached("home") { [unowned self] in self.makeHome() }
        default:
            if let tab = registries.tabs.items.first(where: { $0.id == activeTab }) {
                content = cached("tab." + tab.id) {
                    let body = tab.makeView()
                    return tab.id == "search" ? body : TabPageView(id: tab.id, title: tab.title, content: body)
                }
                if tab.id == "search" { searchView = content as? SearchView }
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
        let home = HomeView(cards: ordered.map { ($0, cached("card." + $0.id, $0.makeView)) }, sizes: general.cardSizes)
        home.resized = { [weak self] id, size in self?.updateGeneral { $0.cardSizes[id] = size.rawValue } }
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
                container.segmentID = item.id
                if item.destination != nil, let label = item.destinationLabel {
                    container.activate = { [weak self] in self?.activateSegment(item.id) }
                    container.toolTip = label
                    container.setAccessibilityElement(true)
                    container.setAccessibilityRole(.button)
                    container.setAccessibilityLabel(label)
                }
                container.identifier = NSUserInterfaceItemIdentifier("segment-slot-" + item.id)
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
            // The line fades out the way it came, then the wings take their status back.
            let views = [self.peekLeft, self.peekRight]
            Motion.leave(views[1], duration: 0.12) { views[1].removeFromSuperview() }
            Motion.leave(views[0], duration: 0.12) { [weak self] in
                views[0].removeFromSuperview()
                guard let self, self.peekHandle == nil else { return }
                self.segmentsChanged()
                for view in [self.leading, self.trailing] where !view.isHidden { Motion.enter(view, duration: 0.2) }
            }
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
        for view in [peekLeft, peekRight] { Motion.enter(view, delay: 0.05, duration: 0.18) }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(10, max(1, seconds))) { [weak handle] in handle?.end() }
        }
        return handle
    }

    private func visibleWidth(_ stack: NSStackView) -> CGFloat {
        stack.arrangedSubviews.contains { !$0.isHidden } ? stack.fittingSize.width : 0
    }

    /// Shows each wing's visible segments while they fit, spilling over to the other wing (WingFit).
    private func fitWings(maxWidth: CGFloat) {
        let hidden = Set(general.hiddenNotchModules).union(gameActive ? Set(gameMode.settings.hiddenModules) : [])
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
        let integrated = layout?.integratesTopBand == true
        // The wing grows to at most 170 points (content plus 24 of margin); a pill to 300.
        var capacity: CGFloat = integrated ? 146 : 150
        if integrated, let wings = layout?.wings(expanded: false, wing: 170) {
            capacity = min(capacity, max(0, min(wings.left.width, wings.right.width) - StatusGutters.inset * 2))
        }
        fitWings(maxWidth: capacity)
        let left = peekShown ? peekLeft.fittingSize.width : visibleWidth(leading)
        let right = peekShown ? peekRight.fittingSize.width : visibleWidth(trailing)
        guard left > 0 || right > 0 else { return 0 }
        if layout?.integratesTopBand == true {
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
        if state.expanded { layoutStatus() } else { present(.status) }
        if appearing, !state.expanded {
            for view in [leading, trailing, pill] { Motion.enter(view, delay: 0.08, duration: 0.28) }
        }
    }

    /// Places status content. With a physical or virtual housing it sits in the side wings (also while expanded,
    /// so nothing jumps); a floating pill shows it centered and hides it under the open panel.
    private func layoutStatus() {
        guard let layout else { return }
        let active = wing > 0
        let peeking = peekShown
        if let wings = layout.wings(expanded: false, wing: wing) {
            pill.isHidden = true
            peekLeft.isHidden = !peeking; peekRight.isHidden = !peeking
            for (stack, area, side) in [(leading, wings.left, StatusGutters.Side.left), (trailing, wings.right, .right),
                                        (peekLeft, wings.left, .left), (peekRight, wings.right, .right)] {
                if stack === leading || stack === trailing { stack.isHidden = !active || peeking }
                guard !stack.isHidden else { continue }
                guard let frame = StatusGutters.frame(size: stack.fittingSize, in: area, side: side) else {
                    stack.isHidden = true
                    continue
                }
                surface.place(stack, at: frame)
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

    // MARK: Nudge (no physical camera housing)

    private var nudgeStart: CGFloat?
    /// Where the dragged pill shows, rubber-banded at the edges; nil when not dragging.
    private var nudgeOffset: CGFloat?

    private func nudge(by dx: CGFloat) {
        guard let screen, let layout else { return }
        if nudgeStart == nil { nudgeStart = CGFloat(general.pillOffsets[String(Self.displayID(screen))] ?? 0) }
        nudgeOffset = layout.dragged(offset: (nudgeStart ?? 0) + dx, width: layout.surface(expanded: false, wing: wing).width)
        present(.none)
    }

    /// Settles the pill at the center or an edge when it would coast close to one, and remembers
    /// the spot per display. A flick throws it and the spring carries on at the pointer's `velocity`.
    private func endNudge(center: Bool, velocity: CGFloat) {
        guard let screen, let layout else { return }
        let width = layout.surface(expanded: false, wing: wing).width
        let current = layout.offset
        let target = center ? 0 : layout.snapped(offset: current, width: width, velocity: velocity)
        nudgeStart = nil
        nudgeOffset = nil
        updateGeneral { $0.pillOffsets[String(Self.displayID(screen))] = target == 0 ? nil : Double(target) }
        present(.release, velocity: center ? 0 : Fluid.relativeVelocity(velocity, from: current, to: target))
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
        clearSegmentDetail()
        contentCache.removeAll()
        searchView = nil
        buildStatus()
        discardPanel()
        rebuildSurface()
    }

    /// Drops the panel (open or closing), so the next open builds it with current settings.
    private func discardPanel() {
        for view in [panelView, closingPanel] { view?.removeFromSuperview() }
        panelView = nil
        closingPanel = nil
    }

    /// Full rebuild for a display, module, or accent change. No animation.
    private func rebuildSurface() {
        guard let layout else { return }
        var world = layout.surface(expanded: true).union(layout.surface(expanded: false, wing: 120)).insetBy(dx: -40, dy: -40)
        // A floating pill moves sideways: spanning the display, the world stays put when it is
        // dropped somewhere new, so the release spring starts exactly where the pill shows.
        if !layout.integratesCameraHousing { world = CGRect(x: layout.frame.minX - 40, y: world.minY, width: layout.frame.width + 80, height: world.height) }
        surface.configure(world: world, integrated: layout.integratesTopBand, band: layout.topBandHeight)
        menuBarRevealed = false
        panel.level = layout.integratesTopBand ? Self.attachedLevel : .floating
        wing = measureWing()
        if let panelView { surface.place(panelView, at: layout.panelBody) }
        present(.none)
    }

    /// Morphs the surface to the current presentation. While animating, the window temporarily
    /// covers both shapes plus overshoot room; it returns to the exact surface when settled.
    /// `velocity`: a released drag's speed in spring units (`Fluid.relativeVelocity`).
    private func present(_ style: NotchSurfaceView.Morph, velocity: CGFloat = 0) {
        guard let layout else { return }
        surfaceRevision += 1
        let expanded = state.expanded
        let target = surfaceRect(layout)
        // With reduced motion the surface crossfades as a whole, panel content included.
        let animated = style != .none && Motion.fades && panel.isVisible
        let moving = animated && Motion.moves
        if expanded, panelView == nil {
            if let view = closingPanel {
                // Reopened while closing: the same panel turns around from where it is on screen.
                closingPanel = nil
                panelView = view
                view.isHidden = false
                view.select(activeTab, animated: false)
                view.setPinned(general.pinned)
                view.setEditing(editing, onHome: activeTab == "home")
                showBody()
                if moving { Motion.resume(view, duration: 0.24) } else { view.layer?.removeAllAnimations() }
            } else {
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
                if moving { Motion.enter(view, delay: 0.07, duration: 0.3, up: 10) }
            }
        } else if !expanded, let view = panelView {
            panelView = nil
            closingPanel = view
            if moving {
                Motion.leave(view, duration: 0.12, up: 8) { [weak self, weak view] in
                    guard let self, let view, self.closingPanel === view else { return }
                    view.isHidden = true
                }
            } else if animated {
                view.isHidden = true
            } else { view.removeFromSuperview(); closingPanel = nil }
        }
        let integrated = layout.integratesTopBand
        let bottom: CGFloat = expanded ? 22 : integrated ? 11 : 16
        var window = target
        if animated {
            let visible = surface.visibleShapeBounds
            window = visible.union(target)
            if moving, velocity != 0 {
                // A thrown pill can overshoot its spot; keep the whole flight inside the window.
                let spring = style.spring(momentum: true)
                let reach = Fluid.springExtent(from: visible.midX, to: target.midX, velocity: velocity * (target.midX - visible.midX),
                                               response: spring.response, dampingRatio: spring.dampingRatio)
                window = window.union(target.offsetBy(dx: reach.lowerBound - target.midX, dy: 0))
                    .union(target.offsetBy(dx: reach.upperBound - target.midX, dy: 0))
            }
            window = window.insetBy(dx: -28, dy: -28).intersection(layout.frame)
        }
        setFrame(window)
        let wasHidden = pill.isHidden
        layoutStatus()
        if moving, !integrated, wasHidden, !pill.isHidden { Motion.enter(pill, delay: 0.1, duration: 0.24) }
        surface.morph(to: target, bottom: bottom, top: expanded ? 20 : 16, outlined: expanded, style: animated ? style : .none,
                      velocity: velocity) { [weak self] in
            self?.settle()
        }
    }

    private func settle() {
        guard let frame = expectedFrame else { return }
        setFrame(frame)
        // The pointer may have been left outside the shrunken window without an exit event.
        if hoverSuppressed, !frame.containsPointer(NSEvent.mouseLocation) { hoverSuppressed = false }
        if hovering, !frame.containsPointer(NSEvent.mouseLocation) { setHovering(false) }
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

    func cachedCard(_ id: String) -> NSView? { contentCache["card." + id] }
    var currentBody: NSView? { transientDetail?.view ?? contentCache[activeTab == "home" ? "home" : "tab." + activeTab] }

    func snapshot(to url: URL) throws {
        guard let view = panel.contentView else { throw CocoaError(.fileWriteUnknown) }
        try Self.snapshot(view: view, to: url)
    }

    /// The running module of this type, nil when it is off.
    func module<Module: NotchModule>(_ type: Module.Type) -> Module? { modules.lazy.compactMap { $0 as? Module }.first }

    /// Ends the peek on screen (a toast or an agent alert), so a snapshot shows the settled wings.
    func endPeek() { peekHandle?.end() }

    /// The Settings window's controller, made without showing the window.
    func makeSettings() -> SettingsController {
        if settingsController == nil { settingsController = SettingsController(shell: self) }
        return settingsController!
    }

    /// Writes `view` as a PNG at `url` and its outline beside it (same name, `.txt`).
    static func snapshot(view: NSView, to url: URL, background: NSColor? = nil) throws {
        try png(of: view, background: background).write(to: url)
        try Outline.write(view: view, png: url)
    }

    /// `view` as a PNG at 2x, whatever the display's scale, over `background` (resolved in the
    /// view's appearance) when given: windows whose views draw no background of their own.
    static func png(of view: NSView, background: NSColor? = nil) throws -> Data { try png(image(of: view, background: background)) }

    /// A 2x image as PNG data, marked 144 dpi so it opens at its size in points. Safe off the main thread.
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// `view` drawn at 2x (see `png(of:background:)`), on the main thread.
    static func image(of view: NSView, background: NSColor? = nil) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        guard var image = render(view, rect: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        if let background {
            var fill = background.cgColor
            view.effectiveAppearance.performAsCurrentDrawingAppearance { fill = background.cgColor }
            guard let context = canvas(image.width, image.height) else { throw CocoaError(.fileWriteUnknown) }
            let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(fill)
            context.fill(all)
            context.draw(image, in: all)
            guard let flat = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            image = flat
        }
        return image
    }

    /// `rect` of `view` at 2x. Outside the notch panel (the welcome tour's rounded, masked window),
    /// caching the view tree leaves scroll views blank: their documents are rendered on their own
    /// and drawn into their clip views. The panel's own render keeps overflowing details (slider knobs).
    private static func render(_ view: NSView, rect: NSRect) -> CGImage? {
        let width = Int((rect.width * 2).rounded(.up)), height = Int((rect.height * 2).rounded(.up))
        guard width > 0, height > 0, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                                    bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = rect.size
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child -> [NSScrollView] in (child as? NSScrollView).map { [$0] } ?? scrollViews(in: child) }
        }
        let scrolls = scrollViews(in: view).filter { !($0.window is NotchPanel) && !$0.isHiddenOrHasHiddenAncestor && $0.documentView?.isHidden == false }
        scrolls.forEach { $0.documentView?.isHidden = true }
        view.cacheDisplay(in: rect, to: bitmap)
        scrolls.forEach { $0.documentView?.isHidden = false }
        guard let base = bitmap.cgImage, !scrolls.isEmpty, let context = canvas(width, height) else { return bitmap.cgImage }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        for scroll in scrolls {
            let clip = scroll.contentView
            let frame = clip.convert(clip.bounds, to: view)
            guard let document = scroll.documentView, frame.intersects(rect), let image = render(document, rect: clip.documentVisibleRect) else { continue }
            let y = view.isFlipped ? rect.maxY - frame.maxY : frame.minY - rect.minY
            context.draw(image, in: CGRect(x: (frame.minX - rect.minX) * 2, y: y * 2, width: frame.width * 2, height: frame.height * 2))
        }
        return context.makeImage()
    }

    private static func canvas(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
