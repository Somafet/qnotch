import AppKit
import QNotchMacCore
import Darwin

enum NativeSmokeTest {
    static func run(shell: ShellController, output: URL, ready: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                guard let layout = shell.layout else { throw Failure("No display available for native UI validation") }
                let placement = "camera_housing=\(layout.hasCameraHousing)\nsafe_top_points=\(layout.safeTop)\ndisplay_frame=\(layout.frame)\ncollapsed_frame=\(layout.surface(expanded: false))\nexpanded_frame=\(layout.surface(expanded: true))\n"
                try Data(placement.utf8).write(to: output.appendingPathComponent("placement.txt"))
                shell.updateGeneral { $0.reduceMotion = true }
                try shell.snapshot(to: output.appendingPathComponent("pill.png"))
                shell.open(keyboard: false)
                guard shell.state.presentation == .hover, !shell.panel.isKeyWindow, !shell.panel.canBecomeKey else {
                    throw Failure("Hover took keyboard focus")
                }
                try shell.snapshot(to: output.appendingPathComponent("home.png"))
                shell.selectTab("timer")
                try shell.snapshot(to: output.appendingPathComponent("timer.png"))
                try shell.accessibilityReport(to: output.appendingPathComponent("accessibility.txt"))
                guard let timer = shell.modules.first as? TimerModule else { throw Failure("Timer module was not constructed") }
                timer.startShortTimer(seconds: 1)
                shell.close(restoreFocus: false)
                guard !shell.panel.canBecomeKey else { throw Failure("Collapsed panel accepts keyboard") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    do {
                        guard timer.countdown.finished, timer.wakeCount == 1 else { throw Failure("Collapsed deadline did not finish with one wake (finished=\(timer.countdown.finished), wakes=\(timer.wakeCount))") }
                        shell.open(keyboard: true)
                        guard shell.panel.canBecomeKey, shell.panel.isKeyWindow, shell.state.acceptsKeyboard else { throw Failure("Explicit summon did not grant keyboard") }
                        shell.panel.cancelOperation(nil)
                        guard !shell.state.expanded else { throw Failure("Escape did not collapse") }
                        timer.startShortTimer(seconds: 60)
                        shell.updateGeneral { $0.timerEnabled = false }
                        guard shell.modules.isEmpty, shell.registries.cards.items.isEmpty, !timer.hasScheduledWake else { throw Failure("Disabled module still constructed or scheduled") }
                        shell.open(keyboard: false)
                        try shell.snapshot(to: output.appendingPathComponent("unavailable.png"))
                        shell.close(restoreFocus: false)
                        shell.updateGeneral { $0.timerEnabled = true }
                        shell.openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            do {
                                try shell.snapshotSettings(to: output.appendingPathComponent("settings.png"))
                                let report = "Native UI smoke: hover preserves focus; explicit summon grants keyboard; Escape collapses; timer completes hidden with one wake; disabled module not constructed; interactive controls named.\nstartup_seconds=\(ready)\ndone\n"
                                try Data(report.utf8).write(to: output.appendingPathComponent("smoke.txt"))
                                NSApp.terminate(nil)
                            } catch { fail(error, output: output) }
                        }
                    } catch { fail(error, output: output) }
                }
            } catch { fail(error, output: output) }
        }
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
                      resident: usage.ri_resident_size, wakeups: usage.ri_interrupt_wkups,
                      draws: RenderDiagnostics.drawCount)
    }
    static func run(shell: ShellController, output: URL, ready: TimeInterval) {
        // One warmup and one end-of-interval callback. No sampling loop changes idle behavior.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            shell.close(restoreFocus: false)
            let before = sample()
            let surfaceRevision = shell.surfaceRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                let after = sample()
                let elapsed = after.time - before.time
                let report: [String: Any] = [
                    "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled",
                    "source_revision": Bundle.main.object(forInfoDictionaryKey: "QNotchSourceRevision") as? String ?? "unknown",
                    "source_dirty": Bundle.main.object(forInfoDictionaryKey: "QNotchSourceDirty") as? Bool ?? true,
                    "hardware_model": hardwareModel(), "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
                    "platform": "macOS", "architecture": "arm64", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "state": shell.state.expanded || shell.surfaceRevision != surfaceRevision ? "presentation activity observed; not a quiet collapsed baseline" : "collapsed, timer not running",
                    "surface_rebuilds_delta": shell.surfaceRevision - surfaceRevision,
                    "panel_expanded_at_end": shell.state.expanded,
                    "interval_seconds": elapsed,
                    "process_start_to_panel_ordered_seconds": ready, "cpu_percent_one_core": (after.cpu - before.cpu) / elapsed * 100,
                    "resident_bytes_start": before.resident, "resident_bytes_end": after.resident,
                    "interrupt_wakeups_delta": after.wakeups - before.wakeups,
                    "app_draw_callbacks_delta": after.draws - before.draws,
                    "method": "proc_pid_rusage RUSAGE_INFO_V2; app draw counters; one 30-second interval after 3-second warmup",
                    "launch_method": "mach_absolute_time minus ri_proc_start_abstime; panel ordered front, before compositor presentation"
                ]
                do {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("performance.json"))
                } catch { fputs("Unable to write performance report\n", stderr); exit(1) }
                NSApp.terminate(nil)
            }
        }
    }
}
