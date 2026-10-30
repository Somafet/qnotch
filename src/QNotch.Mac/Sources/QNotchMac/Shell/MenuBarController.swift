import AppKit
import QNotchMacCore

/// Owns exactly one live status item. Rebuilding after hiding reads current shell contributions.
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private unowned let shell: ShellController
    private let suppressed: Bool
    private(set) var item: NSStatusItem?
    private var status: NSMenuItem!
    private var moduleActionItems: [NSMenuItem] = []
    private var gameItems: [NSMenuItem] = []

    init(shell: ShellController, suppressed: Bool = false) {
        self.shell = shell
        self.suppressed = suppressed
        super.init()
        refreshStatus()
    }

    func removeStatusItem() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        status = nil
        moduleActionItems.removeAll()
        gameItems.removeAll()
    }

    private func installStatusItem() {
        guard item == nil else { return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "QNotch")
        item?.button?.setAccessibilityLabel("QNotch menu")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Panel", action: #selector(openPanel), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        if shell.updater != nil { menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self }
        status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        let gameHeader = NSMenuItem(title: "Game Mode", action: nil, keyEquivalent: "")
        gameHeader.isEnabled = false
        menu.addItem(gameHeader)
        for (title, mode) in [("Automatic", GameOverride.auto), ("On", .on), ("Off", .off)] {
            let entry = NSMenuItem(title: title, action: #selector(setGameMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.indentationLevel = 1
            menu.addItem(entry)
            gameItems.append(entry)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit QNotch", action: #selector(quit), keyEquivalent: "q").target = self
        item?.menu = menu
    }

    @objc private func openPanel() {
        // During the first-run tour there is no panel content yet: bring the tour forward.
        if shell.modulesDeferred, let tour = shell.onboarding { tour.show() } else { Analytics.withSurface("tray") { Analytics.withSurface("tray") { shell.open(keyboard: true) } } }
    }
    @objc private func setGameMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = GameOverride(rawValue: raw) { Analytics.withSurface("tray") { Analytics.record("shell", "game_mode") }; Analytics.withSurface("tray") { Analytics.record("shell", "game_mode") }; shell.gameMode.override = mode }
    }
    @objc private func runModuleAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = shell.registries.menuActions.items.first(where: { $0.id == id }) else { return }
        Analytics.withSurface("tray") { Analytics.withSurface("tray") { action.run() } }
    }
    @objc private func openSettings() { Analytics.withSurface("tray") { Analytics.withSurface("tray") { shell.openSettings() } } }
    @objc private func quit() { Analytics.withSurface("tray") { Analytics.record("shell", "quit") }; Analytics.withSurface("tray") { Analytics.record("shell", "quit") }; NSApp.terminate(nil) }
    @objc private func checkForUpdates() { Analytics.withSurface("tray") { Analytics.record("shell", "check_updates") }; Analytics.withSurface("tray") { Analytics.record("shell", "check_updates") }; shell.updater?.check() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? shell.updater?.canCheck == true : true
    }
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
        for item in gameItems { item.state = (item.representedObject as? String) == shell.gameMode.override.rawValue ? .on : .off }
    }
    func refreshStatus() {
        if shell.general.showMenuBarIcon && !suppressed {
            if item == nil { installStatusItem() }
        } else {
            removeStatusItem()
        }
        guard status != nil else { return }
        if let menu = item?.menu {
            moduleActionItems.forEach { menu.removeItem($0) }
            moduleActionItems = shell.registries.menuActions.items.map { action in
                let entry = NSMenuItem(title: action.title(), action: #selector(runModuleAction(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = action.id
                entry.state = action.isOn() ? .on : .off
                return entry
            }
            for entry in moduleActionItems { menu.insertItem(entry, at: menu.index(of: status)) }
        }
        let problem = [shell.displayMessage, shell.store.problem ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let message = !problem.isEmpty ? problem : shell.updater == nil ? "Development build · Updates unavailable" : "QNotch \(version)"
        status.title = message
        status.isEnabled = false
    }
}
