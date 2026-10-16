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
                   symbol: "timer", tint: .systemOrange) { TimerModule() }
    ]

    static func make(disabled: [String]) -> [NotchModule] {
        all.filter { !disabled.contains($0.id) }.map { $0.make() }
    }
}
