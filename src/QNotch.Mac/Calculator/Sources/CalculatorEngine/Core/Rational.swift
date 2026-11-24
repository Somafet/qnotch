import Foundation

/// An exact reduced fraction (C# Rational). The denominator is positive; both parts stay within 4096 bits.
struct Rational: Hashable, Comparable, CustomStringConvertible {
    let numerator: BigInt
    let denominator: BigInt

    static let zero = Rational(unchecked: .zero, .one)
    static let one = Rational(unchecked: .one, .one)
    private init(unchecked numerator: BigInt, _ denominator: BigInt) { self.numerator = numerator; self.denominator = denominator }

    /// `new Rational(n, d)`: reduces; throws on a zero denominator or a part above 4096 bits.
    init(_ numerator: BigInt, _ denominator: BigInt) throws {
        if denominator.isZero { throw CalcError.arithmetic("Division by zero") }
        if numerator.bitLength > 4096 || denominator.bitLength > 4096 { throw CalcError.arithmetic("Precision limit exceeded") }
        if denominator.isOne { self.init(unchecked: numerator, .one); return }
        let gcd = BigInt.gcd(numerator, denominator)
        let n = numerator / gcd, d = denominator / gcd
        self.init(unchecked: d.sign < 0 ? -n : n, d.sign < 0 ? -d : d)
    }
    init(_ numerator: Int, _ denominator: Int) throws { try self.init(BigInt(numerator), BigInt(denominator)) }
    init(_ integer: BigInt) throws {
        if integer.bitLength > 4096 { throw CalcError.arithmetic("Precision limit exceeded") }
        self.init(unchecked: integer, .one)
    }
    /// A small integer: never throws.
    init(_ integer: Int) { self.init(unchecked: BigInt(integer), .one) }
    init(_ integer: Int64) { self.init(unchecked: BigInt(integer), .one) }

    var sign: Int { numerator.sign }
    var isZero: Bool { numerator.isZero }
    var isInteger: Bool { denominator.isOne }

    /// Rational.Parse: an optional sign, digits and at most one '.', up to 256 characters.
    static func parse(_ text: String) throws -> Rational {
        let u = text.units
        if u.isEmpty || u.count > 256 { throw CalcError.format("Invalid number") }
        let parts = text.netSplit(".")
        let unsigned = text.netTrimStart("+", "-")
        if parts.count > 2 || unsigned.isEmpty || !unsigned.utf16.contains(where: NetChar.isAsciiDigit) || unsigned.utf16.contains(where: { $0 != 0x2E && !NetChar.isAsciiDigit($0) }) {
            throw CalcError.format("Invalid number")
        }
        // BigInteger.Parse accepts one leading sign; "+-1" or "--1" reach it and fail there.
        guard let digits = BigInt(parts.joined()) else { throw CalcError.format("The value could not be parsed.") }
        return try Rational(digits, BigInt.pow(10, parts.count == 2 ? parts[1].netLength : 0))
    }

    static func + (a: Rational, b: Rational) throws -> Rational {
        if a.denominator.isOne && b.denominator.isOne { return try Rational(a.numerator + b.numerator) }
        return try Rational(a.numerator * b.denominator + b.numerator * a.denominator, a.denominator * b.denominator)
    }
    static func - (a: Rational, b: Rational) throws -> Rational {
        if a.denominator.isOne && b.denominator.isOne { return try Rational(a.numerator - b.numerator) }
        return try Rational(a.numerator * b.denominator - b.numerator * a.denominator, a.denominator * b.denominator)
    }
    static func * (a: Rational, b: Rational) throws -> Rational {
        if a.denominator.isOne && b.denominator.isOne { return try Rational(a.numerator * b.numerator) }
        return try Rational(a.numerator * b.numerator, a.denominator * b.denominator)
    }
    static func / (a: Rational, b: Rational) throws -> Rational { try Rational(a.numerator * b.denominator, a.denominator * b.numerator) }
    static prefix func - (a: Rational) -> Rational { Rational(unchecked: -a.numerator, a.denominator) }
    static func < (a: Rational, b: Rational) -> Bool { a.numerator * b.denominator < b.numerator * a.denominator }

    var abs: Rational { numerator.sign < 0 ? -self : self }

    /// Terminating decimals print exactly; repeating values keep their n/d form.
    var description: String {
        var rest = denominator
        var twos = 0, fives = 0
        while rest.isEven && !rest.isZero { rest = rest >> 1; twos += 1 }
        while (rest % 5).isZero { rest = rest / 5; fives += 1 }
        if !rest.isOne { return numerator.description + "/" + denominator.description }
        let places = max(twos, fives)
        let scaled = numerator.magnitude * BigInt.pow(2, places - twos) * BigInt.pow(5, places - fives)
        let digits = scaled.description.netPadLeft(places + 1, "0")
        let value = places == 0 ? digits : digits.netInsert(digits.netLength - places, ".").netTrimEnd("0").netTrimEnd(".")
        return numerator.sign < 0 ? "-" + value : value
    }
}
