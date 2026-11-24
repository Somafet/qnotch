import XCTest
@testable import CalculatorEngine

final class RoundingTests: XCTestCase {
    func testExactFixtures() throws {
        let cases = try JSONNode.parse(Fixtures.data("rounding-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let source = try item.property("input").string(), expected = try item.property("expected").string()
            XCTAssertEqual(try number(source).display, expected, source)
        }
    }
    func testInvalidInputsNeverPublishANumber() throws {
        try theory(["2 to -1 decimals", "2 to 257 decimals", "2 to 2.5 decimals", "2 to 2% decimals", "2 to 0 sig figs", "2 to 257 sig figs", "0 to 0 sig figs",
                    "0 to -1 decimals", "2 to nearest 0", "2 to nearest -1", "2 to nearest 1%", "2% to nearest 1", "2 to nearest", "2 to 2", "2 to 2 sig",
                    "2 to 2 significant", "2 to 2 decimals + 1", "2 to nearest 0.5 + 1", "2 to (2^1000) decimals"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]
            XCTAssertNotNil(result.error, source); XCTAssertNil(result.value, source)
        }
    }
    func testDecimalRoundingMatchesIndependentDecimalArithmetic() throws {
        var random = NetRandom(7519)
        for _ in 0..<1000 {
            let value = try Rational(random.next(-10_000_000, 10_000_001), 1000)
            let places = random.next(0, 7)
            let expected = try roundAwayFromZero(value, places: places)
            XCTAssertEqual(try number("\(value) to \(places) decimals").scalar, expected)
        }
    }
    func testIncrementRoundingMatchesDecimalAndPreservesGridAndErrorBounds() throws {
        var random = NetRandom(3814)
        let steps = try [Rational(1, 100), Rational(5, 100), Rational(25, 100), Rational(25, 10), Rational(7), Rational(3, 1000)]
        for _ in 0..<500 {
            let value = try Rational(random.next(-1_000_000, 1_000_001), 1000); let step = steps[random.next(steps.count)]
            let source = "\(value) to nearest \(step)"
            let rounded = try number(source).scalar
            let expected = try roundAwayFromZero(value / step) * step
            XCTAssertEqual(rounded, expected, source)
            let quantum = step
            XCTAssertEqual(try (rounded / quantum).denominator, BigInt.one)
            let error = try rounded - value
            XCTAssertTrue(error.numerator.magnitude * quantum.denominator * 2 <= quantum.numerator * error.denominator)
            XCTAssertEqual(try number("(\(source)) to nearest \(step)").scalar, rounded)
        }
    }
    func testSignificantFiguresMatchAnIndependentDecimalScaleOracle() throws {
        var random = NetRandom(8291)
        for _ in 0..<500 {
            let value = try Rational(random.next(-1_000_000, 1_000_001), 10_000_000)
            if value.isZero { continue }
            let figures = random.next(1, 7); var normalized = value.abs; var scale = Rational.one
            while normalized >= Rational(10) { normalized = try normalized / Rational(10); scale = try scale * Rational(10) }
            while normalized < Rational.one { normalized = try normalized * Rational(10); scale = try scale / Rational(10) }
            for _ in 1..<max(1, figures) { scale = try scale / Rational(10) }
            let expected = try roundAwayFromZero(value / scale) * scale
            XCTAssertEqual(try number("\(value) to \(figures) sig figs").scalar, expected)
        }
    }
    func testVariablesFunctionsAndExplanationsRetainTypedRounding() throws {
        let source = "places=2\ncost to date=12.375\ncost to date to places decimals\nround(x)=x*2\nrounded(x,p)=x to p decimals\nrounded(12.345%,2)\nround(3)\n100+L6"
        let results = try SheetEvaluator.evaluate(source)
        XCTAssertEqual(results[2].display, "12.38"); XCTAssertEqual(results[2].dependencies, [0, 1])
        XCTAssertEqual(results[5].display, "12.35%"); XCTAssertTrue(results[5].value!.isPercentage)
        XCTAssertEqual(results[6].display, "6"); XCTAssertEqual(results[7].display, "112.35")
        XCTAssertTrue(results[2].explanation.contains { $0.operation == "round to decimal places" && $0.assumption!.contains("away from zero") })
        XCTAssertTrue(results[5].explanation.contains { $0.assumption?.hasPrefix("rounded(") == true })
    }
    func testRoundedAggregatesExcludeThemselvesAndSeparatePrecisionDependencies() throws {
        let results = try SheetEvaluator.evaluate("places=2\n# Costs\n1.234 #x\n2.345 #x\nsum to places decimals #x\naverage to 3 sig figs #x\nsum")
        XCTAssertEqual(results[4].display, "3.58"); XCTAssertEqual(results[4].dependencies, [0, 2, 3])
        XCTAssertEqual(results[5].display, "1.79"); XCTAssertEqual(results[6].display, "3.579")
    }
    func testAggregateMembershipChangesInvalidateCacheEvenWhenUnionOfDependenciesIsUnchanged() throws {
        let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluate("places=2 #x\n1.234 #x\nsum to places decimals #x")[2].display, "3.23")
        XCTAssertEqual(try session.evaluate("places=2\n1.234 #x\nsum to places decimals #x")[2].display, "1.23")
        let changed = try session.evaluate("places=1\n1.234 #x\nsum to places decimals #x")
        XCTAssertEqual(changed[2].display, "1.2")
        XCTAssertEqual(session.lastStatistics.reusedResults, 1)
    }
    func testVeryLargeAndSmallRationalValuesKeepExactMagnitudeAndBounds() throws {
        XCTAssertEqual(try number("(2^1000 + 1) to 3 sig figs").scalar, try Rational(BigInt(107) * BigInt.pow(10, 299)))
        XCTAssertEqual(try number("(1/(2^1000+1)) to 3 sig figs").scalar, try Rational(BigInt(933), BigInt.pow(10, 304)))
        XCTAssertEqual(try number("((2^1000+1)/2^1000) to 256 sig figs").display, "1")
        XCTAssertEqual(try number("(1/(2^1000+1)) to 256 decimals").display, "0")
        XCTAssertEqual(try SheetEvaluator.evaluate("(1/((2^1023)^4+1)) to 256 sig figs")[0].error, "Precision limit exceeded")
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("(1/3) to 256 sig figs", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
