import Foundation

/// C# `System.Decimal`, for the German payroll port: a signed integer mantissa below 2^96 and a scale of 0–28.
/// Arithmetic follows .NET: + − × are exact and keep the larger (or summed) scale, rounding half to even only when
/// the result would need more than 96 bits or 28 decimals; ÷ returns the exact quotient at the smallest scale ≥ the
/// scale difference when one exists, otherwise as many digits as fit, rounded half to even. `description` is
/// `ToString()` (trailing zeros kept). Equality and ordering compare values, as C# does (1.0m == 1.00m).
struct NetDecimal: Hashable, Comparable, CustomStringConvertible {
    /// The signed mantissa; `|mantissa| <= maxMantissa`.
    let mantissa: BigInt
    /// Decimal places, 0...28.
    let scale: Int

    static let maxMantissa = (BigInt.one << 96) - .one
    static let maxScale = 28
    static let zero = NetDecimal(0)
    static let overflowMessage = "Value was either too large or too small for a Decimal."

    /// 10^0 … 10^64, cached: alignment and rounding use them on every operation.
    private static let powers: [BigInt] = (0...64).map { BigInt.pow(10, $0) }
    @inline(__always) static func pow10(_ exponent: Int) -> BigInt { exponent <= 64 ? powers[exponent] : BigInt.pow(10, exponent) }
    private static let smallPowers: [Int64] = (0...18).map { exponent in (0..<exponent).reduce(Int64(1)) { value, _ in value * 10 } }

    // Fast paths: payroll values are small, so most operations fit Int64 mantissas. Each falls back to the
    // BigInt path (same semantics) on any overflow; an Int64 result always fits the 96-bit mantissa.
    @inline(__always) private static func smallAligned(_ a: NetDecimal, _ b: NetDecimal) -> (Int64, Int64, Int)? {
        guard let x = a.mantissa.int64Value, let y = b.mantissa.int64Value else { return nil }
        if a.scale == b.scale { return (x, y, a.scale) }
        if a.scale < b.scale {
            let k = b.scale - a.scale; if k > 18 { return nil }
            let (scaled, overflow) = x.multipliedReportingOverflow(by: smallPowers[k]); return overflow ? nil : (scaled, y, b.scale)
        }
        let k = a.scale - b.scale; if k > 18 { return nil }
        let (scaled, overflow) = y.multipliedReportingOverflow(by: smallPowers[k]); return overflow ? nil : (x, scaled, a.scale)
    }

    private init(unchecked mantissa: BigInt, _ scale: Int) { self.mantissa = mantissa; self.scale = scale }
    init(_ value: Int) { self.init(unchecked: BigInt(value), 0) }
    init(_ value: Int64) { self.init(unchecked: BigInt(value), 0) }
    /// A literal such as `0.093m`: mantissa 93, scale 3. Literals in this engine always fit.
    init(_ mantissa: Int64, scale: Int) { self.init(unchecked: BigInt(mantissa), scale) }

    /// The value `mantissa / 10^scale`, rounded half to even until it fits 96 bits and 28 decimals (VarDec* ScaleResult).
    static func fitting(_ mantissa: BigInt, _ scale: Int) throws -> NetDecimal {
        if scale >= 0 && scale <= maxScale && mantissa.magnitude <= maxMantissa { return NetDecimal(unchecked: mantissa, scale) }
        if scale < 0 {
            let scaled = mantissa * NetDecimal.pow10(-scale)
            if scaled.magnitude > maxMantissa { throw CalcError.arithmetic(overflowMessage) }
            return NetDecimal(unchecked: scaled, 0)
        }
        var drop = max(0, scale - maxScale)
        while true {
            if scale - drop < 0 { throw CalcError.arithmetic(overflowMessage) }
            let rounded = roundHalfEven(mantissa, NetDecimal.pow10(drop))
            if rounded.magnitude <= maxMantissa { return NetDecimal(unchecked: rounded, scale - drop) }
            drop += 1
        }
    }

    /// `numerator / denominator` rounded to the nearest integer, ties to even (denominator > 0).
    private static func roundHalfEven(_ numerator: BigInt, _ denominator: BigInt) -> BigInt {
        if denominator.isOne { return numerator }
        let (q, r) = numerator.magnitude.quotientAndRemainder(dividingBy: denominator)
        let twice = r * BigInt(2)
        var magnitude = q
        if twice > denominator || (twice == denominator && !q.isEven) { magnitude += .one }
        return numerator.sign < 0 ? -magnitude : magnitude
    }

    var sign: Int { mantissa.sign }
    var isZero: Bool { mantissa.isZero }

    private static func aligned(_ a: NetDecimal, _ b: NetDecimal) -> (BigInt, BigInt, Int) {
        if a.scale == b.scale { return (a.mantissa, b.mantissa, a.scale) }
        if a.scale < b.scale { return (a.mantissa * NetDecimal.pow10(b.scale - a.scale), b.mantissa, b.scale) }
        return (a.mantissa, b.mantissa * NetDecimal.pow10(a.scale - b.scale), a.scale)
    }

    static func + (a: NetDecimal, b: NetDecimal) throws -> NetDecimal {
        if let (x, y, scale) = smallAligned(a, b) {
            let (sum, overflow) = x.addingReportingOverflow(y); if !overflow { return NetDecimal(unchecked: BigInt(sum), scale) }
        }
        let (x, y, scale) = aligned(a, b); return try fitting(x + y, scale)
    }
    static func - (a: NetDecimal, b: NetDecimal) throws -> NetDecimal {
        if let (x, y, scale) = smallAligned(a, b) {
            let (difference, overflow) = x.subtractingReportingOverflow(y); if !overflow { return NetDecimal(unchecked: BigInt(difference), scale) }
        }
        let (x, y, scale) = aligned(a, b); return try fitting(x - y, scale)
    }
    static func * (a: NetDecimal, b: NetDecimal) throws -> NetDecimal {
        if let x = a.mantissa.int64Value, let y = b.mantissa.int64Value, a.scale + b.scale <= maxScale {
            let (product, overflow) = x.multipliedReportingOverflow(by: y); if !overflow { return NetDecimal(unchecked: BigInt(product), a.scale + b.scale) }
        }
        return try fitting(a.mantissa * b.mantissa, a.scale + b.scale)
    }
    static prefix func - (a: NetDecimal) -> NetDecimal { NetDecimal(unchecked: -a.mantissa, a.scale) }

    /// VarDecDiv: an exact quotient keeps the smallest scale ≥ max(scale difference, 0) (the dividend is only scaled
    /// up while a remainder is left, and trailing zeros added by that scaling are removed again); an inexact one
    /// keeps every digit that fits 96 bits within 28 decimals, rounds the rest half to even, and also drops the
    /// trailing zeros of that rounded quotient.
    static func / (a: NetDecimal, b: NetDecimal) throws -> NetDecimal {
        if b.isZero { throw CalcError.arithmetic(CalcError.divideByZeroMessage) }
        let difference = a.scale - b.scale
        let n = a.mantissa.magnitude, d = b.mantissa.magnitude
        let negative = (a.sign < 0) != (b.sign < 0)
        func signed(_ value: BigInt) -> BigInt { negative ? -value : value }
        if n.isZero { return NetDecimal(unchecked: .zero, max(difference, 0)) }
        if let exact = smallExactQuotient(n, d, difference) { return NetDecimal(unchecked: signed(BigInt(exact.mantissa)), exact.scale) }
        // Exact when d / gcd(n, d) has no prime factors besides 2 and 5.
        var rest = d / BigInt.gcd(n, d), twos = 0, fives = 0
        while rest.isEven { rest = rest >> 1; twos += 1 }
        while (rest % BigInt(5)).isZero { rest = rest / BigInt(5); fives += 1 }
        if rest.isOne {
            let scale = max(0, difference + max(twos, fives), difference)
            if scale <= maxScale {
                let q = scaledQuotient(n, d, scale - difference)
                if q.remainder.isZero && q.quotient <= maxMantissa { return NetDecimal(unchecked: signed(q.quotient), scale) }
            }
        }
        // Inexact (or exact but too long): the largest scale ≤ 28 whose quotient fits, rounded half to even.
        var scale = maxScale
        while true {
            let q = scaledQuotient(n, d, scale - difference)
            if q.quotient > maxMantissa {
                let excess = q.quotient.description.utf8.count - maxMantissa.description.utf8.count
                scale -= max(1, excess)
                if scale < 0 && scale - difference < -64 { throw CalcError.arithmetic(overflowMessage) }
                continue
            }
            let twice = q.remainder * BigInt(2)
            var rounded = q.quotient
            if twice > q.divisor || (twice == q.divisor && !rounded.isEven) { rounded += .one }
            if rounded > maxMantissa { scale -= 1; continue }
            if scale < 0 { return try fitting(signed(rounded), scale) }
            // .NET scaled the dividend up, so it strips the trailing zeros of the rounded quotient too (Unscale).
            while scale > 0 && (rounded % BigInt(10)).isZero { rounded = rounded / BigInt(10); scale -= 1 }
            return NetDecimal(unchecked: signed(rounded), scale)
        }
    }
    /// The exact-quotient branch of `/` in Int64 arithmetic; nil when the quotient does not terminate or anything overflows.
    private static func smallExactQuotient(_ n: BigInt, _ d: BigInt, _ difference: Int) -> (mantissa: Int64, scale: Int)? {
        guard let n = n.int64Value, let d = d.int64Value else { return nil }
        var x = n, y = d
        while y != 0 { (x, y) = (y, x % y) }
        var rest = d / x, twos = 0, fives = 0
        while rest & 1 == 0 { rest >>= 1; twos += 1 }
        while rest % 5 == 0 { rest /= 5; fives += 1 }
        if rest != 1 { return nil }
        let scale = Swift.max(0, difference + Swift.max(twos, fives), difference)
        let shift = scale - difference
        if scale > maxScale || shift < 0 || shift > 18 { return nil }
        let (numerator, overflow) = n.multipliedReportingOverflow(by: smallPowers[shift])
        if overflow || numerator % d != 0 { return nil }
        return (numerator / d, scale)
    }
    /// `n * 10^shift / d` with its remainder and the divisor used (shift may be negative).
    private static func scaledQuotient(_ n: BigInt, _ d: BigInt, _ shift: Int) -> (quotient: BigInt, remainder: BigInt, divisor: BigInt) {
        let numerator = shift >= 0 ? n * NetDecimal.pow10(shift) : n
        let divisor = shift >= 0 ? d : d * NetDecimal.pow10(-shift)
        let (q, r) = numerator.quotientAndRemainder(dividingBy: divisor)
        return (q, r, divisor)
    }

    /// `decimal.Truncate`: toward zero, scale 0.
    var truncated: NetDecimal {
        if scale == 0 { return self }
        if scale <= 18, let m = mantissa.int64Value { return NetDecimal(unchecked: BigInt(m / NetDecimal.smallPowers[scale]), 0) }
        return NetDecimal(unchecked: mantissa / NetDecimal.pow10(scale), 0)
    }
    /// `decimal.Round(value, places)` (ties to even) or with `MidpointRounding.AwayFromZero`.
    func rounded(_ places: Int, awayFromZero: Bool = false) -> NetDecimal {
        if scale <= places { return self }
        let divisor = NetDecimal.pow10(scale - places)
        let (q, r) = mantissa.magnitude.quotientAndRemainder(dividingBy: divisor)
        let twice = r * BigInt(2)
        var magnitude = q
        if twice > divisor || (twice == divisor && (awayFromZero || !q.isEven)) { magnitude += BigInt.one }
        return NetDecimal(unchecked: mantissa.sign < 0 ? -magnitude : magnitude, places)
    }
    /// `(long)value`: truncates; throws past Int64.
    var int64: Int64 {
        get throws {
            guard let value = truncated.mantissa.int64Value else { throw CalcError.arithmetic(CalcError.overflowInt64Message) }
            return value
        }
    }
    /// The exact value.
    var rational: Rational { get throws { try Rational(mantissa, NetDecimal.pow10(scale)) } }

    static func == (a: NetDecimal, b: NetDecimal) -> Bool {
        if let (x, y, _) = smallAligned(a, b) { return x == y }
        let (x, y, _) = aligned(a, b); return x == y
    }
    static func < (a: NetDecimal, b: NetDecimal) -> Bool {
        if let (x, y, _) = smallAligned(a, b) { return x < y }
        let (x, y, _) = aligned(a, b); return x < y
    }
    func hash(into hasher: inout Hasher) {
        // Hash the value with trailing zeros removed so equal values hash alike.
        var m = mantissa, s = scale
        while s > 0 && (m % BigInt(10)).isZero { m = m / BigInt(10); s -= 1 }
        hasher.combine(m); hasher.combine(s)
    }
    /// `Math.Min`/`decimal.Min`: x < y ? x : y (y when equal, which can differ in scale).
    static func minimum(_ a: NetDecimal, _ b: NetDecimal) -> NetDecimal { a < b ? a : b }
    /// `Math.Max`/`decimal.Max`: x >= y ? x : y.
    static func maximum(_ a: NetDecimal, _ b: NetDecimal) -> NetDecimal { a >= b ? a : b }

    /// `ToString(CultureInfo.InvariantCulture)`: every digit of the scale, no exponent.
    var description: String {
        let digits = mantissa.magnitude.description
        var text: String
        if scale == 0 { text = digits }
        else {
            let padded = digits.netPadLeft(scale + 1, "0")
            text = padded.netInsert(padded.netLength - scale, ".")
        }
        return mantissa.sign < 0 ? "-" + text : text
    }
    /// `ToString("0.00…")` with `places` zeros: rounded half away from zero, as .NET's custom formats round decimals.
    func fixed(_ places: Int) -> String {
        let value = rounded(places, awayFromZero: true)
        var text = value.mantissa.magnitude.description.netPadLeft(value.scale + 1, "0")
        if value.scale < places { text += String(repeating: "0", count: places - value.scale) }
        if places > 0 { text = text.netInsert(text.netLength - places, ".") }
        return value.mantissa.sign < 0 ? "-" + text : text
    }

    /// `decimal.TryParse(text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture)`: ASCII digits with at
    /// most one '.', at least one digit; the scale is the number of typed decimals (rounded to fit like .NET).
    static func parse(_ text: String) -> NetDecimal? {
        let units = text.units
        var digits = BigInt.zero, scale = 0, seenPoint = false, seenDigit = false
        for unit in units {
            if unit == 0x2E { if seenPoint { return nil }; seenPoint = true; continue }
            guard NetChar.isAsciiDigit(unit) else { return nil }
            seenDigit = true
            digits = digits * BigInt(10) + BigInt(Int(unit) - 48)
            if seenPoint { scale += 1 }
        }
        if !seenDigit { return nil }
        return try? fitting(digits, scale)
    }
}
