import AppKit
import QNotchMacCore

/// Verify the real AppKit frames, including integral placement and open-panel reparenting.
enum StatusGutterSmoke {
    /// Drive the existing segment views with diagnostic values, restoring their module-owned
    /// visibility afterwards. This exercises the shell's real fitting, placement and hit targets.
    static func exercise(_ run: SnapshotRun) throws {
        let shell = run.shell
        shell.endPeek()
        shell.close(restoreFocus: false)
        let roots = shell.surface.subviews.compactMap { $0 as? NSStackView }.filter {
            ["notch-left-wing", "notch-right-wing"].contains($0.identifier?.rawValue ?? "")
        }
        // A floating pill owns the roots instead of the surface itself.
        func segments(in view: NSView) -> [NSView] {
            if let stack = view as? NSStackView,
               ["notch-left-wing", "notch-right-wing"].contains(stack.identifier?.rawValue ?? "") {
                return stack.arrangedSubviews.compactMap { $0.subviews.first }
            }
            return view.subviews.flatMap { segments(in: $0) }
        }
        let items = roots.isEmpty ? segments(in: shell.surface) : roots.flatMap { segments(in: $0) }
        let saved = items.map { ($0, $0.isHidden) }
        guard let cpu = items.first(where: { $0.identifier?.rawValue == "stats-cpu" }),
              let value = cpu.subviews.compactMap({ $0 as? NSTextField }).last else {
            throw Failure("Status gutter fixtures require the default CPU segment")
        }
        let text = value.stringValue
        defer {
            value.stringValue = text
            saved.forEach { $0.0.isHidden = $0.1 }
            shell.close(restoreFocus: false)
            shell.segmentsChanged()
        }
        for (name, ids, percent) in [
            ("empty", [String](), "4%"),
            ("cpu-4", ["stats-cpu"], "4%"),
            ("cpu-55", ["stats-cpu"], "55%"),
            ("cpu-100", ["stats-cpu"], "100%"),
            ("right-only", ["stats-memory"], "4%"),
            ("mixed", ["stats-cpu", "stats-memory", "weather-segment"], "4%")
        ] {
            value.stringValue = percent
            for item in items { item.isHidden = !ids.contains(item.identifier?.rawValue ?? "") }
            shell.segmentsChanged()
            guard (shell.wing == 0) == ids.isEmpty else { throw Failure("\(name): missing or unexpected status content") }
            let collapsed = try check(run, phase: name)
            if name == "mixed" {
                shell.open(keyboard: false)
                let expanded = try check(run, phase: "mixed-open")
                if shell.layout?.integratesTopBand == true, collapsed != expanded {
                    throw Failure("Opening moved the status clusters: \(collapsed) -> \(expanded)")
                }
            }
        }
    }

    @discardableResult
    static func check(_ run: SnapshotRun, phase: String) throws -> [String: CGRect] {
        let shell = run.shell
        guard let layout = shell.layout else { return [:] }
        shell.surface.layoutSubtreeIfNeeded()
        var records = ["\(phase): window=\(shell.panel.frame) expanded=\(shell.state.expanded) wing=\(shell.wing)"]
        var frames: [String: CGRect] = [:]
        func walk(_ view: NSView) throws {
            guard !view.isHidden else { return }
            let id = view.identifier?.rawValue
            if let id, id == "notch-left-wing" || id == "notch-right-wing" {
                let frame = shell.panel.convertToScreen(view.convert(view.bounds, to: nil))
                frames[id] = frame
                records.append("  \(id): actual=\(frame) fitting=\(view.fittingSize)")
                if let wings = layout.wings(expanded: false, wing: shell.wing) {
                    let left = id == "notch-left-wing"
                    let area = left ? wings.left : wings.right
                    let outer = left ? frame.minX - area.minX : area.maxX - frame.maxX
                    let camera = left ? area.maxX - frame.maxX : frame.minX - area.minX
                    records.append("    outer_gutter=\(outer) camera_clearance=\(camera) vertical_offset=\(frame.midY - area.midY)")
                    guard abs(outer - 12) <= 1, camera >= 11, abs(frame.midY - area.midY) <= 1 else {
                        throw Failure("\(phase): \(id) has inconsistent gutters: \(records.last!)")
                    }
                } else if let pill = view.superview {
                    let actual = shell.panel.convertToScreen(pill.convert(pill.bounds, to: nil))
                    let expected = layout.surface(expanded: false, wing: shell.wing)
                    guard abs(actual.midX - expected.midX) <= 1, abs(actual.midY - expected.midY) <= 1 else {
                        throw Failure("\(phase): floating pill lost its centered content: \(actual)")
                    }
                }
            }
            for child in view.subviews { try walk(child) }
        }
        try walk(shell.surface)
        let url = run.output.appendingPathComponent("status-gutters.log")
        let previous = (try? Data(contentsOf: url)) ?? Data()
        try (previous + Data((records.joined(separator: "\n") + "\n").utf8)).write(to: url)
        run.notch("placement-gutters-" + phase)
        return frames
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
