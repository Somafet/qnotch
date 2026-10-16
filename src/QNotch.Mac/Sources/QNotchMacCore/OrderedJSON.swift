import Foundation

/// A JSON value that keeps object key order and number spelling, so editing someone's settings file
/// changes only what QNotch adds or removes. Parsing tolerates // and /* */ comments and trailing
/// commas (as Claude Code and Codex do); output uses two-space indentation.
public indirect enum OrderedJSON: Equatable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        get { if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }; return nil }
        set {
            guard case .object(var pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[index].1 = newValue } else { pairs.remove(at: index) }
            } else if let newValue { pairs.append((key, newValue)) }
            self = .object(pairs)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var arrayValue: [OrderedJSON]? { if case .array(let value) = self { return value }; return nil }
    public var objectPairs: [(String, OrderedJSON)]? { if case .object(let value) = self { return value }; return nil }

    // MARK: Parsing

    public struct ParseError: Error, CustomStringConvertible { public let description: String }

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(Array(text.unicodeScalars))
        parser.skip()
        let value = try parser.value()
        parser.skip()
        guard parser.atEnd else { throw ParseError(description: "Unexpected text after the JSON value.") }
        return value
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }
        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func skip() {
            while let c = peek {
                if c == " " || c == "\n" || c == "\r" || c == "\t" || c == "\u{FEFF}" { i += 1; continue }
                if c == "/", i + 1 < s.count, s[i + 1] == "/" { while let d = peek, d != "\n" { i += 1 }; continue }
                if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i = min(s.count, i + 2)
                    continue
                }
                break
            }
        }

        mutating func expect(_ c: Unicode.Scalar) throws {
            skip()
            guard peek == c else { throw ParseError(description: "Expected '\(c)' at \(i).") }
            i += 1
        }

        mutating func value() throws -> OrderedJSON {
            skip()
            guard let c = peek else { throw ParseError(description: "Unexpected end of JSON.") }
            switch c {
            case "{":
                i += 1
                var pairs: [(String, OrderedJSON)] = []
                skip()
                if peek == "}" { i += 1; return .object(pairs) }
                while true {
                    skip()
                    if peek == "}" { i += 1; return .object(pairs) } // trailing comma
                    guard peek == "\"" else { throw ParseError(description: "Expected a key at \(i).") }
                    let key = try string()
                    try expect(":")
                    pairs.append((key, try value()))
                    skip()
                    if peek == "," { i += 1; continue }
                    try expect("}")
                    return .object(pairs)
                }
            case "[":
                i += 1
                var items: [OrderedJSON] = []
                skip()
                if peek == "]" { i += 1; return .array(items) }
                while true {
                    skip()
                    if peek == "]" { i += 1; return .array(items) }
                    items.append(try value())
                    skip()
                    if peek == "," { i += 1; continue }
                    try expect("]")
                    return .array(items)
                }
            case "\"": return .string(try string())
            case "t": try word("true"); return .bool(true)
            case "f": try word("false"); return .bool(false)
            case "n": try word("null"); return .null
            default:
                let start = i
                while let d = peek, "+-0123456789.eE".unicodeScalars.contains(d) { i += 1 }
                guard i > start else { throw ParseError(description: "Unexpected character at \(i).") }
                return .number(String(String.UnicodeScalarView(s[start..<i])))
            }
        }

        mutating func word(_ w: String) throws {
            for c in w.unicodeScalars {
                guard peek == c else { throw ParseError(description: "Unexpected word at \(i).") }
                i += 1
            }
        }

        mutating func string() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while let c = peek {
                i += 1
                if c == "\"" { return String(out) }
                guard c == "\\" else { out.append(c); continue }
                guard let e = peek else { break }
                i += 1
                switch e {
                case "n": out.append("\n"); case "t": out.append("\t"); case "r": out.append("\r")
                case "b": out.append("\u{8}"); case "f": out.append("\u{C}")
                case "u":
                    guard i + 4 <= s.count, let code = UInt32(String(String.UnicodeScalarView(s[i..<i + 4])), radix: 16) else { throw ParseError(description: "Bad escape.") }
                    i += 4
                    if (0xD800...0xDBFF).contains(code), i + 6 <= s.count, s[i] == "\\", s[i + 1] == "u",
                       let low = UInt32(String(String.UnicodeScalarView(s[(i + 2)..<(i + 6)])), radix: 16), (0xDC00...0xDFFF).contains(low) {
                        i += 6
                        out.append(Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) ?? "?")
                    } else { out.append(Unicode.Scalar(code) ?? "?") }
                default: out.append(e)
                }
            }
            throw ParseError(description: "Unterminated string.")
        }
    }

    // MARK: Output

    public func text(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { inner + Self.quote($0.0) + ": " + $0.1.text(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.text(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .string(let value): return Self.quote(value)
        case .number(let raw): return raw
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quote(_ value: String) -> String {
        var out = "\""
        for c in value.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }
}
