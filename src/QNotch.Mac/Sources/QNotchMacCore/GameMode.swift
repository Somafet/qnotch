import CoreGraphics
import Foundation

/// Game mode (Windows GameModeController): when a game or full-screen app is in front, the notch
/// stays out of the way and shows a passive status line.
public enum GameOverride: String, Codable, CaseIterable { case auto, on, off }

public struct GameModeSettings: Codable, Equatable {
    public var autoDetect = true
    /// Automatic detection also for full-screen apps that are not games (Windows' behavior).
    public var anyFullScreen = false
    /// Status opacity in percent (30–100).
    public var opacity = 70
    /// Modules whose segments are hidden in game mode.
    public var hiddenModules: [String] = []
    /// Bundle ids that are always or never game mode (never wins).
    public var always: [String] = []
    public var never: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case autoDetect, anyFullScreen, opacity, hiddenModules, always, never }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoDetect = c.value(.autoDetect, true)
        anyFullScreen = c.value(.anyFullScreen, false)
        opacity = min(100, max(30, c.value(.opacity, 70)))
        hiddenModules = c.value(.hiddenModules, [])
        always = c.value(.always, [])
        never = c.value(.never, [])
    }
}

public enum GameClassifier {
    /// Whether the frontmost app counts as a game. `windows` are its on-screen, normal-level window
    /// bounds; `display` the notch's display (same coordinate space).
    /// `category` is the app's LSApplicationCategoryType ("public.app-category.action-games"…).
    public static func isGame(bundleID: String?, isSelf: Bool, windows: [CGRect], display: CGRect, settings: GameModeSettings, category: String? = nil) -> Bool {
        guard !isSelf, let bundleID else { return false }
        if settings.never.contains(bundleID) { return false }
        if settings.always.contains(bundleID) { return true }
        guard settings.autoDetect else { return false }
        // Finder's desktop window covers every display; it is never a game.
        if bundleID == "com.apple.finder" || bundleID == "com.apple.dock" || bundleID == "com.apple.loginwindow" { return false }
        // Many people work in full-screen Spaces: by default only games count.
        guard settings.anyFullScreen || (category?.contains("games") ?? false) else { return false }
        return windows.contains { window in
            abs(window.minX - display.minX) <= 1 && abs(window.minY - display.minY) <= 1
                && abs(window.width - display.width) <= 1 && abs(window.height - display.height) <= 1
        }
    }

    public static func active(override: GameOverride, detected: Bool) -> Bool {
        switch override {
        case .auto: return detected
        case .on: return true
        case .off: return false
        }
    }

    public static func next(_ value: GameOverride) -> GameOverride {
        switch value {
        case .auto: return .on
        case .on: return .off
        case .off: return .auto
        }
    }
}
