import AppKit
import QNotchMacCore

/// CPU, memory, GPU, network, battery and clock (Windows StatsModule): a System card on Home and
/// optional status in the wings. Samples once a second while the card is on screen, every five
/// seconds while collapsed only if a sampled stat is shown in the wings, and not at all otherwise.
/// Battery is pushed by IOKit; the clock fires on minute boundaries.
final class StatsModule: NotchModule {
    enum Kind: String, CaseIterable { case cpu, memory, gpu, network, battery, clock }

    private var context: ModuleContext!
    private(set) var settings = StatsSettings()
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "qnotch.stats", qos: .utility)
    private let battery = BatteryWatch()
    private(set) var sample: StatsSample?
    private var cardVisible = false
    private var wake: Timer?
    private var clock: Timer?
    private var sampling = false
    private var generation = 0
    private let cards = NSHashTable<StatsCardView>.weakObjects()
    private var segments: [Kind: NSHashTable<StatSegmentView>] = [:]
    private(set) var sampleCount = 0
    var hasScheduledWake: Bool { wake?.isValid == true }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("stats", default: StatsSettings())
        context.registries.cards.register(ViewContribution(id: "system", title: "System", order: 10, symbol: "cpu") { [unowned self] in
            let card = StatsCardView()
            self.cards.add(card)
            card.update(self.sample, gpuAvailable: self.sampler.gpuAvailable)
            return card
        })
        let slots: [(Kind, Int, SegmentSlot)] = [(.cpu, 10, .leading), (.memory, 11, .trailing), (.gpu, 12, .leading),
                                                 (.network, 13, .leading), (.battery, 15, .trailing), (.clock, 20, .trailing)]
        for (kind, order, slot) in slots {
            segments[kind] = .weakObjects()
            let hasDetails = [.cpu, .memory, .gpu, .network].contains(kind)
            let label = kind == .cpu || kind == .gpu ? kind.rawValue.uppercased() : kind.rawValue
            context.registries.segments.register(SegmentContribution(id: "stats." + kind.rawValue, order: order, slot: slot,
                destination: hasDetails ? .card("system", emphasis: kind.rawValue, allowsHiddenDetail: true) : nil,
                destinationLabel: hasDetails ? "Open \(label) details" : nil) { [weak self] in
                let view = StatSegmentView(kind: kind)
                self?.segments[kind]?.add(view)
                self?.refreshSegments(notify: false)
                return view
            })
        }
        context.registries.settingsSections.register(ViewContribution(id: "stats", title: "System stats", order: 20, symbol: "cpu", tint: .systemTeal) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
        battery.changed = { [weak self] in self?.refreshSegments() }
        applySettings()
    }

    func setVisibility(panel: Bool, activeTab: String) {
        let next = panel && activeTab == "home"
        guard next != cardVisible else { return }
        cardVisible = next
        schedule(immediately: next)
    }

    func systemDidWake() {
        schedule(immediately: true)
        scheduleClock()
    }

    func stop() {
        generation += 1
        wake?.invalidate(); wake = nil
        clock?.invalidate(); clock = nil
        battery.stop()
    }

    func set(_ change: (inout StatsSettings) -> Void) {
        change(&settings)
        context.settings.save("stats", settings)
        applySettings()
    }

    private func applySettings() {
        if settings.wingBattery { battery.start() } else { battery.stop() }
        scheduleClock()
        schedule(immediately: true)
        refreshSegments()
    }

    // MARK: Sampling

    private var interval: TimeInterval? { cardVisible ? 1 : settings.sampledWing ? 5 : nil }

    private func schedule(immediately: Bool) {
        wake?.invalidate()
        wake = nil
        guard let interval else { return }
        if immediately { takeSample() }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.takeSample()
            self?.schedule(immediately: false)
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        wake = timer
    }

    private func takeSample() {
        guard !sampling else { return }
        sampling = true
        let wantsGPU = cardVisible || settings.wingGPU
        let generation = generation
        queue.async { [sampler] in
            let reading = sampler.sample(gpu: wantsGPU)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.sampling = false
                self.sampleCount += 1
                guard reading != self.sample else { return }
                self.sample = reading
                if self.cardVisible { self.cards.allObjects.forEach { $0.update(reading, gpuAvailable: self.sampler.gpuAvailable) } }
                self.refreshSegments()
            }
        }
    }

    /// Smoke snapshots only: one synchronous reading, so the rendered card shows real values.
    func sampleNow() {
        let reading = queue.sync { sampler.sample(gpu: true) }
        sample = reading
        sampleCount += 1
        cards.allObjects.forEach { $0.update(reading, gpuAvailable: sampler.gpuAvailable) }
        refreshSegments()
    }

    /// One-shot to the next minute boundary, only while the clock is shown.
    private func scheduleClock() {
        clock?.invalidate()
        clock = nil
        guard settings.wingClock else { return }
        let now = Date()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fireAt: next.addingTimeInterval(0.03), interval: 0, target: self, selector: #selector(clockTick), userInfo: nil, repeats: false)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    @objc private func clockTick() {
        refreshSegments()
        scheduleClock()
    }

    // MARK: Wings

    private var segmentState = ""

    private func refreshSegments(notify: Bool = true) {
        var signature = ""
        for kind in Kind.allCases {
            let (text, symbol, shown) = segmentContent(kind)
            for view in segments[kind]?.allObjects ?? [] { view.update(text: text, symbol: symbol, shown: shown) }
            signature += shown ? "1" : "0"
        }
        guard signature != segmentState else { return }
        segmentState = signature
        if notify { context.shell?.segmentsChanged() }
    }

    private func segmentContent(_ kind: Kind) -> (String, String?, Bool) {
        switch kind {
        case .cpu: return (SystemStats.percentText(sample?.cpu), nil, settings.wingCPU && sample != nil)
        case .memory:
            let percent = sample.map { $0.memoryTotal > 0 ? Double($0.memoryUsed) / Double($0.memoryTotal) * 100 : 0 }
            return (SystemStats.percentText(percent), nil, settings.wingMemory && sample != nil)
        case .gpu: return (SystemStats.percentText(sample?.gpu), nil, settings.wingGPU && sample?.gpu != nil)
        case .network:
            return ("↓\(SystemStats.shortRate(sample?.download)) ↑\(SystemStats.shortRate(sample?.upload))", nil, settings.wingNetwork && sample?.download != nil)
        case .battery:
            guard let state = battery.state else { return ("", nil, false) }
            return ("\(state.percent)%", SystemStats.batterySymbol(percent: state.percent, charging: state.charging), settings.wingBattery)
        case .clock: return (Self.clockFormat.string(from: Date()), nil, settings.wingClock)
        }
    }

    private static let clockFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: Settings

    private func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        func toggle(_ title: String, _ detail: String, _ target: String, _ key: WritableKeyPath<StatsSettings, Bool>) -> NSView {
            let control = ActionSwitch(title, value: settings[keyPath: key]) { [weak self] value in Analytics.setting(target, enabled: value); self?.set { $0[keyPath: key] = value } }
            return settingsRow(title, detail: detail, control: control, width: width)
        }
        return settingsGroup([
            toggle("CPU", "Share of all cores in use.", "stats_cpu", \.wingCPU),
            toggle("Memory", "Memory used, as in Activity Monitor.", "stats_memory", \.wingMemory),
            toggle("GPU", "Busiest graphics processor. Hidden when macOS does not report it.", "stats_gpu", \.wingGPU),
            toggle("Network", "Download and upload speed of your Wi-Fi and Ethernet connections.", "stats_network", \.wingNetwork),
            toggle("Battery", "Also in the menu bar. Hidden on Macs without a battery.", "stats_battery", \.wingBattery),
            toggle("Clock", "Also in the menu bar.", "stats_clock", \.wingClock)
        ], header: "Beside the notch",
        footer: "While the panel is closed, stats shown here are sampled every 5 seconds; with none shown, nothing is sampled. The System card on Home updates every second while you look at it. GPU temperature is not available: macOS has no public sensor API.", width: width)
    }
}

// MARK: - Views

private final class StatSegmentView: NSStackView {
    private let icon = NSImageView()
    private let text = line("", size: 12, weight: .semibold, color: Palette.textSecondary)
    private var symbolName: String?

    init(kind: StatsModule.Kind) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        detachesHiddenViews = true
        let names: [StatsModule.Kind: String] = [.cpu: "CPU", .memory: "RAM", .gpu: "GPU"]
        if let name = names[kind] {
            let tag = line(name, size: 9, weight: .bold, color: Palette.textTertiary)
            addArrangedSubview(tag)
        }
        text.font = .rounded(12, weight: .semibold, monospacedDigits: true)
        icon.contentTintColor = Palette.textTertiary
        icon.setAccessibilityElement(false)
        // Fixed minimum widths so changing digits never resize the wings.
        let minimum: CGFloat = kind == .network ? 78 : kind == .clock ? 38 : 28
        text.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum).isActive = true
        [icon, text].forEach(addArrangedSubview)
        icon.isHidden = true
        identifier = NSUserInterfaceItemIdentifier("stats-" + kind.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(kind.rawValue.capitalized)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text value: String, symbol: String?, shown: Bool) {
        if text.stringValue != value { text.stringValue = value }
        if symbol != symbolName {
            symbolName = symbol
            icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) }
            icon.isHidden = symbol == nil
        }
        if isHidden == shown { isHidden = !shown }
        setAccessibilityValue(value)
    }
}

private final class StatsCardView: NSView, SegmentDetailContent {
    private let cpu = StatRow(title: "CPU", bar: true)
    private let memory = StatRow(title: "RAM", bar: true)
    private let gpu = StatRow(title: "GPU", bar: false)
    private let network = StatRow(title: "NET", bar: false)

    init() {
        super.init(frame: .zero)
        let stack = column([cpu, memory, gpu, network], spacing: 8)
        embed(stack, in: self, inset: 0)
        for view in [cpu, memory, gpu, network] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func emphasize(_ detail: String?) -> Bool {
        let rows = [("cpu", cpu), ("memory", memory), ("gpu", gpu), ("network", network)]
        guard detail == nil || rows.contains(where: { $0.0 == detail }) else { return false }
        for (id, row) in rows { row.emphasized = id == detail }
        return true
    }

    func update(_ sample: StatsSample?, gpuAvailable: Bool) {
        cpu.set(SystemStats.percentText(sample?.cpu), progress: sample?.cpu.map { $0 / 100 })
        if let sample, sample.memoryTotal > 0 {
            memory.set(SystemStats.memoryText(used: sample.memoryUsed, total: sample.memoryTotal), progress: Double(sample.memoryUsed) / Double(sample.memoryTotal))
        } else { memory.set("--", progress: nil) }
        gpu.set(gpuAvailable ? SystemStats.percentText(sample?.gpu) : "n/a", progress: nil)
        network.set(sample?.download == nil ? "--" : "↓ \(SystemStats.rateText(sample?.download))  ↑ \(SystemStats.rateText(sample?.upload))", progress: nil)
    }
}

private final class StatRow: NSView {
    private let value = line("--", size: 12, weight: .medium, color: Palette.textPrimary)
    private let bar: ProgressBar?
    var emphasized = false {
        didSet {
            guard emphasized != oldValue else { return }
            wantsLayer = true
            layer?.backgroundColor = emphasized ? Palette.accentSoft.cgColor : nil
            layer?.cornerRadius = 4
            value.textColor = emphasized ? Palette.accent : Palette.textPrimary
            setAccessibilityHelp(emphasized ? "Selected metric" : nil)
            setAccessibilitySelected(emphasized)
        }
    }

    init(title: String, bar hasBar: Bool) {
        bar = hasBar ? ProgressBar() : nil
        super.init(frame: .zero)
        let name = line(title, size: 11, weight: .semibold, color: Palette.textTertiary)
        name.widthAnchor.constraint(equalToConstant: 32).isActive = true
        value.font = .rounded(12, weight: .medium, monospacedDigits: true)
        value.alignment = .right
        var top: [NSView] = [name, spacer(), value]
        if !hasBar { top = [name, value]; value.alignment = .left }
        let header = row(top, spacing: 6)
        let stack = column(bar.map { [header, $0] } ?? [header], spacing: 4)
        embed(stack, in: self, inset: 0, fill: true)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar?.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        identifier = NSUserInterfaceItemIdentifier("system-metric-" + title.lowercased())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ text: String, progress: Double?) {
        if value.stringValue != text { value.stringValue = text }
        setAccessibilityValue(text)
        guard let bar else { return }
        bar.isHidden = progress == nil
        if let progress { bar.set(progress: CGFloat(progress), animated: true) }
    }
}
