import Foundation

// MARK: - Hook files

/// QNotch's entries in an agent's hooks file (Windows HookFiles): Claude Code `settings.json` or
/// Codex `hooks.json`. Ours are recognized by their command (a QNotch executable followed by
/// `agent`), so Disconnect removes exactly those and leaves the user's hooks and key order alone.
public struct AgentHookFile {
    public enum Kind { case claude, codex }
    public enum Status: Equatable { case notInstalled, connected, otherCopy(String), error(String) }

    public let kind: Kind
    /// The executable the hooks run (this app's binary).
    public let executable: String

    public init(kind: Kind, executable: String) {
        self.kind = kind
        self.executable = executable
    }

    public var events: [String] {
        switch kind {
        case .claude: return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
        case .codex: return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
        }
    }

    /// Hooks run through /bin/sh on macOS: a shell-quoted path and the verb.
    public var command: String { "\(Self.shellQuote(executable)) agent" + (kind == .codex ? " codex" : "") }

    /// Single quotes: sh expands nothing inside them, unlike `$`, backticks and backslashes in double quotes.
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The executable path inside one of our commands, in either quoting style.
    public static func executable(in command: String) -> String {
        var quoted = command.trimmingCharacters(in: .whitespaces)
        for verb in [" agent codex", " agent"] where quoted.hasSuffix(verb) { quoted = String(quoted.dropLast(verb.count)); break }
        if quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") {
            return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        return quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Also recognizes the double-quoted form older builds installed, so Disconnect removes those too.
    public func isOurs(_ command: String?) -> Bool {
        guard let command = command?.trimmingCharacters(in: .whitespaces), command.lowercased().contains("qnotch") else { return false }
        let verb = kind == .codex ? " agent codex" : " agent"
        guard command.hasSuffix(verb) else { return false }
        let quoted = command.dropLast(verb.count)
        return quoted.hasSuffix("'") || quoted.hasSuffix("\"")
    }

    /// Async wherever the agent allows it, so a tool call never waits on QNotch. Codex runs
    /// SessionEnd in line with a short timeout. Tool events need a matcher in Claude Code.
    private func group(_ event: String) -> OrderedJSON {
        let hook: OrderedJSON = kind == .codex && event == "SessionEnd"
            ? .object([("type", .string("command")), ("command", .string(command)), ("timeout", .number("3"))])
            : .object([("type", .string("command")), ("command", .string(command)), ("async", .bool(true))])
        var pairs: [(String, OrderedJSON)] = [("hooks", .array([hook]))]
        if kind == .claude, ["PreToolUse", "PostToolUse"].contains(event) { pairs.insert(("matcher", .string("*")), at: 0) }
        return .object(pairs)
    }

    private func commands(in root: OrderedJSON) -> [String] {
        (root["hooks"]?.objectPairs ?? []).flatMap { $0.1.arrayValue ?? [] }
            .flatMap { $0["hooks"]?.arrayValue ?? [] }
            .compactMap { $0["command"]?.stringValue }
            .filter(isOurs)
    }

    public func status(of text: String?) -> Status {
        do {
            let commands = commands(in: try Self.root(text))
            guard !commands.isEmpty else { return .notInstalled }
            if let other = commands.first(where: { $0 != command }) { return .otherCopy(Self.executable(in: other)) }
            // Some events missing (removed by hand): Connect puts them back.
            return commands.count >= events.count ? .connected : .notInstalled
        } catch { return .error("\(error)") }
    }

    /// Replaces any QNotch hooks with ones that point at this executable.
    public func connect(_ text: String?) throws -> String {
        var root = try Self.root(text)
        var hooks = removingOurs(root["hooks"] ?? .object([]))
        for event in events {
            var groups = hooks[event]?.arrayValue ?? []
            groups.append(group(event))
            hooks[event] = .array(groups)
        }
        root["hooks"] = hooks
        return root.text() + "\n"
    }

    public func disconnect(_ text: String?) throws -> String {
        var root = try Self.root(text)
        if let hooks = root["hooks"] { root["hooks"] = removingOurs(hooks) }
        return root.text() + "\n"
    }

    /// Drops our entries, then any group or event they leave empty.
    private func removingOurs(_ hooks: OrderedJSON) -> OrderedJSON {
        guard let pairs = hooks.objectPairs else { return hooks }
        var result: [(String, OrderedJSON)] = []
        for (event, value) in pairs {
            guard let groups = value.arrayValue else { result.append((event, value)); continue }
            var kept: [OrderedJSON] = []
            for group in groups {
                guard let list = group["hooks"]?.arrayValue else { kept.append(group); continue }
                let remaining = list.filter { !isOurs($0["command"]?.stringValue) }
                guard !remaining.isEmpty else { continue }
                var copy = group
                copy["hooks"] = .array(remaining)
                kept.append(copy)
            }
            if !kept.isEmpty { result.append((event, .array(kept))) }
        }
        return .object(result)
    }

    private static func root(_ text: String?) throws -> OrderedJSON {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .object([]) }
        let value = try OrderedJSON.parse(text)
        guard case .object = value else { throw OrderedJSON.ParseError(description: "The file is not a JSON object.") }
        return value
    }
}

// MARK: - Hook line

/// What `QNotch agent [codex]` sends: the few fields the notch needs, in Claude Code's vocabulary.
public struct AgentEvent: Codable, Equatable {
    public var agent: String
    public var event: String
    public var session: String
    public var cwd: String
    public var transcript: String?
    public var message: String?
    public var type: String?
    public var tool: String?
    public var pid: Int32?
    public var link: String?
    /// Hook time (seconds since 1970); async hooks can arrive out of order.
    public var at: Double

    public init(agent: String, event: String, session: String, cwd: String, transcript: String? = nil, message: String? = nil,
                type: String? = nil, tool: String? = nil, pid: Int32? = nil, link: String? = nil, at: Double) {
        self.agent = agent; self.event = event; self.session = session; self.cwd = cwd; self.transcript = transcript
        self.message = message; self.type = type; self.tool = tool; self.pid = pid; self.link = link; self.at = at
    }

    /// Builds the event from a hook's stdin JSON. Codex events are translated to Claude Code's words.
    public static func from(hookInput data: Data, codex: Bool, pid: Int32?, link: String?, at: Double) -> AgentEvent? {
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func string(_ object: [String: Any]?, _ key: String) -> String? { object?[key] as? String }
        var event = string(input, "hook_event_name") ?? ""
        let tool = string(input, "tool_name")
        var message = string(input, "message")
        // AskUserQuestion is how Claude asks you something mid-task: its first question is the best line to show.
        if tool == "AskUserQuestion", let questions = (input["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]], let first = questions.first {
            message = string(first, "question") ?? message
        }
        var type = string(input, "notification_type")
        if codex, event == "PermissionRequest" {
            (event, type, message) = ("Notification", "permission_prompt", "Codex needs your permission to use \(tool ?? "a tool")")
        } else if codex, event == "Interrupt" {
            (event, type) = ("Notification", "idle_prompt")
        }
        if let text = message, text.count > 200 { message = String(text.prefix(200)) + "…" }
        return AgentEvent(agent: codex ? "codex" : "claude", event: event, session: string(input, "session_id") ?? "", cwd: string(input, "cwd") ?? "",
                          transcript: codex ? nil : string(input, "transcript_path"), message: message, type: type, tool: tool, pid: pid, link: link, at: at)
    }

    /// Only the kinds of link the hook itself makes are kept (any local process could write to the socket).
    public static func isValidLink(_ link: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        if link.hasPrefix("claude://code/continue?session=local_") {
            let id = link.dropFirst("claude://code/continue?session=local_".count)
            return !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy(allowed.contains)
        }
        if link.hasPrefix("codex://threads/") { return UUID(uuidString: String(link.dropFirst("codex://threads/".count))) != nil }
        return false
    }
}

// MARK: - Sessions

public enum AgentStatus: Int, Codable { case needsYou = 0, working = 1, done = 2, ready = 3 }

public struct AgentSession: Equatable, Identifiable {
    public let id: String
    public var agent = "claude"
    public var cwd = ""
    public var title = ""
    public var status = AgentStatus.ready
    public var message = ""
    public var since: Date
    public var at: Double = 0
    public var pid: Int32?
    public var link: String?
    public var transcript: String?
    /// The tool a permission prompt or question waits on, so other tools' events leave "needs you" alone.
    public var waitingTool: String?
    /// T3 Code owns this row's status; hooks may still add its transcript and process.
    public var t3Thread: String?
    public var t3Run: String?
    public var t3Session: String?

    public init(id: String, since: Date) { self.id = id; self.since = since }

    /// The project folder name; what the pill and untitled rows show.
    public var name: String {
        if cwd.isEmpty { return agent == "codex" ? "Codex" : "Claude" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
    public var displayTitle: String { title.isEmpty ? name : title }
}

/// The live session list and its rules (Windows AgentsModule.Apply).
public struct AgentBoard: Equatable {
    public enum Alert: Equatable { case needsYou(AgentSession), done(AgentSession) }

    public private(set) var sessions: [AgentSession] = []
    private var ended: [String] = []
    /// Dismissed T3 threads, by the run that was showing.
    private var t3Dismissed: [String: String] = [:]
    public init() {}

    /// Applies one hook event; returns an alert when a session starts needing you or finishes a turn.
    @discardableResult
    public mutating func apply(_ event: AgentEvent, now: Date = Date()) -> Alert? {
        guard !event.session.isEmpty else { return nil }
        var index = sessions.firstIndex { $0.id == event.session || $0.t3Session == event.session }
        if let found = index, sessions[found].t3Thread != nil {
            // T3 can keep a turn running across provider restarts; hook Stop/SessionEnd cannot end it.
            if let transcript = event.transcript, !transcript.isEmpty { sessions[found].transcript = transcript }
            if let pid = event.pid, pid > 0 { sessions[found].pid = pid }
            return nil
        }
        if event.event == "SessionEnd" {
            // Async hooks race: a Stop that lands after SessionEnd must not bring the row back.
            ended.append(event.session)
            if ended.count > 100 { ended.removeFirst(ended.count - 100) }
            if let index { sessions.remove(at: index) }
            return nil
        }
        if event.event == "SessionStart" { ended.removeAll { $0 == event.session } } // a resumed session keeps its id
        else if ended.contains(event.session) { return nil }
        if index == nil {
            sessions.append(AgentSession(id: event.session, since: now))
            index = sessions.count - 1
        } else if event.at < sessions[index!].at { return nil }
        var s = sessions[index!]
        s.at = event.at
        if !event.cwd.isEmpty { s.cwd = event.cwd }
        if ["claude", "codex"].contains(event.agent) { s.agent = event.agent }
        if let transcript = event.transcript, !transcript.isEmpty { s.transcript = transcript }
        if let link = event.link, AgentEvent.isValidLink(link) { s.link = link }
        if let pid = event.pid, pid > 0 { s.pid = pid }
        // While it waits for you, other tools' events (subagents share the session) must not clear the wait.
        let waiting = s.status == .needsYou && s.waitingTool != nil && event.tool != nil && event.tool != s.waitingTool
        var next: AgentStatus?
        switch event.event {
        case "SessionStart": next = .ready
        case "UserPromptSubmit": next = .working
        case "PostToolUse": next = waiting ? nil : .working
        case "PreToolUse": next = event.tool == "AskUserQuestion" ? .needsYou : waiting ? nil : .working
        case "Notification":
            switch event.type {
            case "permission_prompt", "elicitation_dialog": next = .needsYou
            case nil where event.message?.localizedCaseInsensitiveContains("permission") == true: next = .needsYou
            // Waiting for input with no Stop before it: the turn was interrupted (Esc).
            case "idle_prompt" where s.status == .working: next = .done
            default: next = nil
            }
        case "Stop": next = .done
        default: next = nil
        }
        let was = s.status
        if let next {
            if next != s.status { s.since = now }
            s.status = next
            s.message = next == .needsYou ? (event.message ?? "Waiting for you") : ""
            s.waitingTool = next != .needsYou ? nil : event.event == "PreToolUse" ? event.tool : Self.permissionTool(s.message)
        }
        sessions[index!] = s
        sort()
        guard s.status != was else { return nil }
        if s.status == .needsYou { return .needsYou(s) }
        // Only a finished turn: Done after an interrupt is something the user just did.
        if s.status == .done, event.event == "Stop", was == .working { return .done(s) }
        return nil
    }

    /// "Claude needs your permission to use Bash" names the tool it waits on.
    static func permissionTool(_ message: String) -> String? {
        guard let range = message.range(of: "permission to use ") else { return nil }
        let tool = message[range.upperBound...]
        return tool.isEmpty || tool.contains(" ") ? nil : String(tool)
    }

    public mutating func remove(_ id: String) {
        if let session = sessions.first(where: { $0.id == id }), let thread = session.t3Thread, let run = session.t3Run {
            t3Dismissed[thread] = run
            if t3Dismissed.count > 100, let first = t3Dismissed.keys.first { t3Dismissed[first] = nil }
        }
        sessions.removeAll { $0.id == id }
    }

    /// Drops the hook sessions of an agent process that exited without a SessionEnd (terminal
    /// closed); T3 rows stay, since T3 owns their status.
    @discardableResult
    public mutating func processEnded(_ pid: Int32) -> Bool {
        let before = sessions.count
        sessions.removeAll { $0.pid == pid && $0.t3Thread == nil }
        for index in sessions.indices where sessions[index].pid == pid { sessions[index].pid = nil }
        return sessions.count != before
    }

    /// Merges T3 Code's live runs (by native session id, so hooks never double the count). Live work
    /// is restored at startup without importing the history of finished threads.
    public mutating func applyT3(_ list: [T3Session], now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        let threads = Set(list.map(\.thread))
        sessions.removeAll { $0.t3Thread.map { !threads.contains($0) } ?? false }
        t3Dismissed = t3Dismissed.filter { threads.contains($0.key) }
        for t in list {
            var index = sessions.firstIndex { $0.t3Thread == t.thread } ?? sessions.firstIndex { $0.id == t.session }
            if index == nil {
                if t.status == .done || t3Dismissed[t.thread] == t.run { continue }
                sessions.append(AgentSession(id: t.session, since: t.since))
                index = sessions.count - 1
            }
            var s = sessions[index!]
            let fresh = s.t3Thread == nil && s.t3Run == nil && s.at == 0
            let was = s.status
            if fresh || s.t3Run != t.run || s.status != t.status { s.since = t.status == .needsYou ? now : t.since }
            s.t3Thread = t.thread; s.t3Run = t.run; s.t3Session = t.session
            s.title = t.title; s.cwd = t.cwd; s.agent = t.agent; s.status = t.status; s.message = t.message
            s.link = t.link; s.waitingTool = nil
            sessions[index!] = s
            // A handoff can leave a hook row behind for the same session.
            let keep = s.id
            sessions.removeAll { $0.id != keep && $0.id == t.session }
            if (fresh || was != s.status) && s.status == .needsYou { alerts.append(.needsYou(s)) }
            else if !fresh && was == .working && s.status == .done { alerts.append(.done(s)) }
        }
        sort()
        return alerts
    }

    public mutating func setTitle(_ title: String, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].title != title else { return }
        sessions[index].title = title
    }

    /// Needs you first, then working, then the rest; newest change first within each.
    private mutating func sort() {
        sessions.sort { ($0.status.rawValue, -$0.since.timeIntervalSince1970) < ($1.status.rawValue, -$1.since.timeIntervalSince1970) }
    }

    /// "api needs you", "2 need you", "3 working", or nil while nothing runs.
    public var pillText: String? {
        let waiting = sessions.filter { $0.status == .needsYou }
        let working = sessions.filter { $0.status == .working }.count
        if waiting.count == 1 { return "\(waiting[0].name) needs you" }
        if waiting.count > 1 { return "\(waiting.count) need you" }
        return working > 0 ? "\(working) working" : nil
    }
    public var needsYou: Bool { sessions.contains { $0.status == .needsYou } }
}

/// Settings, Agents (agents.json).
public struct AgentsSettings: Codable, Equatable {
    public var soundNeedsYou = true
    public var soundDone = true
    /// What each session's tokens would cost at API list prices, beside its token count.
    public var showCost = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case soundNeedsYou, soundDone, showCost }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soundNeedsYou = c.value(.soundNeedsYou, true)
        soundDone = c.value(.soundDone, true)
        showCost = c.value(.showCost, true)
    }
}
