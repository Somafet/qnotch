import XCTest
@testable import CalculatorEngine

final class EvaluatorTests: XCTestCase {
    func testExactArithmetic() throws {
        try theory([("0.1 + 0.2", "0.3"), ("2 + 3 * 4", "14"), ("(2 + 3) * 4", "20"), ("-2 * -3", "6"), ("120 * 15%", "18"), ("120 * (1 - 15%)", "102"),
                    ("100 + 10%", "110"), ("1 / 3 * 3", "1"), ("1 / 3", "1/3"), (".5 + .25", "0.75")]) { source, expected in
            XCTAssertEqual(try SheetEvaluator.evaluate(source)[0].display, expected, source)
        }
    }
    func testFailedAssignmentsInvalidateOlderValue() throws {
        let results = try SheetEvaluator.evaluate("a=2\na=1/0\na+1")
        XCTAssertEqual(results[1].error, "Division by zero")
        XCTAssertEqual(results[2].error, "Dependency L2 unavailable")
    }
    func testInvalidInputHasNoValue() throws {
        try theory(["2 +", "2 3", "2 + typo", "1..2", "(1"]) { source in XCTAssertNotNil(try SheetEvaluator.evaluate(source)[0].error, source) }
    }
    func testLimitsAndCancellation() throws {
        XCTAssertNotNil(try SheetEvaluator.evaluate(String(repeating: "(", count: 100) + "1")[0].error)
        XCTAssertThrowsError(try SheetEvaluator.evaluate(String(repeating: "1", count: 200001))) { XCTAssertTrue(($0 as? CalcError)?.isArgument == true) }
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("1+1", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(try SheetEvaluator.evaluate(Array(repeating: "1+1", count: 10000).joined(separator: "\n")).count, 10000)
    }
    func testRationalIdentities() throws {
        for n in -50...50 { for d in 1...50 {
            let value = try Rational(n, d)
            XCTAssertEqual(try value * Rational(d), Rational(n))
            XCTAssertEqual(try value - value, Rational.zero)
        } }
    }
}
