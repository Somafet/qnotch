import Compression
import Foundation

/// "qnotch-setup-1:" codes (Windows SetupCode): base64url of raw-deflated JSON, one object per
/// section. The Mac writes and reads the Windows field names for everything both apps have, so a
/// code works across them; Mac-only choices go in a "mac" section that Windows ignores. Hotkeys are
/// not shared: keyboards and shortcut syntax differ between the platforms.
public enum SetupCode {
    public static let prefix = "qnotch-setup-1:"
    static let maxCode = 16_384, maxJSON = 65_536, maxString = 300, maxItems = 200

    /// Everything a code can carry, as read from or written to the settings files.
    public struct Snapshot: Equatable {
        public var general: GeneralSettings
        public var gameMode: GameModeSettings
        public var timer: TimerSettings
        public var weather: WeatherSettings
        public var notifications: NotificationSettings
        public var ai: AiSettings
        public var agents: AgentsSettings
        public init(general: GeneralSettings, gameMode: GameModeSettings, timer: TimerSettings, weather: WeatherSettings,
                    notifications: NotificationSettings, ai: AiSettings, agents: AgentsSettings) {
            self.general = general; self.gameMode = gameMode; self.timer = timer; self.weather = weather
            self.notifications = notifications; self.ai = ai; self.agents = agents
        }
    }

    public struct Plan {
        public var result: Snapshot
        /// Section titles that change.
        public var titles: [String]
        /// Module ids the code turns on.
        public var turnsOn: [String]
    }

    public struct Failure: Error, Equatable { public let message: String }

    // MARK: Export

    public static func export(_ s: Snapshot) -> String {
        var cardVisible: [String: Bool] = [:]
        s.general.hiddenCards.forEach { cardVisible[$0] = false }
        var general: [String: Any] = ["HoverDwellMs": s.general.hoverDelayMs, "LeaveDelayMs": s.general.closeDelayMs,
                                      "ReduceMotion": s.general.reduceMotion, "DisabledModules": s.general.disabledModules,
                                      "CardOrder": s.general.cardOrder, "CardVisible": cardVisible, "TabOrder": s.general.tabOrder]
        if let accent = s.general.accent { general["AccentColor"] = accent }
        let root: [String: Any] = [
            "general": general,
            "gamemode": ["AutoDetect": s.gameMode.autoDetect, "Opacity": Double(s.gameMode.opacity) / 100],
            "timer": ["Minutes": s.timer.minutes],
            "weather": ["Units": s.weather.units == .metric ? "Metric" : "Imperial", "ShowInPill": s.weather.showInPill],
            "notifications": ["ToastSeconds": s.notifications.toastSeconds, "RetentionDays": s.notifications.retentionDays,
                              "OpenOnError": s.notifications.openOnError, "Sound": s.notifications.sound, "QuietDuringCalls": s.notifications.quietDuringCalls],
            "ai": ["RefreshMinutes": s.ai.refreshMinutes],
            "agents": ["SoundNeedsYou": s.agents.soundNeedsYou, "SoundDone": s.agents.soundDone],
            "mac": ["accent": s.general.accent ?? "auto", "anyFullScreen": s.gameMode.anyFullScreen, "hiddenGameModules": s.gameMode.hiddenModules]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        return prefix + base64url(deflate(json))
    }

    // MARK: Import

    public static func read(_ code: String, current: Snapshot, modules: [String]) throws -> Plan {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(prefix) else { throw Failure(message: "This is not a QNotch setup code.") }
        guard text.count <= maxCode else { throw Failure(message: "This code is too long.") }
        guard let packed = unbase64url(String(text.dropFirst(prefix.count))), let json = inflate(packed, limit: maxJSON + 1) else {
            throw Failure(message: "This code is damaged or incomplete. Copy it again.")
        }
        guard json.count <= maxJSON else { throw Failure(message: "This code is too long.") }
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw Failure(message: "This code is damaged or incomplete. Copy it again.")
        }
        guard fits(root) else { throw Failure(message: "This code has a value QNotch cannot use.") }
        var s = current
        var titles: [String] = []
        func section(_ id: String, _ title: String, _ apply: ([String: Any]) throws -> Void) throws {
            guard let fields = root[id] as? [String: Any], !fields.isEmpty else { return }
            try apply(fields)
            titles.append(title)
        }
        func int(_ value: Any?, _ range: ClosedRange<Int>, _ title: String) throws -> Int? {
            guard let value else { return nil }
            guard let number = value as? NSNumber, !(value is Bool), range.contains(number.intValue) else { throw Failure(message: "This code has a value QNotch cannot use (\(title)).") }
            return number.intValue
        }
        func bool(_ value: Any?, _ title: String) throws -> Bool? {
            guard let value else { return nil }
            guard let flag = value as? Bool else { throw Failure(message: "This code has a value QNotch cannot use (\(title)).") }
            return flag
        }
        func strings(_ value: Any?, _ title: String) throws -> [String]? {
            guard let value else { return nil }
            guard let list = value as? [String] else { throw Failure(message: "This code has a value QNotch cannot use (\(title)).") }
            return list
        }

        try section("general", "Appearance and features") { f in
            let t = "Appearance and features"
            if let v = try int(f["HoverDwellMs"], GeneralSettings.hoverRange, t) { s.general.hoverDelayMs = v }
            if let v = try int(f["LeaveDelayMs"], GeneralSettings.closeRange, t) { s.general.closeDelayMs = v }
            if let v = try bool(f["ReduceMotion"], t) { s.general.reduceMotion = v }
            if let v = try strings(f["DisabledModules"], t) { s.general.disabledModules = v.map { $0.lowercased() }.sorted() }
            if let v = try strings(f["CardOrder"], t) { s.general.cardOrder = v }
            if let v = try strings(f["TabOrder"], t) { s.general.tabOrder = v }
            if let accent = f["AccentColor"] as? String { s.general.accent = GeneralSettings.accents.first { $0.caseInsensitiveCompare(accent) == .orderedSame } }
            if let visible = f["CardVisible"] {
                guard let map = visible as? [String: Bool] else { throw Failure(message: "This code has a value QNotch cannot use (\(t)).") }
                s.general.hiddenCards = map.filter { !$0.value }.map(\.key).sorted()
            }
        }
        try section("gamemode", "Game mode") { f in
            if let v = try bool(f["AutoDetect"], "Game mode") { s.gameMode.autoDetect = v }
            if let value = f["Opacity"] {
                guard let number = value as? Double, (0.3...1).contains(number) else { throw Failure(message: "This code has a value QNotch cannot use (Game mode).") }
                s.gameMode.opacity = Int((number * 100).rounded())
            }
        }
        try section("timer", "Timer") { f in if let v = try int(f["Minutes"], 1...180, "Timer") { s.timer.minutes = v } }
        try section("weather", "Weather") { f in
            if let units = f["Units"] {
                guard let text = units as? String, ["Metric", "Imperial"].contains(text) else { throw Failure(message: "This code has a value QNotch cannot use (Weather).") }
                s.weather.units = text == "Metric" ? .metric : .imperial
            }
            if let v = try bool(f["ShowInPill"], "Weather") { s.weather.showInPill = v }
        }
        try section("notifications", "Notifications") { f in
            let t = "Notifications"
            if let v = try int(f["ToastSeconds"], 0...60, t) { s.notifications.toastSeconds = v }
            if let v = try int(f["RetentionDays"], 1...30, t) { s.notifications.retentionDays = v }
            if let v = try bool(f["OpenOnError"], t) { s.notifications.openOnError = v }
            if let v = try bool(f["Sound"], t) { s.notifications.sound = v }
            if let v = try bool(f["QuietDuringCalls"], t) { s.notifications.quietDuringCalls = v }
        }
        try section("ai", "AI apps and usage") { f in if let v = try int(f["RefreshMinutes"], 5...60, "AI apps and usage") { s.ai.refreshMinutes = v } }
        try section("agents", "Agents") { f in
            if let v = try bool(f["SoundNeedsYou"], "Agents") { s.agents.soundNeedsYou = v }
            if let v = try bool(f["SoundDone"], "Agents") { s.agents.soundDone = v }
        }
        if let mac = root["mac"] as? [String: Any] {
            if let accent = mac["accent"] as? String { s.general.accent = accent == "auto" ? nil : GeneralSettings.accents.first { $0 == accent } }
            if let any = mac["anyFullScreen"] as? Bool { s.gameMode.anyFullScreen = any }
            if let hidden = mac["hiddenGameModules"] as? [String] { s.gameMode.hiddenModules = hidden }
        }
        guard !titles.isEmpty else { throw Failure(message: "This code has no settings this version of QNotch knows.") }
        let turnsOn = modules.filter { !current.general.isEnabled($0) && s.general.isEnabled($0) }
        return Plan(result: s, titles: titles, turnsOn: turnsOn)
    }

    // MARK: Limits and encoding

    /// Strings up to 300 characters, collections up to 200 items, nesting below 4 levels (as Windows).
    static func fits(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }
        switch value {
        case let array as [Any]: return array.count <= maxItems && array.allSatisfy { fits($0, depth: depth + 1) }
        case let object as [String: Any]: return object.count <= maxItems && object.allSatisfy { $0.key.count <= maxString && fits($0.value, depth: depth + 1) }
        case let text as String: return text.count <= maxString
        default: return true
        }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    /// Raw DEFLATE (RFC 1951), what .NET's DeflateStream reads and writes.
    static func deflate(_ data: Data) -> Data { process(data, operation: COMPRESSION_STREAM_ENCODE, limit: Int.max) ?? Data() }
    static func inflate(_ data: Data, limit: Int) -> Data? { process(data, operation: COMPRESSION_STREAM_DECODE, limit: limit) }

    private static func process(_ input: Data, operation: compression_stream_operation, limit: Int) -> Data? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let size = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: size - stream.pointee.dst_size)
                if output.count > limit { return output }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return output
                default: return nil
                }
            }
        }
    }
}
