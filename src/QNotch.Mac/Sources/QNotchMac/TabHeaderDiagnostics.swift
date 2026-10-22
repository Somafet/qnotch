import AppKit

/// Runs with offscreen snapshots as well as graphical smoke: real registered module views,
/// real host geometry and accessibility, independent of the module's body layout.
enum TabHeaderDiagnostics {
    static func check(_ run: SnapshotRun, id: String, title: String, baseline: inout CGFloat?) -> [String] {
        guard let page = run.shell.currentBody as? TabPageView else {
            run.fail("tab-headers", "\(id) has no shared header")
            return []
        }
        page.layoutSubtreeIfNeeded()
        let header = page.header.frame, body = page.content.frame
        // NSTextField's drawing frame extends 2pt past its optical alignment edges.
        let heading = page.heading.alignmentRect(forFrame: page.heading.frame)
        let titleBaseline = header.height - page.heading.frame.maxY + page.heading.firstBaselineOffsetFromTop
        let expectedBaseline = baseline ?? titleBaseline
        baseline = expectedBaseline
        func require(_ condition: Bool, _ message: String) {
            if !condition { run.fail("tab-headers", "\(id): " + message) }
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        require(page.superview.map { near(page.frame.minX, $0.bounds.minX) && near(page.frame.width, $0.bounds.width) } == true, "page shifted the host leading edge")
        require(near(header.height, 28) && near(header.maxY, page.bounds.maxY), "title row is not fixed at the top")
        require(near(heading.minX, 0) && near(titleBaseline, expectedBaseline), "title origin/baseline drifted")
        require(near(header.minY - body.maxY, 12) && near(body.minX, 0) && near(body.width, page.bounds.width), "body gap/leading edge drifted")
        require(page.heading.stringValue == title && page.heading.font == .systemFont(ofSize: 14, weight: .semibold), "wrong title/type scale")
        require(page.accessibilityRole() == .group && page.accessibilityLabel() == title && page.accessibilityTitleUIElement() as? NSView === page.heading, "missing named title landmark")
        require(Outline.unnamedControls(in: Outline.text(for: page)).isEmpty, "an action or body control has no accessible name")
        var log = ["\(id) page=\(page.frame) header=\(header) title=\(heading) title_baseline_from_top=\(titleBaseline) body=\(body)"]
        if let actions = page.actions, !actions.isHidden {
            require(page.header.bounds.insetBy(dx: -1, dy: -1).contains(actions.frame), "actions escape the fixed row")
            require(heading.maxX <= actions.frame.minX - 11, "title overlaps actions")
            var trailing: CGFloat?
            func inspect(_ view: NSView) {
                guard !view.isHidden else { return }
                if let button = view as? NSButton {
                    let frame = button.convert(button.bounds, to: page.header)
                    require(page.header.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(button.accessibilityLabel() ?? button.title) is clipped")
                    trailing = max(trailing ?? frame.maxX, frame.maxX)
                    log.append("\(id) action=\(button.accessibilityLabel() ?? button.title) frame=\(frame)")
                }
                view.subviews.forEach(inspect)
            }
            inspect(actions)
            if let trailing { require(near(trailing, page.header.bounds.maxX), "actions are not trailing-aligned") }
        }
        return log
    }
}
