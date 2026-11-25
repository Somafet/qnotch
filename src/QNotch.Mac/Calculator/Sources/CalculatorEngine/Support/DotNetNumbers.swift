import Foundation

/// System.Math behaviour the engine depends on, reproduced operation for operation so results match bit for bit.
enum NetMath {
    private static let powersOfTen: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15]

    /// Math.Round(x): to the nearest integer, ties to even.
    static func round(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// Math.Round(x, MidpointRounding).
    static func round(_ x: Double, awayFromZero: Bool) -> Double { round(x, 0, awayFromZero: awayFromZero) }

    /// Math.Round(x, digits[, mode]) as .NET computes it: scale by 10^digits, round, scale back, and leave values
    /// of magnitude ≥ 1e16 untouched. AwayFromZero is Truncate(v + CopySign(BitDecrement(0.5), v)), so the binary
    /// error of the scaling shows through (Math.Round(2.675, 2) = 2.68 but Math.Round(1.005, 2, AwayFromZero) = 1).
    static func round(_ x: Double, _ digits: Int, awayFromZero: Bool = false) -> Double {
        precondition((0...15).contains(digits), "Math.Round supports 0…15 digits")
        guard Swift.abs(x) < 1e16 else { return x }
        let power = powersOfTen[digits]
        let scaled = x * power
        let rounded = awayFromZero
            ? (scaled + Double(signOf: scaled, magnitudeOf: 0.5.nextDown)).rounded(.towardZero)
            : scaled.rounded(.toNearestOrEven)
        return rounded / power
    }

    static func truncate(_ x: Double) -> Double { x.rounded(.towardZero) }
    static func floor(_ x: Double) -> Double { x.rounded(.down) }
    static func ceiling(_ x: Double) -> Double { x.rounded(.up) }

    /// Math.Log(a, newBase) = Log(a) / Log(newBase) with .NET's special cases.
    static func log(_ a: Double, _ newBase: Double) -> Double {
        if a.isNaN { return a }
        if newBase.isNaN { return newBase }
        if newBase == 1 { return .nan }
        if a != 1 && (newBase == 0 || newBase == .infinity) { return .nan }
        return Foundation.log(a) / Foundation.log(newBase)
    }
}

/// .NET number formatting with CultureInfo.InvariantCulture, for the format strings the engine uses.
enum NetFormat {
    /// Double.ToString(format, InvariantCulture). Supports nil/"" and "R"/"G" (shortest round trip; scientific
    /// past 17 integer digits or below 1E-04, so "1E+20" and "1.5E-05"), "G<n>", "E<n>" ("1.234560E+004"),
    /// "F<n>", "N<n>" and custom patterns of 0, # and one '.', optionally followed by E+0/E-0/E0 (e.g. "0.##",
    /// "0.#E+0", "00"). Negative zero keeps its sign ("-0"); NaN and infinities print "NaN", "Infinity", "-Infinity".
    ///
    /// Standard formats round the exact binary value, ties to even (0.125 "F2" → "0.12"). Custom formats first
    /// round to 15 significant digits and then round half away from zero (0.125 "0.##" → "0.13", 4.35 "0.0" → "4.4").
    static func double(_ x: Double, _ format: String?) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
        let negative = x.sign == .minus
        let spec = Array((format ?? "").utf8)
        guard let standard = standardSpecifier(spec) else {
            var digits = exactDigits(x.magnitude, negative: negative)
            digits.round(keeping: 15, halfEven: true)
            return custom(digits, spec)
        }
        let (letter, precision) = standard
        let shortest = letter | 0x20 == UInt8(ascii: "r") || (letter | 0x20 == UInt8(ascii: "g") && (precision ?? 0) == 0)
        switch shortest ? UInt8(ascii: "r") : letter | 0x20 { // lowercase
        case UInt8(ascii: "r"):
            let digits = shortestDigits(x.magnitude, negative: negative)
            return general(digits, maxDigits: Swift.max(digits.digits.count, 17), exponentLetter: letter & 0x20 | UInt8(ascii: "E"))
        case UInt8(ascii: "g"):
            var digits = exactDigits(x.magnitude, negative: negative)
            digits.round(keeping: precision!, halfEven: true)
            return general(digits, maxDigits: precision!, exponentLetter: letter & 0x20 | UInt8(ascii: "E"))
        case UInt8(ascii: "e"):
            var digits = exactDigits(x.magnitude, negative: negative)
            let count = (precision ?? 6) + 1
            digits.round(keeping: count, halfEven: true)
            return scientific(digits, significant: count, exponentLetter: letter)
        case UInt8(ascii: "f"), UInt8(ascii: "n"):
            var digits = exactDigits(x.magnitude, negative: negative)
            let decimals = precision ?? 2
            digits.round(keeping: digits.scale + decimals, halfEven: true)
            return fixed(digits, decimals: decimals, grouped: letter | 0x20 == UInt8(ascii: "n"))
        default:
            preconditionFailure("Unsupported double format " + (format ?? ""))
        }
    }

    /// Int64.ToString(format, InvariantCulture) for "" , "D<n>", "X<n>"/"x<n>" (two's complement for negatives),
    /// "N<n>" and the custom patterns `double` accepts (e.g. "00").
    static func integer(_ value: Int64, _ format: String) -> String {
        let spec = Array(format.utf8)
        let negative = value < 0
        let magnitude = String(value.magnitude)
        guard case let (letter, precision)? = standardSpecifier(spec) else {
            return custom(Digits(text: magnitude, negative: negative), spec)
        }
        switch letter | 0x20 {
        case UInt8(ascii: "d"):
            return (negative ? "-" : "") + String(repeating: "0", count: Swift.max(0, (precision ?? 0) - magnitude.count)) + magnitude
        case UInt8(ascii: "x"):
            let hex = String(UInt64(bitPattern: value), radix: 16, uppercase: letter == UInt8(ascii: "X"))
            return String(repeating: "0", count: Swift.max(0, (precision ?? 0) - hex.count)) + hex
        case UInt8(ascii: "n"):
            return fixed(Digits(text: magnitude, negative: negative), decimals: precision ?? 2, grouped: true)
        case UInt8(ascii: "g") where precision == nil:
            return String(value)
        default:
            preconditionFailure("Unsupported integer format " + format)
        }
    }

    // MARK: Digit buffers

    /// A decimal value 0.d₁d₂…dₙ × 10^scale (digits as 0…9 without trailing zeros; zero is no digits).
    struct Digits {
        var digits: [UInt8]
        var scale: Int
        var negative: Bool

        init(digits: [UInt8], scale: Int, negative: Bool) {
            self.digits = digits
            self.scale = scale
            self.negative = negative
            trim()
        }

        /// From an unsigned decimal integer string without leading zeros ("0" for zero).
        init(text: String, negative: Bool) {
            let digits = text.utf8.map { $0 - 48 }
            self.init(digits: digits, scale: digits.count, negative: negative)
        }

        private mutating func trim() {
            while digits.last == 0 { digits.removeLast() }
            if digits.isEmpty { scale = 0 }
        }

        /// Keeps the first `count` digits (count may be ≤ 0), rounding the rest ties-to-even or half-up.
        mutating func round(keeping count: Int, halfEven: Bool) {
            guard count < digits.count else { return }
            guard count >= 0 else { digits = []; scale = 0; return }
            let next = digits[count]
            let up = halfEven
                ? next > 5 || (next == 5 && (count + 1 < digits.count || (count > 0 && digits[count - 1] & 1 == 1)))
                : next >= 5
            digits.removeSubrange(count...)
            if up {
                while digits.last == 9 { digits.removeLast() }
                if digits.isEmpty { digits = [1]; scale += 1 } else { digits[digits.count - 1] += 1 }
            }
            trim()
        }

        func digit(_ index: Int) -> UInt8 { index >= 0 && index < digits.count ? digits[index] + 48 : UInt8(ascii: "0") }
    }

    /// The exact decimal expansion of a finite non-negative double (at most 767 significant digits).
    static func exactDigits(_ x: Double, negative: Bool) -> Digits {
        if x == 0 { return Digits(digits: [], scale: 0, negative: negative) }
        let bits = x.bitPattern, biased = Int(bits >> 52)
        var significand = bits & ((1 << 52) - 1), exponent: Int
        if biased == 0 { exponent = -1074 } else { significand |= 1 << 52; exponent = biased - 1075 }
        let zeros = significand.trailingZeroBitCount
        significand >>= UInt64(zeros)
        exponent += zeros
        // x = s·2^e; for e < 0 that is s·5^(−e) / 10^(−e).
        let integer = exponent >= 0 ? BigInt(significand) << exponent : BigInt(significand) * BigInt.pow(5, -exponent)
        let text = integer.description.utf8.map { $0 - 48 }
        return Digits(digits: text, scale: text.count + Swift.min(exponent, 0), negative: negative)
    }

    /// The shortest digits that round-trip (Swift's and .NET Core 3.0+'s algorithms agree on them).
    static func shortestDigits(_ x: Double, negative: Bool) -> Digits {
        if x == 0 { return Digits(digits: [], scale: 0, negative: negative) }
        var digits: [UInt8] = [], point: Int?, exponent = 0
        let text = Array(x.description.utf8) // e.g. "123.456", "1e-05", "1.5e+20"
        var i = 0
        while i < text.count {
            let c = text[i]
            if c == UInt8(ascii: ".") {
                point = digits.count
            } else if c == UInt8(ascii: "e") {
                exponent = Int(String(decoding: text[(i + 1)...], as: UTF8.self))!
                break
            } else {
                digits.append(c - 48)
            }
            i += 1
        }
        var scale = (point ?? digits.count) + exponent
        while digits.first == 0 { digits.removeFirst(); scale -= 1 }
        return Digits(digits: digits, scale: scale, negative: negative)
    }

    // MARK: Layouts

    /// A standard specifier is one letter plus an optional decimal precision; anything else is a custom pattern.
    private static func standardSpecifier(_ spec: [UInt8]) -> (letter: UInt8, precision: Int?)? {
        if spec.isEmpty { return (UInt8(ascii: "G"), nil) }
        let letter = spec[0]
        guard (letter | 0x20) >= UInt8(ascii: "a") && (letter | 0x20) <= UInt8(ascii: "z"),
              spec.dropFirst().allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return (letter, spec.count > 1 ? Int(String(decoding: spec[1...], as: UTF8.self)) : nil)
    }

    private static func exponentText(_ value: Int, letter: UInt8, minDigits: Int, plus: Bool) -> String {
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : (plus ? "+" : "")
        return String(UnicodeScalar(letter)) + sign + String(repeating: "0", count: Swift.max(0, minDigits - digits.count)) + digits
    }

    /// 'G' layout: fixed unless the decimal exponent passes maxDigits or drops below −4, then d.dddE±XX.
    private static func general(_ d: Digits, maxDigits: Int, exponentLetter: UInt8) -> String {
        var out = [UInt8]()
        if d.negative { out.append(UInt8(ascii: "-")) }
        var position = d.scale
        let isScientific = position > maxDigits || position < -3
        if isScientific { position = 1 }
        var i = 0
        if position > 0 {
            while position > 0 { out.append(d.digit(i)); i += 1; position -= 1 }
        } else {
            out.append(UInt8(ascii: "0"))
        }
        if i < d.digits.count || position < 0 {
            out.append(UInt8(ascii: "."))
            while position < 0 { out.append(UInt8(ascii: "0")); position += 1 }
            while i < d.digits.count { out.append(d.digit(i)); i += 1 }
        }
        var text = String(decoding: out, as: UTF8.self)
        if isScientific { text += exponentText(d.scale - 1, letter: exponentLetter, minDigits: 2, plus: true) }
        return text
    }

    /// 'E' layout: one digit, the point, significant − 1 digits, and a signed exponent of at least three digits.
    private static func scientific(_ d: Digits, significant: Int, exponentLetter: UInt8) -> String {
        var out = [UInt8]()
        if d.negative { out.append(UInt8(ascii: "-")) }
        out.append(d.digit(0))
        if significant != 1 { out.append(UInt8(ascii: ".")) }
        for i in 1..<Swift.max(1, significant) { out.append(d.digit(i)) }
        return String(decoding: out, as: UTF8.self) + exponentText(d.digits.isEmpty ? 0 : d.scale - 1, letter: exponentLetter, minDigits: 3, plus: true)
    }

    /// 'F'/'N' layout of already-rounded digits; N groups the integer part in threes with ",".
    private static func fixed(_ d: Digits, decimals: Int, grouped: Bool) -> String {
        var out = [UInt8]()
        if d.negative { out.append(UInt8(ascii: "-")) }
        if d.scale > 0 {
            for i in 0..<d.scale {
                if grouped && i > 0 && (d.scale - i) % 3 == 0 { out.append(UInt8(ascii: ",")) }
                out.append(d.digit(i))
            }
        } else {
            out.append(UInt8(ascii: "0"))
        }
        if decimals > 0 {
            out.append(UInt8(ascii: "."))
            for k in 0..<decimals { out.append(d.digit(d.scale + k)) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Custom patterns: [0#]+ ('.' [0#]*)? ([Ee] [+-]? 0+)?. Rounds half-up at the last placeholder, pads the integer
    /// part to its '0' count and prints fraction digits up to the last '0' or last non-zero digit.
    private static func custom(_ value: Digits, _ spec: [UInt8]) -> String {
        var integerPlaceholders = 0, minimumInteger = 0, decimalPlaceholders = 0, requiredDecimals = 0
        var inFraction = false, exponent: (minDigits: Int, plus: Bool, letter: UInt8)?
        var i = 0
        while i < spec.count {
            let c = spec[i]
            switch c {
            case UInt8(ascii: "0"), UInt8(ascii: "#"):
                if inFraction {
                    decimalPlaceholders += 1
                    if c == UInt8(ascii: "0") { requiredDecimals = decimalPlaceholders }
                } else {
                    integerPlaceholders += 1
                    if c == UInt8(ascii: "0") || minimumInteger > 0 { minimumInteger += 1 }
                }
            case UInt8(ascii: ".") where !inFraction:
                inFraction = true
            case UInt8(ascii: "E"), UInt8(ascii: "e"):
                var j = i + 1, plus = false
                if j < spec.count && (spec[j] == UInt8(ascii: "+") || spec[j] == UInt8(ascii: "-")) { plus = spec[j] == UInt8(ascii: "+"); j += 1 }
                let zeros = spec[j...].prefix { $0 == UInt8(ascii: "0") }.count
                precondition(zeros > 0 && j + zeros == spec.count, "Unsupported custom format")
                exponent = (zeros, plus, c)
                i = spec.count
                continue
            default:
                preconditionFailure("Unsupported custom format " + String(decoding: spec, as: UTF8.self))
            }
            i += 1
        }
        var d = value
        var out = [UInt8]()
        if d.negative { out.append(UInt8(ascii: "-")) }
        let pointPosition: Int // digit index where the decimal point falls
        if exponent != nil {
            d.round(keeping: integerPlaceholders + decimalPlaceholders, halfEven: false)
            pointPosition = integerPlaceholders
            for k in 0..<integerPlaceholders { out.append(d.digit(k)) }
        } else {
            d.round(keeping: d.scale + decimalPlaceholders, halfEven: false)
            pointPosition = d.scale
            let integerDigits = Swift.max(d.scale, minimumInteger)
            for k in 0..<integerDigits { out.append(d.digit(d.scale - integerDigits + k)) }
        }
        var shownDecimals = requiredDecimals
        for k in 0..<decimalPlaceholders where d.digit(pointPosition + k) != UInt8(ascii: "0") { shownDecimals = Swift.max(shownDecimals, k + 1) }
        if shownDecimals > 0 {
            out.append(UInt8(ascii: "."))
            for k in 0..<shownDecimals { out.append(d.digit(pointPosition + k)) }
        }
        var text = String(decoding: out, as: UTF8.self)
        if let exponent {
            text += exponentText(d.digits.isEmpty ? 0 : d.scale - integerPlaceholders, letter: exponent.letter, minDigits: exponent.minDigits, plus: exponent.plus)
        }
        return text
    }
}
