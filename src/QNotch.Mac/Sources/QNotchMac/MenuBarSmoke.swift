import AppKit
import QNotchMacCore

enum MenuBarSmoke {
    static func check(_ run: SnapshotRun, menuBar: MenuBarController) throws {
        let shell = run.shell
        let original = shell.general
        let game = shell.gameMode.override
        let modules = shell.modules.map(ObjectIdentifier.init)
        let shortcuts = shell.shortcuts.items.map { ($0.id, $0.combo) }
        var actionRuns = 0
        defer {
            shell.registries.menuActions.removeAll(owner: "menu-bar-smoke")
            for (id, combo) in shortcuts { shell.shortcuts.set(id, combo) }
            shell.gameMode.override = game
            shell.updateGeneral { $0 = original }
            shell.settings?.window.close()
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NativeSmokeTest.Failure("menu-bar-visibility", message) }
        }
        shell.updateGeneral { $0.showMenuBarIcon = true }
        for cycle in 0..<3 {
            guard let visible = menuBar.item, let menu = visible.menu else {
                throw NativeSmokeTest.Failure("menu-bar-visibility", "The visible icon has no menu")
            }
            try require(visible.button?.accessibilityLabel() == "QNotch menu", "The icon has no accessible name")
            menuBar.refreshStatus()
            try require(menuBar.item === visible, "Refreshing created a second icon")
            try require(menu.items.filter { $0.title == "Settings…" }.count == 1, "Settings menu entries accumulated")
            guard let settings = menu.items.first(where: { $0.title == "Settings…" }), let action = settings.action else {
                throw NativeSmokeTest.Failure("menu-bar-visibility", "Settings action is missing")
            }
            try require(NSApp.sendAction(action, to: settings.target, from: settings), "The restored menu action failed")
            try require(shell.settings?.window.isVisible == true, "The restored menu did not open Settings")
            if cycle == 0 {
                run.write("menu-bar-icon", visible.button)
                shell.settings?.snapshotPages({ name, view in
                    if name == "settings-general" { run.write("menu-bar-visible", view, background: .windowBackgroundColor) }
                }, problem: run.fail)
            }
            shell.updateGeneral { $0.showMenuBarIcon = false }
            try require(menuBar.item == nil, "Hiding left a live status item")
            menuBar.refreshStatus()
            try require(menuBar.item == nil, "A status update restored the hidden icon")
            if cycle == 0 {
                shell.settings?.snapshotPages({ name, view in
                    if name == "settings-general" { run.write("menu-bar-hidden", view, background: .windowBackgroundColor) }
                }, problem: run.fail)
            }
            // Mutate session state while hidden: the next menu must use the current override.
            shell.registries.menuActions.owner = "menu-bar-smoke"
            shell.registries.menuActions.register(MenuActionContribution(id: "menu-bar-smoke", order: 0,
                title: { "Current module action \(cycle)" }, isOn: { true }, run: { actionRuns += 1 }))
            shell.registries.menuActions.owner = nil
            shell.gameMode.override = .on
            shell.updateGeneral { $0.showMenuBarIcon = true }
            try require(menuBar.item !== visible, "Restoring reused the removed item")
            if let current = menuBar.item?.menu {
                menuBar.menuWillOpen(current)
                try require(current.items.filter { $0.title == "On" && $0.state == .on }.count == 1, "Restored menu has stale game-mode state")
                let entries = current.items.filter { $0.representedObject as? String == "menu-bar-smoke" }
                try require(entries.count == 1 && entries.first?.title == "Current module action \(cycle)", "Restored menu has stale module actions")
                if let entry = entries.first, let action = entry.action {
                    try require(NSApp.sendAction(action, to: entry.target, from: entry), "Restored module action failed")
                }
                try require(actionRuns == cycle + 1, "Restored module action did not run")
            }
            shell.gameMode.override = game
        }
        shell.updateGeneral { $0.showMenuBarIcon = false }
        for shortcut in shell.shortcuts.items { shell.shortcuts.set(shortcut.id, nil) }
        shell.gameMode.override = .on
        try require(shell.shortcuts.items.allSatisfy { !$0.isRegistered }, "A disabled shortcut remains registered")
        shell.openSettings(page: "general")
        try require(shell.settings?.window.isVisible == true && shell.gameActive, "Game mode prevents Settings recovery")
        try require(shell.modules.map(ObjectIdentifier.init) == modules, "Toggling restarted modules")
        var expected = original
        expected.showMenuBarIcon = false
        try require(shell.general == expected, "Toggling changed unrelated preferences")
        run.pass("menu-bar-visibility")
    }
}
