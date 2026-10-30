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
    private var t3: T3Watch?
    var consumerT3Health: String { t3?.health ?? "initializing" }
    private let io = DispatchQueue(label: "qnotch.agents.usage", qos: .utility)
    /// Usage readers by session id (touched on `io` only), and today's usage per session on main.
    private var readers: [String: TranscriptUsage] = [:]
    var consumerIdentity: ConsumerIdentity?
    var consumerUsageCache: [String: (days: [String: AgentUsage], checked: Date, available: Bool)] = [:]
    private var reading: Set<String> = []
    private var stale: Set<String> = []
    private(set) var usage: [String: (cwd: String, today: AgentUsage)] = [:]
    private var appTitles: [String: String] = [:]
    private var t3Titles: [String: String] = [:]
    private let codexTitles = CodexTitles()
    private var titlesPending = false

    // MARK: Processes

    private let tracker = ProcessTracker()
    private var cpuSamples: [Int32: (cpu: UInt64, at: TimeInterval)] = [:]
    private(set) var groups: [AgentProcessGroup] = []
    private var walking = false
    private var walkAgain = false
    private var walkTimer: Timer?
    private var burstUntil = Date.distantPast
    private(set) var tabVisible = false

    /// Walks the process tree off the main thread: every 2 s while the Agents tab is on screen,
    /// every second for 10 s after a shell tool starts, and when a tool ends or an agent exits.
    func walk() {
        if walking { walkAgain = true; return }
        walking = true
        let sessions = board.sessions.compactMap { session in session.pid.map { (id: session.id, project: session.name, pid: $0) } }
        let measure = tabVisible
        io.async { [weak self] in
            guard let self else { return }
            let snapshot = ProcessNative.snapshot()
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let found = self.tracker.walk(snapshot, sessions: sessions, now: now) { ProcessTracker.label(ProcessNative.arguments($0)) }
            let uptime = ProcessInfo.processInfo.systemUptime
            let measured = found.map { group -> AgentProcessGroup in
                guard measure else { return AgentProcessGroup(group: group, memory: 0, cpu: nil, ports: []) }
                var memory: UInt64 = 0, cpu: Double = 0, sampled = false
                var ports: [Int] = []
                for member in group.members {
                    guard let usage = ProcessNative.usage(member.pid) else { continue }
                    memory += usage.resident
                    if let last = self.cpuSamples[member.pid], uptime > last.at, usage.cpu >= last.cpu {
                        cpu += Double(usage.cpu - last.cpu) / 1e9 / (uptime - last.at) * 100
                        sampled = true
                    }
                    self.cpuSamples[member.pid] = (usage.cpu, uptime)
                    ports += ProcessNative.listeningPorts(member.pid)
                }
                return AgentProcessGroup(group: group, memory: memory, cpu: sampled ? cpu : nil, ports: Array(Set(ports)).sorted())
            }
            DispatchQueue.main.async {
                self.walking = false
                self.groups = measured
                self.refresh()
                if self.walkAgain { self.walkAgain = false; self.walk() }
                else if self.tabVisible { self.walkLater(2) }
                else if Date() < self.burstUntil { self.walkLater(1) }
            }
        }
    }

    private func walkLater(_ seconds: TimeInterval) {
        walkTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.walk() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        walkTimer = timer
    }

    /// "npm run dev &" outlives its shell, which ends before PostToolUse: note it while the shell runs.
    private func trackTool(_ event: AgentEvent) {
        guard event.tool == "Bash" || event.tool == "shell" || event.tool == "local_shell" else { return }
        if event.event == "PreToolUse" { burstUntil = Date().addingTimeInterval(10); walkLater(0.2) }
        else if event.event == "PostToolUse" { burstUntil = .distantPast; walk() }
    }

    func stopGroup(_ group: AgentProcessGroup) {
        let members = group.group.members
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ProcessNative.stop(members)
            DispatchQueue.main.async { self?.walk() }
        }
    }

    var today: AgentUsage { usage.values.reduce(AgentUsage()) { $0 + $1.today } }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("agents", default: AgentsSettings())
        context.sounds.add("agents.needsyou", title: "Agent needs you", hint: "An agent waits for your answer.", defaultName: "Tink", order: 20)
        context.sounds.add("agents.done", title: "Agent finished", hint: "An agent finished its turn.", defaultName: "Hero", order: 21)
        if !Runtime.diagnostics {
            consumerIdentity = try? ConsumerIdentity(directory: context.settings.directory)
            context.registries.consumers.capture["agents"] = { [weak self] request in
                guard let self, let identity = self.consumerIdentity else { throw ConsumerFailure("identity_unavailable") }
                return try self.consumerAgents(request, identity: identity)
            }
        }
        let registry = context.registries
        registry.tabs.register(ViewContribution(id: "agents", title: "Agents", order: 35, symbol: "sparkles") { [unowned self] in
            let view = AgentsTabView(module: self)
            self.views.add(view)
            view.reload()
            return view
        })
        registry.segments.register(SegmentContribution(id: "agents.pill", order: 6, slot: .trailing, destination: .tab("agents"), destinationLabel: "Open agents") { [weak self] in
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
        DispatchQueue.main.async { [weak self] in
            self?.startServer()
            self?.t3 = T3Watch { sessions, titles in self?.applyT3(sessions, titles: titles) }
        }
        applySounds()
    }

    func setVisibility(panel: Bool, activeTab: String) {
        let visible = panel && activeTab == "agents"
        if visible != tabVisible { tabVisible = visible; if visible { walk() } else { walkTimer?.invalidate(); walkTimer = nil } }
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
        t3?.stop()
        t3 = nil
        exits.values.forEach { $0.cancel() }
        exits.removeAll()
        clock?.invalidate(); clock = nil
        walkTimer?.invalidate(); walkTimer = nil
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
        trackTool(event)
        if let session = board.sessions.first(where: { $0.id == event.session || $0.t3Session == event.session }) { readUsage(session) }
        readTitles()
        changed()
        handle(alert)
    }

    private func applyT3(_ sessions: [T3Session], titles: [String: String]) {
        let before = board
        let alerts = board.applyT3(sessions)
        t3Titles = titles
        applyTitles()
        if board != before { changed() }
        alerts.forEach { handle($0) }
    }

    private func handle(_ alert: AgentBoard.Alert?) {
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

    // MARK: Usage and titles

    /// Every event means the transcript grew: read the new lines 3 s later, so a burst costs one read.
    private func readUsage(_ session: AgentSession) {
        guard session.agent == "claude", let path = session.transcript, !path.isEmpty else { return }
        let id = session.id, cwd = session.cwd
        if reading.contains(id) { stale.insert(id); return }
        reading.insert(id)
        stale.remove(id)
        io.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let reader = self.readers[id] ?? TranscriptUsage()
            self.readers[id] = reader
            reader.read(URL(fileURLWithPath: path))
            let today = reader.today, title = reader.title
            let days = reader.days, available = reader.readComplete
            let checked = Date()
            DispatchQueue.main.async {
                self.consumerUsageCache[id] = (days, checked, available)
                self.reading.remove(id)
                if self.stale.contains(id), let session = self.board.sessions.first(where: { $0.id == id }) { self.readUsage(session) }
                // Past midnight the reader's "today" starts at zero; keeping yesterday's total would show it as today.
                if today.tokens > 0 { self.usage[id] = (cwd, today) } else { self.usage[id] = nil }
                if let title, self.appTitles[id] == nil, self.board.sessions.first(where: { $0.id == id })?.t3Thread == nil {
                    self.board.setTitle(title, for: id)
                }
                self.refresh()
            }
        }
    }

    /// Codex names its threads in one file; T3 titles come with its sessions. One read serves every row.
    private func readTitles() {
        guard !titlesPending else { return }
        titlesPending = true
        let index = (ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)).appendingPathComponent("session_index.jsonl")
        io.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let names = FileManager.default.fileExists(atPath: index.path) ? self.codexTitles.read(index) : [:]
            DispatchQueue.main.async {
                self.titlesPending = false
                self.appTitles = names
                self.applyTitles()
                self.refresh()
            }
        }
    }

    /// T3 Code wins over Codex, both over a Claude Code transcript title.
    private func applyTitles() {
        for session in board.sessions where session.t3Thread == nil {
            if let title = t3Titles[session.id] ?? appTitles[session.id] { board.setTitle(title, for: session.id) }
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
        walk() // what it started now names a dead parent: find it before anything else exits
    }

    // MARK: Commands

    /// Brings the terminal or app the agent runs in forward, then opens the session link if any.
    func show(_ session: AgentSession) {
        if session.t3Thread != nil, let app = NSRunningApplication.runningApplications(withBundleIdentifier: T3Watch.bundleID).first {
            app.activate(options: [.activateAllWindows])
        } else if let pid = session.pid, let app = NotificationsModule.appOwning(pid) { app.activate(options: [.activateAllWindows]) }
        if let link = session.link, AgentEvent.isValidLink(link) || (session.t3Thread != nil && link.hasPrefix("t3code://threads/")),
           let url = URL(string: link) { NSWorkspace.shared.open(url) }
        context.shell?.dismissPanel()
    }

    func dismiss(_ session: AgentSession) {
        board.remove(session.id)
        if (usage[session.id]?.today.tokens ?? 0) == 0 { usage[session.id] = nil }
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
        let before = settings
        change(&settings)
        context.settings.save("agents", settings)
        applySounds()
        if before.showCost != settings.showCost { refresh() }
    }

    // MARK: Connections
    // Static: the welcome tour's Connect row uses them before the module exists.

    static var executable: String { Bundle.main.executablePath ?? "QNotch" }

    /// The default Claude Code folder (or CLAUDE_CONFIG_DIR), every ~/.claude-* folder in use, and Codex.
    static var connections: [Connection] {
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

    static func status(_ connection: Connection) -> AgentHookFile.Status {
        connection.file.status(of: try? String(contentsOf: connection.path, encoding: .utf8))
    }

    /// Backs up the original file (once, before QNotch first touches it) and writes atomically.
    static func setConnected(_ connection: Connection, _ on: Bool) throws {
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
