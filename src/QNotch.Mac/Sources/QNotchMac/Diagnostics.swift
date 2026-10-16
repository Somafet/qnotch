import AppKit
import QNotchMacCore
import Darwin

enum NativeSmokeTest {
    static func run(shell: ShellController, output: URL, ready: TimeInterval) {
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
                try snapshotCards(shell: shell, output: output)
                if let stats = shell.modules.lazy.compactMap({ $0 as? StatsModule }).first {
                    guard stats.hasScheduledWake, stats.sampleCount > 0 else { throw Failure("System stats did not sample while its card was visible") }
                }
                shell.selectTab("search")
                try shell.snapshot(to: output.appendingPathComponent("search.png"))
                shell.selectTab("timer")
                try shell.snapshot(to: output.appendingPathComponent("timer.png"))
                if let tray = shell.modules.lazy.compactMap({ $0 as? FileTrayModule }).first {
                    guard shell.surface.registeredDraggedTypes.contains(.fileURL) else { throw Failure("The notch does not accept file drops") }
                    let folder = shell.store.directory.appendingPathComponent("tray-sample", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let files = ["Quarterly report.pdf", "Notes.txt", "Screenshot.png", "Archive.zip", "Budget.numbers"].map { folder.appendingPathComponent($0) }
                    for file in files { try Data("QNotch smoke".utf8).write(to: file) }
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
                        guard shell.state.presentation == .hover, shell.activeTab == "home" else { throw Failure("Finishing did not open the panel on Home without the keyboard") }
                        guard timer.countdown.finished, timer.wakeCount == 1 else { throw Failure("Collapsed deadline did not finish with one wake (finished=\(timer.countdown.finished), wakes=\(timer.wakeCount))") }
                        shell.open(keyboard: true)
                        guard shell.panel.canBecomeKey, shell.panel.isKeyWindow, shell.state.acceptsKeyboard else { throw Failure("Explicit summon did not grant keyboard") }
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
                        shell.openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            do {
                                try shell.settings?.snapshotPages(to: output)
                                shell.settings?.window.close()
                                let report = "Native UI smoke: actual window placement verified; camera center reserved; hover preserves focus; explicit summon grants keyboard; Escape collapses; running timer shows its status wing; toggle and search hotkeys work; timer completes hidden with one wake and opens Home; disabled module not constructed; every Home card rendered; file tray accepts drops and lists files; pin, card hiding and accent applied; mic and camera segment shown; system stats sampled; note saved after its debounce; interactive controls named; every settings page rendered.\nstartup_seconds=\(ready)\ndone\n"
                                try Data(report.utf8).write(to: output.appendingPathComponent("smoke.txt"))
                                NSApp.terminate(nil)
                            } catch { fail(error, output: output) }
                        }
                    } catch { fail(error, output: output) }
                }
            } catch { fail(error, output: output) }
        }
    }
    /// One PNG per Home card (cards past the first rows are scrolled out of home.png).
    private static func snapshotCards(shell: ShellController, output: URL) throws {
        guard let root = shell.panel.contentView else { return }
        var found: [String: NSView] = [:]
        func walk(_ view: NSView) {
            if let id = view.identifier?.rawValue, id.hasPrefix("card-") { found[String(id.dropFirst(5))] = view }
            view.subviews.forEach(walk)
        }
        walk(root)
        for card in shell.registries.cards.items {
            guard let view = found[card.id] else { throw Failure("Home card \(card.id) is not on Home") }
            try ShellController.snapshot(view: view, to: output.appendingPathComponent("card-\(card.id).png"))
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
            if id == "notch-panel-body", global.maxY > housing.minY + 0.5 { throw Failure("Panel controls overlap the camera band") }
            if (id == "notch-left-wing" || id == "notch-right-wing"), global.width > 0, global.height > 0 {
                let clearArea = id == "notch-left-wing" ? wings.left : wings.right
                guard clearArea.insetBy(dx: -0.5, dy: -0.5).contains(global), !global.intersects(housing) else {
                    throw Failure("Status content overlaps the camera or bezel: \(id ?? "") \(global)")
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
    private static func fail(_ error: Error, output: URL) {
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

