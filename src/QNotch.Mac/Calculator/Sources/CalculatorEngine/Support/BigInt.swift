import Foundation

/// An arbitrary-precision signed integer that reproduces System.Numerics.BigInteger exactly, so the Swift engine
/// computes what the C# engine computes. Values that fit Int64 stay inline (no allocation); larger ones are a sign
/// plus little-endian 64-bit limbs. Division truncates toward zero, bitwise operators act on an infinite two's
/// complement, and the conversions and formatters copy .NET's (sometimes surprising) rules, noted where they apply.
struct BigInt {
    /// Canonical, so synthesized == and hashing are value equality: every value in Int64's range is `.small`;
    /// `.large` holds the rest with a non-empty magnitude whose top limb is non-zero.
    enum Storage: Hashable {
        case small(Int64)
        case large(negative: Bool, limbs: [UInt64])
    }

    private(set) var storage: Storage

    init(_ value: Int64) { storage = .small(value) }
    init(_ value: Int) { storage = .small(Int64(value)) }
    init(_ value: UInt64) { storage = value <= UInt64(Int64.max) ? .small(Int64(value)) : .large(negative: false, limbs: [value]) }

    /// Builds a value from a sign and a magnitude in any shape (leading zero limbs allowed).
    init(negative: Bool, limbs: [UInt64]) {
        var limbs = limbs
        Limbs.normalize(&limbs)
        if limbs.isEmpty {
            storage = .small(0)
        } else if limbs.count == 1 && limbs[0] <= UInt64(Int64.max) {
            storage = .small(negative ? -Int64(limbs[0]) : Int64(limbs[0]))
        } else if limbs.count == 1 && negative && limbs[0] == 1 << 63 {
            storage = .small(.min)
        } else {
            storage = .large(negative: negative, limbs: limbs)
        }
    }

    static let zero = BigInt(0 as Int64)
    static let one = BigInt(1 as Int64)
    static let minusOne = BigInt(-1 as Int64)

    /// Sign and magnitude (empty for zero); allocates for small values, so only the slow paths use it.
    var parts: (negative: Bool, limbs: [UInt64]) {
        switch storage {
        case .small(let x): return (x < 0, x == 0 ? [] : [x.magnitude])
        case .large(let negative, let limbs): return (negative, limbs)
        }
    }
}

extension BigInt: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int64) { storage = .small(value) }
}

// MARK: - Properties

extension BigInt {
    var sign: Int {
        switch storage {
        case .small(let x): return Int(x.signum())
        case .large(let negative, _): return negative ? -1 : 1
        }
    }
    var isZero: Bool { if case .small(0) = storage { return true }; return false }
    var isOne: Bool { if case .small(1) = storage { return true }; return false }
    var isEven: Bool {
        switch storage {
        case .small(let x): return x & 1 == 0
        case .large(_, let limbs): return limbs[0] & 1 == 0
        }
    }
    var magnitude: BigInt {
        switch storage {
        case .small(let x): return BigInt(x.magnitude)
        case .large(_, let limbs): return BigInt(negative: false, limbs: limbs)
        }
    }
    static func abs(_ value: BigInt) -> BigInt { value.magnitude }

    /// BigInteger.GetBitLength(): the two's complement width without the sign bit (−1 → 0, −128 → 7, −129 → 8).
    var bitLength: Int {
        switch storage {
        case .small(let x): return 64 - (x < 0 ? ~x : x).leadingZeroBitCount
        case .large(let negative, let limbs):
            // For negatives this is the length of |x| − 1, one shorter than |x| exactly when |x| is a power of two.
            let bits = Limbs.bitCount(limbs)
            return negative && Limbs.isPowerOfTwo(limbs) ? bits - 1 : bits
        }
    }

    /// BigInteger.GetByteCount(isUnsigned): bytes of the minimal two's complement (or unsigned) form; 0 takes one byte.
    /// .NET throws OverflowException for a negative value with isUnsigned; that is a programming error here.
    func byteCount(isUnsigned: Bool = false) -> Int {
        if isUnsigned {
            precondition(sign >= 0, "GetByteCount(isUnsigned: true) of a negative value")
            return Swift.max(1, (bitLength + 7) / 8)
        }
        return bitLength / 8 + 1
    }

    /// BigInteger.TrailingZeroCount: the same for x and −x; .NET returns 32 (the width of its inline int) for zero.
    var trailingZeroCount: Int {
        switch storage {
        case .small(let x): return x == 0 ? 32 : x.trailingZeroBitCount
        case .large(_, let limbs):
            var i = 0
            while limbs[i] == 0 { i += 1 }
            return i * 64 + limbs[i].trailingZeroBitCount
        }
    }

    /// The value as Int64, or nil where C#'s explicit cast throws OverflowException.
    var int64Value: Int64? { if case .small(let x) = storage { return x }; return nil }
    var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }
}

// MARK: - Comparison

extension BigInt: Hashable, Comparable {
    static func < (a: BigInt, b: BigInt) -> Bool { compare(a, b) < 0 }

    static func compare(_ a: BigInt, _ b: BigInt) -> Int {
        if case .small(let x) = a.storage, case .small(let y) = b.storage { return x < y ? -1 : (x == y ? 0 : 1) }
        let (sa, sb) = (a.sign, b.sign)
        if sa != sb { return sa < sb ? -1 : 1 }
        let c = Limbs.compare(a.parts.limbs, b.parts.limbs)
        return sa < 0 ? -c : c
    }
}

// MARK: - Arithmetic

extension BigInt {
    static prefix func - (a: BigInt) -> BigInt {
        switch a.storage {
        case .small(let x): return x == .min ? BigInt(UInt64(1) << 63) : BigInt(-x)
        case .large(let negative, let limbs): return BigInt(negative: !negative, limbs: limbs)
        }
    }

    static func + (a: BigInt, b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage {
            let (s, overflow) = x.addingReportingOverflow(y)
            if !overflow { return BigInt(s) }
        }
        return addSigned(a.parts, b.parts)
    }

    static func - (a: BigInt, b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage {
            let (s, overflow) = x.subtractingReportingOverflow(y)
            if !overflow { return BigInt(s) }
        }
        let pb = b.parts
        return addSigned(a.parts, (!pb.negative, pb.limbs))
    }

    private static func addSigned(_ a: (negative: Bool, limbs: [UInt64]), _ b: (negative: Bool, limbs: [UInt64])) -> BigInt {
        if a.negative == b.negative { return BigInt(negative: a.negative, limbs: Limbs.add(a.limbs, b.limbs)) }
        switch Limbs.compare(a.limbs, b.limbs) {
        case 0: return .zero
        case 1: return BigInt(negative: a.negative, limbs: Limbs.subtract(a.limbs, b.limbs))
        default: return BigInt(negative: b.negative, limbs: Limbs.subtract(b.limbs, a.limbs))
        }
    }

    static func * (a: BigInt, b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage {
            let (p, overflow) = x.multipliedReportingOverflow(by: y)
            if !overflow { return BigInt(p) }
        }
        let (pa, pb) = (a.parts, b.parts)
        return BigInt(negative: pa.negative != pb.negative, limbs: Limbs.multiply(pa.limbs, pb.limbs))
    }

    /// BigInteger.DivRem: the quotient truncates toward zero and the remainder takes the dividend's sign.
    func quotientAndRemainder(dividingBy divisor: BigInt) -> (quotient: BigInt, remainder: BigInt) {
        precondition(!divisor.isZero, "BigInt division by zero")
        if case .small(let x) = storage, case .small(let y) = divisor.storage {
            if x == .min && y == -1 { return (BigInt(UInt64(1) << 63), .zero) }
            return (BigInt(x / y), BigInt(x % y))
        }
        let (pa, pb) = (parts, divisor.parts)
        let (q, r) = Limbs.divRem(pa.limbs, pb.limbs)
        return (BigInt(negative: pa.negative != pb.negative, limbs: q), BigInt(negative: pa.negative, limbs: r))
    }

    static func / (a: BigInt, b: BigInt) -> BigInt { a.quotientAndRemainder(dividingBy: b).quotient }
    static func % (a: BigInt, b: BigInt) -> BigInt { a.quotientAndRemainder(dividingBy: b).remainder }

    static func += (a: inout BigInt, b: BigInt) { a = a + b }
    static func -= (a: inout BigInt, b: BigInt) { a = a - b }
    static func *= (a: inout BigInt, b: BigInt) { a = a * b }
    static func /= (a: inout BigInt, b: BigInt) { a = a / b }
    static func %= (a: inout BigInt, b: BigInt) { a = a % b }

    /// BigInteger.Pow; exponent must be non-negative (C# throws), and 0⁰ = 1.
    static func pow(_ base: BigInt, _ exponent: Int) -> BigInt {
        precondition(exponent >= 0, "BigInt.pow with a negative exponent")
        if exponent == 0 { return .one }
        if case .small(let x) = base.storage, (-1...1).contains(x) { return x == -1 && exponent & 1 == 0 ? .one : base }
        var result = BigInt.one, square = base, e = exponent
        while true {
            if e & 1 == 1 { result *= square }
            e >>= 1
            if e == 0 { return result }
            square *= square
        }
    }

    /// BigInteger.ModPow: |value|^exponent mod |modulus|, negated when value is negative and the exponent odd
    /// (the sign C#'s % would give). Exponent must be non-negative and modulus non-zero (C# throws).
    static func modPow(_ value: BigInt, _ exponent: BigInt, _ modulus: BigInt) -> BigInt {
        precondition(exponent.sign >= 0, "BigInt.modPow with a negative exponent")
        precondition(!modulus.isZero, "BigInt.modPow with a zero modulus")
        let m = modulus.parts.limbs, e = exponent.parts.limbs, v = value.parts
        let negative = v.negative && !exponent.isEven
        if m.count == 1 {
            // One-limb modulus (the common primality-test case): 128-bit products, no allocation.
            let n = m[0]
            let base = Limbs.divRem(v.limbs, n).remainder
            var result: UInt64 = 1 % n
            for i in stride(from: Limbs.bitCount(e) - 1, through: 0, by: -1) {
                result = n.dividingFullWidth(result.multipliedFullWidth(by: result)).remainder
                if Limbs.bit(e, i) { result = n.dividingFullWidth(result.multipliedFullWidth(by: base)).remainder }
            }
            return BigInt(negative: negative, limbs: [result])
        }
        let base = Limbs.divRem(v.limbs, m).remainder
        var result: [UInt64] = [1]
        for i in stride(from: Limbs.bitCount(e) - 1, through: 0, by: -1) {
            result = Limbs.divRem(Limbs.multiply(result, result), m).remainder
            if Limbs.bit(e, i) { result = Limbs.divRem(Limbs.multiply(result, base), m).remainder }
        }
        return BigInt(negative: negative, limbs: result)
    }

    /// BigInteger.GreatestCommonDivisor: non-negative, gcd(0, 0) = 0. Lehmer's algorithm on multi-limb values,
    /// finished with binary GCD once both fit a limb.
    static func gcd(_ a: BigInt, _ b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage { return BigInt(Limbs.gcd(x.magnitude, y.magnitude)) }
        var x = a.parts.limbs, y = b.parts.limbs
        if Limbs.compare(x, y) < 0 { swap(&x, &y) }
        while y.count > 1 {
            Limbs.lehmerStep(&x, &y)
            if Limbs.compare(x, y) < 0 { swap(&x, &y) }
        }
        if y.isEmpty { return BigInt(negative: false, limbs: x) }
        return BigInt(Limbs.gcd(Limbs.divRem(x, y[0]).remainder, y[0]))
    }
}

// MARK: - Bits and shifts

extension BigInt {
    /// Shifts with C# semantics: a negative count shifts the other way, and >> floors (arithmetic shift) for negatives.
    static func << (a: BigInt, count: Int) -> BigInt {
        if count < 0 { return a >> count.magnitude.clampedToInt }
        if count == 0 { return a }
        if case .small(let x) = a.storage {
            if x == 0 { return a }
            if count < 64 { let s = x &<< Int64(count); if s >> Int64(count) == x { return BigInt(s) } }
        }
        let p = a.parts
        return BigInt(negative: p.negative, limbs: Limbs.shiftLeft(p.limbs, count))
    }

    static func >> (a: BigInt, count: Int) -> BigInt {
        if count < 0 { return a << count.magnitude.clampedToInt }
        if case .small(let x) = a.storage { return BigInt(count >= 64 ? (x < 0 ? -1 : 0) : x >> Int64(count)) }
        let p = a.parts
        if !p.negative { return BigInt(negative: false, limbs: Limbs.shiftRight(p.limbs, count)) }
        // floor(−m / 2^n) = −(((m − 1) >> n) + 1)
        return BigInt(negative: true, limbs: Limbs.add(Limbs.shiftRight(Limbs.subtract(p.limbs, [1]), count), [1]))
    }

    static func <<= (a: inout BigInt, count: Int) { a = a << count }
    static func >>= (a: inout BigInt, count: Int) { a = a >> count }

    static prefix func ~ (a: BigInt) -> BigInt {
        if case .small(let x) = a.storage { return BigInt(~x) }
        return -a - .one
    }

    static func & (a: BigInt, b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage { return BigInt(x & y) }
        return bitwise(a, b, &)
    }
    static func | (a: BigInt, b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage { return BigInt(x | y) }
        return bitwise(a, b, |)
    }
    static func ^ (a: BigInt, b: BigInt) -> BigInt {
        if case .small(let x) = a.storage, case .small(let y) = b.storage { return BigInt(x ^ y) }
        return bitwise(a, b, ^)
    }
    static func &= (a: inout BigInt, b: BigInt) { a = a & b }
    static func |= (a: inout BigInt, b: BigInt) { a = a | b }
    static func ^= (a: inout BigInt, b: BigInt) { a = a ^ b }

    /// Applies `op` limb by limb to both values as sign-extended two's complement, one limb wider than either.
    private static func bitwise(_ a: BigInt, _ b: BigInt, _ op: (UInt64, UInt64) -> UInt64) -> BigInt {
        let (pa, pb) = (a.parts, b.parts)
        let width = Swift.max(pa.limbs.count, pb.limbs.count) + 1
        let (ta, tb) = (Limbs.twosComplement(pa.limbs, negative: pa.negative, width: width),
                        Limbs.twosComplement(pb.limbs, negative: pb.negative, width: width))
        var r = [UInt64](repeating: 0, count: width)
        for i in 0..<width { r[i] = op(ta[i], tb[i]) }
        let negative = r[width - 1] >> 63 == 1
        return BigInt(negative: negative, limbs: negative ? Limbs.twosComplement(r, negative: true, width: width) : r)
    }
}

private extension UInt {
    var clampedToInt: Int { self > UInt(Int.max) ? Int.max : Int(self) }
}

// MARK: - Text

extension BigInt: CustomStringConvertible {
    /// Decimal digits with a leading "-" for negatives, like ToString(CultureInfo.InvariantCulture).
    var description: String {
        if case .small(let x) = storage { return String(x) }
        let p = parts
        var digits = Limbs.decimalDigits(p.limbs)
        if p.negative { digits.insert(UInt8(ascii: "-"), at: 0) }
        return String(decoding: digits, as: UTF8.self)
    }

    /// Parses an optional leading "+" or "-" followed by ASCII decimal digits, the only input the engine hands to
    /// BigInteger.Parse; anything else (including the whitespace .NET would trim) is rejected.
    init?(_ text: String) {
        var utf8 = Substring(text).utf8[...]
        var negative = false
        if let first = utf8.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            negative = first == UInt8(ascii: "-")
            utf8 = utf8.dropFirst()
        }
        guard !utf8.isEmpty, utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if utf8.count <= 18 {
            var value: Int64 = 0
            for c in utf8 { value = value * 10 + Int64(c - 48) }
            self.init(negative ? -value : value)
            return
        }
        var limbs: [UInt64] = []
        var chunk: UInt64 = 0, chunkDigits = 0
        for c in utf8 {
            chunk = chunk * 10 + UInt64(c - 48)
            chunkDigits += 1
            if chunkDigits == 19 {
                Limbs.multiplyAdd(&limbs, Limbs.tenToThe19, chunk)
                chunk = 0; chunkDigits = 0
            }
        }
        if chunkDigits > 0 { Limbs.multiplyAdd(&limbs, Limbs.powersOfTen[chunkDigits], chunk) }
        self.init(negative: negative, limbs: limbs)
    }

    /// The magnitude's digits in radix 2, 8 or 16 (10 gives `description`), with a leading "-" for negatives.
    func toString(radix: Int, uppercase: Bool = false) -> String {
        if radix == 10 { return description }
        precondition(radix == 2 || radix == 8 || radix == 16, "BigInt.toString supports radix 2, 8, 10 and 16")
        let p = parts
        let width = radix.trailingZeroBitCount
        let count = Swift.max(1, (Limbs.bitCount(p.limbs) + width - 1) / width)
        let alphabet = Array((uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var out = [UInt8](); out.reserveCapacity(count + 1)
        if p.negative { out.append(UInt8(ascii: "-")) }
        for i in stride(from: count - 1, through: 0, by: -1) {
            out.append(alphabet[Int(Limbs.bits(p.limbs, from: i * width, count: width))])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// BigInteger.ToString("X"/"x"/"X<n>"): the shortest two's complement hex whose top nibble carries the sign,
    /// so positives gain a leading 0 when their top nibble is ≥ 8 (255 → "0FF") and negatives start at 8–F
    /// (−1 → "F", −129 → "F7F"); a precision pads on the left with 0 for positives and F for negatives.
    func formatHex(_ format: String) -> String {
        let spec = Array(format.utf8)
        precondition(!spec.isEmpty && (spec[0] == UInt8(ascii: "X") || spec[0] == UInt8(ascii: "x")), "formatHex expects X or x")
        let uppercase = spec[0] == UInt8(ascii: "X")
        let precision = spec.count > 1 ? Int(String(decoding: spec[1...], as: UTF8.self))! : 0
        let nibbles = bitLength / 4 + 1
        let negative = sign < 0
        let bits = negative ? Limbs.twosComplement(parts.limbs, negative: true, width: nibbles / 16 + 1) : parts.limbs
        let alphabet = Array((uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var out = [UInt8](repeating: negative ? alphabet[15] : alphabet[0], count: Swift.max(0, precision - nibbles))
        for i in stride(from: nibbles - 1, through: 0, by: -1) { out.append(alphabet[Int(Limbs.bits(bits, from: i * 4, count: 4))]) }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Floating point

extension BigInt {
    /// C# `new BigInteger(double)`: the value truncated toward zero, exactly; NaN and infinities overflow.
    init(truncating value: Double) throws {
        guard value.isFinite else {
            throw CalcNumericError.overflow(value.isNaN ? "The value is not a number." : "BigInteger cannot represent infinity.")
        }
        let t = value.rounded(.towardZero)
        if Swift.abs(t) < 9.223372036854775808e18 { self.init(Int64(t)); return }
        // |t| ≥ 2^63: an integer significand times a power of two.
        let significand = t.significandBitPattern | (1 << 52)
        let shifted = BigInt(significand) << (Int(t.exponent) - 52)
        self = t < 0 ? -shifted : shifted
    }

    /// C# `(double)bigInteger`: .NET keeps the top 53 bits of the magnitude and truncates the rest (2^53 + 3 →
    /// 2^53 + 2, 2^1024 − 1 → Double.MaxValue) rather than rounding; above 1024 bits it gives ±Infinity.
    func toDouble() -> Double {
        let p = parts
        let bits = Limbs.bitCount(p.limbs)
        let magnitude: Double
        if bits <= 53 {
            magnitude = Double(Limbs.bits(p.limbs, from: 0, count: 64))
        } else if bits > 1024 {
            magnitude = .infinity
        } else {
            magnitude = Double(sign: .plus, exponent: bits - 53, significand: Double(Limbs.bits(p.limbs, from: bits - 53, count: 53)))
        }
        return p.negative ? -magnitude : magnitude
    }

    /// BigInteger.Log(value): natural logarithm via .NET's formula (NaN for negatives, −∞ for zero).
    static func log(_ value: BigInt) -> Double { log(value, base: M_E) }
    /// BigInteger.Log10(value).
    static func log10(_ value: BigInt) -> Double { log(value, base: 10) }

    /// BigInteger.Log(value, base): values in Int32 range use Math.Log(double, base); larger ones split into the
    /// top 64 bits x and the bit count b as Math.Log(x, base) + (b − 64) / Math.Log(base, 2).
    static func log(_ value: BigInt, base: Double) -> Double {
        if value.sign < 0 || base == 1 { return .nan }
        if base == .infinity { return value.isOne ? 0 : .nan }
        if base == 0 && !value.isOne { return .nan }
        if case .small(let x) = value.storage, x <= Int64(Int32.max) { return NetMath.log(Double(x), base) }
        let limbs = value.parts.limbs
        let bits = Limbs.bitCount(limbs)
        let top = bits >= 64 ? Limbs.bits(limbs, from: bits - 64, count: 64) : limbs[0] << UInt64(64 - bits)
        return NetMath.log(Double(top), base) + Double(bits - 64) / NetMath.log(base, 2)
    }
}

// MARK: - Magnitude arithmetic

/// Unsigned magnitudes as little-endian [UInt64] limbs. Results are normalized (no zero top limb; zero is empty).
private enum Limbs {
    static let tenToThe19: UInt64 = 10_000_000_000_000_000_000
    static let powersOfTen: [UInt64] = (0...19).map { (0..<$0).reduce(UInt64(1)) { r, _ in r * 10 } }

    @inline(__always) static func normalize(_ a: inout [UInt64]) {
        while let last = a.last, last == 0 { a.removeLast() }
    }

    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func bitCount(_ a: [UInt64]) -> Int { a.isEmpty ? 0 : a.count * 64 - a[a.count - 1].leadingZeroBitCount }

    static func isPowerOfTwo(_ a: [UInt64]) -> Bool {
        guard let top = a.last, top & (top - 1) == 0 else { return false }
        return a.dropLast().allSatisfy { $0 == 0 }
    }

    @inline(__always) static func bit(_ a: [UInt64], _ index: Int) -> Bool { (a[index >> 6] >> UInt64(index & 63)) & 1 == 1 }

    /// `count` (≤ 64) bits starting at bit `from`, reading zeros past the end.
    static func bits(_ a: [UInt64], from: Int, count: Int) -> UInt64 {
        let limb = from >> 6, offset = UInt64(from & 63)
        guard limb < a.count else { return 0 }
        var value = a[limb] >> offset
        if offset > 0 && limb + 1 < a.count { value |= a[limb + 1] << (64 - offset) }
        return count == 64 ? value : value & ((1 << UInt64(count)) - 1)
    }

    static func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        var r = long
        r.append(0)
        var carry: UInt64 = 0
        r.withUnsafeMutableBufferPointer { r in
            for i in 0..<short.count {
                let (s1, o1) = r[i].addingReportingOverflow(short[i])
                let (s2, o2) = s1.addingReportingOverflow(carry)
                r[i] = s2
                carry = (o1 || o2) ? 1 : 0
            }
            var i = short.count
            while carry != 0 {
                (r[i], carry) = (r[i] &+ 1, r[i] == .max ? 1 : 0)
                i += 1
            }
        }
        normalize(&r)
        return r
    }

    /// a − b, requiring a ≥ b.
    static func subtract(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var r = a
        var borrow: UInt64 = 0
        r.withUnsafeMutableBufferPointer { r in
            for i in 0..<b.count {
                let (d1, o1) = r[i].subtractingReportingOverflow(b[i])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                r[i] = d2
                borrow = (o1 || o2) ? 1 : 0
            }
            var i = b.count
            while borrow != 0 {
                (r[i], borrow) = (r[i] &- 1, r[i] == 0 ? 1 : 0)
                i += 1
            }
        }
        normalize(&r)
        return r
    }

    /// Schoolbook multiplication (operands in this engine rarely exceed a few hundred limbs).
    static func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        if a.isEmpty || b.isEmpty { return [] }
        var r = [UInt64](repeating: 0, count: a.count + b.count)
        r.withUnsafeMutableBufferPointer { r in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    for i in 0..<a.count where a[i] != 0 {
                        let ai = a[i]
                        var carry: UInt64 = 0
                        for j in 0..<b.count {
                            let (hi, lo) = ai.multipliedFullWidth(by: b[j])
                            let (s1, o1) = lo.addingReportingOverflow(r[i + j])
                            let (s2, o2) = s1.addingReportingOverflow(carry)
                            r[i + j] = s2
                            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0) // hi ≤ 2^64 − 2, so this cannot wrap
                        }
                        r[i + b.count] = carry
                    }
                }
            }
        }
        normalize(&r)
        return r
    }

    /// a = a · m + c in place.
    static func multiplyAdd(_ a: inout [UInt64], _ m: UInt64, _ c: UInt64) {
        var carry = c
        for i in 0..<a.count {
            let (hi, lo) = a[i].multipliedFullWidth(by: m)
            let (s, o) = lo.addingReportingOverflow(carry)
            a[i] = s
            carry = hi &+ (o ? 1 : 0)
        }
        if carry != 0 { a.append(carry) }
    }

    /// Divides by a single limb.
    static func divRem(_ a: [UInt64], _ d: UInt64) -> (quotient: [UInt64], remainder: UInt64) {
        var q = a
        let r = divideInPlace(&q, d)
        return (q, r)
    }

    /// a = a / d in place (normalized), returning the remainder.
    @discardableResult static func divideInPlace(_ a: inout [UInt64], _ d: UInt64) -> UInt64 {
        var r: UInt64 = 0
        a.withUnsafeMutableBufferPointer { a in
            var i = a.count - 1
            while i >= 0 {
                (a[i], r) = d.dividingFullWidth((r, a[i]))
                i -= 1
            }
        }
        normalize(&a)
        return r
    }

    /// Knuth's Algorithm D (TAOCP 4.3.1) for multi-limb divisors.
    static func divRem(_ a: [UInt64], _ b: [UInt64]) -> (quotient: [UInt64], remainder: [UInt64]) {
        precondition(!b.isEmpty, "division by zero")
        if compare(a, b) < 0 { return ([], a) }
        if b.count == 1 {
            let (q, r) = divRem(a, b[0])
            return (q, r == 0 ? [] : [r])
        }
        // D1: normalize so the divisor's top bit is set; the dividend gets one extra limb.
        let shift = b[b.count - 1].leadingZeroBitCount
        let v = shiftLeft(b, shift)
        var u = shiftLeft(a, shift)
        while u.count <= a.count { u.append(0) }
        let n = v.count, m = a.count - n
        var q = [UInt64](repeating: 0, count: m + 1)
        let vTop = v[n - 1], vNext = v[n - 2]
        u.withUnsafeMutableBufferPointer { u in
            v.withUnsafeBufferPointer { v in
                for j in stride(from: m, through: 0, by: -1) {
                    // D3: estimate q̂ from the top two limbs, then correct it with the third.
                    var qhat: UInt64, rhat: UInt64, rhatOverflow = false
                    if u[j + n] >= vTop {
                        qhat = .max
                        (rhat, rhatOverflow) = u[j + n - 1].addingReportingOverflow(vTop)
                    } else {
                        (qhat, rhat) = vTop.dividingFullWidth((u[j + n], u[j + n - 1]))
                    }
                    while !rhatOverflow {
                        let (ph, pl) = qhat.multipliedFullWidth(by: vNext)
                        guard ph > rhat || (ph == rhat && pl > u[j + n - 2]) else { break }
                        qhat -= 1
                        (rhat, rhatOverflow) = rhat.addingReportingOverflow(vTop)
                    }
                    // D4: u[j…j+n] −= q̂ · v.
                    var borrow: UInt64 = 0, carry: UInt64 = 0
                    for i in 0..<n {
                        let (ph, pl) = qhat.multipliedFullWidth(by: v[i])
                        let (p, o) = pl.addingReportingOverflow(carry)
                        carry = ph &+ (o ? 1 : 0)
                        let (d1, o1) = u[i + j].subtractingReportingOverflow(p)
                        let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                        u[i + j] = d2
                        borrow = (o1 || o2) ? 1 : 0
                    }
                    let (d1, o1) = u[j + n].subtractingReportingOverflow(carry)
                    let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                    u[j + n] = d2
                    if o1 || o2 {
                        // D6: q̂ was one too large (rare); add the divisor back.
                        qhat -= 1
                        var c: UInt64 = 0
                        for i in 0..<n {
                            let (s1, a1) = u[i + j].addingReportingOverflow(v[i])
                            let (s2, a2) = s1.addingReportingOverflow(c)
                            u[i + j] = s2
                            c = (a1 || a2) ? 1 : 0
                        }
                        u[j + n] &+= c
                    }
                    q[j] = qhat
                }
            }
        }
        normalize(&q)
        var r = Array(u[0..<n])
        normalize(&r)
        return (q, shiftRight(r, shift))
    }

    static func shiftLeft(_ a: [UInt64], _ count: Int) -> [UInt64] {
        if a.isEmpty { return [] }
        let words = count >> 6, bits = UInt64(count & 63)
        var r = [UInt64](repeating: 0, count: a.count + words + 1)
        for i in 0..<a.count {
            r[i + words] |= a[i] << bits
            if bits > 0 { r[i + words + 1] = a[i] >> (64 - bits) }
        }
        normalize(&r)
        return r
    }

    static func shiftRight(_ a: [UInt64], _ count: Int) -> [UInt64] {
        let words = count >> 6, bits = UInt64(count & 63)
        if words >= a.count { return [] }
        var r = [UInt64](repeating: 0, count: a.count - words)
        for i in 0..<r.count {
            r[i] = a[i + words] >> bits
            if bits > 0 && i + words + 1 < a.count { r[i] |= a[i + words + 1] << (64 - bits) }
        }
        normalize(&r)
        return r
    }

    /// The `width`-limb two's complement of ±a (unchanged when non-negative).
    static func twosComplement(_ a: [UInt64], negative: Bool, width: Int) -> [UInt64] {
        var r = a
        if r.count < width { r.append(contentsOf: repeatElement(0, count: width - r.count)) }
        if negative {
            var carry = true
            for i in 0..<r.count {
                r[i] = ~r[i]
                if carry { (r[i], carry) = (r[i] &+ 1, r[i] == .max) }
            }
        }
        return r
    }

    /// Stein's binary GCD for single limbs.
    static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        if a == 0 { return b }
        if b == 0 { return a }
        var (a, b) = (a, b)
        let shift = (a | b).trailingZeroBitCount
        a >>= UInt64(a.trailingZeroBitCount)
        repeat {
            b >>= UInt64(b.trailingZeroBitCount)
            if a > b { swap(&a, &b) }
            b -= a
        } while b != 0
        return a << UInt64(shift)
    }

    /// One step of Lehmer's GCD (Knuth's Algorithm L) on x ≥ y > 0 with y multi-limb: simulate Euclid on the
    /// leading 62 bits, then apply the accumulated cofactors; fall back to a full division when no step is safe.
    static func lehmerStep(_ x: inout [UInt64], _ y: inout [UInt64]) {
        let shift = Swift.max(0, bitCount(x) - 62)
        var xh = Int64(bits(x, from: shift, count: 62)), yh = Int64(bits(y, from: shift, count: 62))
        var a: Int64 = 1, b: Int64 = 0, c: Int64 = 0, d: Int64 = 1
        // Cofactors stay below 2^62 in magnitude, so the sums cannot overflow; products may wrap but their
        // differences land back in range.
        while yh + c != 0 && yh + d != 0 {
            let q = (xh + a) / (yh + c)
            guard q == (xh + b) / (yh + d) else { break }
            (a, c) = (c, a &- q &* c)
            (b, d) = (d, b &- q &* d)
            (xh, yh) = (yh, xh &- q &* yh)
        }
        if b == 0 {
            (x, y) = (y, divRem(x, y).remainder)
            return
        }
        (x, y) = (combine(x, a, y, b), combine(x, c, y, d))
    }

    /// p·x + q·y for cofactors of opposite signs whose combination is known to be non-negative.
    private static func combine(_ x: [UInt64], _ p: Int64, _ y: [UInt64], _ q: Int64) -> [UInt64] {
        let px = multiply(x, p == 0 ? [] : [p.magnitude]), qy = multiply(y, q == 0 ? [] : [q.magnitude])
        if p >= 0 && q >= 0 { return add(px, qy) }
        return p >= 0 ? subtract(px, qy) : subtract(qy, px)
    }

    /// ASCII decimal digits of a non-zero magnitude: divide-and-conquer by 10^(19·2^k) above a few dozen limbs,
    /// then 19 digits per limb division.
    static func decimalDigits(_ a: [UInt64]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(a.count * 20)
        var powers: [[UInt64]] = [[tenToThe19]] // powers[k] = 10^(19·2^k)
        while powers[powers.count - 1].count * 2 <= a.count {
            let last = powers[powers.count - 1]
            powers.append(multiply(last, last))
        }
        appendDecimal(a, powers: powers, level: powers.count - 1, pad: 0, into: &out)
        return out
    }

    /// Appends the digits of `a`, left-padded with zeros to `pad` digits.
    private static func appendDecimal(_ a: [UInt64], powers: [[UInt64]], level: Int, pad: Int, into out: inout [UInt8]) {
        if a.count < 32 || level <= 0 {
            var chunks: [UInt64] = []
            var q = a
            while !q.isEmpty { chunks.append(divideInPlace(&q, tenToThe19)) }
            var text = [UInt8]()
            for (index, chunk) in chunks.reversed().enumerated() {
                var digits = Array(String(chunk).utf8)
                if index > 0 { digits.insert(contentsOf: repeatElement(UInt8(ascii: "0"), count: 19 - digits.count), at: 0) }
                text.append(contentsOf: digits)
            }
            if text.count < pad { out.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: pad - text.count)) }
            out.append(contentsOf: text)
            return
        }
        var level = level
        while level > 0 && compare(a, powers[level]) < 0 { level -= 1 }
        let width = 19 << level
        let (high, low) = divRem(a, powers[level])
        appendDecimal(high, powers: powers, level: level, pad: Swift.max(0, pad - width), into: &out)
        appendDecimal(low, powers: powers, level: level - 1, pad: width, into: &out)
    }
}
