import Foundation

/// Plan usage for Claude Code and Codex (Windows AiModels, ClaudeCodeProvider, CodexProvider).
public struct UsageWindow: Equatable {
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(label: String, usedPercent: Double, resetsAt: Date?) { self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt }
    public var usedText: String { "\(Int(usedPercent.rounded()))%" }
    public var leftText: String { "\(Int((100 - usedPercent).rounded()))% left" }

    public func resetText(now: Date = Date()) -> String {
        guard let resetsAt else { return "" }
        let left = resetsAt.timeIntervalSince(now)
        return left <= 0 ? "Reset, refresh for a new reading" : "Resets " + AiFormat.within(left)
    }
}

public struct BankedResets: Equatable {
    public var count: Int
    public var expiresAt: Date?
    public var label: String?
    public init(count: Int, expiresAt: Date?, label: String?) { self.count = count; self.expiresAt = expiresAt; self.label = label }

    public func text(now: Date = Date()) -> String {
        var text = count == 1 ? "1 banked reset" : "\(count) banked resets"
        if let expiresAt, expiresAt > now { text += "  ·  expires " + AiFormat.within(expiresAt.timeIntervalSince(now)) }
        return text
    }
}

public enum UsageResult: Equatable {
    case ok(windows: [UsageWindow], plan: String?, asOf: Date, banked: BankedResets?)
    case unavailable(String)
}

public enum AiFormat {
    public static func within(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "in under a minute" }
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        if seconds < 86400 { return "in \(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "in \(Int(seconds / 86400))d \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600))h"
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}

public enum ClaudeUsage {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let windows = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")]

    /// The Keychain service Claude Code uses on macOS: plain for ~/.claude, with the first 8 hex
    /// digits of the folder path's SHA-256 for any other config folder.
    public static func keychainService(configDir: String, isDefault: Bool, sha256Hex: (String) -> String) -> String {
        isDefault ? "Claude Code-credentials" : "Claude Code-credentials-" + String(sha256Hex(configDir).prefix(8))
    }

    /// Access token and plan from the credentials JSON (Keychain item or .credentials.json).
    public static func credentials(_ data: Data) -> (token: String, plan: String)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return (token, planName(oauth["subscriptionType"] as? String, oauth["rateLimitTier"] as? String))
    }

    static func planName(_ subscription: String?, _ tier: String?) -> String {
        guard let subscription, let first = subscription.first else { return "" }
        let name = first.uppercased() + subscription.dropFirst()
        if let tier, let range = tier.range(of: #"\d+x"#, options: .regularExpression) { return "\(name) \(tier[range])" }
        return name
    }

    public static func parse(status: Int, body: Data?, plan: String, now: Date = Date()) -> UsageResult {
        switch status {
        case 401, 403: return .unavailable("Sign-in expired. Open Claude Code once to renew it.")
        case 429: return .unavailable("Rate limited by Anthropic. Will retry on the next refresh.")
        case 200..<300: break
        default: return .unavailable("Usage endpoint returned HTTP \(status).")
        }
        guard let body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .unavailable("Unexpected response from the usage endpoint.")
        }
        let list = windows.compactMap { key, label -> UsageWindow? in
            guard let window = root[key] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
            return UsageWindow(label: label, usedPercent: min(100, max(0, used)), resetsAt: AiFormat.date(window["resets_at"] as? String))
        }
        guard !list.isEmpty else { return .unavailable("Unexpected response from the usage endpoint.") }
        return .ok(windows: list, plan: plan, asOf: now, banked: banked(root["cedar_ember"] as? [String: Any], now: now))
    }

    static func banked(_ value: [String: Any]?, now: Date) -> BankedResets? {
        guard let value, value["eligible"] as? Bool == true, let grants = value["grants"] as? [[String: Any]] else { return nil }
        let next = value["next_grant_id"] as? String
        var count = 0, hasNext = false
        var expires: Date?, label: String?
        for grant in grants {
            if grant["paused"] as? Bool == true || grant["usable_now"] as? Bool == false { continue }
            let ends = AiFormat.date(grant["ends_at"] as? String)
            if let ends, ends <= now { continue }
            if let left = grant["resets_left"] as? Int, left > 0 { count += left }
            if grant["id"] as? String == next { hasNext = true; expires = ends; label = grant["label"] as? String }
        }
        return hasNext && count > 0 ? BankedResets(count: count, expiresAt: expires, label: label) : nil
    }
}

public enum CodexUsage {
    /// The newest rate-limit reading in a rollout file's tail; windows that already reset are dropped.
    public static func reading(fromTail text: String, now: Date = Date()) -> UsageResult? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let limits = (root["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
            let at = AiFormat.date(root["timestamp"] as? String) ?? now
            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
                var resets: Date?
                if let seconds = window["resets_at"] as? Double { resets = Date(timeIntervalSince1970: seconds) }
                else if let seconds = window["resets_in_seconds"] as? Double { resets = at.addingTimeInterval(seconds) }
                let item = UsageWindow(label: label(minutes: window["window_minutes"] as? Int ?? 0), usedPercent: min(100, max(0, used)), resetsAt: resets)
                return resets.map { $0 > now } ?? true ? item : nil
            }
            if !windows.isEmpty { return .ok(windows: windows, plan: planName(limits["plan_type"] as? String), asOf: at, banked: nil) }
        }
        return nil
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 300: return "5-hour"
        case 10080: return "Weekly"
        case ...0: return "Limit"
        case let m where m % 1440 == 0: return "\(m / 1440)-day"
        case let m where m % 60 == 0: return "\(m / 60)-hour"
        default: return "\(minutes)-min"
        }
    }

    static func planName(_ plan: String?) -> String? {
        guard let plan, let first = plan.first else { return nil }
        return plan.lowercased() == "prolite" ? "Pro Lite" : first.uppercased() + plan.dropFirst()
    }

    /// `account/rateLimits/read` → rateLimitResetCredits.
    public static func credits(_ value: [String: Any]?) -> BankedResets? {
        guard let value, let list = value["credits"] as? [[String: Any]] else { return nil }
        var count = 0
        var first: Date?, title: String?
        for credit in list where credit["status"] as? String == "available" {
            count += 1
            let at = (credit["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            if count == 1 || (at != nil && (first == nil || at! < first!)) { first = at; title = credit["title"] as? String }
        }
        if let total = value["availableCount"] as? Int { count = max(count, total) }
        return count > 0 ? BankedResets(count: count, expiresAt: first, label: title) : nil
    }
}

/// ai.json (Windows AiSettings).
public struct AiSettings: Codable, Equatable {
    public static let refreshChoices = [5, 10, 15, 30, 60]
    public var claude = true
    public var codex = true
    /// The Claude account (config folder) shown, by folder path; nil = the default one.
    public var claudeAccount: String?
    public var refreshMinutes = 10
    /// Six launcher slots: app ids or nil.
    public var slots: [String?] = Array(repeating: nil, count: 6)
    /// Apps once auto-placed into a slot, so removing one never brings it back.
    public var autoPlaced: [String] = []
    /// Custom apps: paths to .app bundles.
    public var custom: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case claude, codex, claudeAccount, refreshMinutes, slots, autoPlaced, custom }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = c.value(.claude, true)
        codex = c.value(.codex, true)
        claudeAccount = c.value(.claudeAccount, String?.none)
        refreshMinutes = min(60, max(5, c.value(.refreshMinutes, 10)))
        let saved: [String?] = c.value(.slots, [])
        slots = Array((saved + Array(repeating: nil, count: 6)).prefix(6))
        autoPlaced = c.value(.autoPlaced, [])
        custom = c.value(.custom, [])
    }

    /// Puts newly found apps into free slots once (Windows AutoPlaced).
    public mutating func autoPlace(_ ids: [String]) {
        for id in ids where !autoPlaced.contains(id) && !slots.contains(id) {
            guard let free = slots.firstIndex(where: { $0 == nil }) else { break }
            slots[free] = id
            autoPlaced.append(id)
        }
    }
}
