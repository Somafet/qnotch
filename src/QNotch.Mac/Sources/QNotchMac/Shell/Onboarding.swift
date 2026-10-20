import AppKit
import QNotchMacCore
import ServiceManagement

/// Status text in a welcome-tour setup row.
func setupStatus(_ text: String) -> NSTextField {
    let view = label(text, size: 12, color: Palette.textSecondary)
    view.preferredMaxLayoutWidth = 420
    return view
}

/// The tour's window: dark like the notch, a transparent full-size title bar (only the close
/// control), dragged by its background. Return runs the primary button and Esc skips, unless a
/// text field or the shortcut recorder takes the key first.
final class OnboardingWindow: NSWindow {
    var returnPressed: (() -> Void)?
    var escaped: (() -> Void)?
    /// A key press seen before any view gets it (the Open step's "Try it now"); true consumes it.
    var intercept: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, intercept?(event) == true { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, event.keyCode == 36 || event.keyCode == 76 { returnPressed?() } // Return, keypad Enter
        else if plain, event.keyCode == 53 { escaped?() }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { escaped?() }
}

/// The first-run welcome tour (spec/onboarding.md): welcome, open, features, connect and finish,
/// each skippable. On a fresh install it runs before any module is constructed; from Settings,
/// About it runs beside the running app, and its switches apply at once, as in Settings.
///
/// Motion (spec, Motion): the window rises in and, on Open QNotch, flies into the notch; steps
/// slide by direction with a parallax hero and staggered text; each hero has a one-time moment.
/// Loops (the glow drift, the key caps) run only while their step is on screen and the window is
/// visible, and are removed otherwise. Diagnostic runs show only settled states.
final class OnboardingController: NSObject, NSWindowDelegate {
    static let windowSize = NSSize(width: 760, height: 520)
    static let heroHeight: CGFloat = 286
    private static let margin: CGFloat = 40
    private static let cornerRadius: CGFloat = 12

    let firstRun: Bool
    let window: OnboardingWindow
    /// The tour ended (finished, skipped or closed); the shell records it and starts the modules.
    var ended: (() -> Void)?
    private(set) var steps: [Onboarding.Step] = []
    private(set) var index = 0
    var step: Onboarding.Step { steps[index] }
    /// The toggle gesture was pressed on the Open step.
    private(set) var triedGesture = false

    private unowned let shell: ShellController
    private let container = NSView()
    private let backdrop = HeroBackdrop()
    private var page: NSView?
    private let dots = ProgressDots()
    private var back: HoverButton!
    private var skip: HoverButton!
    private var primary: HoverButton!
    private var connectRows: [String: NSView] = [:]
    private var connectNone: Set<String> = []
    private var featureSwitches: [String: ActionSwitch] = [:]
    private var featureTiles: [String: (tile: NSView, chip: FillView?, tint: NSColor)] = [:]
    private var groupButtons: [(group: Onboarding.Group, button: HoverButton)] = []
    private var featureCount: NSTextField?
    private var tryStatus: NSStackView?
    private var heroCaps: KeyCapsView?
    private var contentCaps: KeyCapsView?
    private var shortcutNote = ""
    private var updatesChoice = true
    private var loginChoice: Bool
    private var ending = false
    private var presented = false
    /// The current step's parts for the step transition, and its one-time hero moment.
    private var parts: (hero: NSView, texts: [NSView])?
    private var moments: [() -> Void] = []
    private var loops: [(layer: CALayer, key: String)] = []

    init(shell: ShellController, firstRun: Bool, isolated: Bool) {
        self.shell = shell
        self.firstRun = firstRun
        // A throwaway data folder never adds itself to the login items unless asked to.
        loginChoice = !isolated
        window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to QNotch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = Palette.dark
        // The content draws the dark surface with rounded corners, so it can scale on entrance.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        window.returnPressed = { [weak self] in self?.advance() }
        window.escaped = { [weak self] in self?.skipTour() }
        window.intercept = { [weak self] event in self?.pressed(event) ?? false }
        window.contentView = makeRoot()
        window.setContentSize(Self.windowSize)
        if !firstRun {
            if let updater = shell.updater { updatesChoice = updater.checksAutomatically }
            let status = SMAppService.mainApp.status
            loginChoice = status == .enabled || status == .requiresApproval
        }
        shortcutNote = conflict()
        computeSteps()
        install(animated: false, direction: 0)
    }

    /// Shows the window; the first time it rises in (fade, scale 0.96 → 1, 12 points up) and the
    /// welcome moment plays.
    func show() {
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        guard !presented else {
            window.makeKeyAndOrderFront(nil)
            startLoops()
            return
        }
        presented = true
        if Motion.fades, let content = window.contentView {
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.moves ? 0.3 : Motion.crossfadeDuration
                context.timingFunction = Motion.easeOut
                self.window.animator().alphaValue = 1
            }
            Motion.enter(content, duration: 0.3, up: -12, scale: 0.96, fade: false)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        playMoments()
        startLoops()
    }

    // MARK: Navigation

    func advance() {
        guard !ending else { return }
        if step == .finish { return end(finished: true, closeWindow: true) }
        computeSteps()
        guard index + 1 < steps.count else { return }
        index += 1
        install(animated: true, direction: 1)
    }

    func goBack() {
        guard !ending, index > 0 else { return }
        computeSteps()
        index = max(0, index - 1)
        install(animated: true, direction: -1)
    }

    /// Ends the tour with what was chosen so far plus the defaults.
    func skipTour() { end(finished: false, closeWindow: true) }

    private func computeSteps() {
        let current = steps.isEmpty ? nil : step
        steps = Onboarding.steps(hasConnectRows: !connectItems().isEmpty)
        if let current { index = steps.firstIndex(of: current) ?? min(index, steps.count - 1) }
    }

    /// Setup rows of enabled features, built once each and kept, so a sign-in in progress
    /// survives Back and Continue (it stops while its row is off screen).
    private func connectItems() -> [(info: ModuleInfo, view: NSView)] {
        let shell = self.shell
        return ModuleList.all.filter { shell.general.isEnabled($0.id) }.compactMap { info -> (info: ModuleInfo, view: NSView)? in
            guard let setup = info.setup, !connectNone.contains(info.id) else { return nil }
            if let view = connectRows[info.id] { return (info, view) }
            let id = info.id
            let context = ModuleSetupContext(settings: shell.store, running: { [weak shell] in shell?.module(id) })
            guard let view = setup(context) else {
                connectNone.insert(info.id)
                return nil
            }
            connectRows[info.id] = view
            return (info, view)
        }
    }

    private func end(finished: Bool, closeWindow: Bool) {
        guard !ending else { return }
        ending = true
        stopLoops()
        apply(finished: finished)
        window.delegate = nil
        window.ignoresMouseEvents = true
        shell.shortcuts.suspend(false)
        if finished { handOff() } else { leave(closeWindow: closeWindow) }
    }

    /// Skip or close: a short fade and scale to 0.98 (160 ms, ease-in), then the shell takes over.
    private func leave(closeWindow: Bool) {
        let finish = { [self] in
            ended?()
            if closeWindow { window.close() }
        }
        guard closeWindow, Motion.fades, let content = window.contentView else { return withExtendedLifetime(self) { finish() } }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.moves ? 0.16 : Motion.crossfadeDuration
            context.timingFunction = Motion.easeIn
            self.window.animator().alphaValue = 0
        }, completionHandler: finish)
        if Motion.moves { Motion.leave(content, duration: 0.16, scale: 0.98) {} }
    }

    /// Open QNotch: the tour flies into the notch and the panel springs open as it arrives. The
    /// panel takes the keyboard while the (invisible) tour is still key, and only then does the
    /// tour close: closing the key window first lets AppKit move the keyboard, closing the panel.
    private func handOff() {
        let complete = { [self] in
            ended?()
            shell.openHome()
            window.close()
        }
        guard Motion.fades else { return withExtendedLifetime(self) { complete() } }
        if Motion.moves, flyToNotch(then: complete) { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.crossfadeDuration
            self.window.animator().alphaValue = 0
        }, completionHandler: complete)
    }

    /// A picture of the tour in a click-through overlay shrinks (to 0.3), rises into the notch and
    /// fades: 350 ms, ease-in. The real window stays, invisible, until `then` runs.
    private func flyToNotch(then complete: @escaping () -> Void) -> Bool {
        guard let content = window.contentView, let target = shell.expectedFrame,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        let start = window.convertToScreen(content.convert(content.bounds, to: nil))
        let area = start.union(target).insetBy(dx: -60, dy: -60)
        let overlay = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSView(frame: NSRect(origin: .zero, size: area.size))
        host.wantsLayer = true
        overlay.contentView = host
        let picture = CALayer()
        picture.contents = image
        picture.contentsGravity = .resize
        picture.frame = CGRect(x: start.minX - area.minX, y: start.minY - area.minY, width: start.width, height: start.height)
        picture.cornerRadius = Self.cornerRadius
        picture.masksToBounds = true
        host.layer?.addSublayer(picture)
        overlay.orderFrontRegardless()
        window.alphaValue = 0
        let from = picture.position
        let to = CGPoint(x: target.midX - area.minX, y: target.midY - area.minY)
        let shrunk = CATransform3DMakeScale(0.3, 0.3, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            complete()
            overlay.orderOut(nil)
        }
        CATransaction.setDisableActions(true)
        picture.position = to
        picture.transform = shrunk
        picture.opacity = 0
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: to)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.toValue = NSValue(caTransform3D: shrunk)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.55, 1]
        let group = CAAnimationGroup()
        group.animations = [move, scale, fade]
        group.duration = 0.35
        group.timingFunction = Motion.easeIn
        picture.add(group, forKey: "fly")
        CATransaction.commit()
        return true
    }

    /// First run: the finish step's choices, or the defaults when skipped (updates on, login items
    /// unchanged). From Settings the switches already applied. Diagnostic runs touch neither.
    private func apply(finished: Bool) {
        guard firstRun, !Runtime.diagnostics else { return }
        shell.updater?.checksAutomatically = finished ? updatesChoice : true
        let login = SMAppService.mainApp
        if finished, loginChoice, login.status != .enabled { try? login.register() }
    }

    // MARK: Window

    /// The close control: the same short exit as Skip.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard Motion.fades, !ending else { return true }
        skipTour()
        return false
    }

    func windowWillClose(_ notification: Notification) { end(finished: false, closeWindow: false) }

    // Global shortcuts pause while the tour has the keyboard, so pressing one reaches the window.
    func windowDidBecomeKey(_ notification: Notification) { shell.shortcuts.suspend(true) }
    func windowDidResignKey(_ notification: Notification) { shell.shortcuts.suspend(false) }

    /// Loops stop while the window is hidden or covered.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if windowShown { startLoops() } else { stopLoops() }
    }

    private var windowShown: Bool { window.isVisible && window.occlusionState.contains(.visible) }

    private func pressed(_ event: NSEvent) -> Bool {
        guard let combo = KeyCombo(event: event), combo.isAllowedGlobally, combo == shell.shortcuts.shortcut("toggle")?.combo,
              (window.firstResponder as? ShortcutRecorder)?.isRecording != true else { return false }
        if step == .open, !triedGesture {
            triedGesture = true
            stopLoops()
            for caps in [heroCaps, contentCaps].compactMap({ $0 }) { pressTogether(caps) }
            if let tryStatus { showTried(tryStatus) }
        }
        return true
    }

    /// The Settings, Hotkeys wording for a key another app or QNotch shortcut already uses.
    private func conflict() -> String {
        guard let shortcut = shell.shortcuts.shortcut("toggle") else { return "" }
        if let owner = shortcut.usedBy { return "Used by \(owner)." }
        return shortcut.taken ? "Taken by another app. Pick another shortcut." : ""
    }

    // MARK: Layout

    private func makeRoot() -> NSView {
        let root = FillView(fill: Palette.surface, radius: Self.cornerRadius)
        root.layer?.masksToBounds = true
        let footer = NSView()
        back = HoverButton("Back", style: .plain) { [weak self] in self?.goBack() }
        skip = HoverButton("Skip", style: .chip) { [weak self] in self?.skipTour() }
        primary = HoverButton("Continue", style: .accent) { [weak self] in self?.advance() }
        primary.padding = NSSize(width: 18, height: 7)
        for button in [back, skip, primary] { button?.pressScale = 0.97 }
        back.identifier = NSUserInterfaceItemIdentifier("onboarding-back")
        skip.identifier = NSUserInterfaceItemIdentifier("onboarding-skip")
        primary.identifier = NSUserInterfaceItemIdentifier("onboarding-primary")
        let bar = row([dots, spacer(), skip, back, primary], spacing: 8)
        embed(bar, in: footer, inset: 0, fill: true)
        for view in [backdrop, container, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.windowSize.width), root.heightAnchor.constraint(equalToConstant: Self.windowSize.height),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor), backdrop.heightAnchor.constraint(equalToConstant: Self.heroHeight),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor), container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor), container.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.margin),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.margin),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        container.wantsLayer = true
        return root
    }

    /// Shows the current step. Forward, the old content slides 24 points left and fades while the
    /// new one comes in from the right: the hero first and half as far (parallax), then the title,
    /// subtitle and controls 30 ms apart. Back mirrors it; reduced motion crossfades.
    private func install(animated: Bool, direction: CGFloat) {
        stopLoops()
        let old = page
        featureSwitches = [:]
        featureTiles = [:]
        groupButtons = []
        featureCount = nil
        tryStatus = nil
        heroCaps = nil
        contentCaps = nil
        moments = []
        parts = nil
        let built = build(step)
        built.wantsLayer = true
        built.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(built)
        NSLayoutConstraint.activate([
            built.leadingAnchor.constraint(equalTo: container.leadingAnchor), built.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            built.topAnchor.constraint(equalTo: container.topAnchor), built.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        page = built
        refreshFooter()
        window.makeFirstResponder(nil)
        container.layoutSubtreeIfNeeded()
        if let old {
            if animated, Motion.fades {
                Motion.leave(old, duration: 0.18, dx: -24 * direction) { old.removeFromSuperview() }
            } else {
                old.removeFromSuperview()
            }
        }
        guard animated else { return }
        if let parts {
            Motion.enter(parts.hero, duration: 0.26, dx: 12 * direction)
            for (offset, text) in parts.texts.enumerated() {
                Motion.enter(text, delay: 0.04 + 0.03 * Double(offset), duration: 0.22, dx: 24 * direction)
            }
        }
        playMoments()
        startLoops()
    }

    private func playMoments() {
        guard Motion.fades else { return }
        moments.forEach { $0() }
    }

    private func refreshFooter() {
        dots.set(count: steps.count, index: index)
        back.isHidden = index == 0
        let skipText = step == .welcome ? "Skip setup" : "Skip"
        if skip.text != skipText {
            Motion.crossfade(skip)
            skip.text = skipText
            skip.setAccessibilityLabel(skipText)
        }
        let primaryText = step == .welcome ? "Get started" : step == .finish ? "Open QNotch" : "Continue"
        if primary.text != primaryText {
            Motion.crossfade(primary)
            primary.text = primaryText
            primary.setAccessibilityLabel(primaryText)
        }
    }

    /// Hero (about 55% of the height) with the step's illustration or cards, then the title,
    /// subtitle and the step's own controls.
    private func build(_ step: Onboarding.Step) -> NSView {
        let view = NSView()
        let hero: NSView
        let title: String
        let subtitle: String
        var content: NSView?
        switch step {
        case .welcome:
            title = "Welcome to QNotch"
            subtitle = "Everything you glance at, in the notch at the top of your screen."
            hero = welcomeHero()
            content = line("It takes about a minute. Everything here is also in Settings.", size: 12, color: Palette.textTertiary)
        case .open:
            title = "Open it from anywhere"
            subtitle = "Hover the notch, or press your shortcut."
            hero = openHero()
            content = openControls()
        case .features:
            title = "Pick your features"
            subtitle = "You can change these any time in Settings, Features."
            hero = featuresHero()
            let count = line("", size: 12, color: Palette.textTertiary)
            featureCount = count
            content = count
            refreshFeatures()
        case .connect:
            title = "Connect your accounts"
            subtitle = "Optional. Everything else works without them."
            hero = connectHero()
        case .finish:
            title = "Final touches"
            subtitle = "Start the way you like. You can change these in Settings."
            hero = finishHero()
            content = finishControls()
        }
        let heading = line(title, size: 26, weight: .bold, color: Palette.textPrimary)
        heading.setAccessibilityRole(.staticText)
        let sub = label(subtitle, size: 14, color: Palette.textSecondary)
        sub.preferredMaxLayoutWidth = Self.windowSize.width - Self.margin * 2
        var texts: [NSView] = [heading, sub]
        if let content { texts.append(content) }
        let text = column(texts, spacing: 6)
        if content != nil { text.setCustomSpacing(16, after: sub) }
        for item in [hero, text] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            hero.leadingAnchor.constraint(equalTo: view.leadingAnchor), hero.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hero.topAnchor.constraint(equalTo: view.topAnchor), hero.heightAnchor.constraint(equalToConstant: Self.heroHeight),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin),
            text.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Self.margin),
            text.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 22)
        ])
        view.identifier = NSUserInterfaceItemIdentifier("onboarding-" + step.rawValue)
        parts = (hero, texts)
        return view
    }

    // MARK: Loops

    /// The current step's loop, if any, while the window is on screen.
    private func startLoops() {
        stopLoops()
        guard Motion.moves, presented, !ending, windowShown else { return }
        switch step {
        case .welcome:
            // A very slow drift of the glow behind the hero.
            let drift = CABasicAnimation(keyPath: "transform")
            drift.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(-22, 0, 0))
            drift.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(22, 0, 0))
            drift.duration = 7
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            loop(drift, on: backdrop.glow, key: "drift")
        case .open:
            if !triedGesture, let heroCaps { capsLoop(heroCaps) }
        default:
            break
        }
    }

    private func loop(_ animation: CAAnimation, on layer: CALayer?, key: String) {
        guard let layer else { return }
        layer.add(animation, forKey: key)
        loops.append((layer, key))
    }

    private func stopLoops() {
        for item in loops { item.layer.removeAnimation(forKey: item.key) }
        loops = []
    }

    /// Every 3 seconds the caps press down in order (⌃, ⌥, N) and release together.
    private func capsLoop(_ caps: KeyCapsView) {
        let period: CFTimeInterval = 3
        let keys = caps.arrangedSubviews
        let release = 0.5 + 0.14 * Double(keys.count - 1) + 0.28
        for (offset, cap) in keys.enumerated() {
            let down = (0.5 + 0.14 * Double(offset)) / period
            let up = release / period
            let times = [0, down, down + 0.05 / period, up, up + 0.12 / period, 1].map { NSNumber(value: $0) }
            let rest = NSValue(caTransform3D: CATransform3DIdentity)
            let pressed = NSValue(caTransform3D: Motion.transform(for: cap, up: -2, scale: 0.92))
            let press = CAKeyframeAnimation(keyPath: "transform")
            press.values = [rest, rest, pressed, pressed, rest, rest]
            press.keyTimes = times
            let card = Palette.card.cgColor, lit = Palette.accentSoft.cgColor
            let tint = CAKeyframeAnimation(keyPath: "backgroundColor")
            tint.values = [card, card, lit, lit, card, card]
            tint.keyTimes = times
            let group = CAAnimationGroup()
            group.animations = [press, tint]
            group.duration = period
            group.repeatCount = .infinity
            loop(group, on: cap.layer, key: "caps")
        }
    }

    /// The real gesture: every cap goes down at once and comes back.
    private func pressTogether(_ caps: KeyCapsView) {
        guard Motion.moves else { return }
        for cap in caps.arrangedSubviews {
            let press = CAKeyframeAnimation(keyPath: "transform")
            press.values = [NSValue(caTransform3D: CATransform3DIdentity),
                            NSValue(caTransform3D: Motion.transform(for: cap, up: -2, scale: 0.9)),
                            NSValue(caTransform3D: CATransform3DIdentity)]
            press.keyTimes = [0, 0.35, 1]
            press.duration = 0.28
            press.timingFunction = Motion.easeOut
            cap.layer?.add(press, forKey: "pressed")
        }
    }

    // MARK: Welcome

    private func welcomeHero() -> NSView {
        let (pill, segments) = miniPill()
        let (panel, cards) = miniPanel()
        let art = column([pill, panel], spacing: 12, alignment: .centerX)
        art.setAccessibilityElement(true)
        art.setAccessibilityRole(.image)
        art.setAccessibilityLabel("The notch shows the time, the weather and what is playing; the panel opens below it.")
        // The notch drops in from the bezel, its segments appear one by one, then the panel
        // unfolds downward and its cards follow.
        moments.append {
            Motion.enter(pill, delay: 0.04, duration: 0.32, up: 18, scale: 0.94)
            for (offset, segment) in segments.enumerated() { Motion.enter(segment, delay: 0.24 + 0.05 * Double(offset), duration: 0.2) }
            Motion.enter(panel, delay: 0.42, duration: 0.3, scaleY: 0.8, anchor: .top)
            for (offset, card) in cards.enumerated() { Motion.enter(card, delay: 0.56 + 0.06 * Double(offset), duration: 0.24, up: -8) }
        }
        return centered(art, top: 46)
    }

    /// The collapsed notch with a few live-looking segments.
    private func miniPill() -> (pill: FillView, segments: [NSView]) {
        let pill = FillView(fill: .black, stroke: Palette.strokeStrong, radius: 17)
        size(pill, width: 380, height: 34)
        let time = row([symbol("clock", size: 11, weight: .semibold, color: Palette.textSecondary),
                        line("9:41", size: 12, weight: .semibold, color: Palette.textPrimary)], spacing: 5)
        let weather = row([symbol("cloud.sun.fill", size: 12, weight: .semibold, color: .systemCyan),
                           line("18°", size: 12, weight: .semibold, color: Palette.textPrimary)], spacing: 4)
        let music = row([symbol("music.note", size: 11, weight: .semibold, color: .systemPink),
                         line("Midnight City", size: 12, weight: .medium, color: Palette.textPrimary)], spacing: 5)
        pin(row([time, spacer(), weather, music], spacing: 14), in: pill, horizontal: 16)
        return (pill, [time, weather, music])
    }

    /// The panel open below the notch: header, tabs and three Home cards.
    private func miniPanel() -> (panel: NSView, cards: [NSView]) {
        let panel = FillView(fill: Palette.surface, stroke: Palette.stroke, radius: 18)
        size(panel, width: 500, height: 136)
        let tabs = row(["house.fill", "magnifyingglass", "timer", "sparkles"].enumerated().map { index, name in
            symbol(name, size: 12, weight: .medium, color: index == 0 ? Palette.accent : Palette.textTertiary)
        }, spacing: 14)
        let header = row([line("Good morning", size: 13, weight: .semibold, color: Palette.textPrimary), spacer(), tabs], spacing: 8)
        let cards = [miniCard("timer", tint: .systemOrange, big: "25:00", small: "Focus"),
                     miniCard("cloud.sun.fill", tint: .systemCyan, big: "18°", small: "Partly cloudy"),
                     miniCard("music.note", tint: .systemPink, big: "Midnight City", small: "M83")]
        let cardRow = row(cards, spacing: 10)
        cardRow.distribution = .fillEqually
        let stack = column([header, cardRow], spacing: 12)
        embed(stack, in: panel, inset: 14, fill: true)
        for item in [header, cardRow] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return (panel, cards)
    }

    private func miniCard(_ name: String, tint: NSColor, big: String, small: String) -> NSView {
        let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 12)
        let stack = column([symbol(name, size: 14, weight: .semibold, color: tint),
                            line(big, size: 17, weight: .semibold, color: Palette.textPrimary),
                            line(small, size: 11, color: Palette.textSecondary)], spacing: 4)
        embed(stack, in: card, inset: 12, fill: true)
        return card
    }

    // MARK: Open

    private var toggleCombo: KeyCombo? { shell.shortcuts.shortcut("toggle")?.combo }

    private func openHero() -> NSView {
        let (pill, _) = miniPill()
        let pointer = symbol("cursorarrow", size: 24, weight: .regular, color: Palette.textPrimary)
        let or = line("or press", size: 12, weight: .medium, color: Palette.textTertiary)
        let caps = KeyCapsView(combo: toggleCombo, size: 46)
        heroCaps = caps
        let art = column([pill, pointer, or, caps], spacing: 12, alignment: .centerX)
        art.setCustomSpacing(4, after: pill)
        art.setCustomSpacing(16, after: pointer)
        art.setAccessibilityElement(true)
        art.setAccessibilityRole(.image)
        art.setAccessibilityLabel("Hover the notch, or press \(KeyCapsView.spoken(toggleCombo)).")
        // The hover glow is the settled state; the moment brings it in after the cursor arrives.
        pill.layer?.shadowColor = Palette.accent.cgColor
        pill.layer?.shadowRadius = 14
        pill.layer?.shadowOffset = .zero
        pill.layer?.shadowOpacity = 0.55
        moments.append {
            Motion.enter(pointer, delay: 0.08, duration: 0.5, dx: 70, up: -36)
            Motion.change(pill.layer, "shadowOpacity", from: Float(0), delay: 0.5, duration: 0.3)
            Motion.enter(or, delay: 0.5, duration: 0.2)
            Motion.enter(caps, delay: 0.56, duration: 0.24, up: -6)
        }
        return centered(art, top: 42)
    }

    /// The shortcut as key caps, Change (the Settings, Hotkeys recorder) and Try it now.
    private func openControls() -> NSView {
        let caps = KeyCapsView(combo: toggleCombo, size: 26)
        contentCaps = caps
        let recorder = ShortcutRecorder(registry: shell.shortcuts, id: "toggle")
        recorder.isHidden = true
        let change = HoverButton("Change", style: .plain, label: "Change the shortcut") {}
        change.pressScale = 0.97
        change.handler = { [weak self, weak recorder, weak caps, weak change] in
            caps?.isHidden = true
            change?.isHidden = true
            recorder?.isHidden = false
            recorder?.layoutSubtreeIfNeeded()
            recorder?.begin()
            self?.shortcutNote = ""
        }
        recorder.finished = { [weak self] in
            guard let self else { return }
            // Read before the keys pause again: pausing clears the "taken" state.
            self.shortcutNote = self.conflict()
            if self.window.isKeyWindow { self.shell.shortcuts.suspend(true) }
            // Rebuilt after the recorder's own handling returns, since this replaces it.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.ending, self.step == .open else { return }
                self.install(animated: false, direction: 0)
                self.startLoops()
            }
        }
        let check = symbol("checkmark.circle.fill", size: 14, weight: .semibold, color: .systemGreen)
        let tried = line("", size: 12, weight: .medium, color: Palette.textSecondary)
        let status = row([check, tried], spacing: 5)
        tryStatus = status
        if triedGesture { showTried(status, animated: false) } else {
            check.isHidden = true
            tried.stringValue = toggleCombo == nil ? "The shortcut is off. Change sets one." : "Try it now: press it."
        }
        var lines: [NSView] = [row([caps, recorder, change, status], spacing: 12)]
        if !shortcutNote.isEmpty { lines.append(line(shortcutNote, size: 12, color: .systemOrange)) }
        return column(lines, spacing: 6)
    }

    /// "That's it": the text crossfades and the check pops on a spring.
    private func showTried(_ status: NSStackView, animated: Bool = true) {
        let check = status.arrangedSubviews.first
        let text = status.arrangedSubviews.last as? NSTextField
        if animated, let text { Motion.crossfade(text) }
        check?.isHidden = false
        text?.stringValue = "That's it"
        text?.textColor = Palette.textPrimary
        status.setAccessibilityElement(true)
        status.setAccessibilityLabel("That's it. The shortcut works.")
        if animated, let check {
            status.layoutSubtreeIfNeeded()
            Motion.pop(check, delay: 0.12)
        }
    }

    // MARK: Features

    private func featuresHero() -> NSView {
        let available = ModuleList.all.map(\.id)
        var sections: [NSView] = []
        var tiles: [NSView] = []
        var headers: [NSView] = []
        for group in Onboarding.groups(available: available) {
            let toggle = HoverButton("Turn all off", style: .chip) {}
            toggle.pressScale = 0.97
            toggle.handler = { [weak self] in self?.toggleGroup(group) }
            groupButtons.append((group, toggle))
            let header = row([line(group.title, size: 12, weight: .semibold, color: Palette.textSecondary), spacer(), toggle], spacing: 8)
            headers.append(header)
            let infos = group.modules.compactMap { id in ModuleList.all.first { $0.id == id } }
            var rows: [NSView] = []
            for start in stride(from: 0, to: infos.count, by: 3) {
                let made = infos[start..<min(start + 3, infos.count)].map { featureTile($0) }
                tiles += made
                var cells: [NSView] = made
                while cells.count < 3 { cells.append(NSView()) }
                let tileRow = row(cells, spacing: 8)
                tileRow.distribution = .fillEqually
                rows.append(tileRow)
            }
            let section = column([header] + rows, spacing: 8)
            for item in section.arrangedSubviews { item.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
            sections.append(section)
        }
        let list = column(sections, spacing: 18)
        for item in list.arrangedSubviews { item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        // Tiles come in row by row, 20 ms apart, all within 300 ms.
        moments.append {
            for header in headers { Motion.enter(header, duration: 0.2) }
            for (offset, tile) in tiles.enumerated() { Motion.enter(tile, delay: min(0.02 * Double(offset), 0.28), duration: 0.22, up: -8) }
        }
        return scrolling(list)
    }

    private func featureTile(_ info: ModuleInfo) -> NSView {
        let tile = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 10)
        let title = line(info.title, size: 12, weight: .semibold, color: Palette.textPrimary)
        let detail = label(info.detail, size: 10, color: Palette.textTertiary)
        // Two wrapped lines, the second truncated (a truncating line break would allow only one).
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        detail.cell?.truncatesLastVisibleLine = true
        detail.preferredMaxLayoutWidth = 128
        let toggle = ActionSwitch(info.title, value: shell.general.isEnabled(info.id)) { [weak self] value in
            self?.setFeature(info.id, value)
        }
        toggle.controlSize = .mini
        toggle.setAccessibilityHelp(info.detail)
        toggle.identifier = NSUserInterfaceItemIdentifier("feature-" + info.id)
        featureSwitches[info.id] = toggle
        let text = column([title, detail], spacing: 2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chip = iconTile(info.symbol, tint: info.tint, size: 24)
        let content = row([chip, text, spacer(), toggle], spacing: 8)
        content.alignment = .top
        embed(content, in: tile, inset: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), fill: true)
        tile.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        tile.toolTip = info.detail
        featureTiles[info.id] = (tile, chip as? FillView, info.tint)
        setTileLook(info.id, on: shell.general.isEnabled(info.id), delay: 0, animated: false)
        return tile
    }

    /// An off feature's tile dims to 55% and its icon chip turns gray, in 150 ms.
    private func setTileLook(_ id: String, on: Bool, delay: CFTimeInterval, animated: Bool) {
        guard let item = featureTiles[id] else { return }
        let opacity: Float = on ? 1 : 0.55
        let oldOpacity = item.tile.layer?.presentation()?.opacity ?? item.tile.layer?.opacity
        let oldColor = item.chip?.layer?.presentation()?.backgroundColor ?? item.chip?.layer?.backgroundColor
        item.tile.alphaValue = CGFloat(opacity)
        item.chip?.setFill(on ? item.tint : NSColor(white: 0.42, alpha: 1), animated: false)
        guard animated, oldOpacity != opacity else { return }
        Motion.change(item.tile.layer, "opacity", from: oldOpacity, delay: delay, duration: 0.15)
        Motion.change(item.chip?.layer, "backgroundColor", from: oldColor, delay: delay, duration: 0.15)
    }

    private func setFeature(_ id: String, _ enabled: Bool) {
        shell.updateGeneral { $0.setEnabled(id, enabled) }
        refreshFeatures()
        setTileLook(id, on: enabled, delay: 0, animated: true)
    }

    /// Turn all off/on ripples down the group, 30 ms per tile.
    private func toggleGroup(_ group: Onboarding.Group) {
        let on = !Onboarding.allEnabled(group, in: shell.general)
        shell.updateGeneral { Onboarding.setGroup(group, enabled: on, in: &$0) }
        refreshFeatures()
        for (offset, id) in group.modules.enumerated() { setTileLook(id, on: on, delay: 0.03 * Double(offset), animated: true) }
    }

    /// Switches, Turn all labels, the count and the dots (Connect comes and goes with its features).
    private func refreshFeatures() {
        let general = shell.general
        for (id, toggle) in featureSwitches { toggle.state = general.isEnabled(id) ? .on : .off }
        for item in groupButtons {
            let all = Onboarding.allEnabled(item.group, in: general)
            let text = all ? "Turn all off" : "Turn all on"
            if item.button.text != text {
                Motion.crossfade(item.button)
                item.button.text = text
            }
            item.button.setAccessibilityLabel("\(text): \(item.group.title)")
        }
        let ids = ModuleList.all.map(\.id)
        featureCount?.stringValue = "\(ids.filter(general.isEnabled).count) of \(ids.count) features on. A feature that is off uses no resources."
        if back != nil {
            computeSteps()
            refreshFooter()
        }
    }

    // MARK: Connect

    private func connectHero() -> NSView {
        let cards = connectItems().map { item -> NSView in
            let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 12)
            let title = line(item.info.title, size: 13, weight: .semibold, color: Palette.textPrimary)
            item.view.removeFromSuperview()
            let text = column([title, item.view], spacing: 6)
            item.view.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
            let content = row([iconTile(item.info.symbol, tint: item.info.tint, size: 28), text], spacing: 12)
            content.alignment = .top
            embed(content, in: card, inset: 14, fill: true)
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
            card.identifier = NSUserInterfaceItemIdentifier("onboarding-connect-" + item.info.id)
            return card
        }
        let list = column(cards, spacing: 10)
        for item in list.arrangedSubviews { item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        moments.append {
            for (offset, card) in cards.enumerated() { Motion.enter(card, delay: 0.06 * Double(offset), duration: 0.26, up: -10) }
        }
        return scrolling(list)
    }

    // MARK: Finish

    private func finishHero() -> NSView {
        var tips: [NSView] = []
        let search = shell.shortcuts.shortcut("search")?.combo
        tips.append(tipCard("magnifyingglass", tint: .systemBlue, title: "Search everything",
                            detail: search.map { "Press \($0.display) from any app." } ?? "Click the notch and start typing."))
        tips.append(tipCard("menubar.rectangle", tint: .systemGray, title: "Settings",
                            detail: "Use the menu-bar item, or the gear in the panel."))
        if shell.general.isEnabled("filetray") {
            tips.append(tipCard("tray.and.arrow.down.fill", tint: .systemBlue, title: "Keep files close",
                                detail: "Drag files onto the notch."))
        }
        let cards = row(tips, spacing: 12)
        cards.distribution = .fillEqually
        cards.widthAnchor.constraint(equalToConstant: CGFloat(tips.count) * 212 - 12).isActive = true
        let check = CheckMarkView(side: 18)
        let ready = FillView(fill: NSColor.systemGreen.withAlphaComponent(0.14), stroke: NSColor.systemGreen.withAlphaComponent(0.32), radius: 15)
        embed(row([check, line("QNotch is ready", size: 13, weight: .semibold, color: Palette.textPrimary)], spacing: 8), in: ready,
              inset: NSEdgeInsets(top: 6, left: 7, bottom: 6, right: 14), fill: true)
        ready.setAccessibilityElement(true)
        ready.setAccessibilityRole(.staticText)
        ready.setAccessibilityLabel("QNotch is ready")
        let art = column([ready, cards], spacing: 18, alignment: .centerX)
        // The chip pops, its check draws, then the tips follow.
        moments.append {
            Motion.pop(ready, delay: 0.04)
            check.drawStroke(delay: 0.18)
            for (offset, tip) in tips.enumerated() { Motion.enter(tip, delay: 0.24 + 0.06 * Double(offset), duration: 0.26, up: -8) }
        }
        return centered(art, top: 46)
    }

    private func tipCard(_ name: String, tint: NSColor, title: String, detail: String) -> NSView {
        let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 14)
        let text = label(detail, size: 12, color: Palette.textSecondary)
        text.preferredMaxLayoutWidth = 170
        let stack = column([iconTile(name, tint: tint, size: 34), line(title, size: 13, weight: .semibold, color: Palette.textPrimary), text], spacing: 8)
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[0])
        embed(stack, in: card, inset: 16, fill: true)
        card.heightAnchor.constraint(equalToConstant: 140).isActive = true
        return card
    }

    private func finishControls() -> NSView {
        let updatesAvailable = shell.updater != nil
        let updates = ActionSwitch("Check for updates automatically", value: updatesAvailable && updatesChoice) { [weak self] value in
            guard let self else { return }
            self.updatesChoice = value
            if !self.firstRun, !Runtime.diagnostics { self.shell.updater?.checksAutomatically = value }
        }
        updates.isEnabled = updatesAvailable
        let login = ActionSwitch("Open at login", value: loginChoice) { [weak self] value in self?.setLogin(value) }
        let updatesText = updatesAvailable ? "Check for updates automatically" : "Updates are not available in this build"
        return row([updates, line(updatesText, size: 13, color: updatesAvailable ? Palette.textPrimary : Palette.textTertiary),
                    spacerView(width: 24),
                    login, line("Open at login", size: 13, color: Palette.textPrimary)], spacing: 8)
    }

    private func setLogin(_ value: Bool) {
        loginChoice = value
        guard !firstRun, !Runtime.diagnostics else { return }
        let service = SMAppService.mainApp
        do {
            if value { try service.register() } else { try service.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = value ? "QNotch could not be added to your login items." : "QNotch could not be removed from your login items."
            alert.informativeText = "You can manage login items in System Settings, General, Login Items."
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: Helpers

    private func centered(_ art: NSView, top: CGFloat) -> NSView {
        let hero = NSView()
        art.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(art)
        art.centerXAnchor.constraint(equalTo: hero.centerXAnchor).isActive = true
        art.topAnchor.constraint(equalTo: hero.topAnchor, constant: top).isActive = true
        return hero
    }

    /// Cards in the hero that scroll when they do not fit, below the close control.
    private func scrolling(_ content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(content, in: document, inset: NSEdgeInsets(top: 40, left: Self.margin - 12, bottom: 14, right: Self.margin - 12), fill: true)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        return scroll
    }

    private func pin(_ content: NSView, in parent: NSView, horizontal: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -horizontal),
            content.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        ])
    }

    private func spacerView(width: CGFloat) -> NSView {
        let view = NSView()
        size(view, width: width, height: 1)
        return view
    }

    // MARK: Diagnostics

    /// The smoke test: presses the toggle gesture as the keyboard would, through the window.
    func pressToggleGesture() {
        guard let combo = toggleCombo else { return }
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers & KeyCombo.control != 0 { flags.insert(.control) }
        if combo.modifiers & KeyCombo.option != 0 { flags.insert(.option) }
        if combo.modifiers & KeyCombo.shift != 0 { flags.insert(.shift) }
        if combo.modifiers & KeyCombo.command != 0 { flags.insert(.command) }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: UInt16(combo.keyCode)) {
            window.sendEvent(event)
        }
    }

    /// The smoke test: a feature's switch on the Features step, flipped as a click would.
    func flipFeature(_ id: String) -> Bool {
        guard let toggle = featureSwitches[id] else { return false }
        toggle.state = toggle.state == .on ? .off : .on
        toggle.changed(toggle.state == .on)
        return true
    }

    var connectModuleIds: [String] { connectItems().map { $0.info.id } }

    /// The smoke test: no loop or animation outlives the tour.
    var runningLoops: Int { loops.count }
}

/// The hero's backdrop: a soft accent glow from the top and a hairline at its foot.
final class HeroBackdrop: NSView {
    let glow = CAGradientLayer()
    private let rule = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.type = .radial
        glow.colors = [Palette.accent.withAlphaComponent(0.26).cgColor, Palette.accent.withAlphaComponent(0.06).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 0.55, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 1.15, y: 0.1)
        rule.backgroundColor = Palette.stroke.cgColor
        layer?.addSublayer(glow)
        layer?.addSublayer(rule)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Wider than the window, so the slow drift never shows an edge.
        glow.frame = bounds.insetBy(dx: -30, dy: 0)
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
    }
}

/// A shortcut as key caps: one per modifier, then the key.
final class KeyCapsView: NSStackView {
    init(combo: KeyCombo?, size side: CGFloat) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = (side * 0.16).rounded()
        for part in Self.parts(combo) {
            let cap = FillView(fill: Palette.card, stroke: Palette.strokeStrong, radius: (side * 0.22).rounded())
            let text = line(part, size: (side * 0.42).rounded(), weight: .medium, color: Palette.textPrimary)
            text.alignment = .center
            text.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(text)
            cap.translatesAutoresizingMaskIntoConstraints = false
            let snug = cap.widthAnchor.constraint(equalToConstant: side)
            snug.priority = .defaultLow
            NSLayoutConstraint.activate([
                text.centerXAnchor.constraint(equalTo: cap.centerXAnchor), text.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
                cap.heightAnchor.constraint(equalToConstant: side), cap.widthAnchor.constraint(greaterThanOrEqualToConstant: side),
                cap.widthAnchor.constraint(greaterThanOrEqualTo: text.widthAnchor, constant: side * 0.5), snug
            ])
            addArrangedSubview(cap)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Shortcut: " + Self.spoken(combo))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func parts(_ combo: KeyCombo?) -> [String] {
        guard let combo else { return ["Off"] }
        var parts: [String] = []
        var rest = Substring(combo.display)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            parts.append(String(first))
            rest = rest.dropFirst()
        }
        parts.append(String(rest))
        return parts
    }

    static func spoken(_ combo: KeyCombo?) -> String {
        let names: [String: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]
        return parts(combo).map { names[$0] ?? $0 }.joined(separator: " ")
    }
}
