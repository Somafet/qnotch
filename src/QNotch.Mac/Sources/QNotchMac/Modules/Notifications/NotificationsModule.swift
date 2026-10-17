import AppKit
import Darwin
import QNotchMacCore

/// Lets apps and scripts post notifications to the notch (Windows NotificationsModule): the
/// `QNotch notify` command, a per-user Unix socket, or loopback HTTP with a bearer token.
/// Toasts appear as a peek beside the notch; the unread count sits in the right wing; the
/// Notifications tab keeps the history with action buttons and waiting answers.
/// It does not read other apps' macOS notifications: macOS offers no public API for that.
final class NotificationsModule: NotchModule {
    final class Note {
        let id: String
        let app: String
        let title: String
        let body: String
        let level: NotifyLevel
        let iconSpec: String?
        let created: Date
        var image: NSImage?
        var read = false
        var pending = false
        var status = ""
        var actions: [Action] = []
        var exchange: NotifyExchange?

        init(id: String, app: String, title: String, body: String, level: NotifyLevel, iconSpec: String?, created: Date = Date()) {
            self.id = id; self.app = app; self.title = title; self.body = body; self.level = level; self.iconSpec = iconSpec; self.created = created
        }

        var symbol: String { iconSpec.flatMap { NotifyRules.glyphs[$0.lowercased()] } ?? NotifyRules.levelSymbol(level) }
        var tint: NSColor {
            switch level {
            case .info: return Palette.accent
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }

        /// "Claude Code · 5 min ago · Waiting for your answer"; relative for 30 minutes, then the time.
        func meta(now: Date = Date()) -> String {
            let age = now.timeIntervalSince(created)
            let time: String
            if age >= 0, age < 60 { time = "just now" }
            else if age >= 0, age < 1800 { time = "\(Int(age / 60)) min ago" }
            else { time = (Calendar.current.isDateInToday(created) ? Note.time : Note.dayTime).string(from: created) }
            return status.isEmpty ? "\(app) · \(time)" : "\(app) · \(time) · \(status)"
        }
        private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
        private static let dayTime: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd jmm"); return f }()
    }

    struct Action {
        let id: String
        let label: String
        let url: URL?
        /// The app to bring forward, resolved when the notification arrived (senders exit early).
        let app: NSRunningApplication?
        var answersOnly: Bool { url == nil && app == nil }
    }

    private var context: ModuleContext!
    private(set) var settings = NotificationSettings()
    private(set) var items: [Note] = []
    private var server: NotifyServer?
    private(set) var socketStatus = "Starting"
    private(set) var httpStatus = "Starting"
    private var token: String?
    private var lastToast: [String: Date] = [:]
    private var transient: Note?
    private var toastTask: DispatchWorkItem?
    private var peek: PeekHandle?
    private var peekNote: Note?
    private(set) var quietApps: [String] = []
    private var panelOpen = false
    private var activeTab = ""
    private var autoOpened = false
    private var ages: Timer?
    private var savePending = false
    private let io = DispatchQueue(label: "qnotch.notifications", qos: .utility)
    private let views = NSHashTable<AnyObject>.weakObjects()
    private let bells = NSHashTable<BellSegmentView>.weakObjects()
    static let tokenService = "QNotch/Notify"

    var contextShell: ModuleShell? { context.shell }
    var socketPath: String { context.settings.directory.appendingPathComponent("notify.sock").path }
    private var historyURL: URL { context.settings.directory.appendingPathComponent("notifications.history.json") }
    var unread: Int { items.filter { !$0.read && !settings.isMuted($0.app) }.count }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("notifications", default: NotificationSettings())
        context.sounds.add("notifications.toast", title: "New notification", hint: "A notification arrived (when Play a sound is on).", defaultName: "Ping", order: 10)
        let registry = context.registries
        registry.cards.register(ViewContribution(id: "notifications", title: "Notifications", order: 60, symbol: "bell") { [unowned self] in
            self.track(NotificationsCardView(module: self))
        })
        registry.tabs.register(ViewContribution(id: "notifications", title: "Notifications", order: 50, symbol: "bell") { [unowned self] in
            self.track(NotificationsTabView(module: self))
        })
        registry.segments.register(SegmentContribution(id: "notifications.pill", order: 5, slot: .trailing) { [weak self] in
            let view = BellSegmentView()
            self?.bells.add(view)
            view.update(unread: self?.unread ?? 0)
            return view
        })
        registry.searchSources.register(SearchSource(id: "notifications", order: 40) { [weak self] query in
            guard let self else { return [] }
            return self.items.filter { [$0.title, $0.body, $0.app].contains { $0.localizedCaseInsensitiveContains(query) } }.map { note in
                SearchHit(title: note.title, detail: "\(note.app) · notification", symbol: note.symbol) { [weak self] in self?.context.shell?.selectTab("notifications") }
            }
        })
        registry.settingsSections.register(ViewContribution(id: "notifications", title: "Notifications", order: 60, symbol: "bell.badge.fill", tint: .systemRed) { [weak self] in
            self?.makeSettings() ?? NSView()
        })
        loadHistory()
        // Servers start once the app is idle, like Windows (ApplicationIdle).
        DispatchQueue.main.async { [weak self] in self?.startServers() }
        applyQuiet()
    }

    private func track<V: NSView & NotificationsDisplay>(_ view: V) -> NSView {
        views.add(view)
        view.reload()
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        let opened = panel && !panelOpen
        panelOpen = panel
        self.activeTab = activeTab
        if opened, peekNote != nil { context.shell?.selectTab("notifications") }
        if !panel { autoOpened = false }
        let tabVisible = panel && activeTab == "notifications"
        if tabVisible, ages == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            ages = timer
        } else if !tabVisible { ages?.invalidate(); ages = nil }
        if panel { endPeek() } else { updateToast() }
    }

    func systemDidWake() {}

    func stop() {
        // Waiting senders get their "timeout" reply (exit 2) before the connections go away.
        for note in items where note.pending { close(note, status: "Expired", result: "timeout") }
        server?.stopAll()
        server = nil
        ages?.invalidate(); ages = nil
        toastTask?.cancel()
        endPeek()
        context.capture.remove(self)
        flushHistory()
    }

    // MARK: Servers

    private func startServers() {
        guard context != nil else { return }
        let server = NotifyServer { [weak self] line, exchange in self?.handle(line, exchange: exchange) }
        server.token = { [weak self] in self?.currentToken() ?? "" }
        self.server = server
        try? FileManager.default.createDirectory(at: context.settings.directory, withIntermediateDirectories: true)
        socketStatus = server.startSocket(at: socketPath)
        applyHTTP()
    }

    func applyHTTP() {
        guard let server else { return }
        if settings.httpEnabled { httpStatus = server.startHTTP(port: UInt16(settings.httpPort)) }
        else { server.stop(.http); httpStatus = "Off" }
        refresh()
    }

    /// Read from the Keychain on first use, so a launch never prompts for it.
    func currentToken() -> String {
        if let token { return token }
        let value = Keychain.read(Self.tokenService) ?? {
            let fresh = Keychain.randomToken()
            Keychain.write(fresh, service: Self.tokenService)
            return fresh
        }()
        token = value
        return value
    }

    func renewToken() {
        let fresh = Keychain.randomToken()
        Keychain.write(fresh, service: Self.tokenService)
        token = fresh
    }

    // MARK: Requests (main queue)

    func handle(_ line: Data, exchange: NotifyExchange) {
        let command: NotifyCommand
        do { command = try NotifyRules.parse(line) } catch {
            exchange.answer(NotifyRules.reply(error: (error as? NotifyError)?.message ?? "Bad request."))
            return
        }
        switch command {
        case .dismiss(let id):
            if let note = items.first(where: { $0.id == id }) { dismiss(note) }
            exchange.answer(NotifyRules.reply(ok: id))
        case .notify(let request):
            let note = Note(id: request.id, app: request.app, title: request.title, body: request.body, level: request.level, iconSpec: request.icon)
            note.actions = request.actions.compactMap { spec in
                if let url = spec.url { return Action(id: spec.id, label: spec.label, url: URL(string: url), app: nil) }
                if let pid = spec.focusPid {
                    // Nothing to bring forward: no button (Windows does the same).
                    guard let app = Self.appOwning(pid) else { return nil }
                    return Action(id: spec.id, label: spec.label, url: nil, app: app)
                }
                return Action(id: spec.id, label: spec.label, url: nil, app: nil)
            }
            if request.wait {
                note.pending = true
                note.status = "Waiting for your answer"
                note.exchange = exchange
                exchange.gone = { [weak self, weak note] in
                    guard let self, let note else { return }
                    self.close(note, status: "Sender stopped waiting", result: nil)
                }
                if let timeout = request.timeout {
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak note] in
                        guard let self, let note, note.pending else { return }
                        self.close(note, status: "Timed out", result: "timeout")
                    }
                }
            } else {
                exchange.answer(NotifyRules.reply(ok: note.id))
            }
            post(note, ttl: request.ttl)
            loadIcon(note)
        }
    }

    /// The nearest app (a process with a Dock presence) at or above `pid`, at most 8 parents up.
    static func appOwning(_ pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
            current = Int32(info.pbi_ppid)
        }
        return nil
    }

    private func loadIcon(_ note: Note) {
        guard let spec = note.iconSpec, NotifyRules.glyphs[spec.lowercased()] == nil else { return }
        io.async { [weak self, weak note] in
            let path = (spec as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return }
            var image: NSImage?
            if path.hasSuffix(".app") { image = NSWorkspace.shared.icon(forFile: path) }
            else if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= 4 << 20 {
                image = NSImage(contentsOfFile: path)
            }
            guard let image else { return }
            image.size = NSSize(width: 32, height: 32)
            DispatchQueue.main.async {
                note?.image = image
                self?.refresh()
            }
        }
    }

    // MARK: History

    private func post(_ note: Note, ttl: Double?) {
        if let old = items.first(where: { $0.id == note.id }) {
            close(old, status: "", result: "dismissed")
            items.removeAll { $0 === old }
            if transient === old { transient = nil }
        }
        let muted = settings.isMuted(note.app)
        note.read = muted || (panelOpen && activeTab == "notifications" && !autoOpened)
        items.insert(note, at: 0)
        prune()
        changed()
        let quiet = muted || !quietApps.isEmpty
        if !quiet { toast(note, ttl: ttl) }
        updateToast()
        guard !quiet, note.level == .error, settings.openOnError, !panelOpen else { return }
        // An error opens the panel. It stays unread until the pointer reaches the list.
        autoOpened = true
        if context.shell?.tryOpenPanel(tab: "notifications", linger: min(60, max(5, ttl ?? Double(settings.toastSeconds)))) != true { autoOpened = false }
    }

    private func toast(_ note: Note, ttl: Double?) {
        if note.pending { transient = nil; toastTask?.cancel(); return } // stays up until answered
        let seconds = min(60, max(0, ttl ?? Double(settings.toastSeconds)))
        let now = Date()
        // One toast per app per second; the rest of a burst goes straight to the history.
        if seconds <= 0 || (lastToast[note.app].map { now.timeIntervalSince($0) < 1 } ?? false) && peekNote?.id != note.id { return }
        if lastToast.count > 64 { lastToast.removeAll() }
        lastToast[note.app] = now
        transient = note
        if settings.sound { context.sounds.play("notifications.toast") }
        toastTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.transient = nil
            self?.updateToast()
        }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    /// A notification waiting for an answer shows even during a call: someone is blocked on it.
    private func updateToast() {
        let shown = transient ?? items.first { $0.pending && !settings.isMuted($0.app) }
        guard shown !== peekNote || (shown != nil && peek?.ended == true) else { return }
        endPeek()
        guard let shown, !panelOpen else { return }
        peekNote = shown
        peek = context.shell?.peek(symbol: shown.symbol, tint: shown.tint, leading: shown.app, trailing: shown.title, seconds: nil)
        if peek == nil { peekNote = nil }
    }

    private func endPeek() {
        peek?.end()
        peek = nil
        peekNote = nil
    }

    /// Ends a wait: the sender gets `result` (unless it already left) and answer-only buttons go away.
    private func close(_ note: Note, status: String, result: String?, action: String? = nil) {
        guard note.pending else { return }
        var delivered = true
        if let exchange = note.exchange {
            if let result, !exchange.isAnswered { exchange.answer(NotifyRules.reply(ok: note.id, result: result, action: action)) }
            else if result != nil { delivered = false }
        }
        note.exchange = nil
        note.pending = false
        note.status = delivered ? status : "Expired"
        note.actions.removeAll { $0.answersOnly }
        changed()
        updateToast()
    }

    func invoke(_ action: Action, on note: Note) {
        if let url = action.url { NSWorkspace.shared.open(url) }
        else if let app = action.app, !app.isTerminated { app.activate(options: [.activateAllWindows]) }
        close(note, status: "Answered: \(action.label)", result: "clicked", action: action.id)
        note.read = true
        if transient === note { transient = nil }
        changed()
        updateToast()
        if !action.answersOnly { context.shell?.closePanel() }
    }

    func dismiss(_ note: Note) {
        close(note, status: "", result: "dismissed")
        items.removeAll { $0 === note }
        if transient === note { transient = nil }
        changed()
        updateToast()
    }

    /// Clears the history; notifications still waiting for an answer stay.
    func clear() {
        items.removeAll { !$0.pending }
        transient = nil
        changed()
        updateToast()
    }

    /// The pointer reached the list: everything shown counts as read.
    func seen() {
        guard items.contains(where: { !$0.read }) else { return }
        items.forEach { $0.read = true }
        changed()
    }

    func sendTest() {
        post(Note(id: "qnotch-test", app: "QNotch", title: "Test notification", body: "This is what a notification looks like.", level: .info, iconSpec: "bell"), ttl: nil)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(max(1, settings.retentionDays)) * 86_400)
        items.removeAll { !$0.pending && $0.created < cutoff }
        while items.count > NotifyRules.maxItems, let index = items.lastIndex(where: { !$0.pending }) { items.remove(at: index) }
    }

    private func changed() {
        refresh()
        let count = unread
        bells.allObjects.forEach { $0.update(unread: count) }
        context.shell?.segmentsChanged()
        scheduleSave()
    }

    func refresh() { for case let view as NotificationsDisplay in views.allObjects { view.reload() } }

    // MARK: Quiet during calls

    func applyQuiet() {
        if settings.quietDuringCalls {
            context.capture.observe(self) { [weak self] state in
                guard let self else { return }
                self.quietApps = state.microphone ? (state.microphoneApps.isEmpty ? ["An app"] : state.microphoneApps) : []
                if !self.quietApps.isEmpty { self.transient = nil; self.toastTask?.cancel() }
                self.updateToast()
                self.refresh()
            }
        } else {
            context.capture.remove(self)
            quietApps = []
        }
    }

    var quietStatus: String {
        guard !quietApps.isEmpty else { return "" }
        return "Quiet now: \(quietApps.joined(separator: ", ")) \(quietApps.count == 1 ? "is" : "are") using the microphone."
    }

    // MARK: Settings and persistence

    func set(_ change: (inout NotificationSettings) -> Void) {
        let before = settings
        change(&settings)
        context.settings.save("notifications", settings)
        if before.quietDuringCalls != settings.quietDuringCalls { applyQuiet() }
        if before.httpEnabled != settings.httpEnabled || before.httpPort != settings.httpPort { applyHTTP() }
        if before.retentionDays != settings.retentionDays { prune() }
        changed()
    }

    private struct Saved: Codable {
        struct Item: Codable {
            var id, app, title, body: String
            var icon: String?
            var level: NotifyLevel
            var created: Date
            var read: Bool
            var status: String
            var pending: Bool
            var links: [Link]
        }
        struct Link: Codable { var id, label, url: String }
        var items: [Item]
    }

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        // One write per burst.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushHistory() }
    }

    private func flushHistory() {
        savePending = false
        guard context != nil else { return }
        let saved = Saved(items: items.map { note in
            Saved.Item(id: note.id, app: note.app, title: note.title, body: note.body, icon: note.iconSpec, level: note.level, created: note.created,
                       read: note.read, status: note.status, pending: note.pending,
                       links: note.actions.compactMap { action in action.url.map { Saved.Link(id: action.id, label: action.label, url: $0.absoluteString) } })
        })
        let url = historyURL, directory = context.settings.directory
        io.async {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL), data.count < 8 << 20,
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        items = saved.items.prefix(NotifyRules.maxItems).map { item in
            let note = Note(id: item.id, app: item.app, title: item.title, body: item.body, level: item.level, iconSpec: item.icon, created: item.created)
            note.read = item.read
            // Senders and windows do not survive a restart.
            note.status = item.pending ? "Expired" : item.status
            note.actions = item.links.compactMap { link in URL(string: link.url).map { Action(id: link.id, label: link.label, url: $0, app: nil) } }
            loadIcon(note)
            return note
        }
        prune()
    }
}
