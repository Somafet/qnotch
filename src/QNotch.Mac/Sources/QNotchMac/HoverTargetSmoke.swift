import AppKit
import QNotchMacCore

/// Uses the real contributions and live AppKit slots; no other app, pointer or settings is touched.
enum HoverTargetSmoke {
    static func check(_ run: SnapshotRun) throws {
        let shell = run.shell
        let original = shell.general
        let wasRenderOnly = shell.renderOnly
        shell.renderOnly = true
        defer {
            shell.close(restoreFocus: false)
            shell.pointerLeft()
            shell.updateGeneral { $0 = original }
            shell.renderOnly = wasRenderOnly
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NativeSmokeTest.Failure("hover-targets", message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func selected(_ metric: String) -> Bool {
            guard let body = shell.currentBody else { return false }
            return descendants(body).contains { $0.identifier?.rawValue == "system-metric-" + metric && $0.isAccessibilitySelected() }
        }
        shell.endPeek()
        let settings = shell.makeSettings()
        settings.select("general", animated: false)
        guard let page = settings.window.contentView,
              let toggle = descendants(page).first(where: { $0.identifier?.rawValue == "hover-opens-segment" }) as? ActionSwitch else {
            throw NativeSmokeTest.Failure("hover-targets", "Missing General hover option")
        }
        toggle.state = .on
        toggle.changed(true)
        let saved = shell.store.load("general", default: GeneralSettings())
        try require(saved.hoverOpensSegment, "General option did not persist")
        shell.updateGeneral { $0.setCardVisible("system", true) }
        shell.close(restoreFocus: false)
        shell.pointerLeft()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (segment, metric) in [("cpu", "cpu"), ("memory", "ram")] {
            shell.surface.layoutSubtreeIfNeeded()
            guard let slot = descendants(shell.surface).compactMap({ $0 as? SegmentSlotView }).first(where: { $0.segmentID == "stats." + segment }),
                  !slot.isHiddenOrHasHiddenAncestor else { throw NativeSmokeTest.Failure("hover-targets", "Missing visible \(segment) status") }
            let frame = shell.panel.convertToScreen(slot.convert(slot.bounds, to: nil))
            let point = NSPoint(x: frame.midX, y: frame.midY)
            try require(shell.segmentID(at: point) == "stats." + segment, "Wrong live \(segment) hit target")
            shell.completeHover(at: point)
            try require(shell.activeTab == "home" && selected(metric), "Hover did not reveal/emphasize \(segment)")
            try require(!shell.state.acceptsKeyboard && !shell.panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                        "Hover changed foreground focus")
            run.notch("hover-" + segment)
            shell.close(restoreFocus: false)
            shell.pointerLeft()
        }
        // All four real metric destinations, including unavailable GPU/network values, remain useful.
        for (segment, metric) in [("cpu", "cpu"), ("memory", "ram"), ("gpu", "gpu"), ("network", "net")] {
            shell.activateSegment("stats." + segment)
            try require(selected(metric), "Explicit \(segment) activation lost emphasis")
        }
        shell.updateGeneral { $0.setCardVisible("system", false) }
        let hidden = shell.general
        shell.activateSegment("stats.memory")
        try require(shell.currentBody?.identifier?.rawValue == "segment-detail-system" && selected("ram"), "Hidden System detail missing")
        try require(shell.general == hidden, "Opening details changed saved Home layout")
        run.notch("hover-memory-hidden")
        shell.selectTab("home")
        try require(shell.currentBody?.identifier?.rawValue != "segment-detail-system", "Back to Home retained detail")
        shell.activateSegment("timer.pill")
        try require(shell.activeTab == "timer", "Timer did not route to its tab")
        shell.updateGeneral { $0.setTabVisible("timer", false) }
        shell.activateSegment("timer.pill")
        try require(shell.activeTab == "home", "Hidden Timer did not fall back to Home")
        run.pass("hover-targets")
    }
}

extension HoverTargetSmoke {
    /// Graphical smoke only: move the OS pointer and run the production dwell work item. Entry and
    /// exit use the same callbacks as tracking areas; this is scripted evidence, not a human trial.
    static func exerciseDwell(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        let original = shell.general
        let gameOverride = shell.gameMode.override
        let pointer = CGEvent(source: nil)?.location
        let stats = shell.module(StatsModule.self)
        let statsSettings = stats?.settings
        var records: [String] = []
        let previousTrace = shell.hoverTrace
        shell.hoverTrace = { records.append($0) }
        func record(_ stage: String) {
            records.append("t=\(ProcessInfo.processInfo.systemUptime) stage=\(stage) cocoa=\(NSEvent.mouseLocation) quartz=\(String(describing: CGEvent(source: nil)?.location)) window=\(shell.panel.frame) expected=\(String(describing: shell.expectedFrame)) shape=\(shell.surface.shapeRect) morphing=\(shell.surface.isMorphing) state=\(shell.state.presentation) tab=\(shell.activeTab)")
            func walk(_ view: NSView) {
                if let slot = view as? SegmentSlotView {
                    records.append("  \(slot.segmentID) hidden=\(slot.isHiddenOrHasHiddenAncestor) frame=\(shell.panel.convertToScreen(slot.convert(slot.bounds, to: nil)))")
                }
                view.subviews.forEach(walk)
            }
            walk(shell.surface)
        }
        var finished = false
        func finish(_ error: Error?) {
            guard !finished else { return }
            finished = true
            record("finish error=\(String(describing: error))")
            if error != nil { run.notch("hover-dwell-failed") }
            run.log("hover-dwell", records)
            shell.hoverTrace = previousTrace
            shell.close(restoreFocus: false)
            shell.pointerLeft()
            shell.updateGeneral { $0 = original }
            if let statsSettings { stats?.set { $0 = statsSettings } }
            shell.gameMode.override = gameOverride
            if let pointer { CGWarpMouseCursorPosition(pointer) }
            done(error)
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NativeSmokeTest.Failure("hover-dwell", message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func point(_ id: String) throws -> NSPoint {
            shell.surface.layoutSubtreeIfNeeded()
            guard let slot = descendants(shell.surface).compactMap({ $0 as? SegmentSlotView }).first(where: { $0.segmentID == id }),
                  !slot.isHiddenOrHasHiddenAncestor else { throw NativeSmokeTest.Failure("hover-dwell", "Missing live \(id)") }
            let rect = shell.panel.convertToScreen(slot.convert(slot.bounds, to: nil))
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        func move(_ point: NSPoint) throws {
            guard let primary = NSScreen.screens.first else { throw NativeSmokeTest.Failure("hover-dwell", "No primary display") }
            try require(CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.maxY - point.y)) == .success, "OS pointer move failed")
            record("warp requested=\(point)")
        }
        func selected(_ metric: String) -> Bool {
            guard let body = shell.currentBody else { return false }
            return descendants(body).contains { $0.identifier?.rawValue == "system-metric-" + metric && $0.isAccessibilitySelected() }
        }
        // AppKit may deliver an automatic entry after our explicit callback, restarting dwell.
        // Wait for the real opening instead of asserting against the first nominal deadline.
        // Never wait for a particular metric: an early/wrong opening must fail the exact assertion.
        func waitForOpening(until deadline: TimeInterval? = nil, then: @escaping () -> Void) {
            guard !finished else { return }
            let deadline = deadline ?? ProcessInfo.processInfo.systemUptime + 2
            if shell.state.expanded || ProcessInfo.processInfo.systemUptime >= deadline { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForOpening(until: deadline, then: then) }
        }
        do {
            try require(pointer != nil, "Cannot save the system pointer")
            shell.gameMode.override = .off
            shell.endPeek()
            shell.updateGeneral { $0.hoverOpensSegment = true; $0.hoverDelayMs = 250; $0.pinned = false; $0.setCardVisible("system", true) }
            stats?.set { $0.wingCPU = true; $0.wingMemory = true }
            shell.close(restoreFocus: false)
            guard let layout = shell.layout else { throw NativeSmokeTest.Failure("hover-dwell", "No display") }
            let outside = NSPoint(x: layout.frame.midX, y: layout.frame.midY)
            try move(outside)
            shell.pointerLeft()
            let cpu = try point("stats.cpu"), memory = try point("stats.memory")
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            try move(cpu)
            shell.pointerEntered()
            record("entered-cpu")
            // Cross before dwell without starting a new opening. The work item reads the final point.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                guard !finished else { return }
                do {
                    try require(!shell.state.expanded, "CPU opened before the scripted RAM crossing")
                    try move(memory)
                } catch { return finish(error) }
                waitForOpening {
                    guard !finished else { return }
                    do {
                        record("ram-deadline")
                        try require(shell.state.presentation == .hover && selected("ram"), "Dwell did not choose final RAM target")
                        try require(!shell.panel.isKeyWindow && !shell.state.acceptsKeyboard && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                                    "Dwell stole foreground keyboard focus")
                        run.notch("hover-dwell-memory")
                        try move(cpu)
                        shell.pointerEntered()
                    } catch { return finish(error) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        guard !finished else { return }
                        do {
                            try require(selected("ram"), "Crossing an expanded status switched the latched target")
                            shell.close(restoreFocus: false)
                            shell.pointerEntered()
                        } catch { return finish(error) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                            guard !finished else { return }
                            do {
                                try require(!shell.state.expanded, "Explicit close reopened under the pointer")
                                try move(outside)
                                shell.pointerLeft()
                                try move(cpu)
                                shell.pointerEntered()
                            } catch { return finish(error) }
                            waitForOpening {
                                guard !finished else { return }
                                do {
                                    try require(shell.state.presentation == .hover && selected("cpu"), "Leaving suppression did not permit a fresh CPU destination")
                                    run.notch("hover-dwell-cpu")
                                    records += ["path=pointerEntered -> production DispatchWorkItem -> NSEvent.mouseLocation -> completeHover",
                                        "cpu=\(cpu) memory=\(memory) dwell_ms=250 requested_crossing_delay_ms=70; actual timing in trace", "final_ram=ok latched_crossing=ok close_suppression=ok fresh_cpu=ok foreground_unchanged=ok",
                                        "input=scripted OS pointer warps with tracking callbacks; pointer restored after check"]
                                    run.pass("hover-dwell")
                                    finish(nil)
                                } catch { finish(error) }
                            }
                        }
                    }
                }
            }
        } catch { finish(error) }
    }
}
