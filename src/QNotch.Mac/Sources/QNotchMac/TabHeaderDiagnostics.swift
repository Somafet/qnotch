import AppKit

/// Runs with offscreen snapshots as well as graphical smoke: real registered module views,
/// real host geometry and accessibility, independent of the module's body layout.
enum TabHeaderDiagnostics {
    static func check(_ run: SnapshotRun, id: String, title: String) -> [String] {
        guard let page = run.shell.currentBody as? TabPageView else {
            run.fail("tab-headers", "\(id) has no shared header")
            return []
        }
        page.layoutSubtreeIfNeeded()
        let header = page.header.frame, body = page.content.frame
        func require(_ condition: Bool, _ message: String) {
            if !condition { run.fail("tab-headers", "\(id): " + message) }
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        let hasActions = page.actions != nil
        let expectedHeader: CGFloat = hasActions ? TabPageView.actionRowHeight : 0
        let expectedGap: CGFloat = hasActions ? TabPageView.bodyGap : 0
        require(page.superview.map { near(page.frame.minX, $0.bounds.minX) && near(page.frame.width, $0.bounds.width) } == true, "page shifted the host leading edge")
        require(near(header.height, expectedHeader) && near(header.maxY, page.bounds.maxY), "action row is not fixed at the top")
        require(near(header.minY - body.maxY, expectedGap) && near(body.minX, 0) && near(body.width, page.bounds.width), "body gap/leading edge drifted")
        require(page.accessibilityRole() == .group && page.accessibilityLabel() == title, "page lost its accessible name")
        func visibleTitle(_ view: NSView) -> Bool {
            !view.isHidden && ((view as? NSTextField)?.stringValue == title || view.subviews.contains(where: visibleTitle))
        }
        require(!visibleTitle(page), "shows an in-page title; the tab bar already names the page")
        require(Outline.unnamedControls(in: Outline.text(for: page)).isEmpty, "an action or body control has no accessible name")
        var log = ["\(id) page=\(page.frame) header=\(header) body=\(body)"]
        if let actions = page.actions, !actions.isHidden {
            require(page.header.bounds.insetBy(dx: -1, dy: -1).contains(actions.frame), "actions escape the fixed row")
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
