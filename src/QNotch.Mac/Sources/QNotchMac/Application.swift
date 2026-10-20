import AppKit
import QNotchMacCore

public enum QNotchApplication {
    public static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var shell: ShellController!
    private var item: NSStatusItem!
    private var status: NSMenuItem!
    private let launched = ProcessInfo.processInfo.systemUptime
    private var dataDirectory: URL!
    private var gameItems: [NSMenuItem] = []
    private var lockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let options = DiagnosticOptions(arguments: args)
        var isolated = options.dataDirectory
        if options.mode != nil {
            if let problem = options.problem {
                fputs(problem + "\n", stderr)
                exit(2)
            }
            // Diagnostic runs never read or write the user's Keychain.
            Keychain.inMemory = [:]
            Runtime.diagnostics = true
            if let appearance = options.nsAppearance { NSApp.appearance = appearance }
            // Without --data-dir: a fresh root of their own, deleted on exit (also exit(1)).
            // Short, so the sockets inside stay within the 104-byte socket path limit.
            var template = Array((NSTemporaryDirectory() + "qnotch.XXXXXX").utf8CString)
            if isolated == nil, let path = mkdtemp(&template).map({ String(cString: $0) }) {
                Runtime.temporaryRoot = URL(fileURLWithPath: path, isDirectory: true)
                isolated = path
                atexit { Runtime.removeTemporaryRoot() }
            }
        }
        dataDirectory = isolated.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QNotch.Mac", isDirectory: true)
        // Advisory, per-data-root instance lock. Never terminate another user's app. Diagnostic
        // runs never take it, so they run beside a normal instance.
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            if options.mode == nil {
                lockDescriptor = Darwin.open(dataDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                if lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                    fputs("QNotch is already running with this data directory.\n", stderr)
                    exit(1)
                }
            }
        } catch { /* The Settings window reports persistence failures; the app remains usable. */ }
        // The welcome tour: on a fresh install it runs before any module is constructed; settings
        // from before the tour are marked done without showing it. Diagnostic and debug-control runs never show it.
        let debugControl = args.contains("--debug-control")
        let store = SettingsStore(directory: dataDirectory)
        let generalExists = FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("general.json").path)
        var general = store.load("general", default: GeneralSettings())
        let tour = Onboarding.atLaunch(settingsExist: generalExists, readable: store.problem == nil,
                                       done: general.onboardingDone, diagnostics: Runtime.diagnostics || debugControl)
        if tour == .markDone {
            general.onboardingDone = true
            store.save("general", general)
        }
        shell = ShellController(store: store, deferModules: tour == .show)
        shell.updater = Updater.makeIfAvailable(isolated: isolated != nil) { [weak shell] in shell?.general.betaUpdates == true }
        installMainMenu()
        // A snapshot run shows nothing: no menu-bar item, and the notch is rendered at alpha 0.
        if options.mode == .snapshot { shell.renderOnly = true } else { installStatusItem() }
        shell.statusChanged = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        if tour == .show { shell.showOnboarding(firstRun: true, isolated: isolated != nil) } else { shell.start() }
        // The debug channel opens only on request, and never in a diagnostic run (spec/diagnostics.md, Debug channel).
        if debugControl && options.mode == nil {
            do { try DebugChannel.start(shell: shell, directory: dataDirectory) } catch { fputs("The debug channel did not open: \(error)\n", stderr) }
        }
        let ready = PerformanceMeasurement.secondsSinceProcessStart() ?? (ProcessInfo.processInfo.systemUptime - launched)
        writeLog("ready startup_seconds=\(String(format: "%.4f", ready))")
        if let output = options.output.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            switch options.mode {
            case .snapshot?: NativeSnapshot.run(shell: shell, output: output, options: options)
            case .smoke?: NativeSmokeTest.run(shell: shell, output: output, ready: ready, options: options)
            case .measure?: PerformanceMeasurement.run(shell: shell, output: output, ready: ready)
            case nil: break
            }
        }
    }

    private func installStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "QNotch")
        item.button?.setAccessibilityLabel("QNotch menu")
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
        item.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugChannel.stop()
        shell?.stop()
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }
    @objc private func openPanel() {
        // During the first-run tour there is no panel content yet: bring the tour forward.
        if shell.modulesDeferred, let tour = shell.onboarding { tour.show() } else { shell.open(keyboard: true) }
    }
    @objc private func setGameMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = GameOverride(rawValue: raw) { shell.gameMode.override = mode }
    }
    @objc private func openSettings() { shell.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { shell.updater?.check() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? shell.updater?.canCheck == true : true
    }
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
        for item in gameItems { item.state = (item.representedObject as? String) == shell.gameMode.override.rawValue ? .on : .off }
    }
    private func refreshStatus() {
        guard status != nil else { return }
        let problem = [shell.displayMessage, shell.store.problem ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let message = !problem.isEmpty ? problem : shell.updater == nil ? "Development build · Updates unavailable" : "QNotch \(version)"
        status.title = message
        status.isEnabled = false
    }
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        if shell.updater != nil { app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self }
        app.addItem(.separator())
        app.addItem(withTitle: "Quit QNotch", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = app
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
    private func writeLog(_ message: String) {
        // Bounded startup diagnostics contain no paths, display names, accounts, or credentials.
        let logs = dataDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? Data((message + "\n").utf8).write(to: logs.appendingPathComponent("session.log"), options: .atomic)
    }
}
