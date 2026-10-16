import AppKit
import QNotchMacCore

final class TimerModule: NotchModule {
    private var context: ModuleContext!
    private var preferences = TimerSettings()
    private(set) var countdown = Countdown(duration: 25 * 60)
    private var wake: Timer?
    private var visible = false
    private let views = NSHashTable<TimerContentView>.weakObjects()
    private let segments = NSHashTable<NSTextField>.weakObjects()
    private(set) var wakeCount = 0
    var hasScheduledWake: Bool { wake?.isValid == true }

    func initialize(_ context: ModuleContext) {
        self.context = context
        preferences = context.settings.load("timer", default: TimerSettings())
        preferences.minutes = min(180, max(1, preferences.minutes))
        countdown = Countdown(duration: TimeInterval(preferences.minutes * 60))
        let registry = context.registries
        registry.cards.register(ViewContribution(id: "timer", title: "Countdown", order: 26, makeView: makeContent))
        registry.tabs.register(ViewContribution(id: "timer", title: "Timer", order: 10, makeView: makeContent))
        registry.segments.register(ViewContribution(id: "timer.pill", title: "Timer", order: 7) { [weak self] in
            let text = label("", size: 11, color: .white)
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            self?.segments.add(text)
            self?.refresh()
            return text
        })
        registry.searchSources.register(SearchSource(id: "timer", order: 10) { [weak self] query in
            guard let self, "timer countdown focus".localizedCaseInsensitiveContains(query) else { return [] }
            return [SearchHit(title: "Countdown timer", detail: "Open timer controls") { [weak self] in
                self?.context.shell?.selectTab("timer")
            }]
        })
        registry.settingsSections.register(ViewContribution(id: "timer", title: "Countdown", order: 30) { [weak self] in
            guard let self else { return label("Timer unavailable") }
            return column([
                ActionCheckbox("Play a sound when time is up", value: self.preferences.playSound) { [weak self] value in
                    guard let self else { return }
                    self.preferences.playSound = value
                    self.context.settings.save("timer", self.preferences)
                },
                label("The duration is saved locally. A running timer continues through sleep, and stops when QNotch quits.", size: 11, color: .secondaryLabelColor)
            ], spacing: 6)
        })
    }

    private func makeContent() -> NSView {
        let view = TimerContentView(module: self)
        views.add(view)
        refresh()
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        let next = panel && (activeTab == "home" || activeTab == "timer")
        guard next != visible else { return }
        visible = next
        refresh()
    }

    func systemDidWake() { refresh() }
    func stop() { wake?.invalidate(); wake = nil; visible = false }
    deinit { wake?.invalidate() }

    func toggle() { countdown.toggle(at: Date()); refresh() }
    func reset() { countdown.reset(); refresh() }
    func choose(minutes: Int) {
        preferences.minutes = min(180, max(1, minutes))
        countdown.reset(duration: TimeInterval(preferences.minutes * 60))
        context.settings.save("timer", preferences)
        refresh()
    }

    // Also used by the isolated native smoke test to exercise the actual scheduler.
    func startShortTimer(seconds: TimeInterval) {
        countdown.reset(duration: seconds)
        countdown.toggle(at: Date())
        refresh()
    }

    private func refresh() {
        wake?.invalidate()
        wake = nil
        let now = Date()
        if countdown.refresh(at: now), preferences.playSound { NSSound.beep() }
        if visible {
            for view in views.allObjects { view.update(countdown: countdown, now: now) }
        }
        let status = countdown.finished ? "Time is up" : countdown.isRunning ? "Running" : ""
        for segment in segments.allObjects {
            if segment.stringValue != status { segment.stringValue = status }
            segment.isHidden = status.isEmpty
        }
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
}

private final class TimerContentView: NSView {
    private let time = label("25:00", size: 48)
    private let status = label("Ready when you are", size: 12, color: .secondaryLabelColor)
    private let start: ActionButton
    private let presets: NSSegmentedControl
    private weak var module: TimerModule?

    init(module: TimerModule) {
        self.module = module
        start = ActionButton("Start", symbol: "play.fill") { [weak module] in module?.toggle() }
        presets = NSSegmentedControl(labels: ["5 min", "15 min", "25 min", "50 min"], trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        time.font = .monospacedDigitSystemFont(ofSize: 48, weight: .light)
        time.setAccessibilityIdentifier("timer-remaining")
        start.setAccessibilityIdentifier("timer-toggle")
        presets.target = self
        presets.action = #selector(presetChanged)
        presets.setAccessibilityLabel("Countdown duration")
        let reset = ActionButton("Reset", symbol: "arrow.counterclockwise") { [weak module] in module?.reset() }
        embed(column([time, status, presets, row([start, reset])], spacing: 14), in: self, inset: 0)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func presetChanged() { module?.choose(minutes: [5, 15, 25, 50][presets.selectedSegment]) }

    func update(countdown: Countdown, now: Date) {
        let text = countdown.text(at: now)
        if time.stringValue != text { time.stringValue = text }
        status.stringValue = countdown.finished ? "Time is up" : countdown.isRunning ? "A little space to focus" : countdown.remaining < countdown.duration ? "Paused" : "Ready when you are"
        start.title = countdown.isRunning ? "Pause" : "Start"
        start.setAccessibilityLabel(start.title + " countdown")
        start.image = NSImage(systemSymbolName: countdown.isRunning ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        presets.selectedSegment = [5, 15, 25, 50].firstIndex(of: Int(countdown.duration / 60)) ?? -1
    }
}
