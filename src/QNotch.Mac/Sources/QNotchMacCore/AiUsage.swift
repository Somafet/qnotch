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

    /// The Home card's line for one provider (Windows AiProviderItem.RefreshCard): the first window's
    /// percentage and bar, then the second window and the reset. Unavailable never shows a number.
    public static func summary(_ result: UsageResult?, now: Date = Date()) -> (headline: String, percent: Double?, sub: String) {
        switch result {
        case .ok(let windows, _, _, _)? where !windows.isEmpty:
            let first = windows[0]
            let resetText = first.resetText(now: now)
            let reset = resetText.isEmpty ? first.label : resetText.lowercased()
            return (first.usedText, first.usedPercent, windows.count > 1 ? "\(windows[1].label) \(windows[1].usedText)  ·  \(reset)" : reset)
        case .unavailable(let reason)?: return ("Unavailable", nil, reason)
        default: return ("Checking", nil, "")
        }
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

/// One Claude Code sign-in: a config folder (Windows ClaudeCodeProvider.Discover).
public struct ClaudeAccount: Equatable {
    public let path: String
    /// "Default" for ~/.claude, otherwise the folder's suffix ("work" for ~/.claude-work).
    public let folderName: String
    /// Whether this is ~/.claude, which keeps its account record in ~/.claude.json.
    public let isDefault: Bool
    public init(path: String, folderName: String, isDefault: Bool) { self.path = path; self.folderName = folderName; self.isDefault = isDefault }

    /// ~/.claude (or CLAUDE_CONFIG_DIR) first, then every other signed-in ~/.claude-* folder in name order.
    public static func discover(home: String, configDir: String?, entries: [String], hasLogin: (_ path: String, _ isDefault: Bool) -> Bool) -> [ClaudeAccount] {
        let standard = (home as NSString).appendingPathComponent(".claude")
        let main = configDir.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 } ?? standard
        func name(_ path: String) -> String {
            let folder = (path as NSString).lastPathComponent
            return path == standard ? "Default" : folder.hasPrefix(".claude-") ? String(folder.dropFirst(".claude-".count)) : folder
        }
        var list = [ClaudeAccount(path: main, folderName: name(main), isDefault: main == standard)]
        for entry in entries.filter({ $0 == ".claude" || $0.hasPrefix(".claude-") }).sorted() {
            let path = (home as NSString).appendingPathComponent(entry)
            guard path != main, hasLogin(path, path == standard) else { continue }
            list.append(ClaudeAccount(path: path, folderName: name(path), isDefault: path == standard))
        }
        return list
    }
}

/// Claude Code's plan usage, as its own CLI reports it: the `get_usage` control request of its
/// stream-JSON mode (what T3 Code reads). The CLI reads its login itself, so QNotch never holds
/// the token and never touches the Keychain.
public enum ClaudeUsage {
    static let windows = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")]

    /// The two control requests: `initialize`, then `get_usage`. No user message is ever sent, so
    /// the CLI makes no model request.
    public static let requests = """
    {"type":"control_request","request_id":"qnotch-init","request":{"subtype":"initialize"}}
    {"type":"control_request","request_id":"qnotch-usage","request":{"subtype":"get_usage","skip_behaviors":true}}

    """

    /// Arguments for the CLI: stream-JSON both ways, no settings files (so no hooks, QNotch's own
    /// included), no MCP servers, and no saved session.
    public static let arguments = ["-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                                   "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
                                   "--strict-mcp-config", "--no-session-persistence"]

    /// The config file holding a folder's account record: `.claude.json` inside a custom config
    /// folder, or in the home folder for ~/.claude.
    public static func accountFile(for account: ClaudeAccount, home: String) -> String {
        ((account.isDefault ? home : account.path) as NSString).appendingPathComponent(".claude.json")
    }

    /// Whether the account record shows a Claude login, and its rate-limit tier
    /// ("default_claude_max_5x"). No secret is in this file.
    public static func login(_ data: Data?) -> (signedIn: Bool, tier: String?) {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return (false, nil) }
        return (true, (account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String))
    }

    /// The CLI's answer to `get_usage`.
    public enum Answer {
        case usage([String: Any]?)
        case failed(String)
    }

    /// The `get_usage` answer in one line of the CLI's output; nil for any other line.
    public static func answer(line: Data) -> Answer? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], root["type"] as? String == "control_response",
              let response = root["response"] as? [String: Any], response["request_id"] as? String == "qnotch-usage" else { return nil }
        guard response["subtype"] as? String == "success" else {
            let error = (response["error"] as? String).map { " (\($0.prefix(120)))" } ?? ""
            return .failed("Claude Code could not read usage\(error).")
        }
        return .usage(response["response"] as? [String: Any])
    }

    // MARK: Banked resets (an optional extra; any failure reads as "none")

    /// Usage with the banked resets ("cedar_ember"), which the CLI's `get_usage` leaves out.
    public static let bankedURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!

    /// The Keychain service Claude Code stores its login under: plain for ~/.claude, with the
    /// first 8 hex digits of the folder path's SHA-256 for any other config folder.
    public static func keychainService(configDir: String, isDefault: Bool, sha256Hex: (String) -> String) -> String {
        isDefault ? "Claude Code-credentials" : "Claude Code-credentials-" + String(sha256Hex(configDir).prefix(8))
    }

    /// The access token in Claude Code's credentials JSON (Keychain item or .credentials.json).
    public static func accessToken(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (root["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The banked resets in a successful `bankedURL` response body.
    public static func banked(body: Data?, now: Date = Date()) -> BankedResets? {
        guard let body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return banked(root["cedar_ember"] as? [String: Any], now: now)
    }

    /// A reading with banked resets added (kept as they were when `banked` is nil).
    public static func adding(_ banked: BankedResets?, to result: UsageResult) -> UsageResult {
        guard let banked, case let .ok(windows, plan, asOf, _) = result else { return result }
        return .ok(windows: windows, plan: plan, asOf: asOf, banked: banked)
    }

    static func planName(_ subscription: String?, _ tier: String?) -> String {
        guard let subscription, let first = subscription.first else { return "" }
        let name = first.uppercased() + subscription.dropFirst()
        if let tier, let range = tier.range(of: #"\d+x"#, options: .regularExpression) { return "\(name) \(tier[range])" }
        return name
    }

    /// The `response` object of a successful `get_usage` answer.
    public static func parse(usage: [String: Any]?, tier: String?, now: Date = Date()) -> UsageResult {
        guard let usage else { return .unavailable("Claude Code did not report usage.") }
        guard usage["rate_limits_available"] as? Bool != false, let limits = usage["rate_limits"] as? [String: Any] else {
            return .unavailable("Signed in without a subscription. Usage needs a Claude Pro or Max login.")
        }
        let list = windows.compactMap { key, label -> UsageWindow? in
            guard let window = limits[key] as? [String: Any], let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(label: label, usedPercent: min(100, max(0, used)), resetsAt: AiFormat.date(window["resets_at"] as? String))
        }
        guard !list.isEmpty else { return .unavailable("Claude Code reported no usage windows.") }
        return .ok(windows: list, plan: planName(usage["subscription_type"] as? String, tier), asOf: now,
                   banked: banked(limits["cedar_ember"] as? [String: Any], now: now))
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
    /// The Claude account (config folder) shown on the usage row, by folder path; nil = the first one.
    public var claudeAccount: String?
    /// Names the user gave Claude accounts, by folder path (Windows AccountNames).
    public var accountNames: [String: String] = [:]
    public var refreshMinutes = 10
    /// Six launcher slots: app ids or nil.
    public var slots: [String?] = Array(repeating: nil, count: 6)
    /// Apps once auto-placed into a slot, so removing one never brings it back.
    public var autoPlaced: [String] = []
    /// Custom apps: paths to .app bundles.
    public var custom: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case claude, codex, claudeAccount, accountNames, refreshMinutes, slots, autoPlaced, custom }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = c.value(.claude, true)
        codex = c.value(.codex, true)
        claudeAccount = c.value(.claudeAccount, String?.none)
        accountNames = c.value(.accountNames, [:])
        refreshMinutes = min(60, max(5, c.value(.refreshMinutes, 10)))
        let saved: [String?] = c.value(.slots, [])
        slots = Array((saved + Array(repeating: nil, count: 6)).prefix(6))
        autoPlaced = c.value(.autoPlaced, [])
        custom = c.value(.custom, [])
    }

    /// What the user calls an account: their own name, or the folder's.
    public func name(of account: ClaudeAccount) -> String {
        accountNames[account.path].flatMap { $0.isEmpty ? nil : $0 } ?? account.folderName
    }

    /// The account the usage row shows: the chosen one while it still exists, else the first.
    public func shown(in accounts: [ClaudeAccount]) -> ClaudeAccount? {
        accounts.first { $0.path == claudeAccount } ?? accounts.first
    }

    /// An empty or whitespace name goes back to the folder's own name.
    public mutating func rename(_ account: ClaudeAccount, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accountNames[account.path] = trimmed.isEmpty || trimmed == account.folderName ? nil : String(trimmed.prefix(40))
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
