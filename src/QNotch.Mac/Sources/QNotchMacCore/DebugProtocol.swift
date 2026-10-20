import CoreGraphics
import Foundation

/// The debug channel's wire format (spec/diagnostics.md, Debug channel): UTF-8 JSON, one object per
/// line each way, `id` echoed unchanged (left out when the request had none), requests over 64 KB
/// refused. Pure, so the app, the `debug` verb and tests share it.
public enum DebugProtocol {
    public static let maxRequest = 64 * 1024
    public static let commands = ["ping", "state", "open", "close", "select-tab", "settings", "onboarding", "outline",
                                  "snapshot", "press", "type", "key", "hotkey", "game-mode", "quit"]

    public struct Request {
        /// The request's `id` as decoded (NSNull for `null`); nil when it had none.
        public let id: Any?
        public let command: String
        public let args: [String: Any]
    }

    public struct Failure: Error {
        public let id: Any?
        public let message: String
    }

    public static func parse(_ line: Data) -> Result<Request, Failure> {
        guard line.count <= maxRequest else { return .failure(Failure(id: nil, message: tooLarge)) }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .failure(Failure(id: nil, message: "The request is not a JSON object."))
        }
        let id = object["id"]
        guard let command = object["cmd"] as? String, !command.isEmpty else { return .failure(Failure(id: id, message: "The request has no cmd.")) }
        guard let raw = object["args"], !(raw is NSNull) else { return .success(Request(id: id, command: command, args: [:])) }
        guard let args = raw as? [String: Any] else { return .failure(Failure(id: id, message: "args must be an object.")) }
        return .success(Request(id: id, command: command, args: args))
    }

    public static let tooLarge = "The request is larger than 64 KB."

    /// `{"id":…,"ok":true,"result":{…}}` and a newline.
    public static func success(id: Any?, result: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: result, options: options)) ?? Data("{}".utf8)
        return line(id: id, ok: true, field: "result", body)
    }

    /// `{"id":…,"ok":false,"error":"…"}` and a newline.
    public static func failure(id: Any?, error: String) -> Data {
        line(id: id, ok: false, field: "error", fragment(error) ?? Data("\"\"".utf8))
    }

    private static let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]

    private static func fragment(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: options)
    }

    private static func line(id: Any?, ok: Bool, field: String, _ body: Data) -> Data {
        var out = Data("{".utf8)
        if let id, let encoded = fragment(id) { out += Data("\"id\":".utf8) + encoded + Data(",".utf8) }
        out += Data("\"ok\":\(ok),\"\(field)\":".utf8) + body + Data("}\n".utf8)
        return out
    }

    // MARK: Geometry

    /// An AppKit screen rectangle (origin at the primary display's bottom left, y up) in the shared
    /// convention: points with the origin at the primary display's top left, y down.
    public static func topLeft(_ rect: CGRect, primary: CGRect) -> CGRect {
        CGRect(x: rect.minX - primary.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func frame(_ rect: CGRect) -> [String: Any] {
        func number(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        return ["x": number(rect.minX), "y": number(rect.minY), "width": number(rect.width), "height": number(rect.height)]
    }
}

/// Splits a byte stream into request lines. A line longer than 64 KB yields `tooLarge` once and is
/// dropped up to its newline, so the requests after it still parse.
public struct DebugLineBuffer {
    public enum Event: Equatable { case line(Data), tooLarge }
    private var pending = Data()
    private var discarding = false
    public let limit: Int

    public init(limit: Int = DebugProtocol.maxRequest) { self.limit = limit }

    public mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        var rest = data[...]
        while !rest.isEmpty {
            guard let newline = rest.firstIndex(of: 0x0A) else {
                if !discarding { pending += rest }
                if !discarding, pending.count > limit {
                    events.append(.tooLarge)
                    pending = Data()
                    discarding = true
                }
                break
            }
            if discarding {
                discarding = false
            } else {
                pending += rest[..<newline]
                if pending.count > limit { events.append(.tooLarge) } else if pending.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) {
                    events.append(.line(pending))
                }
            }
            pending = Data()
            rest = rest[rest.index(after: newline)...]
        }
        return events
    }
}

/// The `key` command's names: what to put in the synthesized key events.
public enum DebugKey {
    public struct Stroke: Equatable {
        public let keyCode: UInt16
        public let characters: String
        public init(keyCode: UInt16, characters: String) { self.keyCode = keyCode; self.characters = characters }
    }

    /// `Escape`, `Return`, `Tab`, `Space`, `Up`, `Down`, `Left`, `Right`, `Backspace` (the Mac's Delete key),
    /// `Delete` (forward delete) or one character (its US key code, 0 when it has none).
    public static func stroke(_ name: String) -> Stroke? {
        let named: [String: (UInt16, Int)] = ["escape": (0x35, 0x1B), "return": (0x24, 0x0D), "tab": (0x30, 0x09), "space": (0x31, 0x20),
                                              "up": (0x7E, 0xF700), "down": (0x7D, 0xF701), "left": (0x7B, 0xF702), "right": (0x7C, 0xF703),
                                              "backspace": (0x33, 0x7F), "delete": (0x75, 0xF728)]
        if name.count > 1 {
            guard let (code, scalar) = named[name.lowercased()], let unicode = UnicodeScalar(scalar) else { return nil }
            return Stroke(keyCode: code, characters: String(Character(unicode)))
        }
        guard let character = name.first else { return nil }
        if character == " " { return stroke("space") }
        let upper = String(character).uppercased()
        let code = KeyCombo.names.first { $0.value == upper }?.key ?? KeyCombo.glyphs.first { $0.value == String(character) }?.key
        return Stroke(keyCode: UInt16(code ?? 0), characters: String(character))
    }

    /// `ctrl`, `alt`, `shift`, `cmd`, as a list or one string separated by commas, pluses or spaces.
    public static func modifiers(_ value: Any?) -> Set<String>? {
        let parts: [String]
        switch value {
        case nil, is NSNull: return []
        case let text as String: parts = text.split(whereSeparator: { ",+ ".contains($0) }).map(String.init)
        case let list as [Any]: guard let strings = list as? [String] else { return nil }; parts = strings
        default: return nil
        }
        let aliases = ["ctrl": "ctrl", "control": "ctrl", "alt": "alt", "opt": "alt", "option": "alt", "shift": "shift", "cmd": "cmd", "command": "cmd"]
        var result: Set<String> = []
        for part in parts {
            guard let name = aliases[part.lowercased()] else { return nil }
            result.insert(name)
        }
        return result
    }
}

// MARK: - Command line

/// `QNotch debug <cmd> [--<arg> <value>…]`: one request to a running instance's debug channel.
public enum DebugCLI {
    public static let help = """
        QNotch debug <command> [--<arg> <value>…] [--data-dir PATH]

        Drives a QNotch started with --debug-control through debug.sock in its data root
        (--data-dir, else QNOTCH_MAC_DATA_DIR, else the default). Prints the result as JSON.

          ping                              Platform, version, pid and data root
          state                             Panel, tab, keyboard, edit mode, pin, game mode, modules, windows
          open [--tab ID]                   Opens the panel with the keyboard, optionally on a tab
          close                             Closes the panel
          select-tab --id ID                Opens the panel if needed and selects the tab
          settings [--section ID] [--close true]
          onboarding [--close true]         Opens the welcome tour as Settings does, or closes it
          outline [--window panel|pill|settings|onboarding]
          snapshot --path /abs/x.png [--window …]   Writes the PNG and its outline (x.txt)
          press --id ID                     Clicks, flips or selects the visible, enabled control
          type --text TEXT [--id ID]        Focuses the field (or keeps the focus) and inserts the text
          key --name NAME [--modifiers ctrl,alt,shift,cmd]
                                            Escape, Return, Tab, Space, Up, Down, Left, Right, Backspace, Delete or one character
          hotkey --action toggle|search|game-mode
          game-mode --mode auto|on|off
          quit

        Values: true/false become booleans and numbers numbers, except for text, id, path, name,
        tab and section, which stay strings. A flag without a value is true.

        Exit codes: 0 ok, 1 the command failed, 3 no instance with the debug channel open, 4 bad usage.
        """

    public struct UsageError: Error, Equatable { public let message: String }

    public struct Invocation {
        public var command: String
        public var args: [String: Any]
        public var dataDirectory: String?
    }

    /// Keys whose values are always sent as strings ("42" typed stays text).
    public static let stringKeys: Set<String> = ["text", "id", "path", "name", "tab", "section", "window", "mode", "action", "modifiers"]

    public static func parse(_ args: [String]) throws -> Invocation {
        guard let command = args.first, !command.hasPrefix("-") else { throw UsageError(message: "A command is required. Try QNotch debug --help.") }
        guard DebugProtocol.commands.contains(command) else { throw UsageError(message: "Unknown command \(command). Try QNotch debug --help.") }
        var invocation = Invocation(command: command, args: [:])
        var index = 1
        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("--"), arg.count > 2 else { throw UsageError(message: "Unexpected argument '\(arg)'. Arguments are --name value.") }
            let key = String(arg.dropFirst(2))
            let value: String?
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") { value = args[index + 1]; index += 2 } else { value = nil; index += 1 }
            if key == "data-dir" {
                guard let value else { throw UsageError(message: "--data-dir needs a path.") }
                invocation.dataDirectory = value
            } else {
                invocation.args[key] = value.map { Self.value($0, key: key) } ?? true
            }
        }
        return invocation
    }

    /// true/false, then integers and decimals, else the string itself.
    public static func value(_ raw: String, key: String) -> Any {
        guard !stringKeys.contains(key) else { return raw }
        switch raw {
        case "true": return true
        case "false": return false
        default:
            if raw.range(of: "^-?[0-9]+$", options: .regularExpression) != nil, let number = Int(raw) { return number }
            if raw.range(of: "^-?[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, let number = Double(raw) { return number }
            return raw
        }
    }

    public static func request(_ invocation: Invocation) -> Data {
        let object: [String: Any] = ["id": 1, "cmd": invocation.command, "args": invocation.args]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Exit code and what to print for a reply line.
    public static func outcome(_ reply: Data) -> (code: Int32, stdout: String?, stderr: String?) {
        let line = reply.split(separator: 0x0A).first ?? reply[...]
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return (1, nil, "QNotch sent an unreadable reply.") }
        func json(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
        guard object["ok"] as? Bool == true else { return (1, nil, json(["error": object["error"] as? String ?? "The command failed."])) }
        return (0, json(object["result"] as? [String: Any] ?? [:]), nil)
    }
}
