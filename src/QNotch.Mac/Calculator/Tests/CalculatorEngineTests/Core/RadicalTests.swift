import XCTest
@testable import CalculatorEngine

final class RadicalTests: XCTestCase {
    func testExactIndependentFixtures() throws {
        let cases = try JSONNode.parse(Fixtures.data("radicals-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let source = try item.property("source").string(), expected = try item.property("expected").string()
            let results = try SheetEvaluator.evaluate(source)
            for result in results { XCTAssertNil(result.error, source) }
            XCTAssertEqual(results.last!.display, expected, source)
            let answer = try XCTUnwrap(results.last!.value)
            let pasted = try SheetEvaluator.evaluate(try answer.display)[0]
            XCTAssertNil(pasted.error); XCTAssertEqual(pasted.value, answer, source)
        }
    }
    func testRationalAccessorNeverApproximatesARadical() throws {
        let value = try XCTUnwrap(try SheetEvaluator.evaluate("sqrt(2)")[0].value)
        XCTAssertFalse(value.isRational)
        XCTAssertThrowsError(try value.scalar) { XCTAssertTrue(($0 as? CalcError)?.isArithmetic == true) }
        XCTAssertTrue(NumericValue().isRational); XCTAssertEqual(try NumericValue().display, "0")
    }
    func testCanonicalValuesSupportHashingAndIncrementalDependencies() throws {
        let a = try XCTUnwrap(try SheetEvaluator.evaluate("sqrt(8)")[0].value), b = try XCTUnwrap(try SheetEvaluator.evaluate("2*sqrt(2)")[0].value)
        XCTAssertEqual(a, b); XCTAssertEqual(a.hashValue, b.hashValue)
        let session = SheetEvaluationSession()
        _ = try session.evaluate("a=sqrt(2)\na^2\n7")
        let changed = try session.evaluate("a=sqrt(3)\na^2\n7")
        XCTAssertEqual(changed[1].display, "3"); XCTAssertEqual(changed[1].dependencies, [0])
        XCTAssertGreaterThan(session.lastStatistics.reusedResults, 0)
        XCTAssertTrue(changed[1].explanation.contains { $0.operation == "^" && $0.result == "3" })
        let failed = try session.evaluate("a=sqrt(-1 m^2)\na^2\n7")
        XCTAssertNil(failed[1].value); XCTAssertNotNil(failed[1].error)
    }
    func testPersistentFunctionsKeepRadicalArgumentsAndResultsExact() throws {
        let update = try FunctionUpdate.prepare("f(x)=x*x\ng(x)=sqrt(x)", .empty, [])
        let results = try SheetEvaluationSession().evaluateWithFunctions("f(sqrt(7))\ng(8)", update.library, []).results
        XCTAssertEqual(results.map(\.display), ["7", "2*sqrt(2)"])
    }
    func testSeededRootsAndConjugatesSatisfyIndependentIntegerIdentities() throws {
        var random = NetRandom(2047)
        for _ in 0..<250 {
            let n = random.next(1, 1000), d = random.next(1, 1000), a = random.next(1, 30)
            let square = try SheetEvaluator.evaluate("sqrt(\(n)/\(d))^2")[0]
            XCTAssertNil(square.error); XCTAssertEqual(try square.value?.scalar, try Rational(n, d))
            let norm = try SheetEvaluator.evaluate("(\(a)+sqrt(\(n)))*(\(a)-sqrt(\(n)))")[0]
            XCTAssertNil(norm.error); XCTAssertEqual(try norm.value?.scalar, Rational(a * a - n))
        }
    }
    func testIndependentNestedFieldsRationalizeWithoutLosingTerms() throws {
        for denominator in ["sqrt(2)+sqrt(3)+sqrt(5)", "1+sqrt(6)+sqrt(10)+sqrt(15)", "1+sqrt(2)+sqrt(3)+sqrt(6)", "sqrt(30)+sqrt(42)+sqrt(70)+sqrt(105)"] {
            let result = try SheetEvaluator.evaluate("(1/(\(denominator)))*(\(denominator))")[0]
            XCTAssertNil(result.error); XCTAssertEqual(result.display, "1")
        }
    }
    func testSeededMixedFieldDivisionAndAssociativityRemainExact() throws {
        var random = NetRandom(8242)
        let roots = [2, 3, 5, 6, 7, 10, 14, 15, 21]
        for _ in 0..<150 {
            let a = random.next(1, 8), b = roots[random.next(roots.count)], c = roots[random.next(roots.count)]
            let denominator = "\(a)+sqrt(\(b))+sqrt(\(c))"
            let answer = try SheetEvaluator.evaluate("(\(denominator))/(\(denominator))")[0]
            XCTAssertNil(answer.error); XCTAssertEqual(answer.display, "1")
            let identity = try SheetEvaluator.evaluate("(sqrt(\(b))+sqrt(\(c)))*\(a)-(\(a)*sqrt(\(b))+\(a)*sqrt(\(c)))")[0]
            XCTAssertNil(identity.error); XCTAssertEqual(identity.display, "0")
        }
    }
    func testIndependentDecimalSquareBoundsAgreeWithExplicitRounding() throws {
        for n in 2..<200 {
            var floor = 0
            while (floor + 1) * (floor + 1) <= n * 10000 { floor += 1 }
            let rounded = 4 * n * 10000 >= (2 * floor + 1) * (2 * floor + 1) ? floor + 1 : floor
            let answer = try SheetEvaluator.evaluate("sqrt(\(n)) to 2 decimals")[0]
            XCTAssertNil(answer.error); XCTAssertEqual(try answer.value?.scalar, try Rational(rounded, 100))
        }
    }
    func testCloseRoundingBoundariesAreComparedExactly() throws {
        var p = BigInt.one, q = BigInt.one
        for _ in 0..<60 {
            (p, q) = (p + 2 * q, p + q)
            let expected = p * p > 2 * q * q ? "1" : "2"
            XCTAssertEqual(try SheetEvaluator.evaluate("1.5+sqrt(2)-\(p)/\(q) to 0 decimals")[0].display, expected)
        }
    }
    func testInvalidDomainsAndExhaustedFactorBudgetsHaveNoValue() throws {
        try theory(["sqrt(-1 m^2)", "1/(sqrt(2)-sqrt(2))", "sqrt(2)!", "2^sqrt(2)", "sqrt(1+sqrt(2))", "sqrt(2+sqrt(2)+sqrt(3))", "sqrt(2) to sqrt(2) decimals",
                    "sqrt(2) to nearest -sqrt(3)", "sqrt(2)% to nearest sqrt(3)", "sqrt(100000000000000000000000000000000000003)"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
    func testLargePerfectSquaresBypassFactoringAndCancellationPropagates() throws {
        let answer = try SheetEvaluator.evaluate("sqrt(10^1000)")[0]
        XCTAssertNil(answer.error); XCTAssertEqual(try answer.value?.scalar, try Rational(BigInt.pow(10, 500)))
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("sqrt(100000000000000000003)", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        let many = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137].map { "sqrt(\($0))" }.joined(separator: "+")
        XCTAssertNotNil(try SheetEvaluator.evaluate(many)[0].error)
    }
    func testFactoringConsumesTheSharedSheetBudgetWithoutCommittingPartialCaches() throws {
        let session = SheetEvaluationSession()
        _ = try session.evaluate("sqrt(2)\nprev^2"); let before = session.lastStatistics
        XCTAssertThrowsError(try session.evaluate(Array(repeating: "sqrt(1000000007)", count: 40).joined(separator: "\n"))) { XCTAssertEqual($0 as? CalcError, .computationLimit) }
        XCTAssertEqual(session.lastStatistics, before)
        XCTAssertEqual(try session.evaluate("sqrt(2)\nprev^2")[1].display, "2")
        XCTAssertEqual(session.lastStatistics.reusedResults, 2)
    }
}
