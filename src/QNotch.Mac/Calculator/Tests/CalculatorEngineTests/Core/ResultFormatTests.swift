import XCTest
@testable import CalculatorEngine

final class ResultFormatTests: XCTestCase {
    private let context = EvaluationContext(today: DateOnly(2027, 1, 5))
    private func line(_ source: String) throws -> LineResult { try SheetEvaluator.evaluate(source, context: context)[0] }
    private func show(_ source: String, _ format: ResultFormat) throws -> String {
        let line = try line(source); XCTAssertNil(line.error, source)
        return try ResultFormatter.format(line, format)
    }
    private let period = try! NumberStyle.fromId("period", .invariant)
    private let comma = try! NumberStyle.fromId("comma", .invariant)

    func testDefaultFormatIsTheCanonicalDisplayForEveryKind() throws {
        let source = ["1/3", "2^70", "12.5%", "5 km + 300 m", "1234.567 EUR", "2027-01-05 + 3 days", "09:00 + 90 min", "c", "sqrt(8)",
                      "0xFF", "192.0.2.1/24", "[1, 2.5, 3]", "[[1,2],[3,4]]", "text(\"a.b,c 1234\")", "x = 4", "x * 1000", "1234.5 to 2 decimals"].joined(separator: "\n")
        for line in try SheetEvaluator.evaluate(source, context: context) { XCTAssertEqual(try ResultFormatter.format(line, .default), line.display) }
    }
    /// Independent oracle: half away from zero with integer arithmetic, then the invariant shortest decimal.
    private func roundOracle(_ p: BigInt, _ q: BigInt, _ places: Int) -> String {
        let scale = BigInt.pow(10, places)
        let magnitude = (p.magnitude * scale * 2 + q) / (2 * q)
        if magnitude.isZero { return "0" }
        let digits = magnitude.description.netPadLeft(places + 1, "0")
        let text = places == 0 ? digits : (String(digits.dropLast(places)) + "." + String(digits.suffix(places))).netTrimEnd("0").netTrimEnd(".")
        return (p.sign < 0 ? "-" : "") + text
    }
    func testDecimalPlacesRoundDisplayedFractionsAgainstAnIndependentOracle() throws {
        var random = NetRandom(5005)
        for _ in 0..<400 {
            let q = random.next(2, 5000); let p = random.next(-2_000_000, 2_000_000)
            if p == 0 { continue }
            let places = random.next(0, 9)
            XCTAssertEqual(try show("\(p)/\(q)", ResultFormat(places)), roundOracle(BigInt(p), BigInt(q), places))
        }
    }
    func testSeparatorsMatchDotNetGroupingForRoundedValues() throws {
        var random = NetRandom(611)
        for (style, group, separator) in [(period, ".", ","), (comma, ",", "."), (try NumberStyle.fromId("space", .invariant), NumberStyle.space, ","), (try NumberStyle.fromId("apostrophe", .invariant), "'", ".")] {
            for _ in 0..<200 {
                let q = random.next(1, 400); let p = random.next(-900_000_000, 900_000_000) * random.next(1, 1000)
                if abs(p) < q { continue }
                let places = random.next(0, 7)
                // decimal.Round(p / q, places, AwayFromZero).ToString("#,0.###…") with these separators.
                let rounded = try roundAwayFromZero(Rational(p, q), places: places)
                let plain = rounded.description, negative = plain.hasPrefix("-")
                let unsigned = negative ? String(plain.dropFirst()) : plain
                let parts = unsigned.netSplit(".")
                var integer = parts[0], grouped = ""
                while integer.count > 3 { grouped = group + String(integer.suffix(3)) + grouped; integer = String(integer.dropLast(3)) }
                let expected = (negative ? "-" : "") + integer + grouped + (parts.count > 1 ? separator + parts[1] : "")
                XCTAssertEqual(try show("\(p)/\(q)", ResultFormat(places, style)), expected)
            }
        }
    }
    func testPeriodStyleRewritesOnlyTheMagnitude() throws {
        try theory([("1234567.891", "1.234.567,891"), ("-1234.5", "-1.234,5"), ("12345.5%", "12.345,5%"), ("1234.5 km", "1.234,5 km"), ("1234.5 m^2", "1.234,5 m^2"),
                    ("12345/7", "12345/7"), ("sqrt(20000)", "100*sqrt(2)"), ("999", "999")]) { source, expected in
            XCTAssertEqual(try show(source, ResultFormat(nil, period)), expected)
        }
    }
    func testMoneyKeepsMinorUnitsAndCurrencyCode() throws {
        let plain = try show("1234567.5 EUR", .default)
        XCTAssertEqual(plain, "1234567.5 EUR")
        XCTAssertEqual(try show("1234567.5 EUR", ResultFormat(nil, period)), "1.234.567,5 EUR")
        XCTAssertEqual(try show("10 EUR / 3", ResultFormat(nil, period)), "3,33 EUR")
        XCTAssertEqual(try show("1234567.5 EUR", ResultFormat(0)), plain)
    }
    func testConstantNotationGroupsAndExponentsFollowTheStyle() throws {
        let light = try show("c", .default)
        XCTAssertEqual(try show("c", ResultFormat(nil, period)), light.netReplace(",", "."))
        let planck = try show("planck", .default)
        XCTAssertTrue(planck.contains("e-34"))
        XCTAssertEqual(try show("planck", ResultFormat(nil, period)), planck.netReplace(".", ","))
    }
    func testStructuredValuesKeepTheirCanonicalForm() throws {
        let style = ResultFormat(2, period)
        for source in ["2027-01-05 + 3 days", "09:00 + 90 min", "192.0.2.1/24", "0xFFFF", "[1.25, 2.5]", "text(\"1234.5\")", "[[1.5,2],[3,4]]"] {
            let line = try line(source); XCTAssertNil(line.error, source)
            XCTAssertEqual(try ResultFormatter.format(line, style), line.display, source)
        }
    }
    func testDomainPrecisionOutranksThePreferenceAndValuesStayExact() throws {
        let approximate = SheetValue.number(NumericValue(try Rational(1, 3)).with { $0.displayDecimalPlaces = 4 })
        XCTAssertEqual(try ResultFormatter.format(approximate, ResultFormat(1)), "0.3333")
        XCTAssertEqual(try show("1.23456789 to 4 decimals", ResultFormat(1)), "1.2")
        let line = try line("1/3")
        XCTAssertEqual(try ResultFormatter.format(line, ResultFormat(2)), "0.33")
        XCTAssertEqual(line.display, "1/3")
        XCTAssertEqual(try line.value?.copyText, "1/3")
        XCTAssertEqual(try line.value?.scalar, try Rational(1, 3))
    }
    func testErrorsAndDeclarationsAreNotFormatted() throws {
        let results = try SheetEvaluator.evaluate("f(x) = x * 12345.678\nunknownThing + 1", context: context)
        XCTAssertNil(results[0].value)
        XCTAssertEqual(try ResultFormatter.format(results[0], ResultFormat(2, period)), results[0].display)
        XCTAssertNotNil(results[1].error)
        XCTAssertEqual(try ResultFormatter.format(results[1], ResultFormat(2, period)), results[1].display)
    }
    func testSystemStyleReadsTheRegionalFormat() throws {
        try theory([("en-US", ",", Character(".")), ("de-DE", ".", ","), ("fr-FR", NumberStyle.space, ","), ("ja-JP", ",", "."), ("ro-RO", ".", ",")]) { culture, group, separator in
            let style = try NumberStyle.fromId("system", RegionalNumberFormat(Locale(identifier: culture)))
            XCTAssertEqual(style.groupSeparator, group, culture); XCTAssertEqual(style.decimalSeparator, separator, culture)
        }
    }
    func testInvalidStylesAndPrecisionAreRejected() throws {
        XCTAssertThrowsError(try NumberStyle(",", ","))
        XCTAssertThrowsError(try NumberStyle("_", "."))
        XCTAssertThrowsError(try NumberStyle("", ";"))
        XCTAssertThrowsError(try NumberStyle.fromId("roman", .invariant))
        XCTAssertThrowsError(try ResultFormatter.format(try line("1"), ResultFormat(ResultFormat.maxDecimalPlaces + 1))) { XCTAssertTrue(($0 as? CalcError)?.isArgument == true) }
        XCTAssertEqual(comma.example, "1,234.56")
    }
}
