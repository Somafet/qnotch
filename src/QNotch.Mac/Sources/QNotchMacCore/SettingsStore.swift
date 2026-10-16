import Foundation

public struct GeneralSettings: Codable, Equatable {
    public var displayID: UInt32?
    public var reduceMotion = false
    public var timerEnabled = true
    public init() {}
}

public struct TimerSettings: Codable, Equatable {
    public var minutes = 25
    public var playSound = true
    public init() {}
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
