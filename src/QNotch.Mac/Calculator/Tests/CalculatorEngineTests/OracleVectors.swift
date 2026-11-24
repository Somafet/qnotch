import Foundation
import XCTest
@testable import CalculatorEngine

/// Reads Vectors/DotNetOracle.txt (written by Tools/NetOracle) and regenerates its inputs: the edge values below and
/// the same splitmix64 streams, so this file must stay in step with Tools/NetOracle/Program.cs.
enum Oracle {
    static let sections: [String: [String]] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vectors/DotNetOracle.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var sections: [String: [String]] = [:], current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.isEmpty && line.hasPrefix("#") { continue } // header comment; later '#' lines are compacted results
            if line.hasPrefix("@") { current = String(line.dropFirst()); sections[current] = [] } else if !current.isEmpty { sections[current]!.append(String(line)) }
        }
        for key in sections.keys where sections[key]!.last == "" { sections[key]!.removeLast() }
        return sections
    }()

    static func lines(_ section: String) -> [String] {
        let lines = sections[section] ?? []
        XCTAssertFalse(lines.isEmpty, "Missing oracle section " + section)
        return lines
    }

    /// Checks readable lines (tab-separated, long results compacted) and reports each differing field.
    static func checkReadable(_ section: String, _ results: [[String]], file: StaticString = #filePath, line: UInt = #line) -> Int {
        let expected = lines(section)
        XCTAssertEqual(expected.count, results.count, section + " case count", file: file, line: line)
        var passed = 0
        for (index, (want, got)) in zip(expected, results).enumerated() {
            let wanted = want.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let actual = got.map(compact)
            if wanted == actual { passed += 1; continue }
            let fields = zip(wanted, actual).enumerated().filter { $0.element.0 != $0.element.1 }.map { "field \($0.offset): .NET \($0.element.0) Swift \($0.element.1)" }
            XCTFail("\(section) #\(index) (\(actual.first ?? "")): " + fields.joined(separator: "; ") + (wanted.count != actual.count ? " (field count \(wanted.count) vs \(actual.count))" : ""), file: file, line: line)
        }
        return passed
    }

    /// Checks hashed lines; on a mismatch prints Swift's results so they can be diffed against the oracle's verbose file.
    static func checkHashed(_ section: String, _ results: [[String]], file: StaticString = #filePath, line: UInt = #line) -> Int {
        let expected = lines(section)
        XCTAssertEqual(expected.count, results.count, section + " case count", file: file, line: line)
        var passed = 0, failures = 0
        for (index, (want, got)) in zip(expected, results).enumerated() {
            if hex(fnv(got.joined(separator: "\n"))) == want { passed += 1; continue }
            failures += 1
            if failures <= 10 { XCTFail("\(section) #\(index) differs from .NET; Swift gave: " + got.map(compact).joined(separator: " | "), file: file, line: line) }
        }
        if failures > 10 { XCTFail("\(section): \(failures) cases differ in total", file: file, line: line) }
        return passed
    }

    static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return hash
    }
    static func hex(_ value: UInt64) -> String { let digits = String(value, radix: 16); return String(repeating: "0", count: 16 - digits.count) + digits }
    static func compact(_ text: String) -> String { text.count > 40 ? "#" + hex(fnv(text)) : text }
    static func d(_ x: Double) -> String { x.isNaN ? "NaN" : hex(x.bitPattern) }
    static func b(_ value: Bool) -> String { value ? "true" : "false" }

    // MARK: BigInt cases (mirror Program.cs)

    static func p2(_ n: Int) -> BigInt { BigInt.one << n }
    static let edges: [BigInt] = [
        0, 1, -1, 2, -2, 7, -7, 10, 127, 128, -128, -129, 255, 256, -256, BigInt(Int64(Int32.max)), BigInt(Int64(Int32.min)), BigInt(Int64(UInt32.max)),
        p2(32), -p2(32), BigInt(Int64.max), BigInt(Int64.min), BigInt(Int64.min) - 1, p2(63), BigInt(UInt64.max), p2(64),
        p2(64) + 1, -p2(64), -p2(64) - 1, -(p2(64) - 1), p2(53), p2(53) + 1, p2(53) + 3, -(p2(53) + 3), p2(128),
        p2(128) - 1, -p2(128), p2(1023), p2(1024) - 1, p2(1024), -p2(1024), BigInt.pow(10, 19),
        BigInt.pow(10, 38), BigInt.pow(10, 100), 1 - BigInt.pow(10, 100), p2(4096) - 1, -p2(4095),
    ]

    static func truncate(_ value: BigInt, _ bits: Int) -> BigInt { value >> max(0, value.bitLength - bits) }

    static func unary(_ a: BigInt, shift: Int, hexWidth: Int, power: Int) -> [String] {
        [
            a.description, (-a).description, BigInt.abs(a).description, (~a).description, String(a.sign),
            b(a.isZero), b(a.isOne), b(a.isEven), String(a.bitLength), String(a.byteCount()),
            a.sign >= 0 ? String(a.byteCount(isUnsigned: true)) : "-", String(a.trailingZeroCount),
            a.formatHex("X"), a.formatHex("x"), a.formatHex("X" + String(hexWidth)),
            (a << shift).description, (a >> shift).description, d(a.toDouble()), d(BigInt.log(a)), d(BigInt.log10(a)),
            a.int64Value.map { String($0) } ?? "overflow", BigInt.pow(a, power).description,
        ]
    }

    static func binary(_ a: BigInt, _ b: BigInt, exponent: BigInt, modulus: BigInt) -> [String] {
        var results = [(a + b).description, (a - b).description, (a * b).description]
        if b.isZero {
            results += ["-", "-"]
        } else {
            let (q, r) = a.quotientAndRemainder(dividingBy: b)
            results += [q.description, r.description]
        }
        results += [BigInt.gcd(a, b).description, (a & b).description, (a | b).description, (a ^ b).description,
                    String(BigInt.compare(a, b)), Oracle.b(a == b), modulus.isZero ? "-" : BigInt.modPow(a, exponent, modulus).description]
        return results
    }

    static func randomBig(_ r: inout SplitMix64) -> BigInt {
        let kind = r.next() % 16
        if kind == 0 { return edges[Int(r.next() % UInt64(edges.count))] }
        let bits: Int
        if kind <= 4 {
            bits = Int(r.next() % 65)
        } else if kind <= 13 {
            let value = r.next() // C# evaluates the dividend before the divisor's own draw
            bits = Int(value % ((1 << (r.next() % 13)) + 1))
        } else {
            bits = 4096 + Int(r.next() % 1000)
        }
        let magnitude: BigInt
        switch r.next() % 8 {
        case 0: magnitude = p2(bits) - 1
        case 1: magnitude = p2(bits)
        case 2: magnitude = p2(bits) + BigInt(Int(r.next() % 3)) - 1
        default:
            let limbs = (0..<(bits + 63) / 64).map { _ in r.next() }
            magnitude = BigInt(negative: false, limbs: limbs) & (p2(bits) - 1)
        }
        return r.next() & 1 == 1 ? -magnitude : magnitude
    }

    // MARK: Double and Int64 cases

    static let doubleFormats = ["", "R", "G", "G1", "G2", "G3", "G4", "G6", "G15", "G17", "E", "E0", "E1", "E3", "E10", "E15",
                                "N", "N0", "N1", "N3", "F", "F0", "F1", "F2", "F4", "F10", "0.##", "0.###", "0.00", "0.0", "0.#E+0", "00", "0", "e3", "g5", "r"]
    static let tens: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]
    static let edgeDoubles: [Double] = [0.0, -0.0, 1, -1, 0.1, 0.125, 0.375, 0.5, 1.5, 2.5, -2.5, 2.675, 1.005, 4.35, 1.25, 1.35, 0.0625,
        9.5, 8.5, 12345.5, 123.456, 1e15, 1e16, 1e17, 1e20, 1e21, 1e23, 1.5e-5, 0.0001, 0.00001, 5e-324, .greatestFiniteMagnitude,
        -.greatestFiniteMagnitude, 2.2250738585072014E-308, .nan, .infinity, -.infinity, -0.001, -0.004,
        -0.4, 0.6, 0.06, 0.96, 0.005, 0.015, 1234567890123445, 1234567890123455, 0.1 + 0.2, 1 / 3.0, 2 / 3.0, 100, 1e-7, 9.995,
        0.995, 999999.5, 0.49999999999999994, 4503599627370497, 9007199254740992, 1e16 + 2, 123456789.125, -1e-10, 7e22, 1e22]

    static func randomDouble(_ r: inout SplitMix64) -> Double {
        var value: Double
        switch r.next() % 8 {
        case 0: value = edgeDoubles[Int(r.next() % UInt64(edgeDoubles.count))]
        case 1: value = Double(bitPattern: r.next())
        case 2: let k = Int64(r.next() % 2000001) - 1000000; value = Double(k) / tens[Int(r.next() % 12)]
        case 3: let m = Int64(r.next() % 100000); value = Double(2 * m + 1) / Double(Int64(1) << (r.next() % 10 + 1))
        case 4: let v = r.next(); value = Double(Int64(bitPattern: v >> (r.next() % 64)))
        case 5:
            let mantissa = Double(r.next() >> 11) * (1.0 / 9007199254740992.0)
            let e = Int(r.next() % 45)
            value = e < 22 ? mantissa / tens[22 - e] : mantissa * tens[e - 22]
        case 6: let k = Int64(r.next() % 100000); value = (Double(k) + 0.5) / tens[Int(r.next() % 6)]
        default: value = Double(bitPattern: r.next() % (1 << 53))
        }
        return r.next() & 1 == 1 ? -value : value
    }

    static func doubleResults(_ x: Double, digits: Int) -> [String] {
        doubleFormats.map { NetFormat.double(x, $0) } + [
            d(NetMath.round(x)), d(NetMath.round(x, awayFromZero: true)), d(NetMath.round(x, digits)),
            d(NetMath.round(x, digits, awayFromZero: true)), (try? BigInt(truncating: x))?.description ?? "overflow",
        ]
    }

    static let longFormats = ["", "D", "D1", "D3", "D5", "D19", "D25", "X", "X2", "X4", "x", "x8", "X16", "X20", "N0", "N", "N2", "00", "0", "000", "0.00", "0.#"]
    static let edgeLongs: [Int64] = [0, 1, -1, 5, -5, 9, 10, 99, 100, 999, 1000, -1000, 1234567, -1234567, 65535, 65536, Int64(Int32.max), Int64(Int32.min), .max, .min]
    static func longResults(_ value: Int64) -> [String] { longFormats.map { NetFormat.integer(value, $0) } }
}

/// splitmix64, mirrored by Tools/NetOracle.
struct SplitMix64 {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
