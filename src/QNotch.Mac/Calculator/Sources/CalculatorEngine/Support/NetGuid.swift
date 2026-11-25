import Foundation

/// .NET `Guid` semantics on Foundation's `UUID`: the "N" and "D" text forms, the strict parsers C# uses, and Guid ordering.
/// Documents name files and store identities with these forms, so Mac and Windows must spell them identically.
extension UUID {
    /// `Guid.Empty`.
    static let netEmpty = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    var isNetEmpty: Bool { self == UUID.netEmpty }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private var hexBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { raw in raw.flatMap { [UUID.hexDigits[Int($0 >> 4)], UUID.hexDigits[Int($0 & 15)]] } }
    }
    /// `Guid.ToString("N")`: 32 lowercase hex digits.
    var netN: String { String(decoding: hexBytes, as: UTF8.self) }
    /// `Guid.ToString("D")` (and `Guid.ToString()`): lowercase 8-4-4-4-12.
    var netD: String {
        var hex = hexBytes
        for position in [20, 16, 12, 8] { hex.insert(UInt8(ascii: "-"), at: position) }
        return String(decoding: hex, as: UTF8.self)
    }

    private static func parseHex(_ units: [UInt16]) -> UUID? {
        guard units.count == 32 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<32 {
            let c = units[i]
            let value: UInt16
            switch c {
            case 48...57: value = c - 48
            case 65...70: value = c - 55
            case 97...102: value = c - 87
            default: return nil
            }
            bytes[i / 2] = bytes[i / 2] << 4 | UInt8(value)
        }
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
    /// `Guid.TryParseExact(text, "N")`: exactly 32 hex digits of either case.
    static func netParseN(_ text: String) -> UUID? { parseHex(Array(text.utf16)) }
    /// `Guid.TryParseExact(text, "D")`, which is also all System.Text.Json accepts for a Guid: 8-4-4-4-12 hex digits of either case.
    static func netParseD(_ text: String) -> UUID? {
        let units = Array(text.utf16)
        guard units.count == 36, [8, 13, 18, 23].allSatisfy({ units[$0] == 0x2D }) else { return nil }
        return parseHex(units.enumerated().filter { ![8, 13, 18, 23].contains($0.offset) }.map(\.element))
    }
    /// `Guid.CompareTo`: .NET compares the fields as unsigned numbers in "D" order, which is the byte order of `uuid`.
    static func netCompare(_ a: UUID, _ b: UUID) -> Int {
        withUnsafeBytes(of: a.uuid) { x in
            withUnsafeBytes(of: b.uuid) { y in
                for i in 0..<16 where x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
                return 0
            }
        }
    }
    static func netLess(_ a: UUID, _ b: UUID) -> Bool { netCompare(a, b) < 0 }
    /// `Guid.NewGuid()`: a random version-4 identity.
    static func netNew() -> UUID { UUID() }
}
