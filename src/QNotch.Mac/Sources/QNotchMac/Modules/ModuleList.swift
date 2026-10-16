import AppKit

/// A module the user can turn on or off in Settings, Features.
struct ModuleInfo {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: NSColor
    let make: () -> NotchModule
}

enum ModuleList {
    // The only composition file that names a concrete module. Disabled modules aren't created.
    static let all: [ModuleInfo] = [
        ModuleInfo(id: "stats", title: "System stats", detail: "CPU, memory, GPU and network on a System card, with the stats you pick beside the notch.",
                   symbol: "cpu", tint: .systemTeal) { StatsModule() },
        ModuleInfo(id: "timer", title: "Timer", detail: "Countdown with focus presets on a Home card, in a tab and beside the notch.",
                   symbol: "timer", tint: .systemOrange) { TimerModule() },
        ModuleInfo(id: "volume", title: "Volume", detail: "System volume and mute on a Home card. Follows the current output device.",
                   symbol: "speaker.wave.2.fill", tint: .systemPink) { VolumeModule() },
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
                   symbol: "sparkles", tint: .systemOrange) { AgentsModule() }
    ]

    static func make(disabled: [String]) -> [NotchModule] {
        all.filter { !disabled.contains($0.id) }.map { $0.make() }
    }
}
