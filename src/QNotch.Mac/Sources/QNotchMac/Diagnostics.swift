import AppKit
import QNotchMacCore
import Darwin

enum NativeSmokeTest {
    /// A locked screen (loginwindow in front) never grants another app's window the keyboard.
    /// The shell's own keyboard state is still checked; only the window server's key status is not.
    static var screenLocked: Bool {
        ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool) == true
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    }

    /// `options.only` is parsed but not applied yet: the smoke run writes every view.
    static func run(shell: ShellController, output: URL, ready: TimeInterval, options: DiagnosticOptions) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                guard let layout = shell.layout else { throw Failure("No display available for native UI validation") }
                let placement = "camera_housing=\(layout.hasCameraHousing)\nintegrated=\(layout.integratesCameraHousing)\nsafe_top_points=\(layout.safeTop)\ndisplay_frame=\(layout.frame)\ncollapsed_idle_frame=\(layout.surface(expanded: false))\ncollapsed_status_frame=\(layout.surface(expanded: false, wing: 56))\nexpanded_frame=\(layout.surface(expanded: true))\npanel_body=\(layout.panelBody)\n"
                try Data(placement.utf8).write(to: output.appendingPathComponent("placement.txt"))
                shell.updateGeneral { $0.reduceMotion = true }
                shell.modules.lazy.compactMap({ $0 as? ColorPickerModule }).first?.seedRecent(["#3CC8D9", "#4CD98C", "#FFB54D", "#FF7A6B", "#B07CFF", "#5B9DFF"])
                try checkPlacement(shell: shell, layout: layout)
                try shell.snapshot(to: output.appendingPathComponent("pill.png"))
                shell.gameMode.override = .on
                shell.open(keyboard: false)
                guard shell.gameActive, !shell.state.expanded, shell.panel.ignoresMouseEvents,
                      shell.peek(symbol: "bell", tint: .white, leading: "x", trailing: "y", seconds: 1) == nil else { throw Failure("Game mode did not keep the notch out of the way") }
                try shell.snapshot(to: output.appendingPathComponent("pill-game.png"))
                shell.gameMode.override = .off
                guard !shell.gameActive, !shell.panel.ignoresMouseEvents else { throw Failure("Game mode did not end") }
                shell.gameMode.override = .auto
                if let capture = shell.modules.lazy.compactMap({ $0 as? CaptureModule }).first {
                    let real = capture.state
                    capture.apply(CaptureState(microphone: true, microphoneApps: ["FaceTime"], camera: true))
                    guard shell.wing > 0 else { throw Failure("Mic and camera use did not show a status segment") }
                    try checkPlacement(shell: shell, layout: layout)
                    try shell.snapshot(to: output.appendingPathComponent("pill-capture.png"))
                    capture.apply(real)
                    try Data("capture_input_devices=\(shell.capture.inputDevices.count)\ncapture_cameras=\(shell.capture.cameras.count)\ncapture_active_now=\(real.active)\n".utf8)
                        .write(to: output.appendingPathComponent("capture.txt"))
                }
                shell.open(keyboard: false)
                try checkPlacement(shell: shell, layout: layout)
                guard shell.state.presentation == .hover, !shell.panel.isKeyWindow, !shell.panel.canBecomeKey else {
                    throw Failure("Hover took keyboard focus")
                }
                shell.modules.lazy.compactMap({ $0 as? StatsModule }).first?.sampleNow()
                try shell.snapshot(to: output.appendingPathComponent("home.png"))
                shell.setEditing(true)
                guard shell.editing, shell.isHeld else { throw Failure("Edit mode did not hold the panel open") }
                try shell.snapshot(to: output.appendingPathComponent("home-editing.png"))
                // A real drag through the grid's mouse handlers: the first card onto the second.
                let ids = shell.registries.cards.items.map(\.id)
                if ids.count > 1, let root = shell.panel.contentView {
                    func find(_ id: String, in view: NSView) -> NSView? {
                        if view.identifier?.rawValue == "card-" + id { return view }
                        for child in view.subviews { if let found = find(id, in: child) { return found } }
                        return nil
                    }
                    let order = LayoutOrder.apply(saved: shell.general.cardOrder, defaults: ids)
                    if let first = find(order[0], in: root), let second = find(order[1], in: root), let grid = first.superview {
                        func event(_ type: NSEvent.EventType, _ view: NSView) -> NSEvent {
                            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: shell.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        }
                        grid.mouseDown(with: event(.leftMouseDown, first))
                        grid.mouseDragged(with: event(.leftMouseDragged, second))
                        grid.mouseUp(with: event(.leftMouseUp, second))
                        guard LayoutOrder.apply(saved: shell.general.cardOrder, defaults: ids).prefix(2) == [order[1], order[0]] else {
                            throw Failure("Dragging a card in edit mode did not save its new place (\(shell.general.cardOrder))")
                        }
                        shell.updateGeneral { $0.cardOrder = [] }
                    }
                }
                shell.setEditing(false)
                guard !shell.isHeld else { throw Failure("Ending edit mode kept the panel held") }
                try snapshotCards(shell: shell, output: output)
                if let stats = shell.modules.lazy.compactMap({ $0 as? StatsModule }).first {
                    guard stats.hasScheduledWake, stats.sampleCount > 0 else { throw Failure("System stats did not sample while its card was visible") }
                }
                shell.selectTab("search")
                try shell.snapshot(to: output.appendingPathComponent("search.png"))
                shell.selectTab("timer")
                try shell.snapshot(to: output.appendingPathComponent("timer.png"))
                for tab in shell.registries.tabs.items {
                    shell.selectTab(tab.id)
                    try shell.snapshot(to: output.appendingPathComponent("tab-\(tab.id).png"))
                }
                if let media = shell.modules.lazy.compactMap({ $0 as? MediaModule }).first {
                    media.clearForSmoke()
                    shell.selectTab("media")
                    try shell.snapshot(to: output.appendingPathComponent("media-empty.png"))
                    shell.selectTab("home")
                    try snapshotCards(shell: shell, output: output, only: "media", suffix: "-empty")
                }
                if let clipboard = shell.modules.lazy.compactMap({ $0 as? ClipboardModule }).first {
                    // A private pasteboard: the user's clipboard is never read or written by the smoke test.
                    let board = NSPasteboard(name: NSPasteboard.Name("dev.qnotch.smoke.\(UUID().uuidString)"))
                    defer { board.releaseGlobally() }
                    let samples: [(String, Bool)] = [("hunter2", true), ("Remember the milk", false),
                        ("func greet() {\n    print(\"Hello\")\n}", false), ("https://github.com/Somafet/qnotch", false)]
                    for (text, concealed) in samples {
                        board.clearContents()
                        board.setString(text, forType: .string)
                        if concealed { board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
                        clipboard.capture(board)
                    }
                    guard clipboard.history.entries.map(\.kind) == [.link, .code, .text], !clipboard.history.entries.contains(where: { $0.text == "hunter2" }) else {
                        throw Failure("Clipboard history captured concealed content or misclassified entries")
                    }
                    shell.selectTab("clipboard")
                    try shell.snapshot(to: output.appendingPathComponent("clipboard.png"))
                }
                if let tray = shell.modules.lazy.compactMap({ $0 as? FileTrayModule }).first {
                    guard shell.surface.registeredDraggedTypes.contains(.fileURL) else { throw Failure("The notch does not accept file drops") }
                    let folder = shell.store.directory.appendingPathComponent("tray-sample", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let files = ["Quarterly report.pdf", "Notes.txt", "Screenshot.png", "Archive.zip", "Budget.numbers"].map { folder.appendingPathComponent($0) }
                    for file in files { try Data("QNotch smoke".utf8).write(to: file) }
                    shell.selectTab("files")
                    tray.dropActive = true
                    tray.reloadNow()
                    try shell.snapshot(to: output.appendingPathComponent("files-drop.png"))
                    tray.dropActive = false
                    tray.add(files)
                    try FileManager.default.removeItem(at: files[4])
                    shell.selectTab("files")
                    tray.setVisibility(panel: false, activeTab: "files"); tray.setVisibility(panel: true, activeTab: "files")
                    tray.reloadNow()
                    try shell.snapshot(to: output.appendingPathComponent("files.png"))
                    guard tray.items.count == 5, tray.items.first?.url.lastPathComponent == "Quarterly report.pdf" else { throw Failure("File tray did not keep the dropped files in order") }
                }
                try shell.accessibilityReport(to: output.appendingPathComponent("accessibility.txt"))
                guard let timer = shell.modules.lazy.compactMap({ $0 as? TimerModule }).first else { throw Failure("Timer module was not constructed") }
                let note = shell.modules.lazy.compactMap({ $0 as? NoteModule }).first
                note?.edit("Smoke note\nsecond line")
                timer.startShortTimer(seconds: 1)
                shell.close(restoreFocus: false)
                try shell.snapshot(to: output.appendingPathComponent("pill-running.png"))
                try checkPlacement(shell: shell, layout: layout)
                guard shell.wing > 0 else { throw Failure("A running timer did not show its status segment") }
                guard !shell.panel.canBecomeKey else { throw Failure("Collapsed panel accepts keyboard") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    do {
                        if note != nil {
                            let saved = try? String(contentsOf: shell.store.directory.appendingPathComponent("note.txt"), encoding: .utf8)
                            guard saved == "Smoke note\nsecond line", note?.status == .saved else { throw Failure("Note was not saved atomically after the debounce") }
                        }
                        if let clipboard = shell.modules.lazy.compactMap({ $0 as? ClipboardModule }).first, clipboard.checks == 0, !clipboard.denied {
                            throw Failure("Clipboard history never checked the change count")
                        }
                        guard shell.state.presentation == .hover, shell.activeTab == "home" else { throw Failure("Finishing did not open the panel on Home without the keyboard") }
                        guard timer.countdown.finished, timer.wakeCount == 1 else { throw Failure("Collapsed deadline did not finish with one wake (finished=\(timer.countdown.finished), wakes=\(timer.wakeCount))") }
                        shell.open(keyboard: true)
                        guard shell.panel.canBecomeKey, shell.panel.isKeyWindow || screenLocked, shell.state.acceptsKeyboard else { throw Failure("Explicit summon did not grant keyboard (canBecomeKey=\(shell.panel.canBecomeKey) key=\(shell.panel.isKeyWindow) state=\(shell.state.presentation) keyWindow=\(String(describing: NSApp.keyWindow)) active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))") }
                        shell.panel.cancelOperation(nil)
                        guard !shell.state.expanded else { throw Failure("Escape did not collapse") }
                        for id in ["toggle", "search"] {
                            // Another QNotch instance (the user's own) may already own the key.
                            guard let key = shell.shortcuts.shortcut(id), key.isRegistered || key.taken else { throw Failure("Shortcut \(id) was not registered") }
                        }
                        shell.summonSearch()
                        guard shell.activeTab == "search", shell.state.acceptsKeyboard else { throw Failure("Search shortcut did not open Search with the keyboard") }
                        shell.summonSearch()
                        guard !shell.state.expanded else { throw Failure("Search shortcut did not close an open Search") }
                        shell.toggleFromKeyboard()
                        guard shell.state.acceptsKeyboard else { throw Failure("Toggle shortcut did not open the panel") }
                        shell.toggleFromKeyboard()
                        guard !shell.state.expanded else { throw Failure("Toggle shortcut did not close the panel") }
                        shell.selectTab("home")
                        timer.startShortTimer(seconds: 60)
                        shell.updateGeneral { $0.setEnabled("note", false) }
                        guard shell.modules.contains(where: { $0 === timer }), timer.countdown.isRunning, timer.hasScheduledWake,
                              !shell.modules.contains(where: { $0 is NoteModule }) else { throw Failure("Turning Note off disturbed the running timer") }
                        shell.updateGeneral { $0.setEnabled("note", true) }
                        shell.updateGeneral { $0.setEnabled("timer", false) }
                        guard !shell.modules.contains(where: { $0 is TimerModule }), !shell.registries.cards.items.contains(where: { $0.id == "timer" }), !timer.hasScheduledWake else { throw Failure("Disabled module still constructed or scheduled") }
                        shell.open(keyboard: false)
                        try shell.snapshot(to: output.appendingPathComponent("unavailable.png"))
                        shell.close(restoreFocus: false)
                        shell.updateGeneral { $0.setEnabled("timer", true) }
                        // Pin: a pinned panel ignores outside clicks; a hidden card leaves Home; a swatch recolors.
                        shell.open(keyboard: false)
                        shell.togglePin()
                        shell.panel.cancelOperation(nil)
                        guard !shell.state.expanded else { throw Failure("Escape did not close a pinned panel") }
                        shell.open(keyboard: true)
                        shell.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
                        guard shell.state.expanded, !shell.state.acceptsKeyboard else { throw Failure("A pinned panel closed on focus loss or kept the keyboard") }
                        shell.updateGeneral { $0.setCardVisible("note", false); $0.accent = GeneralSettings.accents[6] }
                        shell.selectTab("home")
                        shell.close(restoreFocus: false); shell.open(keyboard: false)
                        try shell.snapshot(to: output.appendingPathComponent("home-pinned-green.png"))
                        guard !shell.registries.cards.items.isEmpty, (shell.panel.contentView.map { root -> Bool in
                            func find(_ view: NSView) -> Bool { view.identifier?.rawValue == "card-note" || view.subviews.contains(where: find) }
                            return find(root)
                        } ?? true) == false else { throw Failure("A hidden card is still on Home") }
                        shell.togglePin()
                        shell.updateGeneral { $0.setCardVisible("note", true); $0.accent = nil }
                        shell.close(restoreFocus: false)
                        exerciseNotifications(shell: shell, output: output) { problem in
                        if let problem { return fail(problem, output: output) }
                        exerciseAgents(shell: shell, output: output) { problem in
                        if let problem { return fail(problem, output: output) }
                        exerciseOnboarding(shell: shell, output: output) { problem in
                        if let problem { return fail(problem, output: output) }
                        shell.openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            do {
                                guard shell.registries.searchSources.items.contains(where: { $0.find("updates").contains { $0.title == "About" } }) else {
                                    throw Failure("Search does not find the About page")
                                }
                                try shell.settings?.snapshotPages(to: output)
                                shell.settings?.window.close()
                                let report = "Native UI smoke: actual window placement verified; camera center reserved; hover preserves focus; explicit summon grants keyboard; Escape collapses; running timer shows its status wing; toggle and search hotkeys work; timer completes hidden with one wake and opens Home; disabled module not constructed; every Home card and tab rendered; game mode keeps the notch out of the way; edit mode holds the panel and a card drag saves its place; notify command, waiting answer and loopback HTTP work; agent hooks update the board, transcript usage is read and agent processes are tracked and stopped; clipboard skips concealed content; file tray accepts drops and lists files; the welcome tour stays closed at launch, then opens from Settings and steps through every step (the toggle gesture is noticed in the window, a feature switch applies, Open QNotch opens Home with the keyboard, Esc skips); pin, card hiding and accent applied; mic and camera segment shown; system stats sampled; note saved after its debounce; interactive controls named; every settings page rendered, reachable in the sidebar and About found by Search.\nstartup_seconds=\(ready)\n\(screenLocked ? "note=screen locked; window-server key status not checked\n" : "")done\n"
                                try Data(report.utf8).write(to: output.appendingPathComponent("smoke.txt"))
                                NSApp.terminate(nil)
                            } catch { fail(error, output: output) }
                        }
                        }
                        }
                        }
                    } catch { fail(error, output: output) }
                }
            } catch { fail(error, output: output) }
        }
    }
    /// The welcome tour: never shown automatically in a diagnostic run; opened as Settings, About
    /// does, stepped through with snapshots of every step, then finished and, reopened, skipped.
    private static func exerciseOnboarding(shell: ShellController, output: URL, done: @escaping (Error?) -> Void) {
        guard shell.onboarding == nil, !shell.modulesDeferred, shell.general.onboardingDone == nil else {
            return done(Failure("The welcome tour was shown or recorded in a diagnostic run"))
        }
        let tour = shell.showOnboarding()
        var notes: [String] = []
        func snap(_ name: String? = nil) throws {
            guard let view = tour.window.contentView else { throw Failure("The welcome tour has no content") }
            view.layoutSubtreeIfNeeded()
            try ShellController.snapshot(view: view, to: output.appendingPathComponent("onboarding-\(name ?? tour.step.rawValue).png"))
            try requireNames(view, in: "the welcome tour (\(tour.step.rawValue))")
        }
        func expect(_ step: Onboarding.Step) throws {
            guard tour.step == step else { throw Failure("The welcome tour showed \(tour.step.rawValue), expected \(step.rawValue)") }
        }
        do {
            guard !tour.firstRun, tour.window.isVisible, tour.steps.first == .welcome, tour.steps.last == .finish else {
                throw Failure("Show Welcome Tour did not open the tour on its first step (\(tour.steps.map(\.rawValue)))")
            }
            try snap()
            tour.advance()
            try expect(.open)
            try snap()
            tour.pressToggleGesture()
            guard tour.triedGesture, !shell.state.expanded else { throw Failure("The toggle gesture in the tour was not noticed in its window, or opened the panel") }
            try snap("open-tried")
            // Return continues, unless the window cannot take the keyboard here (a locked screen).
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: tour.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36) {
                tour.window.sendEvent(event)
            }
            if tour.step == .open {
                guard !tour.window.isKeyWindow else { throw Failure("Return did not continue the welcome tour") }
                notes.append("return_key=not checked (window not key)")
                tour.advance()
            }
            try expect(.features)
            try snap()
            guard tour.flipFeature("note"), !shell.general.isEnabled("note"), !shell.modules.contains(where: { $0 is NoteModule }) else {
                throw Failure("A feature switch in the tour did not turn the feature off")
            }
            guard tour.flipFeature("note"), shell.general.isEnabled("note"), shell.modules.contains(where: { $0 is NoteModule }) else {
                throw Failure("A feature switch in the tour did not turn the feature back on")
            }
            tour.advance()
            try expect(.connect)
            guard tour.connectModuleIds.contains("github"), tour.connectModuleIds.contains("weather") else {
                throw Failure("The Connect step lacks the GitHub or Weather row (\(tour.connectModuleIds))")
            }
            try snap()
            tour.advance()
            try expect(.finish)
            try snap()
            tour.goBack()
            try expect(.connect)
            tour.advance()
            notes.append("steps=\(tour.steps.map(\.rawValue).joined(separator: ","))")
            notes.append("connect_rows=\(tour.connectModuleIds.joined(separator: ","))")
            tour.advance() // Open QNotch
        } catch { return done(error) }
        func panelState() -> String {
            "presentation=\(shell.state.presentation) tab=\(shell.activeTab) key=\(shell.panel.isKeyWindow) keyWindow=\(String(describing: NSApp.keyWindow)) active=\(NSApp.isActive) game=\(shell.gameActive)"
        }
        let opened = shell.state.acceptsKeyboard && shell.activeTab == "home"
        let atOnce = panelState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard shell.onboarding == nil, !tour.window.isVisible, shell.general.onboardingDone == true else {
                return done(Failure("Open QNotch did not end the tour and record it as done"))
            }
            guard tour.runningLoops == 0, tour.window.contentView?.layer?.animationKeys()?.isEmpty ?? true else {
                return done(Failure("An animation of the welcome tour outlived it"))
            }
            guard opened, shell.state.acceptsKeyboard, shell.activeTab == "home" else {
                return done(Failure("Open QNotch did not open Home with the keyboard (at once: \(atOnce); later: \(panelState()))"))
            }
            shell.close(restoreFocus: false)
            let again = shell.showOnboarding()
            again.window.cancelOperation(nil) // Esc
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard shell.onboarding == nil, !again.window.isVisible, !shell.state.expanded else { return done(Failure("Esc did not skip the welcome tour")) }
                try? Data((notes.joined(separator: "\n") + "\n").utf8).write(to: output.appendingPathComponent("onboarding.txt"))
                done(nil)
            }
        }
    }

    /// Every button and focusable control in `root` has an accessible name.
    private static func requireNames(_ root: NSView, in place: String) throws {
        func walk(_ view: NSView) throws {
            guard !view.isHidden else { return }
            // Scrollers are AppKit's own and named by the system.
            if let control = view as? NSControl, !(control is NSScroller), control is NSButton || control.acceptsFirstResponder {
                let name = control.accessibilityLabel() ?? (control as? NSButton)?.title ?? ""
                guard !name.isEmpty else { throw Failure("A \(type(of: control)) in \(place) has no accessible name") }
            }
            for child in view.subviews { try walk(child) }
        }
        try walk(root)
    }

    /// Hook events through the real `QNotch agent` binary, then sample sessions for the snapshots.
    private static func exerciseAgents(shell: ShellController, output: URL, done: @escaping (Error?) -> Void) {
        guard let module = shell.modules.lazy.compactMap({ $0 as? AgentsModule }).first else { return done(nil) }
        let directory = shell.store.directory.path
        // This process plays the agent: a shell tool it runs starts a long-lived command.
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/bash")
        tool.arguments = ["-c", "sleep 60; true"]
        try? tool.run()
        module.apply(AgentEvent(agent: "claude", event: "UserPromptSubmit", session: "smoke-proc", cwd: "/tmp/proc-demo", pid: getpid(), at: Date().timeIntervalSince1970))
        let transcript = shell.store.directory.appendingPathComponent("smoke-transcript.jsonl")
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? Data((#"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":120000,"output_tokens":8000}}}"# + "\n").utf8).write(to: transcript)
        let events = [#"{"hook_event_name":"UserPromptSubmit","session_id":"smoke","cwd":"/tmp/demo-app","transcript_path":"\#(transcript.path)"}"#,
                      #"{"hook_event_name":"Notification","session_id":"smoke","cwd":"/tmp/demo-app","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#]
        func send(_ index: Int) {
            guard index < events.count else {
                // Hooks are async, and usage is read 3 s after an event.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                    module.walk()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard let group = module.groups.first(where: { $0.group.label.hasPrefix("sleep") && $0.group.session == "smoke-proc" }) else {
                            return done(Failure("The process an agent's shell started was not tracked (\(module.groups.map(\.group.label)))"))
                        }
                        module.stopGroup(group)
                        module.dismiss(module.board.sessions.first { $0.id == "smoke-proc" }!)
                    guard module.usage["smoke"]?.today.tokens == 128_000 else { return done(Failure("Transcript usage was not read (\(String(describing: module.usage["smoke"])))")) }
                    let t3 = module.board.sessions.filter { $0.t3Thread != nil }.count
                    try? Data("t3_running=\(T3Watch.folder.path.isEmpty ? false : !NSRunningApplication.runningApplications(withBundleIdentifier: T3Watch.bundleID).isEmpty)\nt3_sessions=\(t3)\n".utf8)
                        .write(to: output.appendingPathComponent("agents.txt"))
                    guard module.board.sessions.first(where: { $0.id == "smoke" })?.status == .needsYou, module.board.pillText == "demo-app needs you" else {
                        return done(Failure("Agent hook events did not reach the board (\(module.board.sessions))"))
                    }
                    try? shell.snapshot(to: output.appendingPathComponent("pill-agent.png"))
                    module.seed()
                    shell.open(keyboard: false)
                    shell.selectTab("agents")
                    try? shell.snapshot(to: output.appendingPathComponent("agents.png"))
                    shell.close(restoreFocus: false)
                    done(nil)
                    }
                }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
            process.arguments = ["agent"]
            process.environment = ["QNOTCH_MAC_DATA_DIR": directory]
            let input = Pipe()
            process.standardInput = input
            process.terminationHandler = { process in
                DispatchQueue.main.async {
                    guard process.terminationStatus == 0 else { return done(Failure("QNotch agent exited with \(process.terminationStatus)")) }
                    send(index + 1)
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(events[index].utf8))
                try input.fileHandleForWriting.close()
            } catch { done(error) }
        }
        send(0)
    }

    /// The real `QNotch notify` binary and loopback HTTP against this isolated instance.
    private static func exerciseNotifications(shell: ShellController, output: URL, done: @escaping (Error?) -> Void) {
        guard let module = shell.modules.lazy.compactMap({ $0 as? NotificationsModule }).first else { return done(nil) }
        let directory = shell.store.directory.path
        // The user's own QNotch may own the default port; this isolated instance uses its own.
        module.set { $0.httpPort = 49152 + Int(getpid() % 10000) }
        func notify(_ arguments: [String], finished: @escaping (Int32, String) -> Void) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
            process.arguments = ["notify"] + arguments
            process.environment = ["QNOTCH_MAC_DATA_DIR": directory]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { process in
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { finished(process.terminationStatus, text) }
            }
            do { try process.run() } catch { finished(-1, "") }
        }
        notify(["Build finished", "All 42 tests passed.", "--app", "CI", "-l", "success", "--id", "build"]) { code, _ in
            guard code == 0, module.items.first?.id == "build" else { return done(Failure("notify did not post through the socket (exit \(code))")) }
            try? shell.snapshot(to: output.appendingPathComponent("pill-peek.png"))
            notify(["Run the migration?", "--app", "Claude Code", "-i", "chat", "--action", "yes=Approve", "--action", "no=Deny", "--timeout", "10"]) { code, answer in
                guard code == 0, answer == "yes" else { return done(Failure("A waiting notify did not return the answer (exit \(code), \(answer))")) }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(module.settings.httpPort)/notify")!)
                request.httpMethod = "POST"
                request.httpBody = Data(#"{"title":"Deploy failed","body":"Step 3 of 5: database migration","level":"warning","app":"GitHub Actions","actions":[{"label":"Open run","url":"https://github.com"}]}"#.utf8)
                request.setValue("Bearer \(module.currentToken())", forHTTPHeaderField: "Authorization")
                URLSession.shared.dataTask(with: request) { _, response, _ in
                    let ok = (response as? HTTPURLResponse)?.statusCode
                    var bad = request
                    bad.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
                    URLSession.shared.dataTask(with: bad) { _, response, _ in
                        let rejected = (response as? HTTPURLResponse)?.statusCode
                        var web = request
                        web.setValue("https://example.com", forHTTPHeaderField: "Origin")
                        URLSession.shared.dataTask(with: web) { _, response, _ in
                            let origin = (response as? HTTPURLResponse)?.statusCode
                            DispatchQueue.main.async {
                                guard ok == 200, rejected == 401, origin == 403, module.items.first?.title == "Deploy failed" else {
                                    return done(Failure("Loopback HTTP: ok=\(ok ?? 0) wrong token=\(rejected ?? 0) origin=\(origin ?? 0)"))
                                }
                                shell.open(keyboard: false)
                                shell.selectTab("notifications")
                                try? shell.snapshot(to: output.appendingPathComponent("notifications.png"))
                                shell.close(restoreFocus: false)
                                done(nil)
                            }
                        }.resume()
                    }.resume()
                }.resume()
            }
            // Answer the waiting request from the UI once it arrives.
            func answer(_ attempts: Int) {
                if let note = module.items.first(where: { $0.pending }), let approve = note.actions.first {
                    try? shell.snapshot(to: output.appendingPathComponent("pill-waiting.png"))
                    module.invoke(approve, on: note)
                } else if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { answer(attempts - 1) }
                }
            }
            answer(50)
        }
    }

    /// One PNG per Home card (cards past the first rows are scrolled out of home.png).
    private static func snapshotCards(shell: ShellController, output: URL, only: String? = nil, suffix: String = "") throws {
        guard let root = shell.panel.contentView else { return }
        var found: [String: NSView] = [:]
        func walk(_ view: NSView) {
            if let id = view.identifier?.rawValue, id.hasPrefix("card-") { found[String(id.dropFirst(5))] = view }
            view.subviews.forEach(walk)
        }
        walk(root)
        for card in shell.registries.cards.items where only == nil || card.id == only {
            guard let view = found[card.id] else { throw Failure("Home card \(card.id) is not on Home") }
            try ShellController.snapshot(view: view, to: output.appendingPathComponent("card-\(card.id)\(suffix).png"))
        }
    }

    private static func checkPlacement(shell: ShellController, layout: DisplayLayout) throws {
        guard let expected = shell.expectedFrame else { throw Failure("No expected surface") }
        guard abs(shell.panel.frame.maxY - expected.maxY) <= 0.5,
              abs(shell.panel.frame.minX - expected.minX) <= 0.5 else { throw Failure("AppKit displaced the surface from the bezel: actual=\(shell.panel.frame), expected=\(expected)") }
        guard abs(shell.panel.frame.width - expected.width) <= 0.5, abs(shell.panel.frame.height - expected.height) <= 0.5 else {
            throw Failure("Settled window differs from the surface: actual=\(shell.panel.frame), expected=\(expected)")
        }
        guard let housing = layout.cameraHousing, let wings = layout.wings(expanded: shell.state.expanded, wing: shell.wing) else { return }
        guard shell.panel.level == .statusBar else { throw Failure("Integrated surface is below the menu bar level") }
        func walk(_ view: NSView) throws {
            let global = shell.panel.convertToScreen(view.convert(view.bounds, to: nil))
            let id = view.identifier?.rawValue
            if id == "panel", global.maxY > housing.minY + 0.5 { throw Failure("Panel controls overlap the camera band") }
            if (id == "notch-left-wing" || id == "notch-right-wing"), global.width > 0, global.height > 0 {
                let clearArea = id == "notch-left-wing" ? wings.left : wings.right
                guard clearArea.insetBy(dx: -0.5, dy: -0.5).contains(global), !global.intersects(housing) else {
                    throw Failure("Status content overlaps the camera or bezel: \(id ?? "") \(global) area=\(clearArea) wing=\(shell.wing) expanded=\(shell.state.expanded) fitting=\(view.fittingSize)")
                }
            }
            for child in view.subviews { try walk(child) }
        }
        if let view = shell.panel.contentView { try walk(view) }
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    fileprivate static func fail(_ error: Error, output: URL) {
        let message = "Native smoke failed: \(error)\n"
        try? Data(message.utf8).write(to: output.appendingPathComponent("smoke.txt"))
        fputs(message, stderr)
        exit(1)
    }
}

enum PerformanceMeasurement {
    static func secondsSinceProcessStart() -> TimeInterval? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        guard result == 0, usage.ri_proc_start_abstime > 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { return nil }
        return Double(mach_absolute_time() - usage.ri_proc_start_abstime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    private static func hardwareModel() -> String {
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes)
    }
    private struct Sample {
        let time: TimeInterval
        let cpu: TimeInterval
        let resident: UInt64
        let footprint: UInt64
        let wakeups: UInt64
        let draws: Int
    }
    private static func sample() -> Sample {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        precondition(result == 0, "proc_pid_rusage failed")
        return Sample(time: ProcessInfo.processInfo.systemUptime,
                      cpu: Double(usage.ri_user_time + usage.ri_system_time) / 1_000_000_000,
                      resident: usage.ri_resident_size, footprint: usage.ri_phys_footprint, wakeups: usage.ri_interrupt_wkups,
                      draws: RenderDiagnostics.drawCount)
    }
    static func run(shell: ShellController, output: URL, ready: TimeInterval) {
        // Two intervals, each after its own warmup: every module enabled but quiet (no stats in the
        // wings), then the default stats wings. Endpoint samples only; no sampling loop.
        let stats = shell.modules.lazy.compactMap({ $0 as? StatsModule }).first
        let defaults = stats?.settings
        stats?.set { $0.wingCPU = false; $0.wingMemory = false; $0.wingGPU = false; $0.wingNetwork = false; $0.wingBattery = false; $0.wingClock = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            shell.close(restoreFocus: false)
            interval(shell: shell, label: "collapsed, all modules enabled, nothing active") { quiet in
                guard let stats, let defaults else { return write(shell: shell, output: output, ready: ready, quiet: quiet, wings: nil) }
                stats.set { $0 = defaults }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    interval(shell: shell, label: "collapsed, default System stats wings (CPU, memory)") { wings in
                        write(shell: shell, output: output, ready: ready, quiet: quiet, wings: wings)
                    }
                }
            }
        }
    }

    private static func interval(shell: ShellController, label: String, done: @escaping ([String: Any]) -> Void) {
        let before = sample()
        let surfaceRevision = shell.surfaceRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            let after = sample()
            let elapsed = after.time - before.time
            done([
                "state": shell.state.expanded || shell.surfaceRevision != surfaceRevision ? "presentation activity observed; not a quiet collapsed interval" : label,
                "surface_rebuilds_delta": shell.surfaceRevision - surfaceRevision,
                "panel_expanded_at_end": shell.state.expanded,
                "interval_seconds": elapsed,
                "cpu_percent_one_core": (after.cpu - before.cpu) / elapsed * 100,
                "resident_bytes_start": before.resident, "resident_bytes_end": after.resident,
                "phys_footprint_bytes_end": after.footprint,
                "interrupt_wakeups_delta": after.wakeups - before.wakeups,
                "app_draw_callbacks_delta": after.draws - before.draws
            ])
        }
    }

    private static func write(shell: ShellController, output: URL, ready: TimeInterval, quiet: [String: Any], wings: [String: Any]?) {
        var report: [String: Any] = quiet
        report.merge([
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled",
            "source_revision": Bundle.main.object(forInfoDictionaryKey: "QNotchSourceRevision") as? String ?? "unknown",
            "source_dirty": Bundle.main.object(forInfoDictionaryKey: "QNotchSourceDirty") as? Bool ?? true,
            "hardware_model": hardwareModel(), "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "platform": "macOS", "architecture": "arm64", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "enabled_modules": ModuleList.all.map(\.id).filter { shell.general.isEnabled($0) },
            "process_start_to_panel_ordered_seconds": ready,
            "method": "proc_pid_rusage RUSAGE_INFO_V2; app draw counters; 30-second intervals after a warmup",
            "launch_method": "mach_absolute_time minus ri_proc_start_abstime; panel ordered front, before compositor presentation"
        ]) { current, _ in current }
        if let wings { report["stats_wings_interval"] = wings }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("performance.json"))
        } catch { fputs("Unable to write performance report\n", stderr); exit(1) }
        NSApp.terminate(nil)
    }
}

