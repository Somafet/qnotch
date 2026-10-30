import AppKit
import QNotchMacCore

/// Your GitHub contribution graph (Windows GithubModule), from the GraphQL API with a personal
/// access token kept in the Keychain ("QNotch/GitHub"), never in a file. One-shot refresh every
/// hour, 10 minutes after a failure; the last graph is cached atomically and shown while offline.
final class GithubModule: NotchModule {
    enum Status { case noToken, loading, ready, error }
    static let tokenService = "QNotch/GitHub"

    private var context: ModuleContext!
    private(set) var data: GithubData?
    private(set) var status = Status.noToken
    private(set) var message = ""
    private(set) var stale = false
    private var refreshing = false
    private var timer: Timer?
    private var token: String?
    private let views = NSHashTable<GithubCardView>.weakObjects()
    private lazy var session = URLSession(configuration: .ephemeral)
    private var cacheURL: URL { context.settings.directory.appendingPathComponent("github-cache.json") }
    var contextShell: ModuleShell? { context.shell }

    func initialize(_ context: ModuleContext) {
        self.context = context
        context.registries.cards.register(ViewContribution(id: "github", title: "GitHub", order: 50, symbol: "chart.bar.xaxis", span: 2) { [unowned self] in
            let view = GithubCardView(module: self)
            self.views.add(view)
            view.reload()
            return view
        })
        context.registries.settingsSections.register(ViewContribution(id: "github", title: "GitHub", order: 50, symbol: "chevron.left.forwardslash.chevron.right", tint: .darkGray) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
        if Runtime.diagnostics {
            data = GithubData.demo()
            status = .ready
            return
        }
        start()
    }

    func setVisibility(panel: Bool, activeTab: String) { if panel { refreshViews() } }
    func systemDidWake() {}
    func stop() { timer?.invalidate(); timer = nil; session.invalidateAndCancel() }

    var hasToken: Bool { token != nil }

    private func start() {
        // The Keychain read happens off the main thread; macOS may ask once to allow it.
        let cache = cacheURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let token = Keychain.read(Self.tokenService)
            let cached = token == nil ? nil : (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(GithubData.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.token = token
                guard token != nil else { self.status = .noToken; return self.refreshViews() }
                if let cached { self.data = cached; self.status = .ready }
                self.refreshViews()
                let age = cached.map { Date().timeIntervalSince($0.fetched) } ?? 3600
                self.schedule(after: age >= 3300 ? 3 : 3600 - age)
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

    private func query(_ text: String, token: String, done: @escaping (Result<[String: Any], GithubError>) -> Void) {
        Self.query(text, token: token, session: session, done: done)
    }

    /// For checks before the module exists (the welcome tour) and for the sign-in view.
    static let checkSession = URLSession(configuration: .ephemeral)

    /// Checks a token with the login query: the account's login, or the error to show.
    static func login(token: String, session: URLSession = GithubModule.checkSession, done: @escaping (Result<String, GithubError>) -> Void) {
        query(GithubData.loginQuery, token: token, session: session) { result in
            done(result.map { payload in ((payload["viewer"] as? [String: Any])?["login"] as? String) ?? "" })
        }
    }

    static func query(_ text: String, token: String, session: URLSession, done: @escaping (Result<[String: Any], GithubError>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("QNotch", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": text])
        session.dataTask(with: request) { body, response, error in
            let result: Result<[String: Any], GithubError>
            do {
                result = .success(try GithubData.payload(status: (response as? HTTPURLResponse)?.statusCode, body: body, transportFailed: error != nil))
            } catch let failure as GithubError { result = .failure(failure) } catch { result = .failure(.message("GitHub sent an unexpected response.", offline: false)) }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    func refresh() {
        guard !Runtime.diagnostics, !refreshing else { return }
        guard let token else { status = .noToken; return refreshViews() }
        refreshing = true
        if data == nil { status = .loading }
        refreshViews()
        query(GithubData.calendarQuery, token: token) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            switch result {
            case .success(let payload):
                do {
                    let fresh = try GithubData.parse(payload, fetched: Date())
                    if let old = self.data, old.sameGraph(fresh) { self.data?.fetched = fresh.fetched } else { self.data = fresh }
                    self.status = .ready
                    self.stale = false
                    self.message = ""
                    let url = self.cacheURL
                    if let encoded = try? JSONEncoder().encode(fresh) {
                        DispatchQueue.global(qos: .utility).async { try? encoded.write(to: url, options: .atomic) }
                    }
                    self.schedule(after: 3600)
                } catch { self.fail(.message("GitHub sent an unexpected response.", offline: false)) }
            case .failure(let failure): self.fail(failure)
            }
            self.refreshViews()
        }
    }

    private func fail(_ failure: GithubError) {
        if data != nil {
            stale = true
            message = failure.offline ? "Offline, showing saved activity." : failure.text
        } else {
            status = .error
            message = failure.text
        }
        schedule(after: 600)
    }

    var updatedText: String {
        guard let data else { return "" }
        let age = Date().timeIntervalSince(data.fetched)
        let ago = age < 60 ? "just now" : age < 3600 ? "\(Int(age / 60)) min ago" : age < 86400 ? "\(Int(age / 3600)) h ago" : "\(Int(age / 86400)) d ago"
        return (stale ? "Saved " : "Updated ") + ago
    }

    func refreshViews() { views.allObjects.forEach { $0.reload() } }

    // MARK: Token

    func test(_ candidate: String?, done: @escaping (Bool, String) -> Void) { Analytics.record("github", "test_connection");
        guard let token = candidate.flatMap({ $0.isEmpty ? nil : $0 }) ?? self.token else { return done(false, "Enter a token first.") }
        Self.login(token: token, session: session) { result in
            switch result {
            case .success(let login): done(true, "Connected as @\(login).")
            case .failure(let failure): done(false, failure.text)
            }
        }
    }

    func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.write(trimmed, service: Self.tokenService) else { return false }
        token = trimmed
        message = ""
        if data == nil { status = .loading }
        refresh()
        return true
    }

    func removeToken() { Analytics.record("github", "disconnect");
        timer?.invalidate()
        Keychain.delete(Self.tokenService)
        try? FileManager.default.removeItem(at: cacheURL)
        token = nil
        data = nil
        stale = false
        message = ""
        status = .noToken
        refreshViews()
    }
}

// MARK: - Views

final class GithubCardView: NSView, HomeCardSizing {
    private weak var module: GithubModule?
    private let header = line("", size: 12, weight: .semibold, color: Palette.textPrimary)
    private let footer = line("", size: 11, color: Palette.textTertiary)
    private let graph = ContributionGraph()
    private var compact = false
    private let legend: NSStackView
    private let content: NSView
    private let empty = NSStackView()

    init(module: GithubModule) {
        self.module = module
        let refresh = HoverButton(symbol: "arrow.clockwise", style: .icon, symbolSize: 11, label: "Refresh") { [weak module] in Analytics.record("github", "refresh"); module?.refresh() }
        legend = row([line("Less", size: 10, color: Palette.textTertiary)] + (0...4).map { level -> NSView in
            let cell = FillView(fill: ContributionGraph.color(level), radius: 2)
            size(cell, width: 8, height: 8)
            return cell
        } + [line("More", size: 10, color: Palette.textTertiary)], spacing: 3)
        content = column([row([header, spacer(), refresh], spacing: 4), graph, row([footer, spacer(), legend], spacing: 6)], spacing: 6)
        super.init(frame: .zero)
        empty.orientation = .vertical
        empty.alignment = .leading
        empty.spacing = 8
        embed(content, in: self, inset: 0, fill: true)
        embed(empty, in: self, inset: 0)
        for view in content.subviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHomeCardSize(_ size: HomeCardSize) {
        compact = size == .small
        legend.isHidden = compact
        graph.weekLimit = compact ? 20 : 53
        for field in [header, footer] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        reload()
    }

    func reload() {
        guard let module else { return }
        let data = module.data
        content.isHidden = data == nil
        empty.isHidden = data != nil
        empty.arrangedSubviews.forEach { $0.removeFromSuperview() }
        defer {
            for child in empty.arrangedSubviews { child.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor).isActive = true }
        }
        guard let data else {
            switch module.status {
            case .noToken:
                empty.addArrangedSubview(label("Connect GitHub to see your contributions.", size: 13, color: Palette.textSecondary))
                empty.addArrangedSubview(HoverButton("Add Token", style: .plain) { [weak module] in module?.contextShell?.openSettings(section: "github") })
            case .loading:
                empty.addArrangedSubview(line("Loading your contributions…", size: 13, color: Palette.textSecondary))
            default:
                empty.addArrangedSubview(label(module.message, size: 12, color: Palette.textSecondary))
                empty.addArrangedSubview(HoverButton("Retry", style: .plain) { [weak module] in Analytics.record("github", "refresh"); module?.refresh() })
            }
            return
        }
        header.stringValue = compact ? "\(data.total.formatted()) contributions" : "\(data.total.formatted()) contributions · \(data.streak) day streak"
        footer.stringValue = module.message.isEmpty
            ? (compact ? "\(data.streak) day streak · @\(data.login)" : "@\(data.login) · \(module.updatedText)") : module.message
        footer.toolTip = "@\(data.login) · \(module.updatedText)"
        footer.textColor = module.stale ? .systemOrange : Palette.textTertiary
        graph.set(data)
    }
}

/// Up to 53 weeks × 7 days (20 recent weeks in Small), drawn only on data or size changes.
final class ContributionGraph: NSView, NSViewToolTipOwner {
    var weekLimit = 53 { didSet { if weekLimit != oldValue { needsDisplay = true } } }
    private var data: GithubData?
    private var tip: NSView.ToolTipTag?

    static func color(_ level: Int) -> NSColor {
        level == 0 ? Palette.control : Palette.accent.withAlphaComponent([0, 0.3, 0.52, 0.76, 1][min(4, level)])
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 46).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ data: GithubData) {
        if let old = self.data, old.sameGraph(data), old.login == data.login { return }
        self.data = data
        setAccessibilityLabel("GitHub contributions: \(data.total) in the last year")
        needsDisplay = true
    }

    private var weeks: [[GithubData.Day?]] {
        guard let days = data?.days, !days.isEmpty else { return [] }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        let first = parser.date(from: days[0].date).map { parser.calendar.component(.weekday, from: $0) - 1 } ?? 0
        var cells: [GithubData.Day?] = Array(repeating: nil, count: first) + days.map { $0 }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }.suffix(weekLimit)
    }

    private var geometry: (cell: CGFloat, gap: CGFloat, originX: CGFloat) {
        let count = CGFloat(max(1, weeks.count))
        let gap: CGFloat = 1.5
        let cell = min((bounds.height - gap * 6) / 7, (bounds.width - gap * (count - 1)) / count)
        let width = count * cell + (count - 1) * gap
        return (cell, gap, max(0, (bounds.width - width) / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        RenderDiagnostics.drawCount += 1
        let (cell, gap, originX) = geometry
        for (column, week) in weeks.enumerated() {
            for (rowIndex, day) in week.enumerated() {
                guard let day else { continue }
                let rect = NSRect(x: originX + CGFloat(column) * (cell + gap), y: bounds.height - CGFloat(rowIndex + 1) * (cell + gap) + gap, width: cell, height: cell)
                Self.color(day.level).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
        if let tip { removeToolTip(tip) }
        tip = addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let (cell, gap, originX) = geometry
        let column = Int((point.x - originX) / (cell + gap)), rowIndex = Int((bounds.height - point.y) / (cell + gap))
        let weeks = weeks
        guard weeks.indices.contains(column), (0..<7).contains(rowIndex), let day = weeks[column][rowIndex] else { return "" }
        return "\(day.count == 1 ? "1 contribution" : "\(day.count) contributions") on \(day.date)"
    }
}

extension GithubModule {
    func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let status = hasToken ? (data.map { "Connected as @\($0.login). \(updatedText)." } ?? "Token saved.") : "Not connected."
        let field = NSSecureTextField()
        field.placeholderString = hasToken ? "Saved in your Keychain" : "ghp_…"
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        field.setAccessibilityLabel("Personal access token")
        let note = label(message, size: 11, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = width - 30
        let save = actionButton("Save") { [weak self, weak field, weak note] in
            Analytics.record("github", "connect")
            guard let self, let field else { return }
            note?.stringValue = self.save(field.stringValue) ? "Saved. Loading your contributions…" : "Enter a token first, or the Keychain refused it."
            field.stringValue = ""
        }
        let test = actionButton("Test") { [weak self, weak field, weak note] in
            note?.stringValue = "Testing…"
            self?.test(field?.stringValue) { _, text in note?.stringValue = text }
        }
        let remove = actionButton("Remove Token") { [weak self] in
            self?.removeToken()
            self?.contextShell?.openSettings(section: "github")
        }
        remove.isEnabled = hasToken
        let refresh = actionButton("Refresh Now") { [weak self] in Analytics.record("github", "refresh"); self?.refresh() }
        refresh.isEnabled = hasToken
        let box = NSView()
        embed(note, in: box, inset: NSEdgeInsets(top: 0, left: 14, bottom: 8, right: 14), fill: true)
        var signIn: [NSView] = []
        if GithubOAuth.available {
            let view = GithubSignInView(look: .settings) { [weak self] token in self?.save(token) ?? false }
            let flow = NSView()
            embed(view, in: flow, inset: NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14), fill: true)
            signIn = [settingsRow("Sign in with GitHub", detail: "Approve QNotch on github.com in your browser. Only read:user is requested.", width: width), flow]
        }
        return settingsGroup([settingsRow("Status", detail: status, width: width)] + signIn + [
            settingsRow(GithubOAuth.available ? "Or use a personal access token" : "Personal access token",
                        detail: "A classic token with read:user; add repo to count private activity.", control: row([field, save], spacing: 6), width: width),
            settingsRow("Connection", detail: "Test checks the token in the box, or the saved one.", control: row([test, remove], spacing: 6), width: width),
            box,
            settingsRow("Activity", detail: "Refreshes every hour.", control: refresh, width: width)
        ], footer: "The token is stored in your Keychain, never in a file, and sent only to api.github.com." +
            (GithubOAuth.available ? " Signing in talks to github.com only until you approve or cancel." : ""), width: width)
    }
}
