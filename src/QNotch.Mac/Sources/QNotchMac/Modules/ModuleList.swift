import AppKit
import QNotchMacCore

/// What a module's one-step setup may use (the welcome tour's Connect step). It runs before the
/// module exists on a fresh install, so it gets the settings store, never the module's providers.
struct ModuleSetupContext {
    let settings: SettingsStore
    /// The running module when the feature is on and the app is running (a tour opened from
    /// Settings), so a choice goes through the same path as Settings. Nil before modules start.
    let running: () -> NotchModule?
}

/// A module the user can turn on or off in Settings, Features.
struct ModuleInfo {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: NSColor
    /// The welcome tour's Connect row: its status and action (the tour adds the icon and title).
    /// Static helpers, the settings store and the Keychain only; nil when there is nothing to set up.
    let setup: ((ModuleSetupContext) -> NSView?)?
    let make: () -> NotchModule

    init(id: String, title: String, detail: String, symbol: String, tint: NSColor,
         setup: ((ModuleSetupContext) -> NSView?)? = nil, make: @escaping () -> NotchModule) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol; self.tint = tint
        self.setup = setup; self.make = make
    }
}

enum ModuleList {
    // The only composition file that names a concrete module. Disabled modules aren't created.
    static let all: [ModuleInfo] = [
        ModuleInfo(id: "media", title: "Now playing", detail: "Track, artwork and controls for Music and Spotify, beside the notch and on Home.",
                   symbol: "music.note", tint: .systemRed) { MediaModule() },
        ModuleInfo(id: "stats", title: "System stats", detail: "CPU, memory, GPU and network on a System card, with the stats you pick beside the notch.",
                   symbol: "cpu", tint: .systemTeal) { StatsModule() },
        ModuleInfo(id: "timer", title: "Timer", detail: "Countdown with focus presets on a Home card, in a tab and beside the notch.",
                   symbol: "timer", tint: .systemOrange) { TimerModule() },
        ModuleInfo(id: "volume", title: "Volume", detail: "System volume and mute on a Home card. Follows the current output device.",
                   symbol: "speaker.wave.2.fill", tint: .systemPink) { VolumeModule() },
        ModuleInfo(id: "search", title: "Search", detail: "Search enabled features, tabs and settings, with a global shortcut and type-to-search.",
                   symbol: "magnifyingglass", tint: .systemBlue) { SearchModule() },
        ModuleInfo(id: "note", title: "Note", detail: "A quick note on a Home card, saved as you type.",
                   symbol: "note.text", tint: .systemYellow) { NoteModule() },
        ModuleInfo(id: "colorpicker", title: "Color picker", detail: "Pick a color anywhere on screen with the system loupe and copy its hex code.",
                   symbol: "eyedropper", tint: .systemPurple) { ColorPickerModule() },
        ModuleInfo(id: "capture", title: "Mic and camera", detail: "A glyph beside the notch while an app uses your microphone or camera, naming microphone apps where macOS allows.",
                   symbol: "mic.fill", tint: .systemGreen) { CaptureModule() },
        ModuleInfo(id: "filetray", title: "File tray", detail: "Drop files on the notch to keep them within reach. Share with AirDrop, export copies, preview with Quick Look.",
                   symbol: "tray.full.fill", tint: .systemBlue) { FileTrayModule() },
        ModuleInfo(id: "clipboard", title: "Clipboard history", detail: "Text and images you copy, kept in memory. Concealed content from password managers is never captured.",
                   symbol: "doc.on.clipboard.fill", tint: .systemIndigo) { ClipboardModule() },
        ModuleInfo(id: "notifications", title: "Notifications", detail: "Lets apps and scripts post notifications to the notch: QNotch notify, a local socket or loopback HTTP.",
                   symbol: "bell.badge.fill", tint: .systemRed) { NotificationsModule() },
        ModuleInfo(id: "agents", title: "Agents", detail: "Live Claude Code and Codex sessions: working, needs you or done, beside the notch and in the Agents tab.",
                   symbol: "sparkles", tint: .systemOrange, setup: AgentsModule.setupRow) { AgentsModule() },
        ModuleInfo(id: "weather", title: "Weather", detail: "The MET Norway forecast for a place you pick, on a Home card and beside the notch.",
                   symbol: "cloud.sun.fill", tint: .systemCyan, setup: WeatherModule.setupRow) { WeatherModule() },
        ModuleInfo(id: "github", title: "GitHub", detail: "Your GitHub contribution graph on a Home card, once you connect your account in Settings.",
                   symbol: "chart.bar.xaxis", tint: .darkGray, setup: GithubModule.setupRow) { GithubModule() },
        ModuleInfo(id: "ai", title: "AI apps and usage", detail: "⌃⌥1 to ⌃⌥6 open your AI apps; plan usage for Claude Code and Codex.",
                   symbol: "gauge.with.dots.needle.33percent", tint: .systemPurple) { AiModule() },
        ModuleInfo(id: "scheduled", title: "Scheduled tasks", detail: "Your launch agents (scripts and jobs on a timer), with pause, resume and delete.",
                   symbol: "clock.arrow.2.circlepath", tint: .systemBrown) { ScheduledModule() }
    ]

    static func make(disabled: [String]) -> [NotchModule] {
        all.filter { !disabled.contains($0.id) }.map { $0.make() }
    }
}
