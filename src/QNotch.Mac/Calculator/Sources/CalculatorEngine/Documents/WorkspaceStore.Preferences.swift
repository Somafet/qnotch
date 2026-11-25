import Foundation

struct PreferencesDocument: Equatable, JSONDocument {
    var version: Int
    var workdayRegion: String?
    var autoCurrencyRates = false
    // Version 2 display and window preferences. Absent values keep the version-1 behavior.
    var fontSize: Int?
    var decimalPlaces: Int?
    var numberStyle: String?
    var language: String?
    var alwaysOnTop = false
    var window: WindowPlacementPreference?
    /// ISO code plain monetary results are shown in; nil shows each amount in its own currency.
    var defaultCurrency: String?
    static let minimumFontSize = 10, maximumFontSize = 40
    /// Interface languages: the nine keyword-alias languages.
    static let languages = ["en", "ro", "de", "fr", "es", "it", "ja", "zh-Hans", "ko"]

    init(_ version: Int, _ workdayRegion: String?) { self.version = version; self.workdayRegion = workdayRegion }
    func with(_ change: (inout PreferencesDocument) -> Void) -> PreferencesDocument { var copy = self; change(&copy); return copy }
    var usesVersion2: Bool {
        fontSize != nil || decimalPlaces != nil || numberStyle != nil || language != nil || alwaysOnTop || window != nil || defaultCurrency != nil
    }

    static func decode(_ json: NetJSON.Reader) throws -> PreferencesDocument {
        var value = PreferencesDocument(try json.int("Version"), try json.string("WorkdayRegion"))
        value.autoCurrencyRates = try json.bool("AutoCurrencyRates")
        value.fontSize = try json.intOrNil("FontSize")
        value.decimalPlaces = try json.intOrNil("DecimalPlaces")
        value.numberStyle = try json.string("NumberStyle")
        value.language = try json.string("Language")
        value.alwaysOnTop = try json.bool("AlwaysOnTop")
        value.window = try json.object("Window", WindowPlacementPreference.decode)
        value.defaultCurrency = try json.string("DefaultCurrency")
        return value
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("WorkdayRegion", NetJSON.string(workdayRegion)), ("AutoCurrencyRates", NetJSON.bool(autoCurrencyRates)),
                        ("FontSize", NetJSON.int(fontSize)), ("DecimalPlaces", NetJSON.int(decimalPlaces)), ("NumberStyle", NetJSON.string(numberStyle)),
                        ("Language", NetJSON.string(language)), ("AlwaysOnTop", NetJSON.bool(alwaysOnTop)), ("Window", window?.json ?? "null"),
                        ("DefaultCurrency", NetJSON.string(defaultCurrency))])
    }
}

/// Restored (normal) window bounds in Windows workspace pixels, plus whether it was maximized.
/// System.Text.Json also writes the computed Width, Height and IsValid properties; readers ignore them.
struct WindowPlacementPreference: Equatable {
    static let maximumCoordinate = 1_000_000, maximumExtent = 100_000
    let left: Int32, top: Int32, right: Int32, bottom: Int32
    let maximized: Bool
    init(_ left: Int32, _ top: Int32, _ right: Int32, _ bottom: Int32, _ maximized: Bool) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom; self.maximized = maximized
    }
    /// C# `int` subtraction, which wraps.
    var width: Int32 { right &- left }
    var height: Int32 { bottom &- top }
    var isValid: Bool {
        abs(Int64(left)) <= Int64(Self.maximumCoordinate) && abs(Int64(top)) <= Int64(Self.maximumCoordinate) &&
            abs(Int64(right)) <= Int64(Self.maximumCoordinate) && abs(Int64(bottom)) <= Int64(Self.maximumCoordinate) &&
            width > 0 && width <= Self.maximumExtent && height > 0 && height <= Self.maximumExtent
    }
    static func decode(_ json: NetJSON.Reader) throws -> WindowPlacementPreference {
        WindowPlacementPreference(Int32(try json.int("Left")), Int32(try json.int("Top")), Int32(try json.int("Right")), Int32(try json.int("Bottom")), try json.bool("Maximized"))
    }
    var json: String {
        NetJSON.object([("Left", String(left)), ("Top", String(top)), ("Right", String(right)), ("Bottom", String(bottom)), ("Maximized", NetJSON.bool(maximized)),
                        ("Width", String(width)), ("Height", String(height)), ("IsValid", NetJSON.bool(isValid))])
    }
}

extension WorkspaceStore {
    static let preferencesVersion = 2
    var preferencesPath: String { (directory as NSString).appendingPathComponent("preferences.json") }

    func loadPreferences() throws -> PreferencesDocument {
        _ = try requireWorkspace()
        let path = preferencesPath
        if !NetFile.fileExists(path) && !NetFile.fileExists(path + ".bak") { return PreferencesDocument(1, nil) }
        let loaded = try AtomicJson.load(path, 4096, WorkspaceStore.validatePreferences)
        preferencesRecovered = loaded.recovered
        var value = loaded.value
        if loaded.recovered && value.autoCurrencyRates {
            value.autoCurrencyRates = false
            try AtomicJson.write(path, value) // Recovery cannot roll back a user's network-consent revocation.
        }
        return value
    }

    @discardableResult
    func setWorkdayRegion(_ region: String?) throws -> PreferencesDocument { try updatePreferences { $0.with { $0.workdayRegion = region } } }
    @discardableResult
    func setAutoCurrencyRates(_ enabled: Bool) throws -> PreferencesDocument { try updatePreferences { $0.with { $0.autoCurrencyRates = enabled } } }

    /// Replaces preferences atomically. A file is written as version 2 only once it holds a version-2
    /// setting, so version-1 files stay readable by builds that predate these settings.
    @discardableResult
    func updatePreferences(_ change: (PreferencesDocument) throws -> PreferencesDocument) throws -> PreferencesDocument {
        _ = try requireWorkspace()
        let current = try loadPreferences() // Refuse an unsupported/external future document before replacement.
        var next = try change(current)
        next.version = next.usesVersion2 ? 2 : 1
        try WorkspaceStore.validatePreferences(next)
        try AtomicJson.write(preferencesPath, next)
        return next
    }

    static func validatePreferences(_ value: PreferencesDocument) throws {
        if value.version != 1 && value.version != preferencesVersion { throw DocumentError.unsupportedVersion }
        if let region = value.workdayRegion, !WorkdayCalendar.supportedRegions.contains(where: { $0.ordinalEquals(region) }) {
            throw CalcError.invalidData("Unsupported workday calendar preference")
        }
        if value.version == 1 && value.usesVersion2 { throw CalcError.invalidData("Version-1 preferences cannot hold version-2 settings") }
        if let size = value.fontSize, size < PreferencesDocument.minimumFontSize || size > PreferencesDocument.maximumFontSize {
            throw CalcError.invalidData("Unsupported text size preference")
        }
        if let places = value.decimalPlaces, places < 0 || places > ResultFormat.maxDecimalPlaces { throw CalcError.invalidData("Unsupported decimal places preference") }
        if let style = value.numberStyle, !NumberStyle.presetIds.contains(where: { $0.ordinalEquals(style) }) {
            throw CalcError.invalidData("Unsupported number style preference")
        }
        if let language = value.language, !PreferencesDocument.languages.contains(where: { $0.ordinalEquals(language) }) {
            throw CalcError.invalidData("Unsupported language preference")
        }
        if let currency = value.defaultCurrency, CurrencyCatalog.tryCode(currency) == nil { throw CalcError.invalidData("Unsupported default currency preference") }
        if let window = value.window, !window.isValid { throw CalcError.invalidData("Invalid window placement preference") }
    }
}
