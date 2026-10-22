import AppKit
import QNotchMacCore
import Darwin

/// `--smoke-test <dir>`: every view `--snapshot` writes, then scripted interactions with the real
/// shell, each reported as `check <name>: ok` in `smoke.txt` (spec/diagnostics.md, Smoke checks).
/// The shared checks keep their names; Mac-only ones (timer-wake, note-save, …) are added.
enum NativeSmokeTest {
    /// A locked screen (loginwindow in front) never grants another app's window the keyboard.
    /// The shell's own keyboard state is still checked; only the window server's key status is not.
    static var screenLocked: Bool {
        ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool) == true
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    }

    static func run(shell: ShellController, output: URL, ready: TimeInterval, options: DiagnosticOptions) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let run = SnapshotRun(shell: shell, output: output, options: options, readsAllOutlines: true)
            func finish(_ error: Error?) {
                if let error { run.fail((error as? Failure)?.check ?? "smoke", "\(error)") }
                checkNames(run)
                let extra = [String(format: "startup_seconds: %.4f", ready)] + (screenLocked ? ["note: screen locked; window-server key status not checked"] : [])
                if run.finish("smoke.txt", extra: extra) { return NSApp.terminate(nil) }
                for line in run.lines where line.hasPrefix("FAILED") { fputs("Native smoke \(line)\n", stderr) }
                exit(1)
            }
            let timer: TimerModule, note: NoteModule?
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                guard let layout = shell.layout else { throw Failure("placement", "No display available for native UI validation") }
                run.log("placement", ["camera_housing=\(layout.hasCameraHousing)", "integrated=\(layout.integratesTopBand)", "safe_top_points=\(layout.safeTop)", "top_band_points=\(layout.topBandHeight)",
                                      "display_frame=\(layout.frame)", "collapsed_idle_frame=\(layout.surface(expanded: false))",
                                      "collapsed_status_frame=\(layout.surface(expanded: false, wing: 56))", "expanded_frame=\(layout.surface(expanded: true))",
                                      "panel_body=\(layout.panelBody)"])
                SnapshotViews.render(run)
                try checkSearchEnablement(run)
                (timer, note) = try checkShell(run, layout: layout)
            } catch { return finish(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                do { try checkAfterWake(run, timer: timer, note: note) } catch { return finish(error) }
                // Keep panel open: the pointer leaving does not close it, also after the close delay.
                shell.pointerLeft()
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(shell.general.closeDelayMs) / 1000 + 0.2) {
                    do { try checkPinAndCards(run) } catch { return finish(error) }
                    exerciseNotifications(run) { error in
                        if let error { return finish(error) }
                        exerciseAgents(run) { error in
                            if let error { return finish(error) }
                            exerciseOnboarding(run) { error in
                                if let error { return finish(error) }
                                guard shell.registries.searchSources.items.contains(where: { $0.find("updates").contains { $0.title == "About" } }) else {
                                    return finish(Failure("settings-search", "Search does not find the About page"))
                                }
                                run.pass("settings-search")
                                exerciseDebugChannel(run, done: finish)
                            }
                        }
                    }
                }
            }
        }
    }

    /// debug-channel: the channel opened as `--debug-control` does answers ping, state, select-tab
    /// and outline through its real socket; requests are sent from a background queue.
    private static func exerciseDebugChannel(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let channel: DebugChannel
        do { channel = try DebugChannel.start(shell: run.shell, directory: run.shell.store.directory) } catch {
            return done(Failure("debug-channel", "The channel did not open: \(error)"))
        }
        let path = channel.path
        DispatchQueue.global().async {
            func ask(_ cmd: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
                var line = try JSONSerialization.data(withJSONObject: ["id": cmd, "cmd": cmd, "args": args])
                line.append(0x0A)
                guard case .success(let reply) = DebugClient.send(line, to: path, timeout: 10),
                      let object = try? JSONSerialization.jsonObject(with: reply.split(separator: 0x0A).first ?? reply[...]) as? [String: Any],
                      object["id"] as? String == cmd else { throw Failure("debug-channel", "\(cmd) got no readable reply") }
                guard object["ok"] as? Bool == true, let result = object["result"] as? [String: Any] else {
                    throw Failure("debug-channel", "\(cmd) failed: \(object["error"] ?? "no result")")
                }
                return result
            }
            var failure: Error?
            do {
                guard try ask("ping")["platform"] as? String == "macOS" else { throw Failure("debug-channel", "ping does not report macOS") }
                let before = try ask("state")
                guard before["panel"] is String else { throw Failure("debug-channel", "state has no panel") }
                do { _ = try ask("select-tab", ["id": "timer"]) } catch {
                    throw Failure("debug-channel", "\(error); before: panel=\(before["panel"] ?? "?") tab=\(before["tab"] ?? "?") game_mode=\(before["game_mode"] ?? "?") after: \((try? ask("state")).map { "\($0["panel"] ?? "?") \($0["tab"] ?? "?")" } ?? "?")")
                }
                let state = try ask("state")
                guard state["panel"] as? String == "open", state["tab"] as? String == "timer" else { throw Failure("debug-channel", "select-tab did not open Timer: \(state)") }
                guard (try ask("outline")["text"] as? String)?.contains("#tab-timer selected") == true else { throw Failure("debug-channel", "the outline does not show Timer selected") }
                _ = try ask("close")
            } catch { failure = error }
            DispatchQueue.main.async {
                DebugChannel.stop()
                if failure == nil { run.pass("debug-channel") }
                done(failure)
            }
        }
    }

    /// accessible-names: every interactive control line of every view's outline has a name (also
    /// of views `--only` did not write).
    private static func checkNames(_ run: SnapshotRun) {
        guard !run.outlines.isEmpty else { return }
        let unnamed = run.outlines.flatMap { outline in Outline.unnamedControls(in: outline.text).map { "\(outline.name): \($0)" } }
        if unnamed.isEmpty { run.pass("accessible-names") }
        else { run.fail("accessible-names", "\(unnamed.count) controls without a name: " + unnamed.prefix(8).joined(separator: "; ")) }
    }

    /// Game mode, hover, edit mode, stats, clipboard and file tray, then a hidden short countdown.
    private static func checkShell(_ run: SnapshotRun, layout: DisplayLayout) throws -> (TimerModule, NoteModule?) {
        let shell = run.shell
        try checkPlacement(shell: shell, layout: layout)
        try StatusGutterSmoke.check(run, phase: "collapsed")
        try StatusGutterSmoke.exercise(run)
        try checkNudge(run)
        try shell.withDiagnosticLayout(SnapshotViews.virtualDisplay) {
            guard let virtual = shell.layout else { throw Failure("virtual-housing", "No diagnostic layout") }
            try checkPlacement(shell: shell, layout: virtual)
            try StatusGutterSmoke.check(run, phase: "virtual-collapsed")
            try checkNudge(run, prefix: "placement-virtual-nudge")
            shell.open(keyboard: false)
            if let expanded = shell.layout { try checkPlacement(shell: shell, layout: expanded) }
            try StatusGutterSmoke.check(run, phase: "virtual-expanded")
            shell.close(restoreFocus: false)
        }
        run.pass("virtual-housing")
        shell.gameMode.override = .on
        shell.open(keyboard: false)
        guard shell.gameActive, !shell.state.expanded, shell.panel.ignoresMouseEvents,
              shell.peek(symbol: "bell", tint: .white, leading: "x", trailing: "y", seconds: 1) == nil else { throw Failure("game-mode", "Game mode did not keep the notch out of the way") }
        shell.gameMode.override = .off
        guard !shell.gameActive, !shell.panel.ignoresMouseEvents else { throw Failure("game-mode", "Game mode did not end") }
        shell.gameMode.override = .auto
        run.pass("game-mode")
        if let capture = shell.module(CaptureModule.self) {
            let real = capture.state
            capture.apply(CaptureState(microphone: true, microphoneApps: ["FaceTime"], camera: true))
            guard shell.wing > 0 else { throw Failure("capture-segment", "Mic and camera use did not show a status segment") }
            try checkPlacement(shell: shell, layout: layout)
            try StatusGutterSmoke.check(run, phase: "capture")
            capture.apply(real)
            run.log("capture", ["capture_input_devices=\(shell.capture.inputDevices.count)", "capture_cameras=\(shell.capture.cameras.count)", "capture_active_now=\(real.active)"])
            run.pass("capture-segment")
        }
        shell.open(keyboard: false)
        try checkPlacement(shell: shell, layout: layout)
        try StatusGutterSmoke.check(run, phase: "expanded")
        guard shell.state.presentation == .hover, !shell.panel.isKeyWindow, !shell.panel.canBecomeKey else {
            throw Failure("hover-keeps-focus", "Hover took keyboard focus")
        }
        shell.module(StatsModule.self)?.sampleNow()
        shell.setEditing(true)
        guard shell.editing, shell.isHeld else { throw Failure("edit-mode", "Edit mode did not hold the panel open") }
        // A real drag through the grid's mouse handlers: the first card onto the second.
        let ids = shell.registries.cards.items.map(\.id)
        let cards = SnapshotViews.cardViews(shell)
        let order = LayoutOrder.apply(saved: shell.general.cardOrder, defaults: ids)
        if ids.count > 1, let first = cards[order[0]], let second = cards[order[1]], let grid = first.superview {
            func event(_ type: NSEvent.EventType, _ view: NSView) -> NSEvent {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: shell.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            grid.mouseDown(with: event(.leftMouseDown, first))
            grid.mouseDragged(with: event(.leftMouseDragged, second))
            grid.mouseUp(with: event(.leftMouseUp, second))
            guard LayoutOrder.apply(saved: shell.general.cardOrder, defaults: ids).prefix(2) == [order[1], order[0]] else {
                throw Failure("edit-mode", "Dragging a card in edit mode did not save its new place (\(shell.general.cardOrder))")
            }
            shell.updateGeneral { $0.cardOrder = [] }
        }
        shell.setEditing(false)
        guard !shell.isHeld else { throw Failure("edit-mode", "Ending edit mode kept the panel held") }
        run.pass("edit-mode")
        if let stats = shell.module(StatsModule.self) {
            guard stats.hasScheduledWake, stats.sampleCount > 0 else { throw Failure("stats-sampling", "System stats did not sample while its card was visible") }
            run.pass("stats-sampling")
        }
        if let clipboard = shell.module(ClipboardModule.self) {
            guard clipboard.history.entries.map(\.kind) == [.link, .code, .text], !clipboard.history.entries.contains(where: { $0.text == "hunter2" }) else {
                throw Failure("clipboard-private", "Clipboard history captured concealed content or misclassified entries")
            }
        }
        if let tray = shell.module(FileTrayModule.self) {
            guard shell.surface.registeredDraggedTypes.contains(.fileURL) else { throw Failure("file-tray", "The notch does not accept file drops") }
            guard tray.items.count == SnapshotViews.sampleFiles.count, tray.items.first?.url.lastPathComponent == SnapshotViews.sampleFiles[0] else {
                throw Failure("file-tray", "File tray did not keep the dropped files in order")
            }
            run.pass("file-tray")
        }
        guard let timer = shell.module(TimerModule.self) else { throw Failure("timer-wake", "Timer module was not constructed") }
        let note = shell.module(NoteModule.self)
        note?.edit("Smoke note\nsecond line")
        timer.startShortTimer(seconds: 1)
        shell.close(restoreFocus: false)
        try checkPlacement(shell: shell, layout: layout)
        try StatusGutterSmoke.check(run, phase: "timer")
        run.pass("status-gutters")
        run.pass("placement")
        guard shell.wing > 0 else { throw Failure("timer-segment", "A running timer did not show its status segment") }
        run.pass("timer-segment")
        guard !shell.panel.canBecomeKey else { throw Failure("hover-keeps-focus", "Collapsed panel accepts keyboard") }
        run.pass("hover-keeps-focus")
        return (timer, note)
    }

    /// The countdown finished hidden, the note saved; then summon, Escape, the hotkeys and module switches.
    private static func checkAfterWake(_ run: SnapshotRun, timer: TimerModule, note: NoteModule?) throws {
        let shell = run.shell
        if note != nil {
            let saved = try? String(contentsOf: shell.store.directory.appendingPathComponent("note.txt"), encoding: .utf8)
            guard saved == "Smoke note\nsecond line", note?.status == .saved else { throw Failure("note-save", "Note was not saved atomically after the debounce") }
            run.pass("note-save")
        }
        if let clipboard = shell.module(ClipboardModule.self) {
            guard clipboard.checks > 0 || clipboard.denied else { throw Failure("clipboard-private", "Clipboard history never checked the change count") }
            run.pass("clipboard-private")
        }
        guard shell.state.presentation == .hover, shell.activeTab == "home" else { throw Failure("timer-wake", "Finishing did not open the panel on Home without the keyboard") }
        guard timer.countdown.finished, timer.wakeCount == 1 else { throw Failure("timer-wake", "Collapsed deadline did not finish with one wake (finished=\(timer.countdown.finished), wakes=\(timer.wakeCount))") }
        run.pass("timer-wake")
        shell.open(keyboard: true)
        guard shell.panel.canBecomeKey, shell.panel.isKeyWindow || screenLocked, shell.state.acceptsKeyboard else { throw Failure("hotkey-toggle", "Explicit summon did not grant keyboard (canBecomeKey=\(shell.panel.canBecomeKey) key=\(shell.panel.isKeyWindow) state=\(shell.state.presentation) keyWindow=\(String(describing: NSApp.keyWindow)) active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))") }
        shell.panel.cancelOperation(nil)
        guard !shell.state.expanded else { throw Failure("escape-collapses", "Escape did not collapse") }
        for id in ["toggle", "search"] {
            // Another QNotch instance (the user's own) may already own the key.
            guard let key = shell.shortcuts.shortcut(id), key.isRegistered || key.taken else { throw Failure("hotkey-" + id, "Shortcut \(id) was not registered") }
        }
        shell.summonSearch()
        guard shell.activeTab == "search", shell.state.acceptsKeyboard else { throw Failure("hotkey-search", "Search shortcut did not open Search with the keyboard") }
        guard let field = find("search-field", in: shell.panel.contentView), Outline.focused(field) else {
            throw Failure("hotkey-search", "Search shortcut did not put the cursor in search-field")
        }
        try NativeSearchSmoke.check(run)
        shell.summonSearch()
        guard !shell.state.expanded else { throw Failure("hotkey-search", "Search shortcut did not close an open Search") }
        run.pass("hotkey-search")
        shell.toggleFromKeyboard()
        guard shell.state.acceptsKeyboard else { throw Failure("hotkey-toggle", "Toggle shortcut did not open the panel") }
        shell.toggleFromKeyboard()
        guard !shell.state.expanded else { throw Failure("hotkey-toggle", "Toggle shortcut did not close the panel") }
        run.pass("hotkey-toggle")
        shell.selectTab("home")
        timer.startShortTimer(seconds: 60)
        shell.updateGeneral { $0.setEnabled("note", false) }
        guard shell.modules.contains(where: { $0 === timer }), timer.countdown.isRunning, timer.hasScheduledWake,
              shell.module(NoteModule.self) == nil else { throw Failure("module-toggle", "Turning Note off disturbed the running timer") }
        shell.updateGeneral { $0.setEnabled("note", true) }
        guard shell.module(NoteModule.self) != nil else { throw Failure("module-toggle", "Turning Note back on did not construct it") }
        run.pass("module-toggle")
        shell.updateGeneral { $0.setEnabled("timer", false) }
        let registries = shell.registries
        guard shell.module(TimerModule.self) == nil, !registries.cards.items.contains(where: { $0.id == "timer" }), !registries.tabs.items.contains(where: { $0.id == "timer" }),
              !registries.segments.items.contains(where: { registries.segments.owner(of: $0.id) == "timer" }), !timer.hasScheduledWake else {
            throw Failure("module-disabled", "Disabled module still constructed, shown or scheduled")
        }
        shell.updateGeneral { $0.setEnabled("timer", true) }
        run.pass("module-disabled")
        // Pin: a pinned panel survives Escape only by closing, and keeps open on focus loss and pointer leave.
        shell.open(keyboard: false)
        shell.togglePin()
        shell.panel.cancelOperation(nil)
        guard !shell.state.expanded else { throw Failure("escape-collapses", "Escape did not close a pinned panel") }
        run.pass("escape-collapses")
        shell.open(keyboard: true)
        shell.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        guard shell.state.expanded, !shell.state.acceptsKeyboard else { throw Failure("pin", "A pinned panel closed on focus loss or kept the keyboard") }
    }

    /// The pinned panel stayed open; a hidden card leaves Home and a swatch recolors.
    private static func checkPinAndCards(_ run: SnapshotRun) throws {
        let shell = run.shell
        guard shell.state.expanded else { throw Failure("pin", "A pinned panel closed when the pointer left") }
        run.pass("pin")
        shell.updateGeneral { $0.setCardVisible("note", false); $0.accent = GeneralSettings.accents[6] }
        shell.selectTab("home")
        shell.close(restoreFocus: false); shell.open(keyboard: false)
        run.notch("home-pinned-green")
        guard !shell.registries.cards.items.isEmpty, SnapshotViews.cardViews(shell)["note"] == nil else { throw Failure("card-hiding", "A hidden card is still on Home") }
        run.pass("card-hiding")
        shell.togglePin()
        shell.updateGeneral { $0.setCardVisible("note", true); $0.accent = nil }
        shell.close(restoreFocus: false)
    }

    private static func find(_ id: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }

    /// The welcome tour: never shown automatically in a diagnostic run; opened as Settings, About
    /// does and stepped through (its steps were rendered with the other views), then finished and,
    /// reopened, skipped.
    private static func exerciseOnboarding(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        guard shell.onboarding == nil, !shell.modulesDeferred, shell.general.onboardingDone == nil else {
            return done(Failure("onboarding", "The welcome tour was shown or recorded in a diagnostic run"))
        }
        let tour = shell.showOnboarding()
        var notes: [String] = []
        func expect(_ step: Onboarding.Step) throws {
            guard tour.step == step else { throw Failure("onboarding", "The welcome tour showed \(tour.step.rawValue), expected \(step.rawValue)") }
        }
        do {
            guard !tour.firstRun, tour.window.isVisible, tour.steps.first == .welcome, tour.steps.last == .finish else {
                throw Failure("onboarding", "Show Welcome Tour did not open the tour on its first step (\(tour.steps.map(\.rawValue)))")
            }
            tour.advance()
            try expect(.open)
            tour.pressToggleGesture()
            guard tour.triedGesture, !shell.state.expanded else { throw Failure("onboarding", "The toggle gesture in the tour was not noticed in its window, or opened the panel") }
            run.write("onboarding-open-tried", tour.window.contentView, background: Palette.surface)
            // Return continues, unless the window cannot take the keyboard here (a locked screen).
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: tour.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36) {
                tour.window.sendEvent(event)
            }
            if tour.step == .open {
                guard !tour.window.isKeyWindow else { throw Failure("onboarding", "Return did not continue the welcome tour") }
                notes.append("return_key=not checked (window not key)")
                tour.advance()
            }
            try expect(.features)
            try checkSearchOnboarding(tour, run: run)
            run.pass("search-onboarding")
            guard tour.flipFeature("note"), !shell.general.isEnabled("note"), shell.module(NoteModule.self) == nil else {
                throw Failure("onboarding", "A feature switch in the tour did not turn the feature off")
            }
            guard tour.flipFeature("note"), shell.general.isEnabled("note"), shell.module(NoteModule.self) != nil else {
                throw Failure("onboarding", "A feature switch in the tour did not turn the feature back on")
            }
            tour.advance()
            try expect(.connect)
            guard tour.connectModuleIds.contains("github"), tour.connectModuleIds.contains("weather") else {
                throw Failure("onboarding", "The Connect step lacks the GitHub or Weather row (\(tour.connectModuleIds))")
            }
            tour.advance()
            try expect(.finish)
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
                return done(Failure("onboarding", "Open QNotch did not end the tour and record it as done"))
            }
            guard tour.runningLoops == 0, tour.window.contentView?.layer?.animationKeys()?.isEmpty ?? true else {
                return done(Failure("onboarding", "An animation of the welcome tour outlived it"))
            }
            guard opened, shell.state.acceptsKeyboard, shell.activeTab == "home" else {
                return done(Failure("onboarding", "Open QNotch did not open Home with the keyboard (at once: \(atOnce); later: \(panelState()))"))
            }
            shell.close(restoreFocus: false)
            let again = shell.showOnboarding()
            again.window.cancelOperation(nil) // Esc
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard shell.onboarding == nil, !again.window.isVisible, !shell.state.expanded else { return done(Failure("onboarding", "Esc did not skip the welcome tour")) }
                run.log("onboarding", notes)
                run.pass("onboarding")
                done(nil)
            }
        }
    }

    /// Hook events through the real `QNotch agent` binary, a tracked agent process and transcript usage.
    private static func exerciseAgents(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        guard let module = shell.module(AgentsModule.self) else { run.skip("agents-hook", "Agents is off"); return done(nil) }
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
                            return done(Failure("agent-processes", "The process an agent's shell started was not tracked (\(module.groups.map(\.group.label)))"))
                        }
                        module.stopGroup(group)
                        module.dismiss(module.board.sessions.first { $0.id == "smoke-proc" }!)
                        guard module.usage["smoke"]?.today.tokens == 128_000 else { return done(Failure("agent-processes", "Transcript usage was not read (\(String(describing: module.usage["smoke"])))")) }
                        run.pass("agent-processes")
                        let t3 = module.board.sessions.filter { $0.t3Thread != nil }.count
                        run.log("agents", ["t3_running=\(T3Watch.folder.path.isEmpty ? false : !NSRunningApplication.runningApplications(withBundleIdentifier: T3Watch.bundleID).isEmpty)", "t3_sessions=\(t3)"])
                        guard module.board.sessions.first(where: { $0.id == "smoke" })?.status == .needsYou, module.board.pillText == "demo-app needs you" else {
                            return done(Failure("agents-hook", "Agent hook events did not reach the board (\(module.board.sessions))"))
                        }
                        run.pass("agents-hook")
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
                    guard process.terminationStatus == 0 else { return done(Failure("agents-hook", "QNotch agent exited with \(process.terminationStatus)")) }
                    send(index + 1)
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(events[index].utf8))
                try input.fileHandleForWriting.close()
            } catch { done(Failure("agents-hook", "\(error)")) }
        }
        send(0)
    }

    /// The real `QNotch notify` binary over the socket, its `--wait` answer, and loopback HTTP.
    private static func exerciseNotifications(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        guard let module = shell.module(NotificationsModule.self) else {
            run.skip("notify-cli", "Notifications is off"); run.skip("notify-transport", "Notifications is off")
            return done(nil)
        }
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
            guard code == 0, module.items.first?.id == "build" else { return done(Failure("notify-cli", "notify did not post through the socket (exit \(code))")) }
            notify(["Run the migration?", "--app", "Claude Code", "-i", "chat", "--action", "yes=Approve", "--action", "no=Deny", "--timeout", "10"]) { code, answer in
                guard code == 0, answer == "yes" else { return done(Failure("notify-cli", "A waiting notify did not return the answer (exit \(code), \(answer))")) }
                run.pass("notify-cli")
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
                                    return done(Failure("notify-transport", "Loopback HTTP: ok=\(ok ?? 0) wrong token=\(rejected ?? 0) origin=\(origin ?? 0)"))
                                }
                                run.pass("notify-transport")
                                done(nil)
                            }
                        }.resume()
                    }.resume()
                }.resume()
            }
            // Answer the waiting request from the UI once it arrives.
            func answer(_ attempts: Int) {
                if let note = module.items.first(where: { $0.pending }), let approve = note.actions.first {
                    module.invoke(approve, on: note)
                } else if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { answer(attempts - 1) }
                }
            }
            answer(50)
        }
    }

    private static func checkPlacement(shell: ShellController, layout: DisplayLayout) throws {
        guard let expected = shell.expectedFrame else { throw Failure("placement", "No expected surface") }
        guard abs(shell.panel.frame.maxY - expected.maxY) <= 0.5,
              abs(shell.panel.frame.minX - expected.minX) <= 0.5 else { throw Failure("placement", "AppKit displaced the surface from the bezel: actual=\(shell.panel.frame), expected=\(expected)") }
        guard abs(shell.panel.frame.width - expected.width) <= 0.5, abs(shell.panel.frame.height - expected.height) <= 0.5 else {
            throw Failure("placement", "Settled window differs from the surface: actual=\(shell.panel.frame), expected=\(expected)")
        }
        guard let wings = layout.wings(expanded: false, wing: shell.wing) else { return }
        guard abs(shell.panel.frame.maxY - layout.frame.maxY) <= 0.5 else { throw Failure("placement", "Integrated surface is detached from the bezel") }
        if !shell.state.expanded, abs(shell.panel.frame.height - layout.topBandHeight) > 0.5 {
            throw Failure("placement", "Collapsed virtual or physical notch does not fill its top band")
        }
        guard shell.panel.level == .statusBar else { throw Failure("placement", "Integrated surface is below the menu bar level") }
        guard shell.surface.integrated, shell.surface.band == layout.topBandHeight else { throw Failure("placement", "Surface does not use the integrated flare and band") }
        func walk(_ view: NSView) throws {
            guard !view.isHidden else { return }
            let global = shell.panel.convertToScreen(view.convert(view.bounds, to: nil))
            let id = view.identifier?.rawValue
            if id == "panel", global.maxY > layout.frame.maxY - layout.topBandHeight + 0.5 { throw Failure("placement", "Panel controls overlap the top band") }
            if (id == "notch-left-wing" || id == "notch-right-wing"), global.width > 0, global.height > 0 {
                let clearArea = id == "notch-left-wing" ? wings.left : wings.right
                guard clearArea.insetBy(dx: -0.5, dy: -0.5).contains(global), layout.cameraHousing.map({ !global.intersects($0) }) ?? true else {
                    throw Failure("placement", "Status content overlaps the camera or bezel: \(id ?? "") \(global) area=\(clearArea) wing=\(shell.wing) expanded=\(shell.state.expanded) fitting=\(view.fittingSize)")
                }
            }
            for child in view.subviews { try walk(child) }
        }
        if let view = shell.panel.contentView { try walk(view) }
    }

    /// Exercise the real drag callbacks and persistence without moving the system pointer.
    private static func checkNudge(_ run: SnapshotRun, prefix: String = "placement-nudge") throws {
        let shell = run.shell
        guard let original = shell.layout else { return }
        if original.integratesCameraHousing {
            guard shell.panel.canNudge?() == false else { throw Failure("notch-nudge", "Physical housing is movable") }
            run.pass(prefix == "placement-nudge" ? "notch-nudge" : "virtual-notch-nudge")
            return
        }
        let saved = shell.general.pillOffsets
        defer { shell.updateGeneral { $0.pillOffsets = saved } }
        shell.updateGeneral { $0.pillOffsets = [:] }
        guard shell.panel.canNudge?() == true, let centered = shell.layout else { throw Failure("notch-nudge", "Virtual housing cannot be nudged") }
        let width = centered.surface(expanded: false, wing: shell.wing).width
        for direction in [CGFloat(-1), 1] {
            shell.panel.nudged?(direction * 100)
            guard let moved = shell.layout, abs(moved.offset - direction * 100) < 0.5 else { throw Failure("notch-nudge", "Drag did not follow the pointer") }
            try checkPlacement(shell: shell, layout: moved)
            shell.panel.nudgeEnded?(false, direction * 100_000)
            guard let settled = shell.layout, abs(settled.offset - direction * centered.offsetLimit(width: width)) < 0.5,
                  shell.general.pillOffsets.values.contains(Double(settled.offset)) else { throw Failure("notch-nudge", "Flick did not snap and save a per-display offset") }
            try checkPlacement(shell: shell, layout: settled)
            run.notch(prefix + (direction < 0 ? "-left" : "-right"))
            shell.open(keyboard: false)
            guard shell.panel.canNudge?() == false else { throw Failure("notch-nudge", "Open panel can be dragged") }
            if let layout = shell.layout { try checkPlacement(shell: shell, layout: layout) }
            run.notch(prefix + (direction < 0 ? "-left-open" : "-right-open"))
            shell.close(restoreFocus: false)
            shell.panel.nudgeEnded?(true, 0)
            guard shell.layout?.offset == 0, shell.general.pillOffsets.isEmpty else { throw Failure("notch-nudge", "Double click did not recenter") }
        }
        run.pass(prefix == "placement-nudge" ? "notch-nudge" : "virtual-notch-nudge")
    }

    /// A failed check: its name and what went wrong.
    struct Failure: Error, CustomStringConvertible {
        let check: String
        let description: String
        init(_ check: String, _ description: String) { self.check = check; self.description = description }
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
            interval(shell: shell, label: "collapsed, all modules enabled, nothing active") { quiet, limits in
                guard let stats, let defaults else { return write(shell: shell, output: output, ready: ready, quiet: quiet, wings: nil, limits: limits) }
                stats.set { $0 = defaults }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    interval(shell: shell, label: "collapsed, default System stats wings (CPU, memory)", prefix: "stats_wings_interval.") { wings, wingLimits in
                        write(shell: shell, output: output, ready: ready, quiet: quiet, wings: wings, limits: limits + wingLimits)
                    }
                }
            }
        }
    }

    /// One interval's measurements, and the hard limits checked against them.
    private static func interval(shell: ShellController, label: String, prefix: String = "", done: @escaping ([String: Any], [PerformanceLimit]) -> Void) {
        let before = sample()
        let surfaceRevision = shell.surfaceRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            let after = sample()
            let elapsed = after.time - before.time
            let cpu = (after.cpu - before.cpu) / elapsed * 100
            let limits = PerformanceLimits.check(cpuPercent: cpu, drawCallbacks: after.draws - before.draws, residentBytes: after.resident, prefix: prefix)
            done([
                "state": shell.state.expanded || shell.surfaceRevision != surfaceRevision ? "presentation activity observed; not a quiet collapsed interval" : label,
                "surface_rebuilds_delta": shell.surfaceRevision - surfaceRevision,
                "panel_expanded_at_end": shell.state.expanded,
                "interval_seconds": elapsed,
                "cpu_percent_one_core": cpu,
                "resident_bytes_start": before.resident, "resident_bytes_end": after.resident,
                "phys_footprint_bytes_end": after.footprint,
                "interrupt_wakeups_delta": after.wakeups - before.wakeups,
                "app_draw_callbacks_delta": after.draws - before.draws
            ], limits)
        }
    }

    /// Writes `performance.json` and quits: exit 1 when a limit is exceeded.
    private static func write(shell: ShellController, output: URL, ready: TimeInterval, quiet: [String: Any], wings: [String: Any]?, limits: [PerformanceLimit]) {
        var report: [String: Any] = quiet
        report.merge([
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled",
            "source_revision": Bundle.main.object(forInfoDictionaryKey: "QNotchSourceRevision") as? String ?? "unknown",
            "source_dirty": Bundle.main.object(forInfoDictionaryKey: "QNotchSourceDirty") as? Bool ?? true,
            "hardware_model": hardwareModel(), "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "platform": "macOS", "architecture": "arm64", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "enabled_modules": ModuleList.all.map(\.id).filter { shell.general.isEnabled($0) },
            "process_start_to_panel_ordered_seconds": ready, "startup_seconds": ready,
            "method": "proc_pid_rusage RUSAGE_INFO_V2; app draw counters; 30-second intervals after a warmup",
            "launch_method": "mach_absolute_time minus ri_proc_start_abstime; panel ordered front, before compositor presentation",
            "limits": limits.map(\.json)
        ]) { current, _ in current }
        if let wings { report["stats_wings_interval"] = wings }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("performance.json"))
        } catch { fputs("Unable to write performance report\n", stderr); exit(1) }
        let exceeded = limits.filter { !$0.ok }
        guard exceeded.isEmpty else {
            for limit in exceeded { fputs("Limit exceeded: \(limit.name) \(limit.measured) > \(limit.limit)\n", stderr) }
            shell.stop()
            exit(1)
        }
        NSApp.terminate(nil)
    }
}

