import Foundation

/// System.Text.Json's default `JsonSerializer` behaviour for the document records: compact output with the default encoder,
/// properties in declaration order, and a reader with its strictness (no BOM, no comments, valid UTF-8 and surrogates,
/// exact property-name case, last duplicate wins, missing properties take default values, null only where the type allows it).
enum NetJSON {
    // MARK: Writing (each function returns an encoded JSON fragment)

    static func string(_ value: String?) -> String { value.map(NetJSONText.quote) ?? "null" }
    static func int(_ value: Int?) -> String { value.map { String($0) } ?? "null" }
    static func long(_ value: Int64) -> String { String(value) }
    static func bool(_ value: Bool) -> String { value ? "true" : "false" }
    static func guid(_ value: UUID) -> String { "\"" + value.netD + "\"" }
    static func date(_ value: DateTimeOffset) -> String { "\"" + value.jsonText + "\"" }
    static func array(_ items: [String]?) -> String { items.map { "[" + $0.joined(separator: ",") + "]" } ?? "null" }
    static func object(_ properties: [(String, String?)]) -> String {
        // A nil fragment is a property omitted by JsonIgnoreCondition.WhenWritingNull.
        "{" + properties.compactMap { name, value in value.map { "\"" + name + "\":" + $0 } }.joined(separator: ",") + "}"
    }
    static func bytes(_ fragment: String) -> [UInt8] { Array(fragment.utf8) }

    // MARK: Reading

    /// `JsonSerializer.Deserialize<T>(bytes)` for a record: nil when the document is the JSON literal null.
    static func parseObject(_ bytes: [UInt8]) throws -> Reader? {
        try validate(bytes)
        let node: JSONNode
        do { node = try JSONNode.parse(Data(bytes)) } catch { throw DocumentError.json("Invalid JSON: " + error.netMessage) }
        if node.isNull { return nil }
        return try Reader(node)
    }

    /// What JSONNode tolerates but System.Text.Json rejects: a byte-order mark, invalid UTF-8 and unpaired surrogate escapes.
    static func validate(_ bytes: [UInt8]) throws {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw DocumentError.json("'0xEF' is an invalid start of a value.") }
        if !bytes.allSatisfy({ $0 < 0x80 }) && String(bytes: bytes, encoding: .utf8) == nil {
            throw DocumentError.json("The input is not valid UTF-8.")
        }
        var inString = false, i = 0
        func hex(_ at: Int) -> UInt16? {
            guard at + 4 <= bytes.count else { return nil }
            return UInt16(String(decoding: bytes[at..<(at + 4)], as: UTF8.self), radix: 16)
        }
        while i < bytes.count {
            let b = bytes[i]
            if !inString { if b == UInt8(ascii: "\"") { inString = true }; i += 1; continue }
            if b == UInt8(ascii: "\"") { inString = false; i += 1; continue }
            if b == UInt8(ascii: "\\"), i + 1 < bytes.count {
                if bytes[i + 1] == UInt8(ascii: "u"), let unit = hex(i + 2) {
                    if (0xDC00...0xDFFF).contains(unit) { throw DocumentError.json("Unpaired low surrogate in JSON string.") }
                    if (0xD800...0xDBFF).contains(unit) {
                        guard i + 7 < bytes.count, bytes[i + 6] == UInt8(ascii: "\\"), bytes[i + 7] == UInt8(ascii: "u"),
                              let low = hex(i + 8), (0xDC00...0xDFFF).contains(low) else { throw DocumentError.json("Unpaired high surrogate in JSON string.") }
                        i += 12; continue
                    }
                    i += 6; continue
                }
                i += 2; continue
            }
            i += 1
        }
    }

    /// One JSON object read with the serializer's rules. Getters throw `DocumentError.json` for a wrong token type.
    struct Reader {
        let node: JSONNode
        init(_ node: JSONNode) throws {
            guard case .object = node else { throw DocumentError.json("The JSON value could not be converted to an object.") }
            self.node = node
        }
        private func value(_ name: String) -> JSONNode? { node.optionalProperty(name) }
        private static func mismatch(_ name: String) -> DocumentError { .json("The JSON value of '\(name)' could not be converted.") }

        func int(_ name: String) throws -> Int { try intOrNil(name, nullable: false) ?? 0 }
        func intOrNil(_ name: String) throws -> Int? { try intOrNil(name, nullable: true) }
        private func intOrNil(_ name: String, nullable: Bool) throws -> Int? {
            guard let v = value(name) else { return nil }
            if v.isNull { if nullable { return nil }; throw Reader.mismatch(name) }
            return try Reader.int(v, name)
        }
        static func int(_ v: JSONNode, _ name: String) throws -> Int {
            guard let text = v.numberText, let parsed = Int32(text) else { throw mismatch(name) }
            return Int(parsed)
        }
        func long(_ name: String) throws -> Int64 {
            guard let v = value(name) else { return 0 }
            guard let text = v.numberText, let parsed = Int64(text) else { throw Reader.mismatch(name) }
            return parsed
        }
        func bool(_ name: String) throws -> Bool {
            guard let v = value(name) else { return false }
            guard case .bool(let b) = v else { throw Reader.mismatch(name) }
            return b
        }
        func string(_ name: String) throws -> String? {
            guard let v = value(name) else { return nil }
            return try Reader.string(v, name)
        }
        static func string(_ v: JSONNode, _ name: String) throws -> String? {
            if v.isNull { return nil }
            guard case .string(let s) = v else { throw mismatch(name) }
            return s
        }
        func guid(_ name: String) throws -> UUID {
            guard let v = value(name) else { return .netEmpty }
            return try Reader.guid(v, name)
        }
        static func guid(_ v: JSONNode, _ name: String) throws -> UUID {
            guard case .string(let s) = v, let id = UUID.netParseD(s) else { throw mismatch(name) }
            return id
        }
        func date(_ name: String) throws -> DateTimeOffset {
            guard let v = value(name) else { return .minValue }
            guard case .string(let s) = v, let parsed = DateTimeOffset.parseJSON(s) else { throw Reader.mismatch(name) }
            return parsed
        }
        /// An array property: nil when missing or null.
        func array<T>(_ name: String, _ element: (JSONNode) throws -> T) throws -> [T]? {
            guard let v = value(name), !v.isNull else { return nil }
            guard case .array(let items) = v else { throw Reader.mismatch(name) }
            return try items.map(element)
        }
        /// A nested record: nil when missing or null.
        func object<T>(_ name: String, _ decode: (Reader) throws -> T) throws -> T? {
            guard let v = value(name), !v.isNull else { return nil }
            return try decode(try Reader(v))
        }
        /// An array element that is a record (null elements stay null, as in C#).
        static func element<T>(_ v: JSONNode, _ decode: (Reader) throws -> T) throws -> T? {
            if v.isNull { return nil }
            return try decode(try Reader(v))
        }
    }
}
