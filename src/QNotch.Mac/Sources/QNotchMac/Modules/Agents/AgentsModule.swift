import AppKit
import QNotchMacCore

/// Live Claude Code and Codex sessions: working, needs you, done (Windows AgentsModule). The agent
/// runs `QNotch agent` on each event (hooks the user adds with Connect in Settings, Agents), and the
/// hook sends one line over a per-user socket. Process-exit sources drop sessions whose terminal
/// closed. Nothing polls.
final class AgentsModule: NotchModule {
    struct Connection {
        let title: String
        let directory: URL
        let fileName: String
        let file: AgentHookFile
        var path: URL { directory.appendingPathComponent(fileName) }
        var connectedHint: String {
            file.kind == .codex ? "Connected. Codex runs the hooks once you trust them: /hooks in the CLI, or Settings, Hooks in the Codex app."
                : "Connected. Sessions that were already open show up after you restart them."
        }
    }

    private var context: ModuleContext!
    private(set) var board = AgentBoard()
    private(set) var settings = AgentsSettings()
    private var server: NotifyServer?
    private(set) var socketStatus = "Starting"
    private var exits: [Int32: DispatchSourceProcess] = [:]
    private var peek: PeekHandle?
    private var peekFor: String?
    private var inCall = false
    private var clock: Timer?
    private let views = NSHashTable<AnyObject>.weakObjects()
    private let pills = NSHashTable<AgentPillView>.weakObjects()
    var contextShell: ModuleShell? { context.shell }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("agents", default: AgentsSettings())
        context.sounds.add("agents.needsyou", title: "Agent needs you", hint: "An agent waits for your answer.", defaultName: "Tink", order: 20)
        context.sounds.add("agents.done", title: "Agent finished", hint: "An agent finished its turn.", defaultName: "Hero", order: 21)
        let registry = context.registries
        registry.tabs.register(ViewContribution(id: "agents", title: "Agents", order: 35, symbol: "sparkles") { [unowned self] in
            let view = AgentsTabView(module: self)
            self.views.add(view)
            view.reload()
            return view
        })
        registry.segments.register(SegmentContribution(id: "agents.pill", order: 6, slot: .trailing) { [weak self] in
            let view = AgentPillView()
            self?.pills.add(view)
            view.update(text: self?.board.pillText, needsYou: self?.board.needsYou ?? false)
            return view
        })
        registry.searchSources.register(SearchSource(id: "agents", order: 45) { [weak self] query in
            guard let self else { return [] }
            return self.board.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query) }.map { session in
                SearchHit(title: session.displayTitle, detail: Self.meta(session), symbol: "sparkles") { [weak self] in self?.context.shell?.selectTab("agents") }
            }
        })
        registry.settingsSections.register(ViewContribution(id: "agents", title: "Agents", order: 45, symbol: "sparkles", tint: .systemOrange) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
        DispatchQueue.main.async { [weak self] in self?.startServer() }
        applySounds()
    }

    func setVisibility(panel: Bool, activeTab: String) {
        let visible = panel && activeTab == "agents"
        if visible, clock == nil {
            // "4m ago" goes stale only while someone looks.
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
            refresh()
        } else if !visible { clock?.invalidate(); clock = nil }
    }

    func systemDidWake() {}

    func stop() {
        server?.stopAll()
        server = nil
        exits.values.forEach { $0.cancel() }
        exits.removeAll()
        clock?.invalidate(); clock = nil
        peek?.end()
        context.capture.remove(self)
    }

    private func startServer() {
        let server = NotifyServer { [weak self] line, exchange in
            exchange.answer(Data())
            guard let event = try? JSONDecoder().decode(AgentEvent.self, from: line) else { return }
            self?.apply(event)
        }
        self.server = server
        try? FileManager.default.createDirectory(at: context.settings.directory, withIntermediateDirectories: true)
        socketStatus = server.startSocket(at: context.settings.directory.appendingPathComponent("agents.sock").path)
    }

    // MARK: Events

    func apply(_ event: AgentEvent) {
        let alert = board.apply(event)
        if let pid = event.pid, pid > 0 { watch(pid) }
        changed()
        switch alert {
        case .needsYou(let session)?:
            announce(session, what: "Needs you", symbol: "exclamationmark.bubble.fill", tint: .systemOrange, sound: settings.soundNeedsYou ? "agents.needsyou" : nil)
        case .done(let session)?:
            announce(session, what: "Done", symbol: "checkmark.circle.fill", tint: .systemGreen, sound: settings.soundDone ? "agents.done" : nil)
        case nil:
            // Answered in the terminal (or gone): the peek about it goes at once.
            if let id = peekFor, board.sessions.first(where: { $0.id == id })?.status != .needsYou { peek?.end(); peekFor = nil }
        }
    }

    /// A peek ("api: Needs you") and the sound, unless the panel is open (no peek) or a call is on.
    private func announce(_ session: AgentSession, what: String, symbol: String, tint: NSColor, sound: String?) {
        peek?.end()
        peek = context.shell?.peek(symbol: symbol, tint: tint, leading: session.name, trailing: what, seconds: 4)
        peekFor = session.status == .needsYou ? session.id : nil
        if peek != nil, let sound, !inCall { context.sounds.play(sound) }
    }

    /// Drops the sessions of an agent process when it exits (a terminal closed without SessionEnd).
    private func watch(_ pid: Int32) {
        guard exits[pid] == nil else { return }
        guard kill(pid, 0) == 0 || errno == EPERM else { ended(pid); return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.ended(pid) }
        source.resume()
        exits[pid] = source
    }

    private func ended(_ pid: Int32) {
        exits.removeValue(forKey: pid)?.cancel()
        if board.processEnded(pid) { changed() }
    }

    // MARK: Commands

    /// Brings the terminal or app the agent runs in forward, then opens the session link if any.
    func show(_ session: AgentSession) {
        if let pid = session.pid, let app = NotificationsModule.appOwning(pid) { app.activate(options: [.activateAllWindows]) }
        if let link = session.link, AgentEvent.isValidLink(link), let url = URL(string: link) { NSWorkspace.shared.open(url) }
        context.shell?.closePanel()
    }

    func dismiss(_ session: AgentSession) {
        board.remove(session.id)
        changed()
    }

    private func changed() {
        let text = board.pillText, needsYou = board.needsYou
        pills.allObjects.forEach { $0.update(text: text, needsYou: needsYou) }
        context.shell?.segmentsChanged()
        refresh()
    }

    func refresh() { for case let view as AgentsTabView in views.allObjects { view.reload() } }

    static func meta(_ session: AgentSession, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(session.since) / 60))
        let age = minutes == 0 ? "just now" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        let agent = session.agent == "codex" ? "Codex · " : ""
        switch session.status {
        case .needsYou: return agent + (session.message.isEmpty ? "Needs you" : session.message)
        case .working: return agent + (minutes == 0 ? "Working" : "Working for \(age)")
        case .done: return agent + (minutes == 0 ? "Done just now" : "Done \(age) ago")
        case .ready: return agent + "Ready"
        }
    }

    // MARK: Sounds and calls

    private func applySounds() {
        if settings.soundNeedsYou || settings.soundDone {
            context.capture.observe(self) { [weak self] state in self?.inCall = state.microphone }
        } else {
            context.capture.remove(self)
            inCall = false
        }
    }

    func set(_ change: (inout AgentsSettings) -> Void) {
        change(&settings)
        context.settings.save("agents", settings)
        applySounds()
    }

    // MARK: Connections

    var executable: String { Bundle.main.executablePath ?? "QNotch" }

    /// The default Claude Code folder (or CLAUDE_CONFIG_DIR), every ~/.claude-* folder in use, and Codex.
    var connections: [Connection] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let main = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".claude", isDirectory: true)
        var folders = [main]
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0 == ".claude" || $0.hasPrefix(".claude-") }.sorted()
        for name in others {
            let directory = home.appendingPathComponent(name, isDirectory: true)
            guard !folders.contains(where: { $0.standardizedFileURL == directory.standardizedFileURL }),
                  ["settings.json", ".credentials.json"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { continue }
            folders.append(directory)
        }
        var list = folders.map { directory -> Connection in
            let name = directory.lastPathComponent
            let title = name == ".claude" ? "Claude Code" : name.hasPrefix(".claude-") ? "Claude Code (\(name.dropFirst(".claude-".count)))" : "Claude Code (\(name))"
            return Connection(title: title, directory: directory, fileName: "settings.json", file: AgentHookFile(kind: .claude, executable: executable))
        }
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".codex", isDirectory: true)
        if FileManager.default.fileExists(atPath: codex.path) {
            list.append(Connection(title: "Codex", directory: codex, fileName: "hooks.json", file: AgentHookFile(kind: .codex, executable: executable)))
        }
        return list
    }

    func status(_ connection: Connection) -> AgentHookFile.Status {
        connection.file.status(of: try? String(contentsOf: connection.path, encoding: .utf8))
    }

    /// Backs up the original file (once, before QNotch first touches it) and writes atomically.
    func setConnected(_ connection: Connection, _ on: Bool) throws {
        let path = connection.path
        let text = try? String(contentsOf: path, encoding: .utf8)
        let next = on ? try connection.file.connect(text) : try connection.file.disconnect(text)
        try FileManager.default.createDirectory(at: connection.directory, withIntermediateDirectories: true)
        if text != nil, status(connection) == .notInstalled {
            let backup = URL(fileURLWithPath: path.path + ".qnotch-backup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: path, to: backup)
        }
        try Data(next.utf8).write(to: path, options: .atomic)
    }

    /// Smoke snapshots only: sample sessions without real agents.
    func seed() {
        let now = Date().timeIntervalSince1970
        apply(AgentEvent(agent: "claude", event: "UserPromptSubmit", session: "seed-1", cwd: "/Users/me/code/web", at: now - 400))
        apply(AgentEvent(agent: "claude", event: "UserPromptSubmit", session: "seed-2", cwd: "/Users/me/code/api", at: now - 60))
        apply(AgentEvent(agent: "claude", event: "Notification", session: "seed-2", cwd: "/Users/me/code/api", message: "Claude needs your permission to use Bash", type: "permission_prompt", at: now - 30))
        apply(AgentEvent(agent: "codex", event: "Stop", session: "seed-3", cwd: "/Users/me/code/infra", at: now - 700))
        board.setTitle("Rate limit the login endpoint", for: "seed-2")
        changed()
    }
}
