import AppKit
import QNotchMacCore

extension NativeSmokeTest {
    /// Persisted-off startup and live Settings/tour changes use the real module lifecycle.
    static func checkSearchEnablement(_ run: SnapshotRun) throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw Failure("search-enablement", message) }
        }
        func find(_ id: String, in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        func key(_ shell: ShellController, text: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shell.panel.windowNumber,
                                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 3)
            guard let event else { throw Failure("search-enablement", "Could not create a keyboard event") }
            shell.panel.keyDown(with: event)
        }
        let directory = run.shell.store.directory.appendingPathComponent("search-startup")
        let store = SettingsStore(directory: directory)
        var settings = GeneralSettings()
        settings.disabledModules = ModuleList.all.map(\.id)
        store.save("general", settings)
        var hotkeys = ShortcutSettings()
        hotkeys.keys["search"] = "ctrl+opt+shift+f"
        store.save("hotkeys", hotkeys)
        do {
            let boot = ShellController(store: SettingsStore(directory: directory))
            defer { boot.stop() }
            boot.renderOnly = true
            try require(boot.module("search") == nil && boot.shortcuts.shortcut("search") == nil,
                        "Persisted-off Search was constructed or registered a shortcut at startup")
            boot.summonSearch()
            try require(!boot.state.expanded, "Disabled Search opened the panel at startup")
            boot.open(keyboard: true)
            boot.selectTab("search")
            try key(boot, text: "x")
            try key(boot, text: "f", modifiers: .command)
            try require(boot.activeTab == "home" && find("tab-search", in: boot.panel.contentView) == nil,
                        "Persisted-off Search still has a tab or a keyboard entry path")
            boot.updateGeneral { $0.setEnabled("search", true) }
            boot.summonSearch()
            try require(boot.activeTab == "search" && boot.shortcuts.shortcut("search")?.combo?.text == "ctrl+opt+shift+f",
                        "Re-enabling Search did not restore the tab and saved shortcut")
            boot.updateGeneral { $0.setEnabled("search", false) }
            let saved = SettingsStore(directory: directory).load("general", default: GeneralSettings())
            try require(!saved.isEnabled("search"), "Search off choice was not persisted")
        }

        let shell = run.shell
        let timer = shell.module(TimerModule.self)
        timer?.startShortTimer(seconds: 60)
        let before = shell.modules
        guard let shortcut = shell.shortcuts.shortcut("search") else {
            throw Failure("search-enablement", "Default-on Search has no shortcut")
        }
        shell.summonSearch()
        let page = shell.makeSettings()
        page.select("features", animated: false)
        guard let toggle = find("feature-search", in: page.window.contentView) as? ActionSwitch else {
            throw Failure("search-enablement", "Settings has no Search feature switch")
        }
        toggle.state = .off
        toggle.changed(false)
        try require(shell.activeTab == "home" && shell.module("search") == nil && !shortcut.isRegistered && shell.shortcuts.shortcut("search") == nil,
                    "Settings off did not remove Search, release its shortcut and fall back to Home")
        try require(before.filter { !($0 is SearchModule) }.allSatisfy { kept in shell.modules.contains { $0 === kept } }
                    && timer?.countdown.isRunning == true && timer?.hasScheduledWake == true,
                    "Disabling Search disturbed another module or the running countdown")
        try key(shell, text: "x")
        try key(shell, text: "f", modifiers: .command)
        shell.selectTab("search")
        shortcut.action() // A previously captured callback must also be harmless.
        try require(shell.activeTab == "home" && find("tab-search", in: shell.panel.contentView) == nil
                    && find("search-field", in: shell.panel.contentView) == nil,
                    "Disabled Search was entered through typing, Command-F, selection or a stale shortcut")
        run.notch("search-disabled-home")
        let debug = DebugCommands(shell: shell, dataDirectory: shell.store.directory)
        for (command, args) in [("select-tab", ["id": "search"]), ("open", ["tab": "search"]), ("hotkey", ["action": "search"])] {
            var rejected = false
            do { _ = try debug.perform(command, Arguments(values: args)) } catch { rejected = true }
            try require(rejected, "Debug \(command) accepted disabled Search")
        }
        shell.close(restoreFocus: false)
        shortcut.action()
        try require(!shell.state.expanded, "Disabled Search shortcut opened a collapsed panel")
        toggle.state = .on
        toggle.changed(true)
        guard let restored = shell.shortcuts.shortcut("search") else { throw Failure("search-enablement", "Search shortcut was not restored") }
        try require(restored.combo == shortcut.combo && (restored.isRegistered || restored.taken), "Search shortcut was not restored with its gesture")
        restored.action()
        guard let field = find("search-field", in: shell.panel.contentView) else { throw Failure("search-enablement", "Search field was not restored") }
        try require(shell.activeTab == "search" && Outline.focused(field), "Re-enabled Search did not receive keyboard focus")
        run.notch("search-reenabled")
        shell.close(restoreFocus: false)
        shell.selectTab("home")
        shell.open(keyboard: true)
        try key(shell, text: "f", modifiers: .command)
        try require(shell.activeTab == "search", "Command-F did not resume after re-enabling Search")
        shell.selectTab("home")
        try key(shell, text: "x")
        try require(shell.activeTab == "search", "Type-to-search did not resume after re-enabling Search")
        shell.close(restoreFocus: false)
        shell.selectTab("home")
        timer?.reset()

        run.log("search-enablement", ["persisted_off_startup=ok", "settings_toggle_and_home_fallback=ok", "other_modules_preserved=ok",
                                      "shortcut_released_and_saved_gesture_restored=ok", "typing_command_f_and_debug_entry_paths=ok"])
        run.pass("search-enablement")
    }

    static func checkSearchOnboarding(_ tour: OnboardingController, run: SnapshotRun) throws {
        let shell = run.shell
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "feature-search" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = tour.window.contentView, let toggle = find(root),
              tour.flipFeature("search"), shell.module("search") == nil, shell.shortcuts.shortcut("search") == nil else {
            throw Failure("search-onboarding", "Welcome tour could not turn Search off")
        }
        toggle.scrollToVisible(toggle.bounds)
        run.write("onboarding-search-off", root, background: Palette.surface)
        guard tour.flipFeature("search"), shell.module("search") != nil, shell.shortcuts.shortcut("search") != nil else {
            throw Failure("search-onboarding", "Welcome tour could not turn Search back on")
        }
        run.write("onboarding-search-on", root, background: Palette.surface)
    }
}
