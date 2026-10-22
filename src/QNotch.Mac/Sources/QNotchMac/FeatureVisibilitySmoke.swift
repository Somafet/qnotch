import AppKit
import QNotchMacCore

extension NativeSmokeTest {
    static func checkFeatureVisibility(_ run: SnapshotRun) throws {
        let shell = run.shell
        let original = shell.general
        let modules = shell.modules
        let shortcuts = shell.shortcuts.items
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw Failure("feature-visibility", message) }
        }
        func find(_ id: String, in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        let page = shell.makeSettings()
        page.select("features", animated: false)
        func flip(_ id: String, _ on: Bool) throws {
            guard let toggle = find(id, in: page.window.contentView) as? ActionSwitch else {
                throw Failure("feature-visibility", "Missing Settings control \(id)")
            }
            toggle.state = on ? .on : .off
            toggle.changed(on)
        }
        guard let timer = shell.module(TimerModule.self) else { throw Failure("feature-visibility", "Missing countdown") }
        timer.startShortTimer(seconds: 180)
        let deadline = timer.countdown.deadline
        shell.open(keyboard: true)
        shell.selectTab("home")
        let cards = shell.registries.cards.items
        let tabs = shell.registries.tabs.items
        let both = tabs.filter { tab in
            guard let owner = shell.registries.tabs.owner(of: tab.id) else { return false }
            return !shell.registries.cards.ids(owner: owner).isEmpty
        }
        try require(Set(both.map(\.id)) == ["media", "timer", "clipboard", "files", "notifications", "ai", "scheduled"],
                    "Card+tab coverage changed; update the regression inventory")
        for card in cards { try require(find("feature-home-" + card.id, in: page.window.contentView) != nil, "No Home control for \(card.id)") }
        for tab in tabs { try require(find("feature-tab-" + tab.id, in: page.window.contentView) != nil, "No tab control for \(tab.id)") }
        let cardViews = Dictionary(uniqueKeysWithValues: cards.compactMap { card in shell.cachedCard(card.id).map { (card.id, $0) } })
        var tabViews: [String: NSView] = [:]
        for tab in both {
            shell.selectTab(tab.id)
            tabViews[tab.id] = shell.currentBody
        }
        // Cached card/tab content survives unrelated presentation changes.
        shell.selectTab("home")
        for tab in both {
            let owner = shell.registries.tabs.owner(of: tab.id)!
            let ownedCards = cards.filter { shell.registries.cards.owner(of: $0.id) == owner }
            shell.selectTab(tab.id)
            try flip("feature-tab-" + tab.id, false)
            try require(shell.activeTab == "home" && find("tab-" + tab.id, in: shell.panel.contentView) == nil,
                        "Hiding active \(tab.id) did not return to Home/remove its strip button")
            try require(ownedCards.allSatisfy { shell.cachedCard($0.id) === cardViews[$0.id] && SnapshotViews.cardViews(shell)[$0.id] != nil }, "Hiding tab recreated or removed a Home card")
            shell.selectTab(tab.id)
            try require(shell.activeTab == tab.id && find("tab-" + tab.id, in: shell.panel.contentView) != nil
                        && shell.currentBody === tabViews[tab.id], "Hidden \(tab.id) cannot open temporarily with its cached view")
            if tab.id == "media" { run.notch("visibility-media-temporary-tab") }
            shell.selectTab("home")
            try require(find("tab-" + tab.id, in: shell.panel.contentView) == nil, "Temporary \(tab.id) button remained after leaving")
            for card in ownedCards {
                try flip("feature-home-" + card.id, false)
                try require(SnapshotViews.cardViews(shell)[card.id] == nil && shell.general.isEnabled(owner), "Hiding \(card.id) disabled its feature")
                try flip("feature-home-" + card.id, true)
                try require(shell.cachedCard(card.id) === cardViews[card.id] && SnapshotViews.cardViews(shell)[card.id] != nil, "Restoring \(card.id) recreated its view")
            }
            try flip("feature-tab-" + tab.id, true)
        }
        if let card = shell.cachedCard("note") {
            func editor(in view: NSView) -> NSTextView? {
                (view as? NSTextView) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
            }
            if let text = editor(in: card) {
                shell.panel.makeFirstResponder(text)
                try flip("feature-home-note", false)
                try require(shell.panel.firstResponder !== text && shell.cachedCard("note") === card,
                            "A hidden editor retained keyboard focus or lost its cached content")
                try flip("feature-home-note", true)
            } else { throw Failure("feature-visibility", "Missing Note editor") }
        }
        let tabOrder = shell.general.tabOrder, cardOrder = shell.general.cardOrder
        try flip("feature-tab-media", false)
        shell.updateGeneral { $0.tabOrder = LayoutOrder.reorder(Array($0.tabOrder.filter { $0 != "media" }.reversed()), saved: $0.tabOrder) }
        try flip("feature-tab-media", true)
        try require(shell.general.tabOrder.firstIndex(of: "media") == tabOrder.firstIndex(of: "media"), "Hidden tab lost its slot during a drag")
        shell.updateGeneral { $0.tabOrder = tabOrder }
        try flip("feature-home-media", false)
        shell.updateGeneral { $0.cardOrder = LayoutOrder.reorder(Array($0.cardOrder.filter { $0 != "media" }.reversed()), saved: $0.cardOrder) }
        try flip("feature-home-media", true)
        try require(shell.general.cardOrder.firstIndex(of: "media") == cardOrder.firstIndex(of: "media"), "Hidden card lost its slot during a drag")
        shell.updateGeneral { $0.cardOrder = cardOrder }

        // Segment containers stay alive; module-owned hidden flags are never overwritten by the shell.
        let segmentOwners = Set(shell.registries.segments.items.compactMap { shell.registries.segments.owner(of: $0.id) })
        for owner in segmentOwners {
            let ids = shell.registries.segments.ids(owner: owner)
            let slots = ids.compactMap { find("segment-slot-" + $0, in: shell.panel.contentView) }
            try require(slots.count == ids.count, "Missing status slots for \(owner)")
            try flip("feature-notch-" + owner, false)
            try require(slots.allSatisfy(\.isHidden), "Notch visibility failed for \(owner)")
            if owner == "timer" {
                shell.gameMode.override = .on
                try require(slots.allSatisfy(\.isHidden), "Game mode ignored regular notch visibility")
                shell.gameMode.override = .auto
                shell.open(keyboard: true)
                shell.selectTab("home")
            }
            try flip("feature-notch-" + owner, true)
            try require(zip(ids, slots).allSatisfy { find("segment-slot-" + $0.0, in: shell.panel.contentView) === $0.1 }, "Notch change recreated segments")
        }
        let searchShortcut = shell.shortcuts.shortcut("search")
        try flip("feature-tab-search", false)
        shell.summonSearch()
        try require(shell.activeTab == "search" && shell.shortcuts.shortcut("search") === searchShortcut,
                    "Hiding Search disabled its action/shortcut")
        run.notch("visibility-search-temporary-tab")
        shell.selectTab("home")
        try require(find("tab-search", in: shell.panel.contentView) == nil && find("tab-home", in: shell.panel.contentView) != nil,
                    "Leaving hidden Search did not remove its temporary tab or removed fixed Home")
        let debug = DebugCommands(shell: shell, dataDirectory: shell.store.directory)
        _ = try debug.perform("select-tab", Arguments(values: ["id": "search"]))
        try require(shell.activeTab == "search", "Debug entry cannot open hidden enabled Search")
        shell.selectTab("home")
        try flip("feature-tab-media", false)
        try flip("feature-home-media", false)
        try flip("feature-notch-media", false)
        run.notch("visibility-media-hidden")
        run.write("settings-visibility-media-hidden", page.window.contentView, background: .windowBackgroundColor)
        let saved = SettingsStore(directory: shell.store.directory).load("general", default: GeneralSettings())
        try require(saved.hiddenTabs == shell.general.hiddenTabs && saved.hiddenNotchModules == ["media"] && saved.hiddenCards == ["media"], "Visibility choices were not persisted")
        try require(modules.elementsEqual(shell.modules, by: ===) && shortcuts.elementsEqual(shell.shortcuts.items, by: ===), "Presentation changes replaced modules or shortcuts")
        try require(timer.countdown.isRunning && timer.countdown.deadline == deadline && timer.hasScheduledWake, "Presentation changes disturbed the countdown")
        // Off/on is distinct: preferences survive even though that module is reconstructed.
        try flip("feature-media", false)
        try flip("feature-media", true)
        try require(shell.module("media") != nil && !shell.general.isCardVisible("media") && !shell.general.isTabVisible("media")
                    && !shell.general.isNotchVisible("media"), "Feature enablement forgot visibility choices")
        shell.updateGeneral { $0 = original }
        page.select("features", animated: false)
        shell.selectTab("home")
        timer.reset()
        // A new shell reads hidden contributions without constructing disabled features.
        let directory = shell.store.directory.appendingPathComponent("visibility-startup")
        let store = SettingsStore(directory: directory)
        var startup = GeneralSettings()
        startup.disabledModules = ModuleList.all.map(\.id).filter { !["timer", "search"].contains($0) }
        startup.hiddenCards = ["timer"]
        startup.hiddenTabs = ["search", "timer"]
        startup.hiddenNotchModules = ["timer"]
        startup.tabOrder = ["gone", "timer"]
        store.save("general", startup)
        do {
            let boot = ShellController(store: SettingsStore(directory: directory))
            defer { boot.stop() }
            boot.renderOnly = true
            boot.openHome()
            try require(boot.modules.count == 2 && boot.activeTab == "home" && SnapshotViews.cardViews(boot).isEmpty
                        && find("tab-timer", in: boot.panel.contentView) == nil && find("tab-search", in: boot.panel.contentView) == nil,
                        "Persisted hidden choices were ignored at startup")
            boot.summonSearch()
            try require(boot.activeTab == "search", "Hidden enabled Search cannot open after relaunch")
            boot.close(restoreFocus: false)
            try require(boot.tryOpenPanel(tab: "timer", linger: 1) && boot.activeTab == "timer", "Module action cannot open a persisted hidden tab")
            try require(boot.general.tabOrder == ["gone", "timer"], "Startup changed hidden tab order")
        }
        run.log("feature-visibility", ["all_actual_card_tab_pairs=\(both.map(\.id).joined(separator: ","))", "registry_owned_controls=ok",
                                       "cached_views_modules_shortcuts_countdown_preserved=ok", "hidden_order_slots_and_persistence=ok",
                                       "temporary_action_shortcut_debug_tabs=ok", "status_slots_preserved=ok"])
        run.pass("feature-visibility")
    }
}
