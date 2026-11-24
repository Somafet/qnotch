import Foundation

/// Numeric IP literal only: no resolver, socket, interface or OS address state (C# IpAddressValue).
struct IpAddressValue: Hashable, CustomStringConvertible {
    let bitWidth: Int
    let number: BigInt
    let text: String
    var description: String { text }
    init(_ number: BigInt, _ width: Int) throws {
        if (width != 32 && width != 128) || number.sign < 0 || number >= BigInt.one << width { throw CalcError.arithmetic("Invalid address magnitude") }
        self.number = number; bitWidth = width
        if width == 32 {
            text = (0..<4).map { ((number >> (24 - 8 * $0)) & BigInt(255)).description }.joined(separator: ".")
        } else {
            let groups = (0..<8).map { ((number >> (112 - 16 * $0)) & BigInt(65535)).intValue! }
            // The first longest run of two or more zero groups becomes "::".
            var best = -1, length = 1, i = 0
            while i < groups.count {
                if groups[i] != 0 { i += 1; continue }
                let start = i; while i < groups.count && groups[i] == 0 { i += 1 }
                if i - start > length { best = start; length = i - start }
            }
            func join(_ values: ArraySlice<Int>) -> String { values.map { String($0, radix: 16) }.joined(separator: ":") }
            text = best < 0 ? join(groups[...]) : join(groups[..<best]) + "::" + join(groups[(best + length)...])
        }
    }
    static func parse(_ text: String) throws -> IpAddressValue {
        let u = text.units
        if u.count < 2 || u.count > 64 || u.contains(where: { !NetChar.isAsciiHexDigit($0) && $0 != 0x3A && $0 != 0x2E }) {
            throw CalcError.format("Expected an unscoped numeric IPv4/IPv6 address")
        }
        if !u.contains(0x3A) {
            let parts = text.netSplit(".")
            if parts.count != 4 { throw CalcError.format("IPv4 requires four decimal octets") }
            var value = BigInt.zero
            for part in parts {
                let p = part.units
                guard p.count >= 1 && p.count <= 3 && p.allSatisfy(NetChar.isAsciiDigit) && !(p.count > 1 && p[0] == 0x30), let octet = Int(part), octet <= 255 else {
                    throw CalcError.format("IPv4 octets must be 0–255 without leading zeroes")
                }
                value = value * BigInt(256) + BigInt(octet)
            }
            return try IpAddressValue(value, 32)
        }
        if u.contains(0x2E) { _ = try parse(text.netSubstring(text.netLastIndexOf(":") + 1)) } // Keep embedded IPv4 equally strict.
        guard let bytes = IpAddressValue.ipv6Bytes(u) else { throw CalcError.format("Invalid IPv6 literal") }
        return try IpAddressValue(bytes.reduce(BigInt.zero) { $0 * BigInt(256) + BigInt(Int($1)) }, 128)
    }
    /// IPAddress.TryParse for the IPv6 text that reaches it (hex digits, ':' and '.', the embedded IPv4 already
    /// checked): one to four hex digits per group, at most one "::" standing for one or more zero groups, and an
    /// optional dotted quad in the last 32 bits.
    private static func ipv6Bytes(_ u: [UInt16]) -> [UInt8]? {
        let text = u.string
        let halves = text.netSplit("::")
        if halves.count > 2 { return nil }
        func groups(_ part: String, allowIPv4: Bool) -> [Int]? {
            if part.isEmpty { return [] }
            var result: [Int] = []
            let pieces = part.netSplit(":")
            for (index, piece) in pieces.enumerated() {
                let p = piece.units
                if index == pieces.count - 1 && allowIPv4 && p.contains(0x2E) {
                    let octets = piece.netSplit(".")
                    guard octets.count == 4 else { return nil }
                    var values: [Int] = []
                    for octet in octets {
                        guard let v = Int(octet), (1...3).contains(octet.netLength), octet.utf16.allSatisfy(NetChar.isAsciiDigit), v <= 255 else { return nil }
                        values.append(v)
                    }
                    result.append(values[0] << 8 | values[1]); result.append(values[2] << 8 | values[3])
                    continue
                }
                guard (1...4).contains(p.count), p.allSatisfy(NetChar.isAsciiHexDigit), let value = Int(piece, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }
        let values: [Int]
        if halves.count == 1 {
            guard let all = groups(halves[0], allowIPv4: true), all.count == 8 else { return nil }
            values = all
        } else {
            guard let head = groups(halves[0], allowIPv4: false), let tail = groups(halves[1], allowIPv4: true), head.count + tail.count <= 7 else { return nil }
            values = head + [Int](repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        return values.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
    }
}
