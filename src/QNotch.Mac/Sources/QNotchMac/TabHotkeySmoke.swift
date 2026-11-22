import AppKit
import QNotchMacCore

extension NativeSmokeTest {
    /// Per-tab shortcuts through the real registry, Carbon registration and module lifecycle.
    static func checkTabHotkeys(_ run: SnapshotRun) throws {
        let shell = run.shell
        let original = shell.general
        let game = shell.gameMode.override
        let id = "tab.scheduled"
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw Failure("tab-hotkeys", message) }
        }
        func bound() throws -> ShortcutRegistry.Shortcut {
            guard let shortcut = shell.shortcuts.shortcut(id) else { throw Failure("tab-hotkeys", "No shortcut for the Scheduled tasks tab") }
            return shortcut
        }
        defer {
            shell.gameMode.override = game
            shell.close(restoreFocus: false)
            shell.updateGeneral { $0 = original }
            shell.shortcuts.set(id, nil)
            shell.selectTab("home")
        }
        shell.close(restoreFocus: false)
        shell.selectTab("home")
        try require(shell.shortcuts.shortcut("tab.search") == nil && shell.shortcuts.shortcut("search") != nil, "Search got a second shortcut")
        try require(try bound().title == "Open Scheduled tasks" && bound().defaultCombo == nil && bound().combo == nil, "A tab shortcut is not Off by default")

        // An unusual gesture, so a developer's own apps are not disturbed while it is held.
        let combo = try testCombo("ctrl+opt+shift+cmd+f9")
        shell.shortcuts.set(id, combo)
        try require(try bound().isRegistered || bound().taken, "The bound key was not registered")
        let saved: ShortcutSettings = shell.store.load("hotkeys", default: ShortcutSettings())
        try require(saved.keys[id] == combo.text, "The gesture was not saved under its tab id")

        try bound().action()
        try require(shell.state.acceptsKeyboard && shell.activeTab == "scheduled", "The key did not open its tab with the keyboard")
        try bound().action()
        try require(!shell.state.expanded, "A second press did not close the panel")

        shell.selectTab("home")
        shell.open(keyboard: false)
        try bound().action()
        try require(shell.state.acceptsKeyboard && shell.activeTab == "scheduled", "The key did not switch an open panel to its tab")
        shell.close(restoreFocus: false)

        shell.selectTab("home")
        shell.gameMode.override = .on
        try bound().action()
        try require(!shell.state.expanded && shell.activeTab == "home", "The key acted in game mode")
        shell.gameMode.override = game

        let held = try bound()
        shell.updateGeneral { $0.setTabVisible("scheduled", false) }
        try require(shell.shortcuts.shortcut(id) === held && !held.isRegistered && held.combo == combo, "Hiding the tab did not release its key")
        held.action()
        try require(!shell.state.expanded, "A hidden tab's shortcut opened the panel")
        shell.updateGeneral { $0.setTabVisible("scheduled", true) }
        try require(held.isRegistered || held.taken, "Showing the tab did not restore its key")

        shell.updateGeneral { $0.setEnabled("scheduled", false) }
        try require(shell.shortcuts.shortcut(id) == nil, "A turned-off feature kept its tab shortcut")
        shell.updateGeneral { $0.setEnabled("scheduled", true) }
        try require(try bound().combo == combo && (bound().isRegistered || bound().taken), "Turning the feature back on lost its gesture")
        run.pass("tab-hotkeys")
    }

    private static func testCombo(_ text: String) throws -> KeyCombo {
        guard let combo = KeyCombo(text) else { throw Failure("tab-hotkeys", "Invalid test gesture") }
        return combo
    }
}
