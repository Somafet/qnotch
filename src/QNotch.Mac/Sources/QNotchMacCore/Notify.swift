import Foundation

// Wire format shared with QNotch for Windows: one JSON object per request (a socket line, an
// HTTP body or the `notify` command), camelCase keys matched case-insensitively, numbers
// optionally sent as strings.

public enum NotifyLevel: String, Codable, CaseIterable { case info, success, warning, error }

public struct NotifyError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A validated action button.
public struct NotifyActionSpec: Equatable, Codable {
    public var id: String
    public var label: String
    public var url: String?
    public var focusPid: Int32?
    /// Only answers a waiting request (no link, no window to bring forward).
    public var answersOnly: Bool { url == nil && focusPid == nil }
}

/// A validated request.
public enum NotifyCommand: Equatable {
    case dismiss(id: String)
    case notify(NotifyPost)
}

public struct NotifyPost: Equatable {
    public var id: String
    public var app: String
    public var title: String
    public var body: String
    public var level: NotifyLevel
    public var icon: String?
    public var ttl: Double?
    public var wait: Bool
    public var timeout: Double?
    public var actions: [NotifyActionSpec]
}

public enum NotifyRules {
    public static let maxMessage = 64 * 1024
    public static let maxItems = 500, maxTitle = 80, maxBody = 300, maxApp = 40, maxLabel = 24, maxID = 64, maxActions = 3
    public static let schemes: Set<String> = ["http", "https", "vscode", "vscode-insiders", "cursor", "claude"]
    /// Icon names usable instead of an image path, mapped to SF Symbols.
    public static let glyphs: [String: String] = [
        "bell": "bell.fill", "info": "info.circle.fill", "success": "checkmark.circle.fill", "check": "checkmark",
        "warning": "exclamationmark.triangle.fill", "error": "xmark.octagon.fill", "chat": "bubble.left.fill",
        "code": "chevron.left.forwardslash.chevron.right", "link": "link", "clock": "clock.fill", "download": "arrow.down.circle.fill",
        "bolt": "bolt.fill", "person": "person.fill", "folder": "folder.fill", "globe": "globe", "mail": "envelope.fill",
        "play": "play.fill", "build": "hammer.fill"
    ]

    public static func levelSymbol(_ level: NotifyLevel) -> String {
        switch level {
        case .info: return "bell.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    /// Trimmed, capped (the last kept character becomes "…") and free of control characters.
    public static func clean(_ value: String?, _ max: Int, multiline: Bool = false) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "" }
        var result = ""
        for character in value {
            if result.count == max { result.removeLast(); result.append("…"); break }
            if character == "\r" { continue }
            // "\r\n" is one Character in Swift.
            if character.isNewline { result.append(multiline ? "\n" : " "); continue }
            result.append(character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Parses and validates one request. `makeID` supplies an id when the sender gives none.
    public static func parse(_ data: Data, makeID: () -> String = { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased() }) throws -> NotifyCommand {
        guard data.count <= maxMessage else { throw NotifyError("The request is larger than 64 KB.") }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw NotifyError("The request is not a JSON object.") }
        let fields = Fields(object)
        let op = fields.string("op")?.lowercased()
        if op == "dismiss" {
            let id = clean(fields.string("id"), maxID)
            guard !id.isEmpty else { throw NotifyError("dismiss needs an id.") }
            return .dismiss(id: id)
        }
        if let op, !op.isEmpty, op != "notify" { throw NotifyError("Unknown op '\(op)'.") }
        let title = clean(fields.string("title"), maxTitle)
        guard !title.isEmpty else { throw NotifyError("title is required.") }
        let rawActions = fields.array("actions") ?? []
        guard rawActions.count <= maxActions else { throw NotifyError("At most \(maxActions) actions.") }
        var level = NotifyLevel.info
        if let text = fields.string("level")?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            guard let parsed = NotifyLevel(rawValue: text.lowercased()) else { throw NotifyError("level must be info, success, warning or error.") }
            level = parsed
        }
        let wait = fields.bool("wait")
        var actions: [NotifyActionSpec] = []
        for raw in rawActions {
            let action = Fields(raw as? [String: Any] ?? [:])
            let label = clean(action.string("label"), maxLabel)
            guard !label.isEmpty else { throw NotifyError("Every action needs a label.") }
            var url: String?
            var pid: Int32?
            if let text = action.string("url")?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(), schemes.contains(scheme) else {
                    throw NotifyError("Action '\(label)': only \(schemes.sorted().joined(separator: ", ")) links are allowed.")
                }
                url = parsed.absoluteString
            } else if let number = action.number("focusPid"), number > 0, number < Double(Int32.max) {
                pid = Int32(number)
            } else if !wait {
                throw NotifyError("Action '\(label)' needs a url or a focusPid, or the request must wait.")
            }
            let id = clean(action.string("id"), maxID)
            actions.append(NotifyActionSpec(id: id.isEmpty ? label : id, label: label, url: url, focusPid: pid))
        }
        let id = clean(fields.string("id"), maxID)
        let app = clean(fields.string("app"), maxApp)
        let icon = fields.string("icon")?.trimmingCharacters(in: .whitespaces)
        let timeout = fields.number("timeout").map { min(86_400, max(0, $0)) }
        return .notify(NotifyPost(id: id.isEmpty ? makeID() : id, app: app.isEmpty ? "QNotch" : app, title: title,
                                  body: clean(fields.string("body"), maxBody, multiline: true), level: level,
                                  icon: icon?.isEmpty == false ? icon : nil, ttl: fields.number("ttl").map { min(60, max(0, $0)) },
                                  wait: wait, timeout: timeout == 0 ? nil : timeout, actions: actions))
    }

    /// One reply line: `{"ok":true,"id":...}` or `{"error":...}`.
    public static func reply(ok id: String, result: String? = nil, action: String? = nil) -> Data {
        var object: [String: Any] = ["ok": true, "id": id]
        if let result { object["result"] = result }
        if let action { object["action"] = action }
        return line(object)
    }
    public static func reply(error: String) -> Data { line(["ok": false, "error": error]) }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Case-insensitive access; numbers and booleans may arrive as strings.
    private struct Fields {
        let values: [String: Any]
        init(_ object: [String: Any]) {
            values = Dictionary(object.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        func string(_ key: String) -> String? {
            switch values[key.lowercased()] {
            case let value as String: return value
            case let value as NSNumber: return value.stringValue
            default: return nil
            }
        }
        func number(_ key: String) -> Double? {
            switch values[key.lowercased()] {
            case let value as NSNumber: return value.doubleValue
            case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
            default: return nil
            }
        }
        func bool(_ key: String) -> Bool {
            switch values[key.lowercased()] {
            case let value as NSNumber: return value.boolValue
            case let value as String: return ["true", "1", "yes"].contains(value.lowercased())
            default: return false
            }
        }
        func array(_ key: String) -> [Any]? { values[key.lowercased()] as? [Any] }
    }
}

// MARK: - Command line

/// `QNotch notify …`, argument for argument the Windows `QNotch.exe notify`.
public enum NotifyCLI {
    public static let help = """
        QNotch notify [title] [body] [options]

          -t, --title TEXT      Title (required unless --json, --stdin or --dismiss)
          -b, --body TEXT       Description
          -a, --app NAME        Sender name shown with the notification
          -i, --icon VALUE      Image path, app path (its icon is used), or a glyph name (bell, info, check, warning, error, chat, code, ...)
          -l, --level LEVEL     info (default), success, warning, error
              --id ID           Stable id: posting it again replaces the notification
              --ttl SECONDS     Toast time; 0 shows no toast
              --url URL         Adds a button that opens the link (--url-label TEXT, default "Open")
              --focus           Adds a button that brings the calling terminal or app forward (--focus-label TEXT, default "Show")
              --focus-pid PID   Same, for the app of that process (or of its nearest parent app)
              --action ID=TEXT  Adds an answer button and waits; the clicked id is printed. Repeatable (3 buttons at most)
              --wait            Wait until the notification is answered or dismissed
              --timeout SECONDS Give up waiting after this long
              --dismiss ID      Remove a notification
              --json JSON       Send this payload as is
              --stdin           Read the JSON payload from standard input

        Exit codes: 0 sent or answered, 1 dismissed, 2 timed out, 3 QNotch not running, 4 error.
        """

    public struct UsageError: Error, Equatable { public let message: String }

    /// The request line to send. `parentPid` backs `--focus`; `fileExists` resolves `--icon` paths.
    public static func payload(_ args: [String], parentPid: Int32, readStdin: () -> String = { "" },
                               resolvePath: (String) -> String? = { _ in nil }) throws -> Data {
        var title: String?, body: String?, app: String?, icon: String?, level: String?, id: String?, dismiss: String?, raw: String?
        var url: String?, urlLabel: String?, focusLabel: String?, ttl: String?, timeout: String?
        var focusPid: Int32?
        var wait = false
        var answers: [(String, String)] = []
        var index = 0
        func next(_ option: String) throws -> String {
            index += 1
            guard index < args.count else { throw UsageError(message: "\(option) needs a value.") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-t", "--title": title = try next(arg)
            case "-b", "--body": body = try next(arg)
            case "-a", "--app": app = try next(arg)
            case "-i", "--icon": let value = try next(arg); icon = resolvePath(value) ?? value
            case "-l", "--level": level = try next(arg)
            case "--id": id = try next(arg)
            case "--ttl": ttl = try next(arg)
            case "--timeout": timeout = try next(arg)
            case "--url": url = try next(arg)
            case "--url-label": urlLabel = try next(arg)
            case "--focus": focusPid = parentPid
            case "--focus-label": focusLabel = try next(arg)
            case "--focus-pid":
                guard let pid = Int32(try next(arg)) else { throw UsageError(message: "--focus-pid needs a process id.") }
                focusPid = pid
            case "--action":
                let parts = try next(arg).split(separator: "=", maxSplits: 1).map(String.init)
                answers.append((parts.first ?? "", parts.count > 1 ? parts[1] : parts.first ?? ""))
            case "--wait": wait = true
            case "--dismiss": dismiss = try next(arg)
            case "--json": raw = try next(arg)
            case "--stdin": raw = readStdin()
            default:
                if arg.hasPrefix("-") { throw UsageError(message: "Unknown option \(arg). Try QNotch notify --help.") }
                if title == nil { title = arg } else if body == nil { body = arg } else { throw UsageError(message: "Unexpected argument '\(arg)'.") }
            }
            index += 1
        }
        if let raw {
            return Data((raw.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        }
        var object: [String: Any] = [:]
        if let dismiss {
            object = ["op": "dismiss", "id": dismiss]
        } else {
            guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw UsageError(message: "A title is required. Try QNotch notify --help.") }
            object["title"] = title
            if let body { object["body"] = body }
            if let app { object["app"] = app }
            if let icon { object["icon"] = icon }
            if let level { object["level"] = level }
            if let id { object["id"] = id }
            if let ttl { object["ttl"] = ttl }
            if let timeout { object["timeout"] = timeout }
            if wait || !answers.isEmpty { object["wait"] = true }
            var actions: [[String: Any]] = answers.map { ["id": $0.0, "label": $0.1] }
            if let url { actions.append(["label": urlLabel ?? "Open", "url": url]) }
            if let focusPid { actions.append(["label": focusLabel ?? "Show", "focusPid": focusPid]) }
            object["actions"] = actions
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Exit code and what to print for a reply line.
    public static func outcome(_ reply: Data) -> (code: Int32, stdout: String?, stderr: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return (4, nil, "QNotch sent an unreadable reply.") }
        guard object["ok"] as? Bool == true else { return (4, nil, object["error"] as? String ?? "QNotch rejected the request.") }
        switch object["result"] as? String {
        case "clicked": return (0, object["action"] as? String, nil)
        case "dismissed": return (1, nil, nil)
        case "timeout": return (2, nil, nil)
        default: return (0, nil, nil)
        }
    }
}

// MARK: - Local HTTP

/// A deliberately small HTTP/1.1 parser for the loopback endpoint: one request per connection.
public enum LocalHTTP {
    public static let maxHead = 16 * 1024

    public struct Request: Equatable {
        public var method: String
        public var path: String
        public var query: [String: String]
        public var headers: [String: String]
        public var contentLength: Int
    }

    public enum Failure: Error, Equatable {
        case status(Int, String)
    }

    /// Parses the head (everything before the blank line) and applies the security rules:
    /// loopback Host only (DNS rebinding), no Origin (web pages), a bearer token, a sized body.
    public static func parse(head: String, port: UInt16, token: String) throws -> Request {
        var lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw Failure.status(400, "Bad request.") }
        lines.removeFirst()
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw Failure.status(400, "Bad request.") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.status(400, "Bad header.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Duplicate framing headers are a request-smuggling vector.
            if ["content-length", "transfer-encoding", "host"].contains(name), headers[name] != nil { throw Failure.status(400, "Duplicate \(name).") }
            headers[name] = value
        }
        if headers["origin"] != nil { throw Failure.status(403, "Requests from web pages are not accepted.") }
        let allowedHosts = ["127.0.0.1", "localhost"].flatMap { ["\($0)", "\($0):\(port)"] }
        guard let host = headers["host"]?.lowercased(), allowedHosts.contains(host) else { throw Failure.status(403, "Only 127.0.0.1 is accepted.") }
        guard headers["transfer-encoding"] == nil else { throw Failure.status(411, "Send a Content-Length.") }
        let presented = headers["authorization"].flatMap { $0.lowercased().hasPrefix("bearer ") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil } ?? ""
        guard !token.isEmpty, constantTimeEqual(presented, token) else { throw Failure.status(401, "Missing or wrong token.") }
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0 else { throw Failure.status(400, "Bad Content-Length.") }
            length = value
        }
        guard length <= NotifyRules.maxMessage else { throw Failure.status(413, "The request is larger than 64 KB.") }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: components?.path ?? target, query: query, headers: headers, contentLength: length)
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    public static func response(status: Int, body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      408: "Request Timeout", 411: "Length Required", 413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Settings

public struct NotificationSettings: Codable, Equatable {
    public static let toastChoices = [0, 4, 6, 10, 15, 30]
    public static let retentionChoices = [1, 3, 7, 14, 30]
    public var toastSeconds = 6
    public var retentionDays = 7
    public var openOnError = true
    public var sound = false
    /// Manual presentation mute; history, unread counts and action replies remain active.
    public var manuallyMuted = false
    public var quietDuringCalls = true
    public var httpEnabled = true
    public var httpPort = 47821
    public var mutedApps: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case toastSeconds, retentionDays, openOnError, sound, manuallyMuted, quietDuringCalls, httpEnabled, httpPort, mutedApps }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        toastSeconds = min(60, max(0, c.value(.toastSeconds, d.toastSeconds)))
        retentionDays = min(30, max(1, c.value(.retentionDays, d.retentionDays)))
        openOnError = c.value(.openOnError, d.openOnError)
        sound = c.value(.sound, d.sound)
        manuallyMuted = c.value(.manuallyMuted, d.manuallyMuted)
        quietDuringCalls = c.value(.quietDuringCalls, d.quietDuringCalls)
        httpEnabled = c.value(.httpEnabled, d.httpEnabled)
        let port = c.value(.httpPort, d.httpPort)
        httpPort = (1024...65535).contains(port) ? port : d.httpPort
        mutedApps = c.value(.mutedApps, d.mutedApps)
    }

    public func isMuted(_ app: String) -> Bool { mutedApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame } }
}
