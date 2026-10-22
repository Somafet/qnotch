import Foundation

/// Settings structs decode missing keys as their defaults, so adding a field never makes an
/// existing file unreadable.
extension KeyedDecodingContainer {
    public func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public struct GeneralSettings: Codable, Equatable {
    public static let hoverRange = 0...600, closeRange = 100...1500
    public static let accents = ["#5B9DFF", "#7C83FF", "#B07CFF", "#FF7CB0", "#FF7A6B", "#FFB54D", "#4CD98C", "#3CC8D9"]

    public var displayID: UInt32?
    public var reduceMotion = false
    /// Module ids that are off. A module that is off is never constructed.
    public var disabledModules: [String] = []
    /// Explicit opt-in for new, default-off modules; old saved settings never enable a shell.
    public var enabledOptionalModules: [String] = []
    public static let defaultOffModules: Set<String> = ["terminal"]
    /// Choose the segment under the pointer once after hover dwell. Opt-in.
    public var hoverOpensSegment = false
    /// Pointer rest before the panel opens, and pointer absence before it closes (milliseconds).
    public var hoverDelayMs = 120
    public var closeDelayMs = 400
    /// Keep panel open: it never closes on pointer leave, outside clicks or focus loss.
    public var pinned = false
    /// One of `accents`, or nil to follow the macOS accent color.
    public var accent: String?
    /// Header name; nil uses the account's first name.
    public var profileName: String?
    /// Home cards the user hid (by card id).
    public var hiddenCards: [String] = []
    /// Tab-strip visibility is independent of module enablement. Hidden tabs can be opened by actions.
    public var hiddenTabs: [String] = []
    /// Module owners whose regular status segments are hidden beside the notch (peeks are separate).
    public var hiddenNotchModules: [String] = []
    /// Edit mode: the user's order of Home cards and of module tabs (see LayoutOrder).
    public var cardOrder: [String] = []
    public var tabOrder: [String] = []
    /// Floating-pill offsets by display id (points from the display's center).
    public var pillOffsets: [String: Double] = [:]
    /// Offer beta (prerelease) Mac versions as updates, not only stable ones.
    public var betaUpdates = false
    /// The welcome tour ended (finished, skipped or closed). Nil: never recorded, as in settings
    /// from before the tour. A local preference, never part of setup codes.
    public var onboardingDone: Bool?
    public init() {}

    public func isEnabled(_ module: String) -> Bool {
        !disabledModules.contains(module) && (!Self.defaultOffModules.contains(module) || enabledOptionalModules.contains(module))
    }
    public mutating func setEnabled(_ module: String, _ enabled: Bool) {
        if Self.defaultOffModules.contains(module) {
            enabledOptionalModules.removeAll { $0 == module }
            if enabled { enabledOptionalModules.append(module) }
        }
        disabledModules.removeAll { $0 == module }
        if !enabled { disabledModules.append(module); disabledModules.sort() }
    }
    public func isCardVisible(_ card: String) -> Bool { !hiddenCards.contains(card) }
    public mutating func setCardVisible(_ card: String, _ visible: Bool) {
        hiddenCards.removeAll { $0 == card }
        if !visible { hiddenCards.append(card); hiddenCards.sort() }
    }

    public func isTabVisible(_ tab: String) -> Bool { !hiddenTabs.contains(tab) }
    public mutating func setTabVisible(_ tab: String, _ visible: Bool) {
        hiddenTabs.removeAll { $0 == tab }
        if !visible { hiddenTabs.append(tab); hiddenTabs.sort() }
    }
    public func isNotchVisible(_ module: String) -> Bool { !hiddenNotchModules.contains(module) }
    public mutating func setNotchVisible(_ module: String, _ visible: Bool) {
        hiddenNotchModules.removeAll { $0 == module }
        if !visible { hiddenNotchModules.append(module); hiddenNotchModules.sort() }
    }

    /// Name for the panel header: the chosen name, else the account's first name, else "QNotch".
    public static func displayName(chosen: String?, fullUserName: String) -> String {
        if let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty { return String(chosen.prefix(40)) }
        return fullUserName.split(separator: " ").first.map(String.init) ?? "QNotch"
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, reduceMotion, disabledModules, enabledOptionalModules, timerEnabled, hoverOpensSegment, hoverDelayMs, closeDelayMs, pinned, accent, profileName, hiddenCards, hiddenTabs, hiddenNotchModules, cardOrder, tabOrder, pillOffsets, betaUpdates, onboardingDone
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayID = c.value(.displayID, nil)
        reduceMotion = c.value(.reduceMotion, false)
        disabledModules = c.value(.disabledModules, [])
        enabledOptionalModules = c.value(.enabledOptionalModules, [])
        // The first milestone stored one switch for its only module.
        if c.value(.timerEnabled, true) == false, !disabledModules.contains("timer") { disabledModules.append("timer") }
        hoverOpensSegment = c.value(.hoverOpensSegment, false)
        hoverDelayMs = min(Self.hoverRange.upperBound, max(Self.hoverRange.lowerBound, c.value(.hoverDelayMs, 120)))
        closeDelayMs = min(Self.closeRange.upperBound, max(Self.closeRange.lowerBound, c.value(.closeDelayMs, 400)))
        pinned = c.value(.pinned, false)
        accent = c.value(.accent, String?.none).flatMap { Self.accents.contains($0) ? $0 : nil }
        profileName = c.value(.profileName, String?.none)
        hiddenCards = c.value(.hiddenCards, [])
        hiddenTabs = c.value(.hiddenTabs, [])
        hiddenNotchModules = c.value(.hiddenNotchModules, [])
        cardOrder = c.value(.cardOrder, [])
        tabOrder = c.value(.tabOrder, [])
        pillOffsets = c.value(.pillOffsets, [:])
        betaUpdates = c.value(.betaUpdates, false)
        onboardingDone = c.value(.onboardingDone, Bool?.none)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(displayID, forKey: .displayID)
        try c.encode(reduceMotion, forKey: .reduceMotion)
        try c.encode(disabledModules, forKey: .disabledModules)
        try c.encode(enabledOptionalModules, forKey: .enabledOptionalModules)
        try c.encode(hoverOpensSegment, forKey: .hoverOpensSegment)
        try c.encode(hoverDelayMs, forKey: .hoverDelayMs)
        try c.encode(closeDelayMs, forKey: .closeDelayMs)
        try c.encode(pinned, forKey: .pinned)
        try c.encodeIfPresent(accent, forKey: .accent)
        try c.encodeIfPresent(profileName, forKey: .profileName)
        try c.encode(hiddenCards, forKey: .hiddenCards)
        try c.encode(hiddenTabs, forKey: .hiddenTabs)
        try c.encode(hiddenNotchModules, forKey: .hiddenNotchModules)
        try c.encode(cardOrder, forKey: .cardOrder)
        try c.encode(tabOrder, forKey: .tabOrder)
        try c.encode(pillOffsets, forKey: .pillOffsets)
        try c.encode(betaUpdates, forKey: .betaUpdates)
        try c.encodeIfPresent(onboardingDone, forKey: .onboardingDone)
    }
}

public struct TimerSettings: Codable, Equatable {
    public var minutes = 25
    public var playSound = true
    /// Open the panel on Home for a few seconds when time is up (Windows behavior).
    public var openWhenDone = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case minutes, playSound, openWhenDone }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = c.value(.minutes, 25)
        playSound = c.value(.playSound, true)
        openWhenDone = c.value(.openWhenDone, true)
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
