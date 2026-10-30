import AppKit
import QNotchMacCore

/// Detects a game or full-screen app in front of the notch's display (Windows GameModeController).
/// Event driven: app activation, Space changes and display changes trigger one window-list check
/// (owner and bounds only, which need no Screen Recording permission). Entering waits 250 ms;
/// leaving is immediate. macOS reports no event when another app resizes its own window, so a game
/// that turns borderless full screen without changing Space is noticed at the next activation.
final class GameModeController {
    private let store: SettingsStore
    private(set) var settings: GameModeSettings
    private(set) var detected = false
    var override = GameOverride.auto { didSet { if oldValue != override { changed?() } } }
    var active: Bool { GameClassifier.active(override: override, detected: detected) }
    var changed: (() -> Void)?
    /// The notch's display in global window-list coordinates (top-left origin).
    var display: () -> CGRect? = { nil }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: DispatchWorkItem?

    init(store: SettingsStore) {
        self.store = store
        settings = store.load("gamemode", default: GameModeSettings())
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.schedule() }))
        }
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.schedule() }))
    }

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    func set(_ change: (inout GameModeSettings) -> Void) { Analytics.setting("game_mode");
        change(&settings)
        store.save("gamemode", settings)
        evaluate(now: true)
        changed?()
    }

    func cycle() { Analytics.record("shell", "game_mode"); Analytics.record("shell", "game_mode"); override = GameClassifier.next(override) }

    func schedule() { evaluate(now: false) }

    private func evaluate(now: Bool) {
        pending?.cancel()
        let next = detect()
        guard next != detected else { return }
        guard next, !now else { detected = next; changed?(); return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.detect() else { return }
            self.detected = true
            self.changed?()
        }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func detect() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let display = display() else { return false }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
        let category = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        return GameClassifier.isGame(bundleID: app.bundleIdentifier, isSelf: app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                                     windows: windows, display: display, settings: settings, category: category)
    }

    var status: String {
        switch (override, active) {
        case (.on, _): return "On (forced)"
        case (.off, _): return "Off (forced)"
        case (.auto, true): return "On: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app") is full screen"
        case (.auto, false): return settings.anyFullScreen ? "Off: no full-screen app in front" : "Off: no full-screen game in front"
        }
    }
}
