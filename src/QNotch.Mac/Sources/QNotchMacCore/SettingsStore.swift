import Foundation

/// Settings structs decode missing keys as their defaults, so adding a field never makes an
/// existing file unreadable.
extension KeyedDecodingContainer {
    public func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public struct GeneralSettings: Codable, Equatable {
    public var displayID: UInt32?
    public var reduceMotion = false
    /// Module ids that are off. A module that is off is never constructed.
    public var disabledModules: [String] = []
    public init() {}

    public func isEnabled(_ module: String) -> Bool { !disabledModules.contains(module) }
    public mutating func setEnabled(_ module: String, _ enabled: Bool) {
        disabledModules.removeAll { $0 == module }
        if !enabled { disabledModules.append(module); disabledModules.sort() }
    }

    private enum CodingKeys: String, CodingKey { case displayID, reduceMotion, disabledModules, timerEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayID = c.value(.displayID, nil)
        reduceMotion = c.value(.reduceMotion, false)
        disabledModules = c.value(.disabledModules, [])
        // The first milestone stored one switch for its only module.
        if c.value(.timerEnabled, true) == false, !disabledModules.contains("timer") { disabledModules.append("timer") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(displayID, forKey: .displayID)
        try c.encode(reduceMotion, forKey: .reduceMotion)
        try c.encode(disabledModules, forKey: .disabledModules)
    }
}

public struct TimerSettings: Codable, Equatable {
    public var minutes = 25
    public var playSound = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case minutes, playSound }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = c.value(.minutes, 25)
        playSound = c.value(.playSound, true)
    }
}

/// Changed shortcut gestures by id ("" = off). Unlisted ids use their default.
public struct ShortcutSettings: Codable, Equatable {
    public var keys: [String: String] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case keys }
    public init(from decoder: Decoder) throws { keys = try decoder.container(keyedBy: CodingKeys.self).value(.keys, [:]) }
}

/// Chosen sounds by id: a system sound name or an absolute audio file path. Unlisted ids use their default.
public struct SoundSettings: Codable, Equatable {
    public var sounds: [String: String] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case sounds }
    public init(from decoder: Decoder) throws { sounds = try decoder.container(keyedBy: CodingKeys.self).value(.sounds, [:]) }
}

/// One atomic JSON file per owner. Tests and smoke runs always supply a temporary root.
public final class SettingsStore {
    public let directory: URL
    public private(set) var problem: String? {
        didSet { if oldValue != problem { problemChanged?() } }
    }
    public var problemChanged: (() -> Void)?

    public init(directory: URL) { self.directory = directory }

    public func load<T: Decodable>(_ name: String, default fallback: T) -> T {
        let url = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            problem = "Saved settings could not be read. Defaults are in use."
            return fallback
        }
    }

    @discardableResult public func save<T: Encodable>(_ name: String, _ value: T) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
            problem = nil
            return true
        } catch {
            problem = "Settings are unavailable. Changes apply only for this session."
            return false
        }
    }
}
