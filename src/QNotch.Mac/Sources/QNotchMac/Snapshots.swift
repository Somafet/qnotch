import AppKit
import QNotchMacCore

/// One `--snapshot` or `--smoke-test` run (spec/diagnostics.md): the views it writes (a PNG at 2x
/// and an outline each), the checks it reports, and its report file.
final class SnapshotRun {
    let shell: ShellController
    let output: URL
    let options: DiagnosticOptions
    /// Smoke runs read every view's outline for the accessible-names check, also of views `--only` leaves out.
    let readsAllOutlines: Bool
    private(set) var lines: [String] = []
    private(set) var outlines: [(name: String, text: String)] = []
    var failed: Bool { lines.contains { $0.hasPrefix("FAILED") } }

    init(shell: ShellController, output: URL, options: DiagnosticOptions, readsAllOutlines: Bool) {
        self.shell = shell
        self.output = output
        self.options = options
        self.readsAllOutlines = readsAllOutlines
    }

    /// Whether any of these views is written or read.
    func wants(_ names: [String]) -> Bool { readsAllOutlines || names.contains(where: options.includes) }

    /// Writes `<name>.png` and `<name>.txt` when `--only` includes the view. A failure is reported
    /// and the run goes on.
    func write(_ name: String, _ view: NSView?, background: NSColor? = nil, missing: String = "nothing to render") {
        let included = options.includes(name)
        guard included || readsAllOutlines else { return }
        guard let view else { return fail(name, missing) }
        view.layoutSubtreeIfNeeded()
        let text = Outline.text(for: view)
        outlines.append((name, text))
        guard included else { return }
        let image: CGImage
        do { image = try ShellController.image(of: view, background: background) } catch { return fail(name, error.localizedDescription) }
        lines.append("\(name): ok")
        // Drawing needs the main thread; encoding and writing do not. `finish` waits for them.
        let url = output.appendingPathComponent(name + ".png")
        DispatchQueue.global(qos: .userInitiated).async(group: encoding) { [self] in
            do {
                try ShellController.png(image).write(to: url)
                try Data(text.utf8).write(to: url.deletingPathExtension().appendingPathExtension("txt"))
            } catch {
                lock.lock(); encodingFailures.append("FAILED: \(name): " + error.localizedDescription); lock.unlock()
            }
        }
    }
    private let encoding = DispatchGroup()
    private let lock = NSLock()
    private var encodingFailures: [String] = []

    /// The notch window as it is now.
    func notch(_ name: String) { write(name, shell.panel.contentView) }

    /// Other diagnostic text, as `<name>.log` (every `.txt` but the report is an outline).
    func log(_ name: String, _ lines: [String]) {
        try? Data(lines.map { $0 + "\n" }.joined().utf8).write(to: output.appendingPathComponent(name + ".log"))
    }

    func pass(_ check: String) { lines.append("check \(check): ok") }
    func skip(_ check: String, _ reason: String) { lines.append("check \(check): skip: \(reason)") }
    func fail(_ name: String, _ message: String) { lines.append("FAILED: \(name): " + message.replacingOccurrences(of: "\n", with: " ")) }

    /// Writes the report: `version`, `only` under `--only`, the entries, `extra`, and `done` when
    /// nothing failed. Returns whether it passed.
    @discardableResult
    func finish(_ file: String, extra: [String] = []) -> Bool {
        encoding.wait()
        lines += encodingFailures
        encodingFailures = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        var report = ["version: \(version)"] + (options.only.isEmpty ? [] : ["only: " + options.only.joined(separator: ",")]) + lines + extra
        if !failed { report.append("done") }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(report.map { $0 + "\n" }.joined().utf8).write(to: output.appendingPathComponent(file))
        } catch {
            fputs("Unable to write \(file): \(error.localizedDescription)\n", stderr)
            return false
        }
        return !failed
    }
}

/// Every view in the contract's file table, rendered from the running shell with demo data:
/// shared by `--snapshot` and `--smoke-test`. Synchronous, so no click or timer moves anything in
/// between. Leaves the panel collapsed on Home, without the demo agents.
enum SnapshotViews {
    static func render(_ run: SnapshotRun) {
        let shell = run.shell
        shell.updateGeneral { $0.reduceMotion = true; $0.setEnabled("terminal", true) }
        shell.module(ColorPickerModule.self)?.seedRecent(["#3CC8D9", "#4CD98C", "#FFB54D", "#FF7A6B", "#B07CFF", "#5B9DFF"])
        shell.module(StatsModule.self)?.sampleNow()
        shell.close(restoreFocus: false)

        // The collapsed notch, idle and in each state.
        run.notch("pill")
        shell.gameMode.override = .on
        run.notch("pill-game")
        shell.gameMode.override = .auto
        if let capture = shell.module(CaptureModule.self) {
            let real = capture.state
            capture.apply(CaptureState(microphone: true, microphoneApps: ["FaceTime"], camera: true))
            run.notch("pill-capture")
            capture.apply(real)
        }
        if let timer = shell.module(TimerModule.self) {
            timer.startShortTimer(seconds: 25 * 60)
            run.notch("pill-running")
            timer.reset()
        }
        if let notifications = shell.module(NotificationsModule.self) {
            // The same requests the socket takes; nobody waits for the answers.
            func post(_ json: String) { notifications.handle(Data(json.utf8), exchange: NotifyExchange { _ in }) }
            post(#"{"id":"demo-build","title":"Build finished","body":"All 42 tests passed.","app":"Xcode Cloud","level":"success"}"#)
            run.notch("pill-peek")
            post(#"{"id":"demo-question","title":"Run the migration?","body":"3 pending migrations in api","app":"Claude Code","icon":"chat","wait":true,"actions":[{"id":"yes","label":"Approve"},{"id":"no","label":"Deny"}]}"#)
            run.notch("pill-waiting")
            notifications.toggleMute()
            run.notch("notifications-muted")
            shell.open(keyboard: false)
            shell.selectTab("notifications")
            run.notch("tab-notifications-muted")
            shell.selectTab("home")
            run.notch("tab-home-muted")
            run.write("notifications-muted-card", cardViews(shell)["notifications"], missing: "Notifications card unavailable")
            shell.close(restoreFocus: false)
            notifications.toggleMute()
            // The waiting one replaced the first toast; answered, no toast is left. The last shows none.
            if let note = notifications.items.first(where: { $0.pending }), let approve = note.actions.first { notifications.invoke(approve, on: note) }
            post(#"{"id":"demo-backup","title":"Backup failed","body":"The disk Archive is full.","app":"Time Machine","level":"warning","ttl":0,"actions":[{"label":"Open log","url":"https://example.com"}]}"#)
        }
        if let agents = shell.module(AgentsModule.self) {
            agents.seed()
            shell.endPeek()
            run.notch("pill-agent")
        }

        // The open panel: Home, its edit mode and cards, then every tab.
        seedSamples(shell)
        shell.open(keyboard: false)
        shell.selectTab("home")
        shell.module(StatsModule.self)?.sampleNow()
        run.notch("tab-home")
        shell.setEditing(true)
        run.notch("tab-home-edit")
        shell.setEditing(false)
        let cards = cardViews(shell)
        for card in shell.registries.cards.items { run.write("card-" + card.id, cards[card.id], missing: "the card is not on Home") }
        let originalSizes = shell.general.cardSizes
        shell.updateGeneral { settings in
            for card in shell.registries.cards.items { settings.cardSizes[card.id] = HomeCardSize.small.rawValue }
        }
        run.notch("tab-home-small")
        shell.setEditing(true)
        run.notch("tab-home-small-edit")
        shell.setEditing(false)
        let smallCards = cardViews(shell)
        for card in shell.registries.cards.items { run.write("card-" + card.id + "-small", smallCards[card.id], missing: "the Small card is not on Home") }
        shell.updateGeneral { $0.cardSizes = originalSizes }
        if let tray = shell.module(FileTrayModule.self) {
            shell.selectTab("files")
            tray.dropActive = true
            tray.reloadNow()
            run.notch("files-drop")
            tray.dropActive = false
            addSampleFiles(shell, to: tray)
        }
        var headerFrames: [String] = ["Native AppKit points; page/header/body use bottom-left origins; title/actions are relative to header."]
        var headerBaseline: CGFloat?
        for tab in shell.registries.tabs.items {
            shell.selectTab(tab.id)
            run.notch("tab-" + tab.id)
            if tab.id == "search" {
                if (shell.currentBody as? SearchView)?.field.accessibilityLabel() != "Search QNotch" {
                    run.fail("tab-headers", "Search must retain its labeled field landmark")
                }
            } else {
                headerFrames += TabHeaderDiagnostics.check(run, id: tab.id, title: tab.title, baseline: &headerBaseline)
            }
        }
        if let media = shell.module(MediaModule.self) {
            media.clearForSmoke()
            shell.selectTab("media")
            run.notch("media-empty")
            headerFrames += TabHeaderDiagnostics.check(run, id: "media-empty", title: "Media", baseline: &headerBaseline)
            shell.selectTab("home")
            run.write("media-empty-card", cardViews(shell)["media"], missing: "the card is not on Home")
        }
        run.log("tab-header-frames", headerFrames)
        if !run.failed { run.pass("tab-headers") }
        shell.selectTab("home")
        shell.close(restoreFocus: false)
        // A non-notched external display, even when the developer only has a notched laptop.
        shell.withDiagnosticLayout(virtualDisplay) {
            run.notch("placement-virtual")
            shell.open(keyboard: false)
            run.notch("placement-virtual-open")
            shell.close(restoreFocus: false)
        }
        if let agents = shell.module(AgentsModule.self) {
            for session in agents.board.sessions where session.id.hasPrefix("seed-") { agents.dismiss(session) }
        }

        // Real destination routing, including the transient hidden-card surface, rendered offscreen.
        do { try HoverTargetSmoke.check(run) }
        catch { run.fail("hover-targets", "\(error)") }

        // Settings and the welcome tour, without showing their windows.
        let settings = shell.makeSettings()
        if run.wants(settings.snapshotNames) {
            settings.snapshotPages({ run.write($0, $1, background: .windowBackgroundColor) }, problem: run.fail)
        }
        if run.wants(Onboarding.Step.allCases.map { "onboarding-" + $0.rawValue }) {
            let tour = OnboardingController(shell: shell, firstRun: false, isolated: true)
            while true {
                run.write("onboarding-" + tour.step.rawValue, tour.window.contentView, background: Palette.surface)
                guard tour.step != .finish, tour.index + 1 < tour.steps.count else { break }
                tour.advance()
            }
            tour.window.close()
        }
    }

    static var virtualDisplay: DisplayLayout {
        DisplayLayout(frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                      visibleFrame: CGRect(x: -1920, y: -100, width: 1920, height: 1055), safeTop: 0, cameraGap: nil)
    }

    /// Home's card views by card id (cards past the first rows are scrolled out of tab-home).
    static func cardViews(_ shell: ShellController) -> [String: NSView] {
        var found: [String: NSView] = [:]
        func walk(_ view: NSView) {
            if let id = view.identifier?.rawValue, id.hasPrefix("card-") { found[String(id.dropFirst(5))] = view }
            view.subviews.forEach(walk)
        }
        shell.panel.contentView.map(walk)
        return found
    }

    /// Sample clipboard entries through a private pasteboard: the user's clipboard is never read
    /// or written. The concealed one must be skipped.
    static let clipboardSamples: [(text: String, concealed: Bool)] = [("hunter2", true), ("Remember the milk", false),
        ("func greet() {\n    print(\"Hello\")\n}", false), ("https://github.com/Somafet/qnotch", false)]

    private static func seedSamples(_ shell: ShellController) {
        guard let clipboard = shell.module(ClipboardModule.self) else { return }
        let board = NSPasteboard(name: NSPasteboard.Name("dev.qnotch.diagnostics.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        for sample in clipboardSamples {
            board.clearContents()
            board.setString(sample.text, forType: .string)
            if sample.concealed { board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
            clipboard.capture(board)
        }
    }

    static let sampleFiles = ["Quarterly report.pdf", "Notes.txt", "Screenshot.png", "Archive.zip", "Budget.numbers"]

    /// Sample files in the data root, the last one deleted again so the tray shows a missing file.
    private static func addSampleFiles(_ shell: ShellController, to tray: FileTrayModule) {
        let folder = shell.store.directory.appendingPathComponent("tray-sample", isDirectory: true)
        let files = sampleFiles.map { folder.appendingPathComponent($0) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try? Data("QNotch sample".utf8).write(to: file) }
        tray.add(files)
        try? FileManager.default.removeItem(at: files[files.count - 1])
        tray.setVisibility(panel: false, activeTab: "files"); tray.setVisibility(panel: true, activeTab: "files")
        tray.reloadNow()
    }
}

/// `--snapshot <dir>`: renders every view, writes `snapshot.txt` and quits; exit 0 when it ends in `done`.
enum NativeSnapshot {
    static func run(shell: ShellController, output: URL, options: DiagnosticOptions) {
        DispatchQueue.main.async {
            let run = SnapshotRun(shell: shell, output: output, options: options, readsAllOutlines: false)
            do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) } catch {
                fputs("Unable to create \(output.path): \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            if shell.layout == nil { run.fail("pill", "no display to place the notch on") } else { SnapshotViews.render(run) }
            if run.finish("snapshot.txt") { NSApp.terminate(nil) } else { shell.stop(); exit(1) }
        }
    }
}
