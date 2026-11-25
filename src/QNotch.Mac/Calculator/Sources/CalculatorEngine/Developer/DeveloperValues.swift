import Foundation

enum ColourPresentation: Hashable { case hex, rgb, hsl }

/// Exact sRGB channels in 0…1 with derived exact HSL (C# ColourValue). Presentation never changes the stored channels.
struct ColourValue: Hashable {
    let red: Rational
    let green: Rational
    let blue: Rational
    let alpha: Rational
    let presentation: ColourPresentation
    let hue: Rational
    let saturation: Rational
    let lightness: Rational
    var achromatic: Bool { saturation.numerator.isZero }
    var hexQuantized: Bool { get throws { try [red, green, blue, alpha].contains { !(try $0 * Rational(255)).denominator.isOne } } }
    var hex: String {
        "#" + [red, green, blue].map(ColourValue.byteText).joined() + (alpha == .one ? "" : ColourValue.byteText(alpha))
    }
    var display: String {
        get throws {
            switch presentation {
            case .rgb:
                return (alpha == .one ? "rgb(" : "rgba(") + (try [red, green, blue].map { try ColourValue.shown($0 * Rational(255)) }).joined(separator: ", ") +
                    (alpha == .one ? "" : ", " + (try ColourValue.shown(alpha))) + ")"
            case .hsl:
                return (alpha == .one ? "hsl(" : "hsla(") + (try ColourValue.shown(hue)) + ", " + (try ColourValue.shown(saturation * Rational(100))) + "%, " +
                    (try ColourValue.shown(lightness * Rational(100))) + "%" + (alpha == .one ? "" : ", " + (try ColourValue.shown(alpha))) + ")"
            case .hex:
                return (try hexQuantized ? "≈ " : "") + hex
            }
        }
    }
    var copyText: String {
        get throws {
            let source = "rgb(" + (try [red, green, blue].map { DeveloperSource.fraction(try $0 * Rational(255)) }).joined(separator: ",") + "," + DeveloperSource.fraction(alpha) + ")"
            return presentation == .hsl ? "hsl(" + source + ")" : presentation == .hex ? "colourhex(" + source + ")" : source
        }
    }
    var details: String {
        get throws {
            "sRGB encoded channels (not linear light): R=" + red.description + ", G=" + green.description + ", B=" + blue.description + "; alpha=" + alpha.description +
                "\nHSL: H=" + hue.description + " degrees, S=" + saturation.description + ", L=" + lightness.description + (achromatic ? "; achromatic hue rendered as zero by convention" : "") +
                "\n8-bit hex: " + hex + (try hexQuantized ? "; nearest-byte presentation, exact stored channels retained" : "; exact byte channels") +
                "\nFour-decimal presentation does not replace stored fractions; no profile, gamut mapping or alpha compositing inferred"
        }
    }
    init(_ red: Rational, _ green: Rational, _ blue: Rational, _ alpha: Rational, _ presentation: ColourPresentation) throws {
        for v in [red, green, blue, alpha] where v.numerator < 0 || v.numerator > v.denominator { throw CalcError.arithmetic("Colour channels and alpha must be in range") }
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.presentation = presentation
        // MaxBy/MinBy keep the first extreme; equal channels make the choice irrelevant to the hue branch below.
        var max = red, min = red
        for v in [green, blue] { if v > max { max = v }; if v < min { min = v } }
        let delta = try max - min
        lightness = try (max + min) / Rational(2)
        if delta.numerator.isZero { hue = .zero; saturation = .zero }
        else {
            saturation = try delta / (Rational.one - (try Rational(2) * lightness - Rational.one).abs)
            let sector = max == red ? try (green - blue) / delta : max == green ? try (blue - red) / delta + Rational(2) : try (red - green) / delta + Rational(4)
            hue = try DeveloperSource.mod(sector * Rational(60), 360)
        }
    }
    func with(presentation style: ColourPresentation) throws -> ColourValue { try ColourValue(red, green, blue, alpha, style) }
    /// The nearest byte, halfway upward: (n·510 + d) / 2d, as int.ToString("X2").
    private static func byteText(_ value: Rational) -> String {
        let byte = (value.numerator * BigInt(510) + value.denominator) / (BigInt(2) * value.denominator)
        return String(byte.intValue!, radix: 16, uppercase: true).netPadLeft(2, "0")
    }
    private static func shown(_ value: Rational) throws -> String { try NumericValue(value).with { $0.displayDecimalPlaces = 4 }.display }
}

/// Unix mode bits 0000–7777 octal (C# PermissionValue). Conversion only; no filesystem state is read or changed.
struct PermissionValue: Hashable {
    let bits: Int
    let showOctal: Bool
    let symbolic: String
    var octal: String { String(bits, radix: 8).netPadLeft(3, "0") }
    var display: String { get throws { showOctal ? octal : symbolic } }
    var copyText: String { get throws { showOctal ? "modeoctal(chmod(\"" + octal + "\"))" : "chmod(\"" + octal + "\")" } }
    var details: String {
        // C# concatenates bools as "True"/"False".
        func flag(_ mask: Int) -> String { bits & mask != 0 ? "True" : "False" }
        let s = symbolic
        return "Unix permission bits: 0o" + octal + " (" + String(bits) + " decimal); " + s +
            "\nOwner: " + s.netSubstring(0, 3) + "; group: " + s.netSlice(3, 6) + "; other: " + s.netSubstring(6) +
            "; setuid=" + flag(2048) + ", setgid=" + flag(1024) + ", sticky=" + flag(512) +
            "\nMode-bit conversion only; no filesystem, Windows ACL, umask, ownership or effective-access change"
    }
    init(_ bits: Int, _ showOctal: Bool = false) throws {
        if bits < 0 || bits > 4095 { throw CalcError.arithmetic("Permission mode must fit 0000–7777 octal") }
        self.bits = bits; self.showOctal = showOctal
        var chars = Array("---------".utf16)
        for group in 0..<3 {
            let n = (bits >> (6 - group * 3)) & 7
            if n & 4 != 0 { chars[group * 3] = UInt16(ascii: "r") }
            if n & 2 != 0 { chars[group * 3 + 1] = UInt16(ascii: "w") }
            chars[group * 3 + 2] = n & 1 != 0 ? UInt16(ascii: "x") : UInt16(ascii: "-")
        }
        for (flag, index, lower, upper) in [(2048, 2, "s", "S"), (1024, 5, "s", "S"), (512, 8, "t", "T")] as [(Int, Int, Unicode.Scalar, Unicode.Scalar)] where bits & flag != 0 {
            chars[index] = chars[index] == UInt16(ascii: "x") ? UInt16(ascii: lower) : UInt16(ascii: upper)
        }
        symbolic = chars.string
    }
}

/// A reduced positive width:height ratio (C# AspectValue).
struct AspectValue: Hashable {
    let ratio: Rational
    var fullText: String { ratio.numerator.description + ":" + ratio.denominator.description }
    var display: String { get throws { let full = fullText; return full.netLength <= 96 ? full : full.netSubstring(0, 64) + "…" + full.netSubstring(full.netLength - 24) } }
    var copyText: String { get throws { "aspect(" + DeveloperSource.integer(ratio.numerator) + "," + DeveloperSource.integer(ratio.denominator) + ")" } }
    var details: String { "Reduced width:height = " + fullText + "; exact ratio " + ratio.description + "\nPositive proportional dimensions; no pixel rounding, resize target or physical display geometry inferred" }
    init(_ ratio: Rational) throws { if ratio.numerator.sign <= 0 { throw CalcError.arithmetic("Aspect dimensions must be positive") }; self.ratio = ratio }
}

/// 1–256 Unicode scalar values (C# UnicodeValue); not grapheme clusters, and no normalization.
struct UnicodeValue: Hashable {
    let scalars: [Int]
    let showGlyph: Bool
    let text: String
    let displayText: String
    var labels: String { scalars.map { "U+" + String($0, radix: 16, uppercase: true).netPadLeft(4, "0") }.joined(separator: " ") }
    var display: String { get throws { displayText } }
    var copyText: String { get throws { showGlyph ? "codepoint(" + String(scalars[0]) + ")" : "unicode(" + (try TextValue(text)).expressionText + ")" } }
    var details: String {
        "Unicode scalar sequence: " + labels + "\nUTF-8: " + text.utf8.map { String(format: "%02x", $0) }.joined() +
            "\nScalars are not grapheme clusters; no normalization, character-name catalog or glyph support inferred"
    }
    init(_ scalars: [Int], _ showGlyph: Bool) throws {
        if scalars.count < 1 || scalars.count > 256 || scalars.contains(where: { !DeveloperSource.isScalar($0) }) { throw CalcError.arithmetic("Expected 1–256 Unicode scalar values") }
        if showGlyph && scalars.count != 1 { throw CalcError.arithmetic("Glyph form requires one scalar") }
        self.scalars = scalars; self.showGlyph = showGlyph
        var text = ""; text.unicodeScalars.append(contentsOf: scalars.map { Unicode.Scalar(UInt32($0))! }); self.text = text
        let labels = scalars.map { "U+" + String($0, radix: 16, uppercase: true).netPadLeft(4, "0") }.joined(separator: " ")
        displayText = showGlyph ? (try TextValue(text)).display + " " + labels :
            labels.netLength <= 96 ? labels : labels.netSubstring(0, 64) + "…" + labels.netSubstring(labels.netLength - 24)
    }
    static func == (a: UnicodeValue, b: UnicodeValue) -> Bool { a.showGlyph == b.showGlyph && a.scalars == b.scalars }
    func hash(into hasher: inout Hasher) { hasher.combine(showGlyph); hasher.combine(scalars) }
}

/// Helpers shared by the developer values' exact presentation (C# DeveloperSource).
enum DeveloperSource {
    /// Rune.IsValid: 0…0x10FFFF outside the surrogate range.
    static func isScalar(_ value: Int) -> Bool { value >= 0 && value <= 0x10FFFF && !(value >= 0xD800 && value <= 0xDFFF) }
    static func isScalar(_ value: BigInt) -> Bool { value.intValue.map(isScalar) ?? false }
    /// The nonnegative remainder modulo a whole divisor.
    static func mod(_ v: Rational, _ divisor: Int) throws -> Rational {
        let denominator = v.denominator * BigInt(divisor); let n = v.numerator % denominator
        return try Rational(n.sign < 0 ? n + denominator : n, v.denominator)
    }
    /// A reusable hex literal: BigInteger.ToString("X") keeps a sign nibble, so 255 copies as 0x0FF.
    static func integer(_ n: BigInt) -> String { n.sign < 0 ? "(-" + integer(n.magnitude) + ")" : "0x" + n.formatHex("X") }
    static func fraction(_ r: Rational) -> String { r.denominator.isOne ? integer(r.numerator) : "(" + integer(r.numerator) + "/" + integer(r.denominator) + ")" }
}
