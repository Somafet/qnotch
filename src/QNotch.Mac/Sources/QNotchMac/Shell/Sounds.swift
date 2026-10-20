import AppKit
import QNotchMacCore

/// Every sound goes through here (Windows `ctx.Sounds`). A sound plays its macOS system sound
/// until the user picks another one or an audio file in Settings, Sounds; a missing or broken file
/// falls back to the default. Whether a sound plays at all is the module's call (its own switch).
final class SoundRegistry {
    struct Sound {
        let id: String
        let title: String
        let hint: String
        let defaultName: String
        let order: Int
        let owner: String?
    }

    private let store: SettingsStore
    private var settings: SoundSettings
    private var sounds: [String: Sound] = [:]
    /// Keeps a file-backed sound alive until it finishes.
    private var playing: NSSound?

    init(store: SettingsStore) {
        self.store = store
        settings = store.load("sounds", default: SoundSettings())
    }

    /// The module whose `initialize` is running; its sounds are removed with it.
    var owner: String?

    var items: [Sound] { sounds.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }

    /// Call once per id in `initialize`. `defaultName` is a system sound such as "Glass".
    func add(_ id: String, title: String, hint: String, defaultName: String, order: Int) {
        sounds[id] = Sound(id: id, title: title, hint: hint, defaultName: defaultName, order: order, owner: owner)
    }

    func removeAll(owner: String) { sounds = sounds.filter { $0.value.owner != owner } }

    /// The saved choice: a system sound name or an absolute file path.
    func choice(for id: String) -> String { settings.sounds[id] ?? sounds[id]?.defaultName ?? "" }
    func isDefault(_ id: String) -> Bool { settings.sounds[id] == nil }

    func choose(_ id: String, _ value: String?) {
        if let value, value != sounds[id]?.defaultName { settings.sounds[id] = value } else { settings.sounds[id] = nil }
        store.save("sounds", settings)
    }

    func play(_ id: String) {
        // Diagnostic runs post demo notifications and agent alerts; they stay silent.
        guard let sound = sounds[id], !Runtime.diagnostics else { return }
        let value = choice(for: id)
        let chosen: NSSound? = value.hasPrefix("/") ? NSSound(contentsOf: URL(fileURLWithPath: value), byReference: true) : NSSound(named: value)
        guard let player = chosen ?? NSSound(named: sound.defaultName) else { return }
        playing?.stop()
        playing = player
        player.play()
    }

    /// Display name for a choice ("Glass", or a file's name).
    static func title(of value: String) -> String {
        value.hasPrefix("/") ? URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent : value
    }

    /// System alert sounds (the list System Settings offers), plus the user's own in ~/Library/Sounds.
    static var systemNames: [String] {
        let folders = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"]
        let names = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
                .map { ($0 as NSString).deletingPathExtension }
        }
        return Array(Set(names)).sorted()
    }

    static let fileTypes = ["aiff", "aif", "aifc", "wav", "caf", "mp3", "m4a", "aac", "flac"]
}
