import Foundation

/// Tokens and what they would cost at API list prices (Windows AgentUsage). `unpriced`: some
/// tokens came from a model the price table does not know.
public struct AgentUsage: Equatable {
    public var tokens: Int64 = 0
    public var cost: Double = 0
    public var unpriced = false
    public init(tokens: Int64 = 0, cost: Double = 0, unpriced: Bool = false) { self.tokens = tokens; self.cost = cost; self.unpriced = unpriced }

    public static func + (a: AgentUsage, b: AgentUsage) -> AgentUsage { AgentUsage(tokens: a.tokens + b.tokens, cost: a.cost + b.cost, unpriced: a.unpriced || b.unpriced) }
    public static func - (a: AgentUsage, b: AgentUsage) -> AgentUsage { AgentUsage(tokens: a.tokens - b.tokens, cost: a.cost - b.cost, unpriced: a.unpriced) }

    /// "1.9M tokens · $2.14", empty when there is nothing to show.
    public var text: String { tokens == 0 ? "" : "\(Self.tokens(tokens)) tokens · \(costText)" }

    public static func tokens(_ n: Int64) -> String {
        if n >= 10_000_000 { return "\(n / 1_000_000)M" }
        if n >= 1_000_000 {
            let value = (Double(n) / 1_000_000 * 10).rounded(.down) / 10
            return (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + "M"
        }
        if n >= 1_000 { return "\(n / 1_000)K" }
        return "\(n)"
    }

    public var costText: String {
        if cost == 0 && unpriced { return "price unknown" }
        return cost >= 100 ? String(format: "$%.0f", cost) : String(format: "$%.2f", cost)
    }
}

/// API list prices in USD per million tokens. Cache writes cost 1.25x input (5-minute cache) or 2x
/// (1-hour cache); fast mode 2x everything. First matching prefix wins. Same table as Windows.
public enum AgentPrices {
    static let table: [(prefix: String, input: Double, output: Double, cacheRead: Double)] = [
        ("claude-fable-5-1", 10, 50, 0.25),
        ("claude-mythos-5-1", 10, 50, 0.25),
        ("claude-fable-5", 10, 50, 1),
        ("claude-mythos-5", 10, 50, 1),
        ("claude-opus-5-5", 4, 20, 0.20),
        ("claude-opus-5", 5, 25, 0.50),
        ("claude-opus-4-5", 5, 25, 0.50),
        ("claude-opus-4-6", 5, 25, 0.50),
        ("claude-opus-4-7", 5, 25, 0.50),
        ("claude-opus-4-8", 5, 25, 0.50),
        ("claude-opus-4", 15, 75, 1.50),
        ("claude-sonnet-5", 2, 10, 0.20),
        ("claude-sonnet-4", 3, 15, 0.30),
        ("claude-3-7-sonnet", 3, 15, 0.30),
        ("claude-haiku-4", 1, 5, 0.10),
        ("claude-3-5-haiku", 0.80, 4, 0.08)
    ]

    public static func cost(model: String, input: Int64, write5m: Int64, write1h: Int64, read: Int64, output: Int64, fast: Bool) -> Double? {
        guard let price = table.first(where: { model.hasPrefix($0.prefix) }) else { return nil }
        let usd = (Double(input) * price.input + Double(write5m) * price.input * 1.25 + Double(write1h) * price.input * 2
                   + Double(read) * price.cacheRead + Double(output) * price.output) / 1_000_000
        return fast ? usd * 2 : usd
    }
}

/// Complete lines appended to a file since the last read. A line still being written waits;
/// a file that shrank was rewritten.
public final class LineTail {
    public private(set) var offset: UInt64 = 0
    public private(set) var readSucceeded = false
    public init() {}

    /// Returns nil when the file shrank (the caller decides whether to start over).
    public func read(_ url: URL, maxBytes: Int = 64 << 20) -> [Data]? {
        readSucceeded = false
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        readSucceeded = end >= offset && end - offset <= UInt64(maxBytes)
        if end < offset { return nil }
        guard end > offset else { return [] }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: min(Int(end - offset), maxBytes)) else { readSucceeded = false; return [] }
        guard let last = data.lastIndex(of: 0x0A) else { return [] }
        offset += UInt64(last - data.startIndex + 1)
        return data[data.startIndex..<last].split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    public func reset() { offset = 0 }
}

/// One session's token usage from the transcripts Claude Code writes (the session's .jsonl and its
/// subagents' files), picking up where the last read stopped. One read at a time per session.
public final class TranscriptUsage {
    private var tails: [String: LineTail] = [:]
    /// Per file: the reply counted last. Each content block of a reply is its own line with the same
    /// message id; some versions grow output_tokens line by line, so the last line counts.
    private var last: [String: (id: String?, day: String, usage: AgentUsage)] = [:]
    public private(set) var days: [String: AgentUsage] = [:]
    private var aiTitle: String?
    private var customTitle: String?
    public private(set) var bytesRead = 0
    public private(set) var readComplete = false

    public init() {}

    /// A rename (by the user or the Claude app) wins over the generated title.
    public var title: String? { customTitle ?? aiTitle }
    public var today: AgentUsage { days[Self.dayKey(Date())] ?? AgentUsage() }

    public static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func read(_ transcript: URL) {
        bytesRead = 0
        readComplete = true
        readFile(transcript, main: true)
        let subagents = transcript.deletingPathExtension().appendingPathComponent("subagents")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: subagents.path)) ?? []).sorted() where name.hasSuffix(".jsonl") {
            readFile(subagents.appendingPathComponent(name), main: false)
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func readFile(_ url: URL, main: Bool) {
        let tail = tails[url.path] ?? LineTail()
        tails[url.path] = tail
        let before = tail.offset
        // Rewritten: leave the counts alone rather than count it twice.
        guard let lines = tail.read(url) else { readComplete = false; return }
        if !tail.readSucceeded { readComplete = false }
        bytesRead += Int(tail.offset - before)
        for line in lines {
            if line.range(of: Data(#""type":"assistant""#.utf8)) != nil { add(line, file: url.path) }
            else if main, line.range(of: Data(#""type":"ai-title""#.utf8)) != nil { aiTitle = title(line, "aiTitle") ?? aiTitle }
            else if main, line.range(of: Data(#""type":"custom-title""#.utf8)) != nil { customTitle = title(line, "customTitle") ?? customTitle }
        }
    }

    private func title(_ line: Data, _ key: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func add(_ line: Data, file: String) {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = root["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return }
        func number(_ object: [String: Any]?, _ key: String) -> Int64 { (object?[key] as? NSNumber)?.int64Value ?? 0 }
        let input = number(usage, "input_tokens"), read = number(usage, "cache_read_input_tokens"), output = number(usage, "output_tokens")
        let write = number(usage, "cache_creation_input_tokens")
        let write1h = number(usage["cache_creation"] as? [String: Any], "ephemeral_1h_input_tokens")
        let tokens = input + write + read + output
        guard tokens > 0 else { return }
        let model = message["model"] as? String ?? ""
        let cost = AgentPrices.cost(model: model, input: input, write5m: max(0, write - write1h), write1h: write1h, read: read, output: output,
                                    fast: usage["speed"] as? String == "fast")
        let entry = AgentUsage(tokens: tokens, cost: cost ?? 0, unpriced: cost == nil)
        let id = message["id"] as? String
        var day: String
        let key = file + ":" + (id ?? UUID().uuidString)
        if let previous = last[key], id != nil, id == previous.id {
            day = previous.day
            days[day] = (days[day] ?? AgentUsage()) - previous.usage // a later line of the same reply replaces it
        } else {
            day = (root["timestamp"] as? String).flatMap { Self.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }.map(Self.dayKey) ?? Self.dayKey(Date())
        }
        last[key] = (id, day, entry)
        days[day] = (days[day] ?? AgentUsage()) + entry
    }
}

/// Thread names from Codex's session_index.jsonl ({"id","thread_name"}, newest last).
public final class CodexTitles {
    private let tail = LineTail()
    public private(set) var names: [String: String] = [:]
    public init() {}

    public func read(_ url: URL) -> [String: String] {
        guard let lines = tail.read(url) else {
            tail.reset(); names.removeAll()
            return read(url)
        }
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = object["id"] as? String,
                  let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}

// MARK: - T3 Code

/// T3 Code's durable run state (Windows T3Sessions), read from its own database.
public struct T3Session: Equatable {
    public var thread: String
    public var session: String
    public var run: String
    public var agent: String
    public var title: String
    public var cwd: String
    public var status: AgentStatus
    public var since: Date
    public var message: String
    public var link: String?

    public static let query = """
        SELECT t.thread_id, coalesce(json_extract(p.payload_json, '$.nativeThreadRef.nativeId'), ''),
               r.run_id, coalesce(json_extract(p.payload_json, '$.nativeThreadRef.driver'), r.provider), t.title,
               coalesce(json_extract(t.payload_json, '$.worktreePath'), project.workspace_root, ''),
               r.status, coalesce(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at),
               coalesce((SELECT q.kind FROM orchestration_v2_projection_runtime_requests q
                         JOIN orchestration_v2_projection_nodes n ON n.node_id = q.node_id
                         WHERE q.thread_id = t.thread_id AND n.run_id = r.run_id AND q.status = 'pending'
                         ORDER BY q.created_at DESC LIMIT 1), '')
        FROM orchestration_v2_projection_threads t
        JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
             AND r.ordinal = (SELECT max(latest.ordinal) FROM orchestration_v2_projection_runs latest
                              WHERE latest.thread_id = t.thread_id AND latest.status <> 'queued')
        LEFT JOIN orchestration_v2_projection_provider_threads p ON p.provider_thread_id = r.provider_thread_id
        LEFT JOIN projection_projects project ON project.project_id = t.project_id
        WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
        """

    public static let titlesQuery = """
        SELECT json_extract(p.payload_json, '$.nativeThreadRef.nativeId'), t.title
        FROM orchestration_v2_projection_provider_threads p
        JOIN orchestration_v2_projection_threads t USING (thread_id)
        WHERE t.deleted_at IS NULL AND t.title <> ''
        """

    public static func from(row: [String], environment: String) -> T3Session? {
        guard row.count >= 9 else { return nil }
        let active = ["preparing", "starting", "running", "waiting"].contains(row[6])
        let status: AgentStatus = active ? (row[8].isEmpty ? .working : .needsYou) : .done
        let driver = row[3].lowercased()
        let agent = driver.hasPrefix("codex") ? "codex" : driver.hasPrefix("claude") ? "claude" : row[3]
        let since = parseDate(row[7]) ?? Date()
        let message = status != .needsYou ? "" : row[8] == "user_input" ? "T3 Code is waiting for your answer" : "T3 Code needs your permission"
        return T3Session(thread: row[0], session: row[1].isEmpty ? "t3:" + row[0] : row[1], run: row[2], agent: agent,
                         title: row[4].trimmingCharacters(in: .whitespacesAndNewlines), cwd: row[5], status: status, since: since,
                         message: message, link: threadLink(environment: environment, thread: row[0]))
    }

    /// Only locally constructed links (two UUIDs) are ever opened.
    public static func threadLink(environment: String, thread: String) -> String? {
        guard UUID(uuidString: environment) != nil, UUID(uuidString: thread) != nil else { return nil }
        return "t3code://threads/\(environment)/\(thread)"
    }

    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}
