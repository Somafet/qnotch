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

private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var shell: ShellController!
    private var menuBar: MenuBarController?
    private var instance: ApplicationInstance?
    private var consumer: ConsumerService?
    private var pendingReopen = false
    private let launched = ProcessInfo.processInfo.systemUptime
    private var dataDirectory: URL!

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
        // Acquire before constructing any provider. A second process only delivers Settings to
        // the owner of this data directory, then exits; diagnostics retain their separate contract.
        if options.mode == nil {
            do { instance = try ApplicationInstance.acquire(directory: dataDirectory) }
            catch ApplicationInstance.Failure.alreadyRunning {
                let delivered = ApplicationInstance.requestSettings(directory: dataDirectory)
                if !delivered { fputs("QNotch is already running; Settings recovery could not be delivered.\n", stderr) }
                exit(delivered ? 0 : 1)
            } catch {
                fputs("QNotch could not acquire its data-directory instance lock: \(error)\n", stderr)
                exit(1)
            }
        }
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
        if options.mode == .snapshot { shell.renderOnly = true }
        menuBar = MenuBarController(shell: shell, suppressed: options.mode == .snapshot)
        shell.statusChanged = { [weak self] in self?.menuBar?.refreshStatus() }
        if tour == .show { shell.showOnboarding(firstRun: true, isolated: isolated != nil) } else { shell.start() }
        do { try instance?.startRecovery { [weak self] in self?.reopenSettings() } }
        catch { fputs("Settings reopen recovery did not open: \(error)\n", stderr) }
        if options.mode == nil {
            shell.registries.consumers.status = { [weak shell] command in
                guard let shell, let module = ModuleList.consumerModules[command] else { return "unavailable" }
                if !shell.general.isEnabled(module) { return "disabled" }
                if shell.modulesDeferred { return "initializing" }
                return shell.registries.consumers.capture[command] == nil ? "unavailable" : "ready"
            }
            do { consumer = try ConsumerService(path: ConsumerWire.path(directory: dataDirectory), registry: shell.registries.consumers) }
            catch { fputs("Consumer service unavailable.\n", stderr) }
        }
        if pendingReopen { pendingReopen = false; reopenSettings() }
        // The debug channel opens only on request, and never in a diagnostic run (spec/diagnostics.md, Debug channel).
        if debugControl && options.mode == nil {
            do { try DebugChannel.start(shell: shell, directory: dataDirectory) } catch { fputs("The debug channel did not open: \(error)\n", stderr) }
        }
        let ready = PerformanceMeasurement.secondsSinceProcessStart() ?? (ProcessInfo.processInfo.systemUptime - launched)
        writeLog("ready startup_seconds=\(String(format: "%.4f", ready))")
        if let output = options.output.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            switch options.mode {
            case .snapshot?: NativeSnapshot.run(shell: shell, output: output, options: options)
            case .smoke?: NativeSmokeTest.run(shell: shell, menuBar: menuBar!, output: output, ready: ready, options: options)
            case .measure?: PerformanceMeasurement.run(shell: shell, output: output, ready: ready)
            case nil: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.removeStatusItem()
        consumer?.close(); consumer = nil
        DebugChannel.stop()
        shell?.stop()
        // Keep the lock through provider teardown as well as startup.
        instance?.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenSettings()
        return false
    }

    private func reopenSettings() {
        guard let shell else { pendingReopen = true; return }
        shell.openSettings(page: "general")
    }

    @objc private func openSettings() { shell.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { shell.updater?.check() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? shell.updater?.canCheck == true : true
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
