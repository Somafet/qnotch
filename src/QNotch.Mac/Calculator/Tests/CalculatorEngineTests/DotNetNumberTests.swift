import XCTest
@testable import CalculatorEngine

/// Math.Round and Double/Int64 formatting against .NET (InvariantCulture): oracle vectors plus targeted checks.
final class DotNetNumberTests: XCTestCase {
    func testEdgeDoublesMatchDotNet() {
        let passed = Oracle.checkReadable("double-edge", Oracle.edgeDoubles.map { [Oracle.d($0)] + Oracle.doubleResults($0, digits: 2) })
        print("double-edge: \(passed) oracle vectors passed")
    }

    func testRandomDoublesMatchDotNet() {
        var r = SplitMix64(0x51A7_C0DE_0002)
        var results: [[String]] = []
        for _ in 0..<4000 {
            let x = Oracle.randomDouble(&r)
            results.append([Oracle.d(x)] + Oracle.doubleResults(x, digits: Int(r.next() % 16)))
        }
        let passed = Oracle.checkHashed("double-random", results)
        print("double-random: \(passed) oracle vectors passed")
    }

    func testEdgeLongsMatchDotNet() {
        let passed = Oracle.checkReadable("long-edge", Oracle.edgeLongs.map { [String($0)] + Oracle.longResults($0) })
        print("long-edge: \(passed) oracle vectors passed")
    }

    func testRandomLongsMatchDotNet() {
        var r = SplitMix64(0x51A7_C0DE_0003)
        var results: [[String]] = []
        for _ in 0..<1500 {
            let raw = r.next()
            var value = Int64(bitPattern: raw >> (r.next() % 64))
            if r.next() & 1 == 1 { value = 0 &- value }
            results.append([String(value)] + Oracle.longResults(value))
        }
        let passed = Oracle.checkHashed("long-random", results)
        print("long-random: \(passed) oracle vectors passed")
    }

    func testDoubleFormatting() {
        XCTAssertEqual(NetFormat.double(1e20, nil), "1E+20")
        XCTAssertEqual(NetFormat.double(1.5e-5, "R"), "1.5E-05")
        XCTAssertEqual(NetFormat.double(1e16, nil), "10000000000000000")
        XCTAssertEqual(NetFormat.double(-0.0, nil), "-0")
        XCTAssertEqual(NetFormat.double(.infinity, nil), "Infinity")
        XCTAssertEqual(NetFormat.double(-.infinity, "0.##"), "-Infinity")
        XCTAssertEqual(NetFormat.double(.nan, "E"), "NaN")
        XCTAssertEqual(NetFormat.double(123.456, "E"), "1.234560E+002")
        XCTAssertEqual(NetFormat.double(123.456, "G4"), "123.5")
        XCTAssertEqual(NetFormat.double(12345.5, "G3"), "1.23E+04")
        XCTAssertEqual(NetFormat.double(1234567.891, "N"), "1,234,567.89")
        XCTAssertEqual(NetFormat.double(0.125, "F2"), "0.12") // standard formats: exact value, ties to even
        XCTAssertEqual(NetFormat.double(0.125, "0.##"), "0.13") // custom formats: 15 digits, then half up
        XCTAssertEqual(NetFormat.double(4.35, "0.0"), "4.4")
        XCTAssertEqual(NetFormat.double(0.0625, "0.#E+0"), "6.3E-2")
        XCTAssertEqual(NetFormat.double(-0.001, "0.##"), "-0")
        XCTAssertEqual(NetFormat.double(0.5, "00"), "01")
        XCTAssertEqual(NetFormat.double(1e23, "F0"), "99999999999999991611392")
        XCTAssertEqual(NetFormat.double(.greatestFiniteMagnitude, "0.##"), "179769313486232" + String(repeating: "0", count: 294))
    }

    func testIntegerFormatting() {
        XCTAssertEqual(NetFormat.integer(-5, "D3"), "-005")
        XCTAssertEqual(NetFormat.integer(-5, "X4"), "FFFFFFFFFFFFFFFB")
        XCTAssertEqual(NetFormat.integer(255, "x4"), "00ff")
        XCTAssertEqual(NetFormat.integer(-5, "00"), "-05")
        XCTAssertEqual(NetFormat.integer(Int64.min, "N0"), "-9,223,372,036,854,775,808")
        XCTAssertEqual(NetFormat.integer(1234, ""), "1234")
    }

    func testMathRound() {
        XCTAssertEqual(NetMath.round(2.5), 2)
        XCTAssertEqual(NetMath.round(-0.4).sign, .minus)
        XCTAssertEqual(NetMath.round(2.675, 2), 2.68)
        XCTAssertEqual(NetMath.round(1.005, 2), 1)
        XCTAssertEqual(NetMath.round(1.005, 2, awayFromZero: true), 1)
        XCTAssertEqual(NetMath.round(0.285, 2, awayFromZero: true), 0.28)
        XCTAssertEqual(NetMath.round(0.5, awayFromZero: true), 1)
        XCTAssertEqual(NetMath.round(-2.5, awayFromZero: true), -3)
        XCTAssertEqual(NetMath.round(0.49999999999999994, awayFromZero: true), 0)
        XCTAssertEqual(NetMath.round(1e16 + 2, 2), 1e16 + 2)
    }
}
