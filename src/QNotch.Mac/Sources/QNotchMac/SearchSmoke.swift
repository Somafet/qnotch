import AppKit

/// Populated Search exercises the real shell host and field editor with in-memory sources.
enum NativeSearchSmoke {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = "search-containment: " + message }
    }

    static func check(_ run: SnapshotRun) throws {
        let shell = run.shell
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let root = shell.panel.contentView,
              let view = descendants(root).compactMap({ $0 as? SearchView }).first,
              let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView, let host = view.superview,
              let editor = view.field.currentEditor() else { throw Failure("Missing Search viewport or field editor") }
        let sources = shell.registries.searchSources
        let owner = sources.owner
        sources.owner = "search-smoke"
        var count = 0
        var activated: [Int] = []
        sources.register(SearchSource(id: "search-smoke-first", order: -2) { query in
            guard query == "qnotch-smoke" else { return [] }
            return (0..<min(count, 5)).map { index in
                SearchHit(title: "Result \(index + 1): " + String(repeating: "long title ", count: 15),
                          detail: String(repeating: "Long search containment fixture detail. ", count: 12),
                          run: { activated.append(index) })
            }
        })
        sources.register(SearchSource(id: "search-smoke-last", order: -1) { query in
            query == "qnotch-smoke" && count == 6 ? [SearchHit(title: "Last result", detail: "Return opens Home", run: {
                activated.append(5)
                shell.selectTab("home")
            })] : []
        })
        sources.owner = owner
        defer { sources.removeAll(owner: "search-smoke"); view.clear() }
        let commands = DebugCommands(shell: shell, dataDirectory: shell.store.directory)
        func key(_ name: String) throws { _ = try commands.perform("key", Arguments(values: ["name": name])) }
        func type(_ text: String) throws {
            editor.selectAll(nil)
            if text.isEmpty { try key("Backspace") }
            else { _ = try commands.perform("type", Arguments(values: ["text": text, "id": "search-field"])) }
            root.layoutSubtreeIfNeeded()
        }
        func buttons() -> [HoverButton] { descendants(document).compactMap { $0 as? HoverButton } }
        func selected(_ index: Int) -> Bool {
            buttons().filter { $0.isAccessibilitySelected() }.map { $0.identifier?.rawValue } == ["search-result-\(index)"]
        }
        func frame(_ child: NSView) -> NSRect { shell.panel.convertToScreen(child.convert(child.bounds, to: nil)) }
        let windowFrame = shell.panel.frame
        let hostFrame = host.frame
        let fieldFrame = frame(view.field)
        var frames = ["coordinates=AppKit screen points (bottom-left origin)", "window=\(windowFrame) expected=\(String(describing: shell.expectedFrame))"]
        func bounded(_ state: String) throws {
            root.layoutSubtreeIfNeeded()
            frames.append("\(state) window=\(shell.panel.frame) host=\(host.frame) search=\(view.frame) field_screen=\(frame(view.field)) viewport=\(scroll.frame) document=\(document.frame) visible=\(scroll.documentVisibleRect)")
            run.log("search-frames", frames)
            guard shell.panel.frame == windowFrame, host.frame == hostFrame, frame(view.field) == fieldFrame,
                  view.frame.size == host.bounds.size, view.bounds.contains(scroll.frame),
                  scroll.frame.height == host.bounds.height - 46,
                  shell.panel.firstResponder === editor, Outline.focused(view.field) else {
                throw Failure("Panel, host, field or keyboard focus changed at \(state)")
            }
        }
        for total in [0, 1, 5, 6] {
            count = total
            try type("qnotch-smoke")
            try bounded("hits=\(total)")
            guard buttons().count == total else { throw Failure("Expected \(total) results") }
        }
        run.notch("search-populated")
        for _ in 0..<5 { try key("Down") }
        try bounded("last-selected")
        guard selected(5), let last = buttons().last?.superview,
              scroll.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5).contains(last.convert(last.bounds, to: document)),
              scroll.documentVisibleRect.minY > 0 else { throw Failure("Down did not select and reveal the last row") }
        guard let detail = descendants(last).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "Return opens Home" }),
              detail.frame.width >= detail.intrinsicContentSize.width else { throw Failure("Short detail is unnecessarily truncated") }
        run.notch("search-last-selected")
        try key("Down")
        guard selected(5) else { throw Failure("Down did not clamp to the last row") }
        for _ in 0..<8 { try key("Up") }
        guard selected(0), scroll.documentVisibleRect.minY == 0 else { throw Failure("Up did not reveal and clamp to the first row") }
        for _ in 0..<5 { try key("Down") }
        try key("Return")
        guard activated == [5], shell.activeTab == "home", shell.panel.frame == windowFrame else {
            throw Failure("Return did not activate only the selected last result and open Home")
        }
        shell.selectTab("search")
        count = 1
        try type("qnotch-smoke")
        guard selected(0) else { throw Failure("A shorter query result set retained stale selection") }
        try key("Return")
        guard activated == [5, 0] else { throw Failure("Return did not use the refreshed result") }
        try type("no-matching-search-fixture")
        try key("Down")
        try key("Return")
        try bounded("no-results")
        try type("")
        try key("Up")
        try key("Return")
        try bounded("empty-query")
        guard buttons().isEmpty, activated == [5, 0] else { throw Failure("Empty results activated a stale hit") }
        run.pass("search-containment")
    }
}
