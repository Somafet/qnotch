import AppKit
import QNotchMacCore

/// The yr.no weather symbols (github.com/metno/weathericons, MIT), 96-pixel PNGs that the build
/// copies into Resources/WeatherIcons, decoded once each. Multicolor SF Symbols stand in when a
/// file is missing (a `swift run` build has no app bundle).
private enum WeatherIcons {
    private static var cache: [String: NSImage?] = [:]
    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("WeatherIcons", isDirectory: true)

    static func image(_ symbol: String) -> NSImage? {
        if let cached = cache[symbol] { return cached }
        // Two file names in the set carry a typo; the MET symbol codes do not.
        let file = symbol.replacingOccurrences(of: "lightsleetshowersandthunder", with: "lightssleetshowersandthunder")
            .replacingOccurrences(of: "lightsnowshowersandthunder", with: "lightssnowshowersandthunder")
        let image = folder.flatMap { NSImage(contentsOf: $0.appendingPathComponent(file + ".png")) }
        image?.accessibilityDescription = WeatherFormat.condition(symbol)
        cache[symbol] = image
        return image
    }
}

/// The symbol at `size` points square (the Windows sizes: 16 in the wing, 44 now, 30 per day).
func weatherImage(_ symbol: String, size: CGFloat) -> NSImage? {
    guard !symbol.isEmpty else { return nil }
    if let icon = WeatherIcons.image(symbol)?.copy() as? NSImage {
        icon.size = NSSize(width: size, height: size)
        return icon
    }
    return NSImage(systemSymbolName: WeatherFormat.sfSymbol(symbol), accessibilityDescription: WeatherFormat.condition(symbol))?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: (size * 0.72).rounded(), weight: .regular).applying(.preferringMulticolor()))
}

/// Icon and temperature in the right wing.
final class WeatherPillView: NSStackView {
    private let icon = NSImageView()
    private let temp = line("", size: 12, weight: .semibold, color: Palette.textPrimary)
    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        temp.font = .rounded(12, weight: .semibold, monospacedDigits: true)
        [icon, temp].forEach(addArrangedSubview)
        identifier = NSUserInterfaceItemIdentifier("weather-segment")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(view: WeatherView?) {
        isHidden = view == nil
        guard let view else { return }
        icon.image = weatherImage(view.symbol, size: 16)
        temp.stringValue = view.temp
        setAccessibilityLabel("\(view.condition), \(view.temp)")
    }
}

final class WeatherCardView: NSView, HomeCardSizing {
    private weak var module: WeatherModule?
    private let icon = NSImageView()
    private let temp = line("", size: 26, weight: .semibold, color: Palette.textPrimary)
    private let condition = line("", size: 12, weight: .medium, color: Palette.textSecondary)
    private let detail = line("", size: 11, color: Palette.textTertiary)
    private let days = NSStackView()
    private let status = line("", size: 11, color: Palette.textTertiary)
    private let content: NSView
    private let empty = NSStackView()

    init(module: WeatherModule) {
        self.module = module
        temp.font = .rounded(26, weight: .semibold, monospacedDigits: true)
        let readout = column([row([icon, temp], spacing: 8), condition, detail], spacing: 2)
        days.orientation = .horizontal
        days.distribution = .fillEqually
        days.spacing = 4
        let open = HoverButton(symbol: "arrow.up.right.square", style: .icon, symbolSize: 12, label: "Open on yr.no") { [weak module] in module?.openYr() }
        let top = row([readout, spacer(), days], spacing: 12)
        top.alignment = .top
        content = column([top, row([status, spacer(), open], spacing: 4)], spacing: 6)
        super.init(frame: .zero)
        empty.orientation = .vertical
        empty.alignment = .leading
        empty.spacing = 8
        embed(content, in: self, inset: 0, fill: true)
        embed(empty, in: self, inset: 0)
        for view in content.subviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        days.widthAnchor.constraint(equalToConstant: 230).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHomeCardSize(_ size: HomeCardSize) {
        days.isHidden = size == .small
        for field in [condition, detail, status] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
    }

    func reload() {
        guard let module else { return }
        let view = module.view
        content.isHidden = view == nil
        empty.isHidden = view != nil
        empty.arrangedSubviews.forEach { $0.removeFromSuperview() }
        defer {
            for child in empty.arrangedSubviews { child.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor).isActive = true }
        }
        guard let view, let place = module.settings.place else {
            switch module.status {
            case .noPlace:
                empty.addArrangedSubview(label("Pick a place for the forecast.", size: 13, color: Palette.textSecondary))
                empty.addArrangedSubview(HoverButton("Choose a Place", style: .plain) { [weak module] in module?.contextShell?.openSettings(section: "weather") })
            case .loading:
                empty.addArrangedSubview(line("Loading the forecast for \(module.settings.place?.name ?? "")…", size: 13, color: Palette.textSecondary))
            default:
                empty.addArrangedSubview(label(module.message, size: 12, color: Palette.textSecondary))
                empty.addArrangedSubview(HoverButton("Retry", style: .plain) { [weak module] in Analytics.record("weather", "refresh"); module?.refresh() })
            }
            return
        }
        icon.image = weatherImage(view.symbol, size: 44)
        temp.stringValue = view.temp
        condition.stringValue = view.condition
        detail.stringValue = [place.name, view.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        status.stringValue = module.message.isEmpty ? module.updatedText + " · MET Norway" : module.message
        status.textColor = module.stale ? .systemOrange : Palette.textTertiary
        days.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for day in view.days {
            let image = NSImageView(image: weatherImage(day.symbol, size: 30) ?? NSImage())
            let high = line(day.high, size: 12, weight: .semibold, color: Palette.textPrimary)
            let low = line(day.low, size: 11, color: Palette.textTertiary)
            let item = column([line(day.name, size: 11, weight: .medium, color: Palette.textSecondary), image, row([high, low], spacing: 3)], spacing: 4, alignment: .centerX)
            item.toolTip = day.tip
            item.setAccessibilityElement(true)
            item.setAccessibilityLabel(day.tip)
            days.addArrangedSubview(item)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Weather in \(place.name): \(view.condition), \(view.temp)")
    }
}

extension WeatherModule {
    func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let field = NSSearchField()
        field.placeholderString = "City or place"
        field.sendsSearchStringImmediately = false
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        field.setAccessibilityLabel("Find a place")
        let results = NSStackView()
        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 2
        let note = label("", size: 11, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = width - 30
        field.onAction { [weak self, weak field, weak results, weak note] in
            guard let self, let field, field.stringValue.trimmingCharacters(in: .whitespaces).count >= 2 else { note?.stringValue = "Type at least two letters."; return }
            note?.stringValue = "Searching…"
            self.search(field.stringValue) { result in
                results?.arrangedSubviews.forEach { $0.removeFromSuperview() }
                switch result {
                case .success(let places):
                    note?.stringValue = places.isEmpty ? "No places found." : ""
                    for place in places {
                        let button = actionButton(place.detail.isEmpty ? place.name : "\(place.name), \(place.detail)", size: .regular, bezel: .inline) { [weak self] in
                            self?.choose(place); self?.contextShell?.openSettings(section: "weather")
                        }
                        results?.addArrangedSubview(button)
                    }
                case .failure(let error): note?.stringValue = error.message
                }
            }
        }
        let units = ActionPopUp("Units", items: ["°C, m/s", "°F, mph"], selected: settings.units == .metric ? 0 : 1) { [weak self] index in
            Analytics.setting("weather_units"); self?.set { $0.units = index == 0 ? .metric : .imperial }
        }
        let pill = ActionSwitch("Show in the notch", value: settings.showInPill) { [weak self] value in Analytics.setting("weather_show_in_pill", enabled: value); self?.set { $0.showInPill = value } }
        let refreshButton = actionButton("Refresh Now") { [weak self] in Analytics.record("weather", "refresh"); self?.refresh() }
        let place = settings.place.map { $0.detail.isEmpty ? $0.name : "\($0.name), \($0.detail)" } ?? "No place yet"
        let searchBox = NSView()
        embed(column([note, results], spacing: 4), in: searchBox, inset: NSEdgeInsets(top: 0, left: 14, bottom: 8, right: 14), fill: true)
        return settingsGroup([
            settingsRow("Place", detail: place, width: width),
            settingsRow("Find a place", detail: "Search the yr.no places, then pick one. QNotch never asks for your location.", control: field, width: width),
            searchBox,
            settingsRow("Units", control: units, width: width),
            settingsRow("Show in the notch", detail: "The current temperature beside the notch.", control: pill, width: width),
            settingsRow("Forecast", detail: updatedText.isEmpty ? "Refreshes when MET Norway publishes new data, about every 30 minutes." : "\(updatedText). Refreshes when MET Norway publishes new data.", control: refreshButton, width: width)
        ], footer: "Weather data from MET Norway (api.met.no), place search from yr.no (MET Norway and NRK), CC BY 4.0; symbols by yr.no under MIT. The only data sent is the place's coordinates.", width: width)
    }

    /// The welcome tour's Connect row: the place search from Settings, Weather.
    static func setupRow(_ context: ModuleSetupContext) -> NSView? { WeatherSetupView(context: context) }
}

/// The chosen place, a search box and up to five results. Saves through the running module when
/// there is one (as Settings does), else into weather.json for the module to read when it starts.
final class WeatherSetupView: NSStackView {
    private let context: ModuleSetupContext
    private let status = setupStatus("")
    private let field = NSSearchField()
    private let results = NSStackView()
    private let note = setupStatus("")

    init(context: ModuleSetupContext) {
        self.context = context
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        field.placeholderString = "City or place"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.setAccessibilityLabel("Find a place")
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.onAction { [weak self] in self?.find() }
        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 2
        note.isHidden = true
        let top = row([status, spacer(), field], spacing: 10)
        [top, note, results].forEach(addArrangedSubview)
        top.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refreshStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var running: WeatherModule? { context.running() as? WeatherModule }

    private var place: WeatherPlace? {
        if let running { return running.settings.place }
        return context.settings.load("weather", default: WeatherSettings()).place
    }

    private func refreshStatus() {
        Motion.crossfade(status)
        status.stringValue = place.map { $0.detail.isEmpty ? $0.name : "\($0.name), \($0.detail)" } ?? "No place yet. QNotch never asks for your location."
    }

    private func find() { Analytics.withSurface("onboarding") { Analytics.record("weather", "search") };
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        note.isHidden = false
        guard query.count >= 2 else { note.stringValue = "Type at least two letters."; return }
        note.stringValue = "Searching…"
        WeatherModule.search(query) { [weak self] result in
            guard let self else { return }
            self.results.arrangedSubviews.forEach { $0.removeFromSuperview() }
            switch result {
            case .success(let places):
                self.note.stringValue = places.isEmpty ? "No places found." : ""
                self.note.isHidden = !places.isEmpty
                for (offset, place) in places.prefix(5).enumerated() {
                    let title = place.detail.isEmpty ? place.name : "\(place.name), \(place.detail)"
                    let result = HoverButton(title, style: .row, label: "Use \(title)") { [weak self] in self?.choose(place) }
                    self.results.addArrangedSubview(result)
                    self.results.layoutSubtreeIfNeeded()
                    Motion.enter(result, delay: 0.03 * Double(offset), duration: 0.2, up: 4)
                }
            case .failure(let error): self.note.stringValue = error.message
            }
        }
    }

    private func choose(_ place: WeatherPlace) {
        if let running {
            running.choose(place)
        } else {
            Analytics.withSurface("onboarding") { Analytics.record("weather", "select_place") }
            var settings = context.settings.load("weather", default: WeatherSettings())
            settings.place = place
            context.settings.save("weather", settings)
        }
        results.arrangedSubviews.forEach { $0.removeFromSuperview() }
        field.stringValue = ""
        note.isHidden = true
        refreshStatus()
    }
}
