import AppKit
import CryptoKit
import QNotchMacCore

/// AI apps and plan usage (Windows AiModule): Claude Code and Codex usage bars on a Home card and
/// in the AI tab, and up to six AI apps with ⌃⌥1…6. Usage refreshes on one-shot timers (every 5–60
/// minutes). Claude Code keeps its login in the Keychain on macOS; reading it shows a one-time
/// macOS prompt. Codex usage comes from its local session files (no network).
final class AiModule: NotchModule {
    struct App: Equatable {
        let id: String
        let name: String
        let url: URL
        let custom: Bool
    }

    struct Provider {
        let id: String
        let name: String
        var result: UsageResult?
    }

    /// Known AI apps by bundle id; the name shown is the one the app itself declares.
    static let known = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92", "com.google.antigravity"]

    private var context: ModuleContext!
    private(set) var settings = AiSettings()
    private(set) var apps: [App] = []
    private(set) var claude = Provider(id: "claude", name: "Claude Code")
    private(set) var codex = Provider(id: "codex", name: "Codex")
    private(set) var checked: Date?
    private(set) var refreshing = false
    private var timer: Timer?
    private var clock: Timer?
    private let io = DispatchQueue(label: "qnotch.ai", qos: .utility)
    private let views = NSHashTable<AnyObject>.weakObjects()
    private lazy var session = URLSession(configuration: .ephemeral)
    var contextShell: ModuleShell? { context.shell }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("ai", default: AiSettings())
        let registry = context.registries
        registry.cards.register(ViewContribution(id: "ai.usage", title: "AI usage", order: 40, symbol: "gauge.with.dots.needle.33percent") { [unowned self] in
            self.track(AiUsageCardView(module: self))
        })
        registry.cards.register(ViewContribution(id: "ai.apps", title: "AI apps", order: 70, symbol: "square.grid.2x2") { [unowned self] in
            self.track(AiAppsView(module: self, compact: true))
        })
        registry.tabs.register(ViewContribution(id: "ai", title: "AI", order: 30, symbol: "gauge.with.dots.needle.33percent") { [unowned self] in
            self.track(AiTabView(module: self))
        })
        registry.searchSources.register(SearchSource(id: "ai.apps", order: 60) { [weak self] query in
            guard let self else { return [] }
            return self.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }.map { app in
                SearchHit(title: app.name, detail: "AI app · opens it", symbol: "app") { [weak self] in self?.launch(app) }
            }
        })
        registry.settingsSections.register(ViewContribution(id: "ai", title: "AI", order: 40, symbol: "gauge.with.dots.needle.33percent", tint: .systemPurple) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
        for slot in 1...6 {
            context.shortcuts.add("ai.slot\(slot)", title: "Open AI app \(slot)", hint: "Opens the app in slot \(slot) of Settings, AI.",
                                  gesture: "ctrl+opt+\(slot)", order: 29 + slot, enabled: false) { [weak self] in self?.launch(slot: slot) }
        }
        scan()
        if Runtime.diagnostics { seedDemo(); return }
        schedule(after: 4)
    }

    private func track<V: NSView & AiDisplay>(_ view: V) -> NSView {
        views.add(view)
        view.reload()
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        // "Resets in 2h 5m" goes stale only while someone looks.
        if panel, clock == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshViews() }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
            refreshViews()
        } else if !panel { clock?.invalidate(); clock = nil }
    }

    func systemDidWake() {}
    func stop() { timer?.invalidate(); timer = nil; clock?.invalidate(); clock = nil; session.invalidateAndCancel() }

    func refreshViews() { for case let view as AiDisplay in views.allObjects { view.reload() } }

    // MARK: Apps

    func scan() {
        var found: [App] = []
        for id in Self.known {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), !found.contains(where: { $0.url == url }) else { continue }
            found.append(App(id: id, name: Self.name(of: url), url: url, custom: false))
        }
        for path in settings.custom where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            found.append(App(id: "custom:" + path, name: Self.name(of: url), url: url, custom: true))
        }
        apps = found
        let before = settings
        settings.autoPlace(found.filter { !$0.custom }.map(\.id))
        if settings != before { context.settings.save("ai", settings) }
        applySlots()
    }

    static func name(of url: URL) -> String {
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func app(inSlot slot: Int) -> App? { settings.slots[slot - 1].flatMap { id in apps.first { $0.id == id } } }

    /// A slot's shortcut is on only while the slot holds an app.
    private func applySlots() {
        for slot in 1...6 { context.shortcuts.setEnabled("ai.slot\(slot)", app(inSlot: slot) != nil) }
        refreshViews()
    }

    func launch(slot: Int) { if let app = app(inSlot: slot) { launch(app) } }

    func launch(_ app: App) {
        context.shell?.closePanel()
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    func setSlot(_ slot: Int, _ id: String?) {
        settings.slots[slot - 1] = id
        context.settings.save("ai", settings)
        applySlots()
    }

    func addCustom(_ url: URL) {
        guard !settings.custom.contains(url.path) else { return }
        settings.custom.append(url.path)
        if let free = settings.slots.firstIndex(where: { $0 == nil }) { settings.slots[free] = "custom:" + url.path }
        context.settings.save("ai", settings)
        scan()
    }

    func removeCustom(_ app: App) {
        settings.custom.removeAll { $0 == app.url.path }
        for index in settings.slots.indices where settings.slots[index] == app.id { settings.slots[index] = nil }
        context.settings.save("ai", settings)
        scan()
    }

    // MARK: Usage

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = min(60, seconds * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Claude Code config folders: ~/.claude (or CLAUDE_CONFIG_DIR) and every ~/.claude-* in use.
    var claudeAccounts: [(path: String, name: String, isDefault: Bool)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = home.appendingPathComponent(".claude").path
        let main = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? standard
        func display(_ path: String) -> String {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return path == standard ? "Default" : name.hasPrefix(".claude-") ? String(name.dropFirst(".claude-".count)) : name
        }
        var list = [(main, display(main), main == standard)]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.sorted()
        for name in names {
            let path = home.appendingPathComponent(name).path
            guard path != main, Self.hasClaudeLogin(path, isDefault: path == standard) else { continue }
            list.append((path, display(path), path == standard))
        }
        return list
    }

    static func service(for path: String, isDefault: Bool) -> String {
        ClaudeUsage.keychainService(configDir: path, isDefault: isDefault) { text in
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Whether a login exists, without reading the secret (no Keychain prompt).
    static func hasClaudeLogin(_ path: String, isDefault: Bool) -> Bool {
        if FileManager.default.fileExists(atPath: path + "/.credentials.json") { return true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: path, isDefault: isDefault),
                                    kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func refresh() {
        guard !Runtime.diagnostics, !refreshing else { return }
        refreshing = true
        refreshViews()
        let group = DispatchGroup()
        if settings.claude {
            group.enter()
            fetchClaude { [weak self] result in self?.claude.result = result; group.leave() }
        }
        if settings.codex {
            group.enter()
            io.async { [weak self] in
                let result = Self.readCodex()
                DispatchQueue.main.async { self?.codex.result = result; group.leave() }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.refreshing = false
            self.checked = Date()
            self.refreshViews()
            self.schedule(after: TimeInterval(self.settings.refreshMinutes * 60))
        }
    }

    private func fetchClaude(done: @escaping (UsageResult) -> Void) {
        let accounts = claudeAccounts
        let account = accounts.first { $0.path == settings.claudeAccount } ?? accounts[0]
        io.async { [weak self] in
            // macOS keeps Claude Code's login in the Keychain; older installs also write a file.
            let secret = Keychain.read(Self.service(for: account.path, isDefault: account.isDefault), account: NSUserName()).flatMap { Data($0.utf8) }
                ?? Self.keychainAnyAccount(Self.service(for: account.path, isDefault: account.isDefault))
                ?? (try? Data(contentsOf: URL(fileURLWithPath: account.path + "/.credentials.json")))
            guard let secret else { return DispatchQueue.main.async { done(.unavailable("Not signed in. Sign in to Claude Code to see usage.")) } }
            guard let credentials = ClaudeUsage.credentials(secret) else {
                return DispatchQueue.main.async { done(.unavailable("Signed in without a subscription. Usage needs a Claude Pro or Max login.")) }
            }
            var request = URLRequest(url: ClaudeUsage.url)
            request.timeoutInterval = 25
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-cli/\(Self.cliVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
            self?.session.dataTask(with: request) { body, response, error in
                let result: UsageResult = error != nil ? .unavailable("No connection to Anthropic.")
                    : ClaudeUsage.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body, plan: credentials.plan)
                DispatchQueue.main.async { done(result) }
            }.resume()
        }
    }

    private static func keychainAnyAccount(_ service: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard Keychain.inMemory == nil, SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// The newest installed Claude Code version, for the usage request's User-Agent.
    static let cliVersion: String = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/claude/versions").path
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.first?.isNumber == true }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending } ?? "2.1.289"
    }()

    /// Codex writes its rate limits into the session rollouts; the newest reading wins.
    static func readCodex() -> UsageResult {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let auth = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else { return .unavailable("Not signed in. Sign in to Codex to see usage.") }
        guard ((try? JSONSerialization.jsonObject(with: auth)) as? [String: Any])?["tokens"] is [String: Any] else {
            return .unavailable("Signed in with an API key. Plan usage needs a ChatGPT login.")
        }
        let sessions = home.appendingPathComponent("sessions")
        func children(_ url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var checked = 0
        for year in children(sessions) { for month in children(year) { for day in children(month) {
            for file in children(day) where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard checked < 8 else { return .unavailable("No recent rate limit reading. Run a Codex task to refresh it.") }
                checked += 1
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let end = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: end > 512 * 1024 ? end - 512 * 1024 : 0)
                let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                try? handle.close()
                if case .ok(let windows, let plan, let asOf, _)? = CodexUsage.reading(fromTail: text) {
                    return .ok(windows: windows, plan: plan, asOf: asOf, banked: codexCredits())
                }
            }
        } } }
        return checked == 0 ? .unavailable("No Codex sessions yet. Run a task to get a reading.") : .unavailable("No recent rate limit reading. Run a Codex task to refresh it.")
    }

    /// Banked resets come only from `codex app-server` (15-second cap, then it is stopped).
    private static func codexCredits() -> BankedResets? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { if process.isRunning { process.terminate() } }
        // Reading blocks; stopping the process ends the read.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { if process.isRunning { process.terminate() } }
        let requests = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"qnotch","version":"1.0"},"capabilities":{"experimentalApi":true}}}
        {"jsonrpc":"2.0","method":"initialized"}
        {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}

        """
        input.fileHandleForWriting.write(Data(requests.utf8))
        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        let reader = output.fileHandleForReading
        while Date() < deadline {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            for line in buffer.split(separator: 0x0A) where line.range(of: Data("\"id\":2".utf8)) != nil {
                let root = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
                return CodexUsage.credits((root?["result"] as? [String: Any])?["rateLimitResetCredits"] as? [String: Any])
            }
        }
        return nil
    }

    func set(_ change: (inout AiSettings) -> Void) {
        let before = settings
        change(&settings)
        context.settings.save("ai", settings)
        if before.claude != settings.claude { claude.result = nil }
        if before.codex != settings.codex { codex.result = nil }
        if before.refreshMinutes != settings.refreshMinutes || before.claudeAccount != settings.claudeAccount { refresh() }
        refreshViews()
    }

    var providers: [Provider] { (settings.claude ? [claude] : []) + (settings.codex ? [codex] : []) }

    private func seedDemo() {
        let now = Date()
        claude.result = .ok(windows: [UsageWindow(label: "5-hour", usedPercent: 38, resetsAt: now.addingTimeInterval(7500)),
                                      UsageWindow(label: "Weekly", usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86400))],
                            plan: "Max 20x", asOf: now, banked: BankedResets(count: 2, expiresAt: now.addingTimeInterval(5 * 86400), label: nil))
        codex.result = .ok(windows: [UsageWindow(label: "5-hour", usedPercent: 12, resetsAt: now.addingTimeInterval(9000))], plan: "Pro", asOf: now, banked: nil)
        checked = now
        refreshViews()
    }
}
