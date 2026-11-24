import Foundation

/// Exact integer with an optional two's-complement word profile (C# IntegerValue). Formatting never changes its value.
struct IntegerValue: Hashable {
    static let maximumBits = 4096
    let value: BigInt
    let width: Int?
    let signed: Bool
    let radix: Int
    let fullText: String
    let copyTextValue: String
    /// The word's bit pattern: the value masked to its width.
    var bits: BigInt { width.map { value & ((BigInt.one << $0) - .one) } ?? value }
    var display: String { get throws { fullText.netLength <= 128 ? fullText : fullText.netSubstring(0, 64) + "…" + fullText.netSubstring(fullText.netLength - 32) } }
    var copyText: String { get throws { copyTextValue } }

    init(_ value: BigInt, _ radix: Int = 10, _ width: Int? = nil, _ signed: Bool = false) throws {
        if ![2, 8, 10, 16].contains(radix) { throw CalcError.arithmetic("Unsupported integer base") }
        if let width, width < 1 || width > IntegerValue.maximumBits { throw CalcError.arithmetic("Integer width must be 1–4096 bits") }
        self.width = width; self.signed = width != nil && signed; self.radix = radix
        var value = value
        if let w = width {
            value = value & ((BigInt.one << w) - .one)
            if self.signed && value >= BigInt.one << (w - 1) { value = value - (BigInt.one << w) }
        }
        if value.magnitude.bitLength > IntegerValue.maximumBits { throw CalcError.arithmetic("Integer precision limit exceeded") }
        self.value = value
        let bits = width.map { value & ((BigInt.one << $0) - .one) } ?? value
        fullText = IntegerValue.format(radix == 10 ? value : width == nil ? value : bits, radix, width)
        let target = radix == 2 ? "bin" : radix == 8 ? "oct" : radix == 16 ? "hex" : "dec"
        if let width { copyTextValue = "(" + IntegerValue.format(bits, 16, nil) + " in " + target + " " + (self.signed ? "i" : "u") + String(width) + ")" }
        else { copyTextValue = radix == 10 ? "(" + IntegerValue.format(value, 16, nil) + " in dec)" : fullText }
    }
    /// Prefixed digits; a word width pads with leading zeroes to its full digit count.
    private static func format(_ value: BigInt, _ radix: Int, _ width: Int?) -> String {
        if radix == 10 { return value.description }
        let bitsPerDigit = radix == 16 ? 4 : radix == 8 ? 3 : 1
        var digits = value.magnitude.toString(radix: radix, uppercase: true)
        if let w = width { digits = digits.netPadLeft((w + bitsPerDigit - 1) / bitsPerDigit, "0") }
        return (value.sign < 0 ? "-" : "") + (radix == 16 ? "0x" : radix == 8 ? "0o" : "0b") + digits
    }
}
