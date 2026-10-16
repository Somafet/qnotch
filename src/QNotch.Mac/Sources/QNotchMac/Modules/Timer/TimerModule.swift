import AppKit
import QNotchMacCore

private protocol TimerDisplay: AnyObject {
    func update(countdown: Countdown, now: Date, animated: Bool)
}

final class TimerModule: NotchModule {
    static let presets = [5, 15, 25, 50]
    private var context: ModuleContext!
    private var preferences = TimerSettings()
    private(set) var countdown = Countdown(duration: 25 * 60)
    private var wake: Timer?
    private var visible = false
    /// Completion stays in the notch until the panel has been seen.
    private var completionUnseen = false
    private let displays = NSHashTable<AnyObject>.weakObjects()
    private let rings = NSHashTable<ProgressRing>.weakObjects()
    private let texts = NSHashTable<NSTextField>.weakObjects()
    private var segmentState = ""
    private(set) var wakeCount = 0
    var hasScheduledWake: Bool { wake?.isValid == true }

    func initialize(_ context: ModuleContext) {
        self.context = context
        preferences = context.settings.load("timer", default: TimerSettings())
        preferences.minutes = min(180, max(1, preferences.minutes))
        countdown = Countdown(duration: TimeInterval(preferences.minutes * 60))
        context.sounds.add("timer.done", title: "Timer is up", hint: "A countdown reached zero.", defaultName: "Glass", order: 30)
        let registry = context.registries
        registry.cards.register(ViewContribution(id: "timer", title: "Timer", order: 26, symbol: "timer") { [unowned self] in
            self.track(TimerCardView(module: self))
        })
        registry.tabs.register(ViewContribution(id: "timer", title: "Timer", order: 10, symbol: "timer") { [unowned self] in
            self.track(TimerTabView(module: self))
        })
        registry.segments.register(SegmentContribution(id: "timer.ring", order: 7, slot: .leading) { [weak self] in
            let ring = ProgressRing(lineWidth: 2.5)
            size(ring, width: 15, height: 15)
            ring.setAccessibilityElement(false)
            self?.rings.add(ring)
            self?.refreshSegments(notify: false)
            return ring
        })
        registry.segments.register(SegmentContribution(id: "timer.pill", order: 7, slot: .trailing) { [weak self] in
            let text = line("", size: 13, weight: .semibold, color: Palette.textPrimary)
            text.font = .rounded(13, weight: .semibold, monospacedDigits: true)
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            text.setAccessibilityIdentifier("timer-segment")
            self?.texts.add(text)
            self?.refreshSegments(notify: false)
            return text
        })
        registry.searchSources.register(SearchSource(id: "timer", order: 10) { [weak self] query in
            guard let self, "timer countdown focus pomodoro".localizedCaseInsensitiveContains(query) else { return [] }
            return [SearchHit(title: "Timer", detail: self.countdown.isRunning ? "Running · open the timer" : "Start a focus countdown", symbol: "timer") { [weak self] in
                self?.context.shell?.selectTab("timer")
            }]
        })
        registry.settingsSections.register(ViewContribution(id: "timer", title: "Countdown", order: 30, symbol: "timer", tint: .systemOrange) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
    }

    private func track(_ view: NSView & TimerDisplay) -> NSView {
        displays.add(view)
        view.update(countdown: countdown, now: Date(), animated: false)
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        let next = panel && (activeTab == "home" || activeTab == "timer")
        if panel, completionUnseen { completionUnseen = false }
        guard next != visible else { refreshSegments(); return }
        visible = next
        refresh()
    }

    func systemDidWake() { refresh() }
    func stop() { wake?.invalidate(); wake = nil; visible = false }
    deinit { wake?.invalidate() }

    func toggle() { completionUnseen = false; countdown.toggle(at: Date()); refresh(animated: true) }
    func reset() { completionUnseen = false; countdown.reset(); refresh(animated: true) }
    func choose(minutes: Int) {
        preferences.minutes = min(180, max(1, minutes))
        completionUnseen = false
        countdown.reset(duration: TimeInterval(preferences.minutes * 60))
        context.settings.save("timer", preferences)
        refresh(animated: true)
    }
    var isActive: Bool { countdown.isRunning || isPaused }
    var isPaused: Bool { !countdown.isRunning && !countdown.finished && countdown.remaining < countdown.duration }

    // Also used by the isolated native smoke test to exercise the actual scheduler.
    func startShortTimer(seconds: TimeInterval) {
        countdown.reset(duration: seconds)
        countdown.toggle(at: Date())
        refresh()
    }

    private func refresh(animated: Bool = false) {
        wake?.invalidate()
        wake = nil
        let now = Date()
        if countdown.refresh(at: now) {
            completionUnseen = !visible
            if preferences.playSound { context.sounds.play("timer.done") }
        }
        if visible {
            for case let view as TimerDisplay in displays.allObjects { view.update(countdown: countdown, now: now, animated: animated || countdown.isRunning) }
        }
        refreshSegments()
        guard let delay = countdown.nextWake(at: now, visible: visible) else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.wakeCount += 1
            self.refresh()
        }
        timer.tolerance = visible ? 0.05 : 0.2
        RunLoop.main.add(timer, forMode: .common)
        wake = timer
    }

    /// Collapsed status: ring on the left, time on the right. Hidden while idle.
    private func refreshSegments(notify: Bool = true) {
        let now = Date()
        let shown = countdown.isRunning || isPaused || completionUnseen
        let text = completionUnseen || countdown.finished ? "Done" : countdown.isRunning ? countdown.shortText(at: now) : countdown.text(at: now)
        let color = completionUnseen ? Palette.accent : isPaused ? Palette.textSecondary : Palette.textPrimary
        for label in texts.allObjects {
            if label.stringValue != text { label.stringValue = text }
            label.textColor = color
            label.isHidden = !shown
            label.setAccessibilityLabel(shown ? "Timer \(text)" : nil)
        }
        for ring in rings.allObjects {
            ring.color = isPaused ? Palette.textTertiary : Palette.accent
            ring.set(progress: completionUnseen ? 1 : countdown.progress(at: now), animated: notify)
            ring.isHidden = !shown
        }
        let signature = shown ? text : ""
        guard signature != segmentState else { return }
        segmentState = signature
        if notify { context?.shell?.segmentsChanged() }
    }

    private func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let sound = ActionSwitch("Play a sound when time is up", value: preferences.playSound) { [weak self] value in
            guard let self else { return }
            self.preferences.playSound = value
            self.context.settings.save("timer", self.preferences)
        }
        var titles = Self.presets.map { "\($0) minutes" }
        var values = Self.presets
        if !values.contains(preferences.minutes) { titles.append("\(preferences.minutes) minutes"); values.append(preferences.minutes) }
        let length = ActionPopUp("Default length", items: titles, selected: values.firstIndex(of: preferences.minutes) ?? 0) { [weak self] index in
            self?.choose(minutes: values[index])
        }
        return settingsGroup([
            settingsRow("Play a sound", detail: "When the countdown finishes. Pick the sound in Settings, Sounds. QNotch never takes focus.", control: sound, width: width),
            settingsRow("Length", detail: "Also set from the presets in the panel, or scroll over the Home card.", control: length, width: width)
        ], footer: "The length is saved on this Mac. A running timer keeps going through sleep and stops when QNotch quits.", width: width)
    }

    func status(at now: Date) -> String {
        countdown.finished ? "Time is up" : countdown.isRunning ? "Focusing" : isPaused ? "Paused" : "Ready"
    }
}

// MARK: - Home card

private final class TimerCardView: NSView, TimerDisplay {
    private let time = line("25:00", size: 30, weight: .semibold, color: Palette.textPrimary)
    private let status = line("Ready", size: 12, color: Palette.textTertiary)
    private let start: HoverButton
    private let resetButton: HoverButton
    private let progress = ProgressBar()
    private let presets: ChipPicker
    private weak var module: TimerModule?
    private var scrolled: CGFloat = 0

    init(module: TimerModule) {
        self.module = module
        start = HoverButton(symbol: "play.fill", style: .icon, symbolSize: 15, label: "Start countdown") { [weak module] in module?.toggle() }
        resetButton = HoverButton(symbol: "arrow.counterclockwise", style: .icon, symbolSize: 14, label: "Reset countdown") { [weak module] in module?.reset() }
        presets = ChipPicker(values: TimerModule.presets, format: { "\($0)" }, label: { "\($0) minutes" }) { [weak module] in module?.choose(minutes: $0) }
        super.init(frame: .zero)
        time.font = .rounded(30, weight: .semibold, monospacedDigits: true)
        time.setAccessibilityIdentifier("timer-remaining")
        start.setAccessibilityIdentifier("timer-toggle")
        start.tint = Palette.textPrimary
        let readout = NSStackView(views: [time, status])
        readout.orientation = .horizontal
        readout.alignment = .firstBaseline
        readout.spacing = 8
        let top = row([readout, spacer(), start, resetButton], spacing: 2)
        let stack = column([top, progress, presets], spacing: 12)
        stack.setCustomSpacing(14, after: progress)
        embed(stack, in: self, inset: 0)
        for view in [top, progress] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        toolTip = "Scroll to change the length"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(countdown: Countdown, now: Date, animated: Bool) {
        let text = countdown.text(at: now)
        if time.stringValue != text { time.stringValue = text }
        status.stringValue = module?.status(at: now) ?? ""
        status.textColor = countdown.finished ? Palette.accent : Palette.textTertiary
        let running = countdown.isRunning
        start.setSymbol(running ? "pause.fill" : "play.fill", size: 15, label: running ? "Pause countdown" : "Start countdown")
        progress.set(progress: countdown.progress(at: now), animated: animated)
        presets.select(TimerModule.presets.contains(Int(countdown.duration / 60)) && countdown.duration.truncatingRemainder(dividingBy: 60) == 0 ? Int(countdown.duration / 60) : nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let module, !module.isActive else { return super.scrollWheel(with: event) }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        let steps = Int(scrolled.rounded(.towardZero))
        guard steps != 0 else { return }
        scrolled -= CGFloat(steps)
        module.choose(minutes: Int(module.countdown.duration / 60) + steps)
    }
}

// MARK: - Timer tab

private final class TimerTabView: NSView, TimerDisplay {
    private let ring = ProgressRing(lineWidth: 6)
    private let time = line("25:00", size: 30, weight: .semibold, color: Palette.textPrimary)
    private let status = line("Ready", size: 12, color: Palette.textSecondary)
    private let headline = line("Focus timer", size: 15, weight: .semibold, color: Palette.textPrimary)
    private let detail = line("", size: 12, color: Palette.textTertiary)
    private let start: HoverButton
    private let presets: ChipPicker
    private weak var module: TimerModule?

    init(module: TimerModule) {
        self.module = module
        start = HoverButton(symbol: "play.fill", style: .accentCircle, symbolSize: 17, label: "Start countdown") { [weak module] in module?.toggle() }
        presets = ChipPicker(values: TimerModule.presets, format: { "\($0) min" }, label: { "\($0) minutes" }) { [weak module] in module?.choose(minutes: $0) }
        super.init(frame: .zero)
        time.font = .rounded(30, weight: .semibold, monospacedDigits: true)
        time.alignment = .center
        time.setAccessibilityIdentifier("timer-remaining")
        start.setAccessibilityIdentifier("timer-toggle")
        let reset = HoverButton(symbol: "arrow.counterclockwise", style: .plain, symbolSize: 14, label: "Reset countdown") { [weak module] in module?.reset() }
        size(reset, width: 44, height: 44)
        reset.layer?.cornerRadius = 22
        reset.layer?.cornerCurve = .circular

        let dial = NSView()
        size(dial, width: 148, height: 148)
        let readout = column([time, status], spacing: 2, alignment: .centerX)
        for view in [ring, readout] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            dial.addSubview(view)
        }
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: dial.leadingAnchor), ring.trailingAnchor.constraint(equalTo: dial.trailingAnchor),
            ring.topAnchor.constraint(equalTo: dial.topAnchor), ring.bottomAnchor.constraint(equalTo: dial.bottomAnchor),
            readout.centerXAnchor.constraint(equalTo: dial.centerXAnchor), readout.centerYAnchor.constraint(equalTo: dial.centerYAnchor)
        ])
        let side = column([column([headline, detail], spacing: 3), row([start, reset], spacing: 10), presets], spacing: 16)
        let layout = row([dial, side], spacing: 28)
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.centerYAnchor.constraint(equalTo: centerYAnchor),
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            layout.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(countdown: Countdown, now: Date, animated: Bool) {
        let text = countdown.text(at: now)
        if time.stringValue != text { time.stringValue = text }
        let state = module?.status(at: now) ?? ""
        status.stringValue = state
        status.textColor = countdown.finished ? Palette.accent : Palette.textSecondary
        ring.color = module?.isPaused == true ? Palette.textTertiary : Palette.accent
        ring.set(progress: countdown.finished ? 0 : countdown.progress(at: now), animated: animated)
        let minutes = Int(countdown.duration / 60)
        detail.stringValue = countdown.isRunning ? "Ends at \(Self.clock.string(from: now.addingTimeInterval(countdown.secondsLeft(at: now))))"
            : countdown.finished ? "Nice work. Pick a length to go again." : "\(minutes)-minute session"
        let running = countdown.isRunning
        start.setSymbol(running ? "pause.fill" : "play.fill", size: 17, label: running ? "Pause countdown" : "Start countdown")
        presets.select(TimerModule.presets.contains(minutes) && countdown.duration.truncatingRemainder(dividingBy: 60) == 0 ? minutes : nil)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
