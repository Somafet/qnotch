import AppKit
import CryptoKit
import QNotchMacCore

/// AI apps and plan usage (Windows AiModule): Claude Code and Codex usage bars on a Home card and
/// in the AI tab, and up to six AI apps with ⌃⌥1…6. Usage refreshes on one-shot timers (every 5–60
/// minutes). Every Claude Code account (config folder) is read; they share one row, and its account
/// picker chooses which reading it shows. Claude usage comes from Claude Code's own CLI (its
/// `get_usage` control request, as T3 Code reads it), which reads its login itself. Banked resets
/// are not in that answer: for them the login is read the way Claude Code stores it, through
/// /usr/bin/security (already on the item's access list, so macOS shows no prompt), and sent only
/// to api.anthropic.com. Codex usage comes from its local session files.
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
    /// Claude Code accounts found at the last refresh, and the latest reading of each by folder path.
    private(set) var accounts: [ClaudeAccount] = []
    var claudeResults: [String: UsageResult] = [:]
    private(set) var codex = Provider(id: "codex", name: "Codex")
    private(set) var checked: Date?
    private(set) var refreshing = false
    var consumerIdentity: ConsumerIdentity?
    var quotaChecked: [String: Date] = [:]
    var bankedChecked: [String: Date] = [:]
    private var timer: Timer?
    private var clock: Timer?
    private let io = DispatchQueue(label: "qnotch.ai", qos: .utility)
    private let views = NSHashTable<AnyObject>.weakObjects()
    var contextShell: ModuleShell? { context.shell }

    init(accounts: [ClaudeAccount] = []) { self.accounts = accounts }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("ai", default: AiSettings())
        if !Runtime.diagnostics {
            consumerIdentity = try? ConsumerIdentity(directory: context.settings.directory)
            context.registries.consumers.capture["usage"] = { [weak self] request in
                guard let self, let identity = self.consumerIdentity else { throw ConsumerFailure("identity_unavailable") }
                return try self.consumerUsage(request, identity: identity)
            }
        }
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
        loadAccounts { [weak self] accounts in self?.accounts = accounts; self?.refreshViews() }
        schedule(after: 4)
    }

    /// Lists the home folder and reads each account file off the main thread; ~/.claude.json can be many megabytes.
    private func loadAccounts(_ done: @escaping ([ClaudeAccount]) -> Void) {
        io.async {
            let accounts = Self.discoverAccounts()
            DispatchQueue.main.async { done(accounts) }
        }
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
    func stop() { timer?.invalidate(); timer = nil; clock?.invalidate(); clock = nil; }

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
        context.shell?.dismissPanel()
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

    /// Claude Code config folders: ~/.claude (or CLAUDE_CONFIG_DIR) and every signed-in ~/.claude-*.
    static func discoverAccounts() -> [ClaudeAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeAccount.discover(home: home, configDir: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
                                      entries: (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []) { path, isDefault in
            hasClaudeLogin(ClaudeAccount(path: path, folderName: "", isDefault: isDefault))
        }
    }

    /// The account the Claude row shows.
    var shownAccount: ClaudeAccount? { settings.shown(in: accounts) }
    func name(of account: ClaudeAccount) -> String { settings.name(of: account) }

    /// Shows another account's reading on the Claude row (no new request: every account is read on each refresh).
    func showAccount(_ account: ClaudeAccount) {
        guard account.path != shownAccount?.path else { return }
        settings.claudeAccount = account.path
        context.settings.save("ai", settings)
        claude.result = claudeResults[account.path]
        refreshViews()
    }

    func renameAccount(_ account: ClaudeAccount, to name: String) {
        let before = settings
        settings.rename(account, to: name)
        guard settings != before else { return }
        context.settings.save("ai", settings)
        refreshViews()
    }

    /// Whether a folder has a Claude login, from its account record (no secret, no Keychain).
    static func hasClaudeLogin(_ account: ClaudeAccount) -> Bool {
        ClaudeUsage.login(FileManager.default.contents(atPath: ClaudeUsage.accountFile(for: account, home: NSHomeDirectory()))).signedIn
    }

    func refresh() {
        guard !Runtime.diagnostics, !refreshing else { return }
        refreshing = true
        refreshViews()
        let group = DispatchGroup()
        if settings.claude {
            group.enter()
            loadAccounts { [weak self] accounts in
                guard let self else { return group.leave() }
                self.accounts = accounts
                self.claudeResults = self.claudeResults.filter { path, _ in accounts.contains { $0.path == path } }
                // Each account has its own request, timeout and failure; one never affects another.
                for account in accounts {
                    group.enter()
                    self.fetchClaude(account) { [weak self] result, quotaAt, bankedAt in
                        guard let self else { return group.leave() }
                        self.claudeResults[account.path] = result
                        self.quotaChecked[account.path] = quotaAt
                        self.bankedChecked[account.path] = bankedAt
                        if account.path == self.shownAccount?.path { self.claude.result = result }
                        group.leave()
                    }
                }
                group.leave()
            }
        }
        if settings.codex {
            group.enter()
            io.async { [weak self] in
                let result = Self.readCodex()
                DispatchQueue.main.async { self?.codex.result = result; self?.quotaChecked["codex"] = Date(); group.leave() }
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

    private func fetchClaude(_ account: ClaudeAccount, done: @escaping (UsageResult, Date, Date?) -> Void) {
        io.async {
            var result = Self.readClaude(account)
            let quotaAt = Date()
            var bankedAt: Date?
            if case .ok = result { result = ClaudeUsage.adding(Self.readClaudeBanked(account), to: result); bankedAt = Date() }
            DispatchQueue.main.async { done(result, quotaAt, bankedAt) }
        }
    }

    /// Where Claude Code's CLI usually is; an app started from Finder has no shell PATH.
    static func claudeExecutable() -> String? {
        let home = NSHomeDirectory()
        let path: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        let candidates: [String] = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] + path
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Asks Claude Code's CLI for the account's plan usage (20-second cap, then it is stopped).
    /// The CLI gets the folder through CLAUDE_CONFIG_DIR, reads its own login, and sends the
    /// request to Anthropic itself. Blocking; call off the main thread.
    static func readClaude(_ account: ClaudeAccount) -> UsageResult {
        let login = ClaudeUsage.login(FileManager.default.contents(atPath: ClaudeUsage.accountFile(for: account, home: NSHomeDirectory())))
        guard login.signedIn else { return .unavailable("Not signed in. Sign in to Claude Code to see usage.") }
        guard let executable = claudeExecutable() else { return .unavailable("Claude Code's command line tool was not found.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ClaudeUsage.arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = account.isDefault ? nil : account.path
        environment["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "0"
        environment["CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"] = "1"
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable("Claude Code could not be started.") }
        defer { if process.isRunning { process.terminate() } }
        // Reading blocks; stopping the process ends the read.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
        input.fileHandleForWriting.write(Data(ClaudeUsage.requests.utf8))
        var buffer = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                switch ClaudeUsage.answer(line: Data(line)) {
                case .usage(let usage)?: return ClaudeUsage.parse(usage: usage, tier: login.tier)
                case .failed(let message)?: return .unavailable(message)
                case nil: continue
                }
            }
        }
        return .unavailable("Claude Code did not answer. Open it once to check its sign-in.")
    }

    /// The banked resets of an account; nil on any failure, so the usage bars never depend on it.
    /// Blocking; call off the main thread.
    static func readClaudeBanked(_ account: ClaudeAccount) -> BankedResets? {
        guard let token = claudeToken(account) else { return nil }
        var request = URLRequest(url: ClaudeUsage.bankedURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/\(claudeVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var banked: BankedResets?
        URLSession.shared.dataTask(with: request) { body, response, _ in
            if let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) { banked = ClaudeUsage.banked(body: body) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return banked
    }

    /// Claude Code's login, read as Claude Code itself reads it: `security find-generic-password`
    /// (5-second cap), or the folder's .credentials.json when there is no Keychain item.
    private static func claudeToken(_ account: ClaudeAccount) -> String? {
        let service = ClaudeUsage.keychainService(configDir: account.path, isDefault: account.isDefault) { text in
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let token = ClaudeUsage.accessToken(data) { return token }
        }
        return FileManager.default.contents(atPath: account.path + "/.credentials.json").flatMap(ClaudeUsage.accessToken)
    }

    /// The newest installed Claude Code version, for the request's User-Agent.
    static let claudeVersion: String = {
        let folder = NSHomeDirectory() + "/.local/share/claude/versions"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.first?.isNumber == true }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending } ?? "2.1.300"
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
        if before.claude != settings.claude { claude.result = nil; claudeResults = [:] }
        if before.codex != settings.codex { codex.result = nil }
        if before.refreshMinutes != settings.refreshMinutes || (!before.claude && settings.claude) || (!before.codex && settings.codex) { refresh() }
        refreshViews()
    }

    var providers: [Provider] { (settings.claude ? [claude] : []) + (settings.codex ? [codex] : []) }

    private func seedDemo() {
        let now = Date()
        let home = NSHomeDirectory()
        accounts = [ClaudeAccount(path: home + "/.claude", folderName: "Default", isDefault: true),
                    ClaudeAccount(path: home + "/.claude-work", folderName: "work", isDefault: false)]
        settings.claudeAccount = accounts[0].path
        claude.result = .ok(windows: [UsageWindow(label: "5-hour", usedPercent: 38, resetsAt: now.addingTimeInterval(7500)),
                                      UsageWindow(label: "Weekly", usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86400))],
                            plan: "Max 20x", asOf: now, banked: BankedResets(count: 2, expiresAt: now.addingTimeInterval(5 * 86400), label: nil))
        claudeResults = [accounts[0].path: claude.result!,
                         accounts[1].path: .ok(windows: [UsageWindow(label: "5-hour", usedPercent: 81, resetsAt: now.addingTimeInterval(2400))], plan: "Pro", asOf: now, banked: nil)]
        codex.result = .ok(windows: [UsageWindow(label: "5-hour", usedPercent: 12, resetsAt: now.addingTimeInterval(9000))], plan: "Pro", asOf: now, banked: nil)
        checked = now
        refreshViews()
    }
}
