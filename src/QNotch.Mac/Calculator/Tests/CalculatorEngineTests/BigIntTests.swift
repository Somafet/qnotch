import XCTest
@testable import CalculatorEngine

/// BigInt against System.Numerics.BigInteger: differential vectors from Tools/NetOracle plus targeted checks.
final class BigIntTests: XCTestCase {
    func testEdgeValuesMatchDotNet() {
        let results = Oracle.edges.map { Oracle.unary($0, shift: 5, hexWidth: 24, power: 3) }
            + Oracle.edges.map { Oracle.unary($0, shift: -70, hexWidth: 0, power: 0) }
        let passed = Oracle.checkReadable("bigint-edge-unary", results)
        print("bigint-edge-unary: \(passed) oracle vectors passed")
    }

    func testEdgePairsMatchDotNet() {
        var results: [[String]] = []
        for a in Oracle.edges {
            for b in Oracle.edges { results.append(Oracle.binary(a, b, exponent: Oracle.truncate(BigInt.abs(a), 160), modulus: Oracle.truncate(b, 1100))) }
        }
        let passed = Oracle.checkHashed("bigint-edge-binary", results)
        print("bigint-edge-binary: \(passed) oracle vectors passed")
    }

    func testRandomValuesMatchDotNet() {
        var r = SplitMix64(0x51A7_C0DE_0001)
        var results: [[String]] = []
        for _ in 0..<2500 {
            let a = Oracle.randomBig(&r), b = Oracle.randomBig(&r), c = Oracle.randomBig(&r)
            let shift = Int(r.next() % 401) - 200, hexWidth = Int(r.next() % 40)
            let power = Int(r.next() % (a.bitLength <= 64 ? 40 : 4))
            results.append(Oracle.unary(a, shift: shift, hexWidth: hexWidth, power: power)
                + Oracle.binary(a, b, exponent: Oracle.truncate(BigInt.abs(b), 160), modulus: Oracle.truncate(c, 1100)))
        }
        let passed = Oracle.checkHashed("bigint-random", results)
        print("bigint-random: \(passed) oracle vectors passed")
    }

    /// The oracle parses with NumberStyles.AllowLeadingSign: a sign and ASCII digits, nothing else.
    func testParsingMatchesDotNet() {
        let texts = ["0", "-0", "+0", "+17", "-17", "007", "-0009223372036854775808", "9223372036854775808",
                     "123456789012345678901234567890", "-99999999999999999999", "1" + String(repeating: "0", count: 400), "", "-", "+", " 1", "1 ", "1_0",
                     "0x10", "1e3", "--1", "+-1", "١٢", "12a"]
        let passed = Oracle.checkReadable("bigint-parse", texts.map { [$0, BigInt($0)?.description ?? "invalid"] })
        print("bigint-parse: \(passed) oracle vectors passed")
    }

    func testDotNetSpecificSemantics() throws {
        XCTAssertEqual([0, 1, -1, -2, -128, -129].map { BigInt($0).bitLength }, [0, 1, 0, 1, 7, 8])
        XCTAssertEqual(BigInt.zero.trailingZeroCount, 32) // .NET quirk: the width of its inline int
        XCTAssertEqual(BigInt(-8).trailingZeroCount, 3)
        XCTAssertEqual(BigInt.zero.byteCount(), 1)
        XCTAssertEqual(BigInt(255).byteCount(), 2)
        XCTAssertEqual(BigInt(255).byteCount(isUnsigned: true), 1)
        // (double)BigInteger truncates instead of rounding.
        XCTAssertEqual(BigInt("9007199254740995")!.toDouble(), 9007199254740994)
        XCTAssertEqual(((BigInt.one << 1024) - 1).toDouble(), .greatestFiniteMagnitude)
        XCTAssertEqual((-(BigInt.one << 1024)).toDouble(), -.infinity)
        XCTAssertEqual(BigInt.log(.zero), -.infinity)
        XCTAssertTrue(BigInt.log(-1).isNaN)
        XCTAssertEqual(BigInt.log10(1000), 2.9999999999999996)
        // Hex: shortest two's complement whose top nibble carries the sign.
        XCTAssertEqual([255, 1, 0, -1, -8, -16, -128, -129].map { BigInt($0).formatHex("X") }, ["0FF", "1", "0", "F", "8", "F0", "80", "F7F"])
        XCTAssertEqual(BigInt(-1).formatHex("x4"), "ffff")
        XCTAssertEqual(BigInt(255).formatHex("x4"), "00ff")
        XCTAssertEqual((-(BigInt.one << 64)).formatHex("X"), "F0000000000000000")
        // Truncated division, floor shifts, ModPow signs.
        XCTAssertEqual(BigInt(-7).quotientAndRemainder(dividingBy: 2).quotient, -3)
        XCTAssertEqual(BigInt(-7) % 2, -1)
        XCTAssertEqual(BigInt(7) % -2, 1)
        XCTAssertEqual(BigInt(-5) >> 1, -3)
        XCTAssertEqual(BigInt(-5) >> 100, -1)
        XCTAssertEqual(BigInt(5) << -1, 2)
        XCTAssertEqual(BigInt(5) >> -2, 20)
        XCTAssertEqual(BigInt.modPow(-7, 3, 5), -3)
        XCTAssertEqual(BigInt.modPow(7, 3, -5), 3)
        XCTAssertEqual(BigInt.modPow(-7, 0, 1), 0)
        XCTAssertEqual(BigInt.gcd(0, 0), 0)
        XCTAssertEqual(BigInt.gcd(BigInt(Int64.min), 0), BigInt(UInt64(1) << 63))
        XCTAssertEqual(BigInt(Int64.min) / -1, BigInt(UInt64(1) << 63))
        XCTAssertEqual(try BigInt(truncating: -0.9), 0)
        XCTAssertEqual(try BigInt(truncating: -1.9e300).description.count, 302)
        XCTAssertThrowsError(try BigInt(truncating: .nan))
        XCTAssertThrowsError(try BigInt(truncating: -.infinity))
    }

    func testCanonicalRepresentation() {
        let a = BigInt(negative: false, limbs: [5, 0, 0]), b = BigInt(5)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(BigInt(negative: true, limbs: [1 << 63]), BigInt(Int64.min))
        XCTAssertEqual(BigInt(negative: true, limbs: []), .zero)
        XCTAssertEqual((BigInt(Int64.max) + 1) - 1, BigInt(Int64.max))
        XCTAssertEqual(Set([BigInt.one << 70, (BigInt.one << 71) / 2]).count, 1)
        XCTAssertEqual(BigInt(Int64.min).int64Value, .min)
        XCTAssertNil((BigInt(Int64.max) + 1).int64Value)
        XCTAssertEqual(BigInt(42).intValue, 42)
    }

    func testTextRoundTripsAndRadixes() {
        var r = SplitMix64(7)
        for _ in 0..<300 {
            let value = Oracle.randomBig(&r)
            XCTAssertEqual(BigInt(value.description), value)
            let hex = value.toString(radix: 16, uppercase: true)
            let magnitudeHex = value.magnitude.formatHex("X")
            XCTAssertEqual(hex, (value.sign < 0 ? "-" : "") + (magnitudeHex.count > 1 && magnitudeHex.hasPrefix("0") ? String(magnitudeHex.dropFirst()) : magnitudeHex))
        }
        XCTAssertEqual(BigInt(10).toString(radix: 2), "1010")
        XCTAssertEqual(BigInt(-8).toString(radix: 8), "-10")
        XCTAssertEqual(BigInt(255).toString(radix: 16), "ff")
        XCTAssertEqual(BigInt.zero.toString(radix: 2), "0")
        let factorial = (1...3000).reduce(BigInt.one) { $0 * BigInt($1) } // ~30,000 bits
        XCTAssertEqual(BigInt(factorial.description), factorial)
        XCTAssertEqual(factorial.description.count, 9131)
    }

    /// Limbs built from 0, 1, 2^63 ± 1 and 2^64 − 1 reach the rare branches of Knuth's division (q̂ corrections and
    /// the add-back step) that random values almost never do; DivRem and GCD are checked by their defining properties.
    func testDivisionAndGcdInvariantsOnStructuredLimbs() {
        let patterns: [UInt64] = [0, 1, 2, 1 << 32, (1 << 63) - 1, 1 << 63, (1 << 63) + 1, .max - 1, .max]
        var r = SplitMix64(2024)
        func structured() -> BigInt {
            let limbs = (0..<Int(r.next() % 6 + 1)).map { _ in patterns[Int(r.next() % UInt64(patterns.count))] }
            return r.next() & 1 == 1 ? -BigInt(negative: false, limbs: limbs) : BigInt(negative: false, limbs: limbs)
        }
        for _ in 0..<20_000 {
            let a = structured(), b = structured()
            guard !b.isZero else { continue }
            let (q, rem) = a.quotientAndRemainder(dividingBy: b)
            XCTAssertEqual(q * b + rem, a)
            XCTAssertLessThan(BigInt.abs(rem), BigInt.abs(b))
            XCTAssertTrue(rem.isZero || rem.sign == a.sign)
            let g = BigInt.gcd(a, b)
            XCTAssertTrue((a % g).isZero && (b % g).isZero)
            XCTAssertEqual(BigInt.gcd(a / g, b / g), 1)
        }
    }

    func testPerformance() {
        var start = Date()
        var x = BigInt(1), y = BigInt(7), acc = BigInt.zero
        for i in 0..<50_000 {
            x = (x * 31 + BigInt(i)) % 1_000_000_007
            y = BigInt.gcd(x, y + 12)
            acc += x / (y + 1) - (x & 0xFFFF)
        }
        let small = Date().timeIntervalSince(start)
        XCTAssertNotEqual(acc, -1)

        var r = SplitMix64(99)
        let words = (0..<64).map { _ in r.next() }
        let a = BigInt(negative: false, limbs: words), b = BigInt(negative: false, limbs: words.reversed()) + 1
        start = Date()
        var g = BigInt.zero
        for i in 0..<100 { g += BigInt.gcd(a + BigInt(i), b * 3) }
        let gcd = Date().timeIntervalSince(start)

        start = Date()
        let big = BigInt.pow(3, 40_000) // ~63,000 bits
        let text = big.description
        let format = Date().timeIntervalSince(start)
        XCTAssertEqual(BigInt(text), big)

        print(String(format: "BigInt timings: 200k small ops %.3fs, 100 × 4096-bit gcd %.3fs, 63k-bit pow+toString %.3fs", small, gcd, format))
        XCTAssertLessThan(small, 1)
        XCTAssertLessThan(gcd, 1)
        XCTAssertLessThan(format, 1)
    }
}
