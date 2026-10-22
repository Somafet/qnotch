import AppKit
import QNotchMacCore

extension NativeSmokeTest {
    static func checkHomeCardSizes(_ run: SnapshotRun) throws {
        let shell = run.shell
        let original = shell.general
        defer {
            shell.setEditing(false)
            shell.updateGeneral { $0 = original }
            shell.close(restoreFocus: false)
        }
        shell.open(keyboard: true)
        shell.selectTab("home")
        shell.setEditing(true)
        let home = shell.currentBody as? HomeView
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw Failure("home-card-sizes", message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func boundedViews(_ view: NSView) -> [NSView] {
            guard !view.isHidden else { return [] }
            return [view] + (view is NSScrollView ? [] : view.subviews.flatMap(boundedViews))
        }
        let cards = shell.registries.cards.items
        let cached = cards.compactMap { shell.cachedCard($0.id) }
        try require(home != nil && cached.count == cards.count, "Missing Home or card content")
        let timer = shell.module(TimerModule.self)
        timer?.startShortTimer(seconds: 180)
        let deadline = timer?.countdown.deadline
        for card in cards {
            try require(card.supportedCardSizes.contains(.small), "No Small layout for \(card.id)")
            guard card.supportedCardSizes.count > 1 else { continue }
            try require(shell.cachedCard(card.id) is HomeCardSizing, "No size adaptation for \(card.id)")
            let handles = (home.map(descendants) ?? []).compactMap { $0 as? HomeResizeHandle }.filter {
                $0.identifier?.rawValue.hasPrefix("home-resize-" + card.id + "-") == true
            }
            try require(handles.count == 2, "Missing edge anchors for \(card.id)")
            for (round, size) in [HomeCardSize.small, .medium, .small].enumerated() {
                let handle = handles[round % 2]
                let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: home?.documentView?.superview)
                try require(home?.documentView?.hitTest(point) === handle, "Edit mode intercepts edge drags")
                let before = shell.general.cardSizes
                let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
                let startUnit = SnapshotViews.cardViews(shell)["system"]?.frame.width ?? 0
                let delta = CGFloat(size.rawValue - handle.currentSize.rawValue) * (startUnit + HomeView.gap) * CGFloat(handle.direction)
                func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                                       timestamp: 0, windowNumber: shell.panel.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                handle.mouseDown(with: event(.leftMouseDown, 0))
                handle.mouseDragged(with: event(.leftMouseDragged, delta))
                try require(shell.general.cardSizes == before, "Drag preview wrote settings before release")
                handle.mouseUp(with: event(.leftMouseUp, delta))
                shell.panel.contentView?.layoutSubtreeIfNeeded()
                let hosts = SnapshotViews.cardViews(shell)
                guard let host = hosts[card.id], let unit = hosts["system"]?.frame.width else {
                    throw Failure("home-card-sizes", "Missing resized host")
                }
                try require(abs(host.frame.width - (unit * CGFloat(size.rawValue) + HomeView.gap * CGFloat(size.rawValue - 1))) < 1,
                            "Wrong \(size.title) width for \(card.id)")
                for view in descendants(host) where !view.isHiddenOrHasHiddenAncestor && view !== host {
                    let rect = view.convert(view.bounds, to: host)
                    try require(host.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                                "\(card.id) \(size.title) content escapes the card: \(type(of: view)) \(rect)")
                }
                try require(shell.general.cardSizes[card.id] == size.rawValue, "Size was not saved")
                try require(SettingsStore(directory: shell.store.directory).load("general", default: GeneralSettings()).cardSizes[card.id] == size.rawValue,
                            "Size did not survive a fresh settings read")
                try require(cached.allSatisfy { view in cards.contains { shell.cachedCard($0.id) === view } }, "Resize recreated card state")
                try require(timer?.countdown.deadline == deadline, "Resize restarted the timer")
            }
        }
        shell.updateGeneral { settings in for card in cards { settings.cardSizes[card.id] = 1 } }
        shell.panel.contentView?.layoutSubtreeIfNeeded()
        let hosts = SnapshotViews.cardViews(shell)
        let unit = hosts["system"]?.frame.width ?? 0
        for card in cards {
            guard let host = hosts[card.id] else { throw Failure("home-card-sizes", "Missing \(card.id)") }
            try require(abs(host.frame.width - unit) < 1, "Small is not one column for \(card.id)")
            try require(hosts.values.allSatisfy { $0 === host || !$0.frame.intersects(host.frame) }, "Cards overlap after resizing")
            for view in boundedViews(host) {
                try require(host.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: host)),
                            "\(card.id) Small content escapes the card: \(type(of: view))")
            }
        }
        // Rebuild Home as on a later launch, retaining its saved widths and cached content.
        shell.updateGeneral { $0.setCardVisible("weather", false) }
        shell.updateGeneral { $0.setCardVisible("weather", true) }
        shell.panel.contentView?.layoutSubtreeIfNeeded()
        try require(SnapshotViews.cardViews(shell).values.allSatisfy { abs($0.frame.width - unit) < 1 }, "Rebuilt Home lost the saved sizes")
        shell.setEditing(false)
        try require((shell.currentBody.map(descendants) ?? []).compactMap { $0 as? HomeResizeHandle }.allSatisfy(\.isHidden), "Resize controls remain outside edit mode")
        timer?.reset()
        run.pass("home-card-sizes")
    }
}
