import AppKit
import QNotchMacCore

/// The MET Norway forecast for a place the user picks (Windows WeatherModule): a two-column Home
/// card and the temperature beside the notch. No location services: the place comes from the yr.no
/// search. One-shot refreshes follow MET's Expires header (10 minutes to 2 hours), with
/// If-Modified-Since; errors retry after 10 minutes, rate limits after an hour.
final class WeatherModule: NotchModule {
    enum Status { case noPlace, loading, ready, error }

    private var context: ModuleContext!
    private(set) var settings = WeatherSettings()
    private(set) var forecast: WeatherForecast?
    private(set) var view: WeatherView?
    private(set) var status = Status.noPlace
    private(set) var message = ""
    private(set) var stale = false
    private(set) var refreshing = false
    private var timer: Timer?
    private let views = NSHashTable<AnyObject>.weakObjects()
    private let pills = NSHashTable<WeatherPillView>.weakObjects()
    private lazy var session = Self.makeSession()
    /// The welcome tour's place search, before the module exists.
    private static var setupSession: URLSession?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "QNotch/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") (+https://github.com/Somafet/qnotch)"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
    private var cacheURL: URL { context.settings.directory.appendingPathComponent("weather-cache.json") }
    var contextShell: ModuleShell? { context.shell }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("weather", default: WeatherSettings())
        context.registries.cards.register(ViewContribution(id: "weather", title: "Weather", order: 15, symbol: "cloud.sun", span: 2) { [unowned self] in
            let view = WeatherCardView(module: self)
            self.views.add(view)
            view.reload()
            return view
        })
        context.registries.segments.register(SegmentContribution(id: "weather.pill", order: 9, slot: .trailing, destination: .card("weather", emphasis: nil, allowsHiddenDetail: false), destinationLabel: "Open weather") { [weak self] in
            let view = WeatherPillView()
            self?.pills.add(view)
            self?.refreshViews(notify: false)
            return view
        })
        context.registries.settingsSections.register(ViewContribution(id: "weather", title: "Weather", order: 55, symbol: "cloud.sun.fill", tint: .systemCyan) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
        if Runtime.diagnostics { seedDemo(); return }
        start()
    }

    func setVisibility(panel: Bool, activeTab: String) {
        guard panel else { return }
        show()
        if let forecast, Date() > forecast.expires.addingTimeInterval(60) { refresh() }
    }

    func systemDidWake() {
        show()
        if let forecast, Date() > forecast.expires.addingTimeInterval(60) { refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil; session.invalidateAndCancel() }

    // MARK: Data

    private func start() {
        guard let place = settings.place else { show(); return }
        let url = cacheURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(WeatherForecast.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let cached, place.sameSpot(cached) { self.forecast = cached }
                self.show()
                let wait = self.forecast.map { min(7200, max(2, $0.expires.timeIntervalSinceNow)) } ?? 2
                self.schedule(after: wait)
            }
        }
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = min(60, seconds * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !Runtime.diagnostics, let place = settings.place, let url = place.forecastURL, !refreshing else { show(); return }
        refreshing = true
        if forecast == nil { status = .loading }
        refreshViews()
        let prior = forecast.flatMap { place.sameSpot($0) ? $0 : nil }
        var request = URLRequest(url: url)
        if let modified = prior?.lastModified, !modified.isEmpty { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let now = Date()
            let expires = http.flatMap { Self.httpDate($0.value(forHTTPHeaderField: "Expires")) } ?? now.addingTimeInterval(1800)
            var result: Outcome
            if error != nil || http == nil {
                result = .failed(("No connection to MET Norway.", true, 600))
            } else if http!.statusCode == 304, var prior {
                prior.fetched = now; prior.expires = expires
                result = .fetched(prior)
            } else if [403, 429].contains(http!.statusCode) {
                result = .failed(("MET Norway asked QNotch to slow down. Trying again in an hour.", false, 3600))
            } else if !(200..<300).contains(http!.statusCode) {
                result = .failed(("MET Norway returned \(http!.statusCode).", false, 600))
            } else if let data, let parsed = try? WeatherForecast.parse(data, lat: place.lat, lon: place.lon, fetched: now, expires: expires,
                                                                         lastModified: http!.value(forHTTPHeaderField: "Last-Modified") ?? "") {
                result = .fetched(parsed)
            } else {
                result = .failed(("MET Norway sent an unexpected response.", false, 600))
            }
            if case .fetched(let forecast) = result, let encoded = try? JSONEncoder().encode(forecast), let self {
                try? FileManager.default.createDirectory(at: self.context.settings.directory, withIntermediateDirectories: true)
                try? encoded.write(to: self.cacheURL, options: .atomic)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                guard self.settings.place == place else { return self.refresh() } // the place changed meanwhile
                switch result {
                case .fetched(let forecast):
                    self.forecast = forecast
                    self.stale = false
                    self.message = ""
                    self.schedule(after: WeatherFormat.nextRefresh(expires: forecast.expires, now: Date()))
                case .failed(let failure):
                    if self.forecast != nil {
                        self.stale = true
                        self.message = failure.offline ? "Offline, showing the saved forecast." : "Could not refresh: \(failure.message)"
                    } else {
                        self.message = failure.message
                        self.status = .error
                    }
                    self.schedule(after: failure.retry)
                }
                self.show()
            }
        }.resume()
    }

    private enum Outcome {
        case fetched(WeatherForecast)
        case failed((message: String, offline: Bool, retry: TimeInterval))
    }

    struct SearchError: Error { let message: String }

    private static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    private func show() {
        guard let place = settings.place else { status = .noPlace; view = nil; return refreshViews() }
        if let forecast, let built = WeatherFormat.build(forecast, place: place, units: settings.units, now: Date()) {
            view = built
            status = .ready
        } else {
            view = nil
            if forecast != nil { message = "The saved forecast is out of date."; status = .error }
            else if status != .error { status = .loading }
        }
        refreshViews()
    }

    var updatedText: String { forecast.map { (stale ? "Saved " : "Updated ") + WeatherFormat.ago($0.fetched) } ?? "" }

    private var pillState = ""
    private func refreshViews(notify: Bool = true) {
        for case let view as WeatherCardView in views.allObjects { view.reload() }
        let shown = settings.showInPill && view != nil
        pills.allObjects.forEach { $0.update(view: shown ? view : nil) }
        let state = shown ? (view?.temp ?? "") + (view?.symbol ?? "") : ""
        guard state != pillState else { return }
        pillState = state
        if notify { context.shell?.segmentsChanged() }
    }

    // MARK: Settings actions

    func choose(_ place: WeatherPlace) {
        settings.place = place
        context.settings.save("weather", settings)
        forecast = nil
        stale = false
        message = ""
        show()
        refresh()
    }

    func set(_ change: (inout WeatherSettings) -> Void) {
        change(&settings)
        context.settings.save("weather", settings)
        show()
    }

    func search(_ query: String, done: @escaping (Result<[WeatherPlace], SearchError>) -> Void) {
        Self.search(query, session: session, done: done)
    }

    /// The yr.no place search (Settings, Weather and the welcome tour).
    static func search(_ query: String, session: URLSession? = nil, done: @escaping (Result<[WeatherPlace], SearchError>) -> Void) {
        guard !Runtime.diagnostics, let url = WeatherPlace.searchURL(query) else { return done(.success([])) }
        let client: URLSession
        if let session { client = session } else if let setupSession { client = setupSession } else {
            client = makeSession()
            setupSession = client
        }
        client.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<[WeatherPlace], SearchError>
            if error != nil { result = .failure(SearchError(message: "No connection to yr.no.")) }
            else if status == 404 { result = .success([]) }
            else if !(200..<300).contains(status) { result = .failure(SearchError(message: "yr.no returned \(status).")) }
            else if let data, let places = try? WeatherPlace.parseSearch(data) { result = .success(places) }
            else { result = .failure(SearchError(message: "yr.no sent an unexpected response.")) }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    func openYr() { if let url = settings.place?.yrURL { NSWorkspace.shared.open(url) } }

    /// Diagnostic runs: a made-up forecast, nothing fetched.
    private func seedDemo() {
        settings.place = settings.place ?? WeatherPlace(id: "1-72837", name: "Oslo", detail: "Norway", lat: 59.9133, lon: 10.7389, elevation: nil,
                                                        timeZone: "Europe/Oslo", urlPath: "Norway/Oslo/Oslo/Oslo")
        let start = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let symbols = ["partlycloudy_day", "lightrainshowers_day", "cloudy", "clearsky_day", "fair_day"]
        let points = (0..<120).map { hour -> WeatherPoint in
            let time = start.addingTimeInterval(Double(hour) * 3600)
            let phase: Double = Double(hour) / 24 * 2 * Double.pi - 1.6
            let trend: Double = Double(hour / 24) * 0.6
            let temp: Double = 9 + 4 * sin(phase) + trend
            return WeatherPoint(time: time, temp: temp, feels: temp - 2, wind: 4, symbol1: symbols[(hour / 24) % symbols.count],
                                symbol6: hour % 6 == 0 ? symbols[(hour / 24) % symbols.count] : nil, precip1: hour < 2 ? 0.4 : 0,
                                max6: temp + 1.5, min6: temp - 2)
        }
        forecast = WeatherForecast(lat: 59.9133, lon: 10.7389, fetched: Date(), expires: Date().addingTimeInterval(1800), lastModified: "", points: points)
        show()
    }
}
