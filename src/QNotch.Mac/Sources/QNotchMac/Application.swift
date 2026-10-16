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

private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var shell: ShellController!
    private var item: NSStatusItem!
    private var status: NSMenuItem!
    private let launched = ProcessInfo.processInfo.systemUptime
    private var dataDirectory: URL!
    private var lockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let isolated = option("--data-dir", in: args) ?? ProcessInfo.processInfo.environment["QNOTCH_MAC_DATA_DIR"]
        dataDirectory = isolated.map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QNotch.Mac", isDirectory: true)
        if args.contains("--smoke-test") || args.contains("--measure") {
            guard isolated != nil, option("--output", in: args) != nil else {
                fputs("Diagnostics require --data-dir and --output.\n", stderr)
                exit(2)
            }
        }
        // Advisory, per-data-root instance lock. Never terminate another user's app.
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            lockDescriptor = Darwin.open(dataDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                fputs("QNotch is already running with this data directory.\n", stderr)
                exit(1)
            }
        } catch { /* The Settings window reports persistence failures; the app remains usable. */ }
        shell = ShellController(store: SettingsStore(directory: dataDirectory))
        installMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "QNotch")
        item.button?.setAccessibilityLabel("QNotch menu")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Panel", action: #selector(openPanel), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit QNotch", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        shell.statusChanged = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        shell.start()
        let ready = PerformanceMeasurement.secondsSinceProcessStart() ?? (ProcessInfo.processInfo.systemUptime - launched)
        writeLog("ready startup_seconds=\(String(format: "%.4f", ready))")
        if let output = option("--output", in: args) {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            if args.contains("--smoke-test") { NativeSmokeTest.run(shell: shell, output: directory, ready: ready) }
            if args.contains("--measure") { PerformanceMeasurement.run(shell: shell, output: directory, ready: ready) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shell?.stop()
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }
    @objc private func openPanel() { shell.open(keyboard: true) }
    @objc private func openSettings() { shell.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }
    private func refreshStatus() {
        guard status != nil else { return }
        let problem = [shell.displayMessage, shell.store.problem ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let message = problem.isEmpty ? "Development build · Updates unavailable" : problem
        status.title = message
        status.isEnabled = false
    }
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
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
    private func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    private func writeLog(_ message: String) {
        // Bounded startup diagnostics contain no paths, display names, accounts, or credentials.
        let logs = dataDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? Data((message + "\n").utf8).write(to: logs.appendingPathComponent("session.log"), options: .atomic)
    }
}
