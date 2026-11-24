import Foundation

/// A parsed JSON document in the spirit of System.Text.Json's JsonDocument: objects keep their property
/// order (and duplicates), and numbers keep their source text so they can be read exactly.
/// Parsing follows JsonDocument's defaults: RFC 8259, no comments, no trailing commas, depth 64.
indirect enum JSONNode: Equatable {
    case object([(String, JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func == (a: JSONNode, b: JSONNode) -> Bool {
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

    enum Kind: String { case object = "Object", array = "Array", string = "String", number = "Number", bool = "Boolean", null = "Null" }
    var kind: Kind {
        switch self { case .object: return .object; case .array: return .array; case .string: return .string; case .number: return .number; case .bool: return .bool; case .null: return .null }
    }

    // MARK: Reading (JsonElement-style accessors; they throw CalcError.invalidData when the shape is wrong)

    /// JsonElement.GetProperty: the last property of that name (case-sensitive).
    func property(_ name: String) throws -> JSONNode {
        guard let value = optionalProperty(name) else { throw CalcError.invalidData("Missing JSON property " + name) }
        return value
    }
    /// JsonElement.TryGetProperty.
    func optionalProperty(_ name: String) -> JSONNode? {
        guard case .object(let properties) = self else { return nil }
        return properties.last(where: { $0.0 == name })?.1
    }
    subscript(_ name: String) -> JSONNode? { optionalProperty(name) }
    var properties: [(String, JSONNode)] { if case .object(let p) = self { return p }; return [] }
    var items: [JSONNode] { if case .array(let a) = self { return a }; return [] }
    func arrayItems() throws -> [JSONNode] { guard case .array(let a) = self else { throw CalcError.invalidData("Expected a JSON array") }; return a }
    func objectProperties() throws -> [(String, JSONNode)] { guard case .object(let p) = self else { throw CalcError.invalidData("Expected a JSON object") }; return p }
    /// JsonElement.GetString: a string, or nil for null.
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    func string() throws -> String { guard case .string(let s) = self else { throw CalcError.invalidData("Expected a JSON string") }; return s }
    func bool() throws -> Bool { guard case .bool(let b) = self else { throw CalcError.invalidData("Expected a JSON boolean") }; return b }
    var numberText: String? { if case .number(let n) = self { return n }; return nil }
    /// JsonElement.GetInt32 / GetInt64: an integral number in range (no fraction or exponent).
    func int() throws -> Int {
        guard case .number(let n) = self, let value = Int(n), value >= Int(Int32.min), value <= Int(Int32.max) else { throw CalcError.invalidData("Expected a 32-bit integer") }
        return value
    }
    func int64() throws -> Int64 {
        guard case .number(let n) = self, let value = Int64(n) else { throw CalcError.invalidData("Expected a 64-bit integer") }
        return value
    }
    func double() throws -> Double {
        guard case .number(let n) = self, let value = Double(n), value.isFinite else { throw CalcError.invalidData("Expected a number") }
        return value
    }
    var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: Parsing

    static func parse(_ data: Data, maxDepth: Int = 64) throws -> JSONNode {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) } // JsonDocument skips a UTF-8 BOM
        var parser = Parser(bytes: bytes, maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        if parser.position != bytes.count { throw CalcError.invalidData("Unexpected data after JSON value") }
        return value
    }
    static func parse(_ text: String, maxDepth: Int = 64) throws -> JSONNode { try parse(Data(text.utf8), maxDepth: maxDepth) }

    private struct Parser {
        let bytes: [UInt8]
        let maxDepth: Int
        var position = 0
        init(bytes: [UInt8], maxDepth: Int) { self.bytes = bytes; self.maxDepth = maxDepth }
        func fail(_ what: String = "Invalid JSON") -> CalcError { .invalidData(what) }
        mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }
        mutating func value(depth: Int) throws -> JSONNode {
            guard position < bytes.count else { throw fail() }
            switch bytes[position] {
            case UInt8(ascii: "{"):
                if depth >= maxDepth { throw fail("JSON depth limit exceeded") }
                position += 1; skipWhitespace()
                var properties: [(String, JSONNode)] = []
                if position < bytes.count && bytes[position] == UInt8(ascii: "}") { position += 1; return .object(properties) }
                while true {
                    skipWhitespace()
                    guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw fail() }
                    let key = try string()
                    skipWhitespace()
                    guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw fail() }
                    position += 1; skipWhitespace()
                    properties.append((key, try value(depth: depth + 1)))
                    skipWhitespace()
                    guard position < bytes.count else { throw fail() }
                    if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                    if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(properties) }
                    throw fail()
                }
            case UInt8(ascii: "["):
                if depth >= maxDepth { throw fail("JSON depth limit exceeded") }
                position += 1; skipWhitespace()
                var items: [JSONNode] = []
                if position < bytes.count && bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard position < bytes.count else { throw fail() }
                    if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                    if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
                    throw fail()
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }
        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard position + w.count <= bytes.count, Array(bytes[position..<(position + w.count)]) == w else { throw fail() }
            position += w.count
        }
        mutating func number() throws -> String {
            let start = position
            func digits() -> Int { let s = position; while position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 { position += 1 }; return position - s }
            if position < bytes.count && bytes[position] == UInt8(ascii: "-") { position += 1 }
            guard position < bytes.count else { throw fail() }
            if bytes[position] == UInt8(ascii: "0") { position += 1 } else if digits() == 0 { throw fail() }
            if position < bytes.count && bytes[position] == UInt8(ascii: ".") { position += 1; if digits() == 0 { throw fail() } }
            if position < bytes.count && (bytes[position] | 0x20) == UInt8(ascii: "e") {
                position += 1
                if position < bytes.count && (bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-")) { position += 1 }
                if digits() == 0 { throw fail() }
            }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }
        mutating func string() throws -> String {
            position += 1
            var units: [UInt16] = []
            var run = position
            func flush(_ end: Int) { if end > run { units.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).utf16) } }
            while true {
                guard position < bytes.count else { throw fail() }
                let b = bytes[position]
                if b == UInt8(ascii: "\"") { flush(position); position += 1; return String(units: units) }
                if b < 0x20 { throw fail() }
                if b == UInt8(ascii: "\\") {
                    flush(position); position += 1
                    guard position < bytes.count else { throw fail() }
                    let e = bytes[position]; position += 1
                    switch e {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard position + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[position..<(position + 4)], as: UTF8.self), radix: 16) else { throw fail() }
                        units.append(v); position += 4
                    default: throw fail()
                    }
                    run = position
                    continue
                }
                position += 1
            }
        }
    }
}
