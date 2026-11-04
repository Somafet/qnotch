import AppKit
import QNotchMacCore

/// Send files to your own devices with Tailscale's Taildrop (Windows TaildropModule).
///
/// Transport: the local Tailscale service's LocalAPI, spoken directly (HTTP/1.0 over one short
/// connection per request, see `TaildropClient`), never the CLI. The standalone app publishes a
/// loopback port and a same-user key in `/Library/Tailscale`, and the open-source daemon a Unix
/// socket; both are documented, file-based and need no private API, prompt or sandbox escape.
/// The LocalAPI also gives what the CLI's text output lacks: stable ids, the OS, online state and
/// byte-level upload progress. The Mac App Store edition only exposes its LocalAPI inside its own
/// sandbox, so QNotch shows an explicit state for it instead of scraping `lsof` like the CLI does.
///
/// Endpoints: `status?peers=false` (BackendState), `file-targets` (your devices, offline ones
/// included), `file-put/<id>/<name>` (streamed PUT) and the waiting inbox `files/` (GET, then
/// `files/<name>` GET and DELETE to save into Downloads; never overwrites). The standalone app
/// usually saves received files to Downloads itself, so the inbox stays empty (`null`) there and
/// its banner never shows; with the open-source daemon files wait until saved.
///
/// Work only while visible: one refresh when the panel shows the Taildrop tab or a visible Home
/// card, then a one-shot refresh 10 seconds after each finished one while it stays visible.
/// Nothing runs collapsed. Diagnostic runs use generic demo data and touch no socket.
final class TaildropModule: NotchModule {
    static let refreshInterval: TimeInterval = 10

    private var context: ModuleContext!
    private(set) var state = TaildropState()
    private(set) var transfer: TaildropTransfer?
    private(set) var result: TaildropResult?
    private(set) var refreshing = false
    private(set) var saving = false
    private var visible = false
    private var lastRefresh: Date?
    private var nextRefresh: DispatchWorkItem?
    private var resultTask: DispatchWorkItem?
    private var cancellation: TaildropCancellation?
    private let io = DispatchQueue(label: "qnotch.taildrop", qos: .utility)
    private let sending = DispatchQueue(label: "qnotch.taildrop.send", qos: .userInitiated)
    private let views = NSHashTable<AnyObject>.weakObjects()
    var contextShell: ModuleShell? { context.shell }

    func initialize(_ context: ModuleContext) {
        self.context = context
        context.registries.cards.register(ViewContribution(id: "taildrop", title: "Taildrop", order: 85, symbol: "paperplane") { [unowned self] in
            self.track(TaildropCardView(module: self))
        })
        context.registries.tabs.register(ViewContribution(id: "taildrop", title: "Taildrop", order: 45, symbol: "paperplane") { [unowned self] in
            self.track(TaildropTabView(module: self))
        })
        context.registries.searchSources.register(SearchSource(id: "taildrop", order: 25) { [weak self] query in
            guard let self, self.state.availability == .ready else { return [] }
            return self.state.targets.filter { $0.name.localizedCaseInsensitiveContains(query) }.map { target in
                SearchHit(title: target.name, detail: "Taildrop · " + (target.online ? "send files" : "offline"), symbol: target.symbol) { [weak self] in
                    self?.context.shell?.selectTab("taildrop")
                }
            }
        })
        if Runtime.diagnostics { state = .demo }
    }

    private func track<V: NSView & TaildropDisplay>(_ view: V) -> NSView {
        views.add(view)
        view.reload()
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        guard panel != visible else { return }
        visible = panel
        if panel {
            let due = lastRefresh.map { Self.refreshInterval - Date().timeIntervalSince($0) } ?? 0
            if due <= 0 { refresh() } else { schedule(after: due) }
        } else {
            nextRefresh?.cancel()
            nextRefresh = nil
        }
    }
    func systemDidWake() { lastRefresh = nil; if visible { refresh() } }
    func stop() {
        nextRefresh?.cancel()
        resultTask?.cancel()
        cancellation?.cancel()
    }

    func refreshViews() { for case let view as TaildropDisplay in views.allObjects { view.reload() } }

    // MARK: Refresh

    /// One probe off the main thread; the next one is scheduled only while still visible.
    func refresh() {
        nextRefresh?.cancel()
        nextRefresh = nil
        guard !Runtime.diagnostics, !refreshing else { return }
        refreshing = true
        let previous = state
        io.async { [weak self] in
            let next = Self.probe(previous: previous)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.lastRefresh = Date()
                if self.state.update(to: next) { self.refreshViews() }
                if self.visible { self.schedule(after: Self.refreshInterval) }
            }
        }
    }

    private func schedule(after delay: TimeInterval) {
        nextRefresh?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.refresh() }
        nextRefresh = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Reads status, targets and the inbox. A failure keeps the previous list and reports why.
    static func probe(previous: TaildropState, discover: () -> TaildropDiscovery.Outcome = { TaildropDiscovery.discover() }) -> TaildropState {
        let endpoint: TaildropEndpoint
        switch discover() {
        case .endpoint(let found): endpoint = found
        case .notInstalled: return TaildropState(availability: .notInstalled)
        case .notRunning: return TaildropState(availability: .notRunning)
        case .appStoreEdition: return TaildropState(availability: .appStoreEdition)
        case .noAccess: return TaildropState(availability: .noAccess)
        }
        let client = TaildropClient(endpoint: endpoint)
        let backend: TaildropBackend
        do {
            backend = try TaildropJSON.backend(from: client.get("status?peers=false"))
        } catch TaildropError.notRunning {
            return TaildropState(availability: .notRunning)
        } catch TaildropError.noAccess, TaildropError.http(403, _) {
            return TaildropState(availability: .noAccess)
        } catch {
            return failed(previous, error)
        }
        guard backend == .running else { return TaildropState(availability: TaildropAvailability(backend)) }
        var next = TaildropState(availability: .ready)
        do {
            next.targets = try TaildropJSON.targets(from: client.get("file-targets"))
        } catch {
            return failed(previous, error)
        }
        // Harmless when empty or unsupported (the standalone app saves files itself).
        next.waiting = (try? TaildropJSON.waiting(from: client.get("files/"))) ?? []
        return next
    }

    private static func failed(_ previous: TaildropState, _ error: Error) -> TaildropState {
        var kept = previous
        if kept.availability == .checking { kept.availability = .ready }
        kept.message = "Couldn't refresh: " + error.localizedDescription
        return kept
    }

    // MARK: Sending

    /// Sends `urls` to `target`, one file after another. Folders are skipped: Taildrop sends files.
    func send(_ urls: [URL], to target: TaildropTarget) {
        guard transfer == nil, target.online, state.availability == .ready else { return }
        var files: [(url: URL, size: Int64)] = []
        var folders = 0
        for url in urls {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue { folders += 1; continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            files.append((url, size))
        }
        guard !files.isEmpty else { return finish(folders > 0 ? .foldersOnly : TaildropResult(text: "Nothing to send", success: false), peek: false) }
        guard !Runtime.diagnostics, case .endpoint(let endpoint) = TaildropDiscovery.discover() else {
            return finish(TaildropResult(text: Runtime.diagnostics ? "Demo: nothing was sent" : "Tailscale is not reachable", success: false), peek: false)
        }
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        let cancel = TaildropCancellation()
        cancellation = cancel
        resultTask?.cancel()
        result = nil
        transfer = TaildropTransfer(deviceID: target.id, deviceName: target.name, fileName: files[0].url.lastPathComponent,
                                    index: 1, count: files.count, fraction: 0)
        refreshViews()
        sending.async { [weak self] in
            let client = TaildropClient(endpoint: endpoint)
            var done: Int64 = 0
            var shownPercent = -1
            var outcome = TaildropResult.sent(files.count, firstName: files[0].url.lastPathComponent, to: target.name, skippedFolders: folders)
            for (index, file) in files.enumerated() {
                let name = file.url.lastPathComponent
                DispatchQueue.main.async { self?.transfer?.fileName = name; self?.transfer?.index = index + 1; self?.refreshViews() }
                do {
                    let path = "file-put/\(TaildropNames.pathEscape(target.id))/\(TaildropNames.pathEscape(name))"
                    try client.put(path, file: file.url, length: file.size, cancel: cancel) { sent in
                        let fraction = Double(done + sent) / Double(total)
                        let percent = Int(fraction * 100)
                        guard percent != shownPercent else { return }
                        shownPercent = percent
                        DispatchQueue.main.async { self?.transfer?.fraction = fraction; self?.refreshViews() }
                    }
                    done += file.size
                } catch {
                    outcome = cancel.isCancelled
                        ? TaildropResult(text: index == 0 ? "Sending cancelled" : "Cancelled after \(index) of \(files.count) files", success: false)
                        : .failed(name, to: target.name, sent: index, count: files.count, reason: error.localizedDescription)
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.transfer = nil
                self.cancellation = nil
                self.finish(outcome, peek: !cancel.isCancelled)
            }
        }
    }

    func cancelSend() { cancellation?.cancel() }

    /// Chooses files for `target` with the system panel; the notch stays open meanwhile.
    func chooseFiles(for target: TaildropTarget) {
        guard transfer == nil, target.online else { return }
        let hold = context.shell?.holdOpen()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(target.name) with Taildrop."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            _ = hold
            if response == .OK { self?.send(panel.urls, to: target) }
        }
    }

    // MARK: Inbox

    /// Moves every waiting file into Downloads under a free name, then removes it from the inbox.
    func saveWaiting() {
        guard !saving, !state.waiting.isEmpty else { return }
        guard !Runtime.diagnostics, case .endpoint(let endpoint) = TaildropDiscovery.discover() else {
            return finish(TaildropResult(text: Runtime.diagnostics ? "Demo: nothing was saved" : "Tailscale is not reachable", success: false), peek: false)
        }
        saving = true
        refreshViews()
        let waiting = state.waiting
        io.async { [weak self] in
            let client = TaildropClient(endpoint: endpoint)
            var saved: [URL] = []
            var failure: String?
            for file in waiting {
                do { saved.append(try Self.save(file, client: client)) } catch {
                    failure = "Couldn't save \(file.name): \(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.saving = false
                if let failure {
                    self.finish(TaildropResult(text: failure, success: false), peek: false)
                } else {
                    let what = saved.count == 1 ? saved[0].lastPathComponent : "\(saved.count) files"
                    self.finish(TaildropResult(text: "Saved \(what) to Downloads", success: true, reveal: saved.last), peek: false)
                }
                self.refresh()
            }
        }
    }

    private static func save(_ file: TaildropWaitingFile, client: TaildropClient) throws -> URL {
        guard TaildropNames.isSafeInboxName(file.name) else { throw TaildropError.io("unsafe file name") }
        let files = FileManager.default
        let downloads = try files.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let partial = downloads.appendingPathComponent(".qnotch-taildrop-\(UUID().uuidString).partial")
        guard files.createFile(atPath: partial.path, contents: nil), let handle = try? FileHandle(forWritingTo: partial) else {
            throw TaildropError.io("Downloads can't be written")
        }
        do {
            try client.download("files/" + TaildropNames.pathEscape(file.name), into: handle, cancel: TaildropCancellation())
            try handle.close()
        } catch {
            try? handle.close()
            try? files.removeItem(at: partial)
            throw error
        }
        // moveItem never replaces; a name taken in between moves on to the next free one.
        for _ in 0..<20 {
            let name = TaildropNames.freeName(file.name) { files.fileExists(atPath: downloads.appendingPathComponent($0).path) }
            let destination = downloads.appendingPathComponent(name)
            do {
                try files.moveItem(at: partial, to: destination)
                try? client.delete("files/" + TaildropNames.pathEscape(file.name))
                return destination
            } catch CocoaError.fileWriteFileExists { continue }
        }
        try? files.removeItem(at: partial)
        throw TaildropError.io("no free name in Downloads")
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Results and actions

    private func finish(_ outcome: TaildropResult, peek: Bool) {
        result = outcome
        resultTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.result = nil; self?.refreshViews() }
        resultTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: task)
        refreshViews()
        // Shown only while collapsed; the shell drops peeks while the panel is open.
        if peek {
            _ = context.shell?.peek(symbol: outcome.success ? "paperplane.fill" : "exclamationmark.triangle.fill",
                                    tint: outcome.success ? .systemGreen : .systemRed, leading: "Taildrop",
                                    trailing: outcome.success ? outcome.text : "Send failed", seconds: 4)
        }
    }

    func perform(_ action: TaildropAvailability.Action) {
        switch action {
        case .openApp:
            if let app = TaildropDiscovery.appURL {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                context.shell?.dismissPanel()
            } else {
                NSWorkspace.shared.open(Self.downloadPage)
            }
        case .download:
            NSWorkspace.shared.open(Self.downloadPage)
            context.shell?.dismissPanel()
        }
    }

    static let downloadPage = URL(string: "https://tailscale.com/download/mac")!

    // MARK: Diagnostics

    /// Snapshot states: a send at 45%, a finished send, a failure, or a fresh demo state.
    func showDemo(_ state: TaildropState, transfer: TaildropTransfer? = nil, result: TaildropResult? = nil) {
        precondition(Runtime.diagnostics)
        self.state = state
        self.transfer = transfer
        self.result = result
        refreshViews()
    }
}
