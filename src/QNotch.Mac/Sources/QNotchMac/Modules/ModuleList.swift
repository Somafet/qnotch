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
        ModuleInfo(id: "timer", title: "Timer", detail: "Countdown with focus presets on a Home card, in a tab and beside the notch.",
                   symbol: "timer", tint: .systemOrange) { TimerModule() },
        ModuleInfo(id: "volume", title: "Volume", detail: "System volume and mute on a Home card. Follows the current output device.",
                   symbol: "speaker.wave.2.fill", tint: .systemPink) { VolumeModule() },
        ModuleInfo(id: "note", title: "Note", detail: "A quick note on a Home card, saved as you type.",
                   symbol: "note.text", tint: .systemYellow) { NoteModule() }
    ]

    static func make(disabled: [String]) -> [NotchModule] {
        all.filter { !disabled.contains($0.id) }.map { $0.make() }
    }
}
