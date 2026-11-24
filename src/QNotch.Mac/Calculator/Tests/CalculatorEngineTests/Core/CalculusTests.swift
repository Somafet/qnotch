import XCTest
@testable import CalculatorEngine

final class CalculusTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try MathSheet.line(source) }
    private func value(_ source: String) throws -> SheetValue { try MathSheet.value(source) }
    private func double(_ source: String) throws -> Double {
        try MathSheet.double(try value(source).number.with { $0.isApproximate = false; $0.displayDecimalPlaces = nil }.display)
    }

    func testPublishedReferenceExamples() throws {
        try theory([("integral(x^2, 0, 3)", "9"), ("derivative(x^3, 2)", "12")]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testExactAndNumericContracts() throws {
        try theory([
            ("integral(2x + 1, 1, 4)", "18"), ("integral(x, 3, 0)", "-4.5"), ("integral(x^2, 0, sqrt(2))^2", "8/9"), ("integral(t^2, 0, 3, t)", "9"),
            ("k = 2\nintegral(k*x, 0, 3)", "9"), ("x = 100\nintegral(x, 0, 2)", "2"), ("integral(x^2, 1, 1)", "0"), ("integral(sin(x), 1, 1)", "≈ 0"),
            ("integral(sin(x), 0, pi)", "≈ 2"), ("integral(1/x, 1, e)", "≈ 1"), ("derivative(t^3, 2, t)", "12"), ("derivative(3x^2 - 2x + 7, 5)", "28"),
            ("derivative(sin(x), 0)", "≈ 1"), ("derivative(ln(x), 2)", "≈ 0.5"), ("derivative(sqrt(x), 4)", "≈ 0.25"), ("derivative(abs(x), -2)", "≈ -1"),
            ("derivative(x^x, 1)", "≈ 1"), ("derivative(tan(x), 0)", "≈ 1"), ("derivative(exp(2x), 0)", "≈ 2"), ("a = sin(1)\nintegral(a*x, 0, 2)", "≈ 1.682941969616"),
            ("sin(0)", "≈ 0"), ("cos(pi)", "≈ -1"), ("exp(1)", "≈ 2.71828182846"), ("ln(e)", "≈ 1"), ("log(1000)", "≈ 3"), ("tanh(0)", "≈ 0"), ("sqrt(2)", "sqrt(2)"),
            ("abs(-3)", "3"), ("sin(50%)", "≈ 0.479425538604"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testAnalyticValuesWithinTolerance() throws {
        try theory([
            ("integral(exp(x), 0, 1)", 1.718281828459045), ("integral(cos(x), 0, 2)", 0.9092974268256817), ("derivative(sin(x^2), 1)", 1.0806046117362795),
            ("derivative(x*sin(x), 1)", 1.3817732906760363), ("derivative(exp(x), 1)", 2.718281828459045), ("atan(1)*4", 3.141592653589793),
            ("asin(0.5)*6", 3.141592653589793), ("cosh(1)^2 - sinh(1)^2", 1),
        ]) { source, expected in MathSheet.inRange(try double(source), expected - 1e-9, expected + 1e-9, source) }
    }
    func testNumericResultsAreMarkedApproximateWithMethodDisclosure() throws {
        let integral = try MathSheet.last("integral(sin(x), 0, pi)")
        XCTAssertTrue(try XCTUnwrap(integral.value).number.isApproximate); XCTAssertTrue(integral.explanation.last?.assumption?.contains("Gauss-Kronrod") == true)
        let derivative = try MathSheet.last("derivative(sin(x), 0)")
        XCTAssertTrue(derivative.explanation.last?.assumption?.contains("cos(x)") == true)
        XCTAssertFalse(try value("integral(x^2, 0, 3)").number.isApproximate); XCTAssertFalse(try value("derivative(x^3, 2)").number.isApproximate)
        XCTAssertTrue(try value("a = sin(1)\nintegral(a*x, 0, 2)").number.isApproximate)
    }
    func testDomainAndGrammarErrors() throws {
        try theory([
            "integral(1/x, -1, 1)", "integral(1/x, 0, 1)", "integral(sin(1000x), 0, 1000)", "integral(x, 0, 1 m)", "integral(x^2, 0)", "integral(x^2, 0, 1, 2)",
            "integral(sin(x), 0, 10^400)", "integral(y, 0, 1)", "derivative(x)", "derivative(ln(x), 0)", "derivative(abs(x), 0)", "derivative(x^2, 1 m)", "asin(2)",
            "ln(0)", "sin(1 m)", "sin(1, 2)", "solutionRoot(sin(1), 1)",
        ]) { source in XCTAssertNotNil(try last(source).error, source) }
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let definitions = [FunctionDefinition(name: "area", parameters: ["b"], body: "integral(x^2, 0, b)"), FunctionDefinition(name: "slope", parameters: ["p"], body: "derivative(x^3, p)"),
                           FunctionDefinition(name: "wave", parameters: ["t"], body: "sin(t) * 2")]
        let library = try FunctionLibrary(definitions)
        XCTAssertEqual(library.minimumCatalogVersion, FunctionLibrary.formulaCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("area(3)\nslope(2)\nwave(0)", library, []).results
        XCTAssertEqual(results.map(\.display), ["9", "12", "≈ 0"])
        let update = try FunctionUpdate.prepare("area(b) = integral(x^2, 0, b)", .empty, [])
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("area(3)", update.library, []).results[0].display, "9")
        XCTAssertEqual(try FunctionLibrary([FunctionDefinition(name: "plain", parameters: ["v"], body: "v + 1")]).minimumCatalogVersion, 1)
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "unbound", parameters: ["b"], body: "integral(x^2, 0, q)")]) }
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "sin", parameters: ["v"], body: "v")]) }
    }
    func testCancellationAndStepBudgetApply() throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        MathSheet.throwsError(.cancelled) { try SheetEvaluator.evaluate("integral(sin(x), 0, 1)", cancellation) }
        let definitions = (0..<12).map { i in FunctionDefinition(name: "f\(i)", parameters: ["x"], body: i == 0 ? "integral(sin(t), 0, x, t)" : "f\(i - 1)(x)+f\(i - 1)(x)") }
        let values = try SheetEvaluationSession().evaluateWithFunctions("f11(1)", try FunctionLibrary(definitions), []).results
        XCTAssertEqual(values[0].error, "Expression step limit exceeded")
    }
    // Expected values are the powers themselves: 2^20 = 1048576, 2^50 = 1125899906842624, 3^20 = 3486784401, 10^20 / 2 = 5 * 10^19.
    func testConstantPowersInFormulasKeepTheirTrueExponent() throws {
        try theory([
            ("solve x = 2^20", "x = 1048576"), ("solve x = 10^18", "x = 1000000000000000000"), ("solve x^2 = 2^100", "x = -1125899906842624 or x = 1125899906842624"),
            ("solve x = (-2)^21", "x = -2097152"), ("integral(2^20, 0, 1)", "1048576"), ("integral(10^20 * x, 0, 1)", "50000000000000000000"),
            ("integral((1/2)^20, 0, 1)", "0.00000095367431640625"), ("derivative(x * 3^20, 1)", "3486784401"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testScientificNotationInFormulasIsAnErrorNotEuler() throws {
        try theory(["solve x^2 - 1e-10 = 0", "integral(1e-10 + x, 0, 1)", "derivative(3e*x, 0)", "solve x = 2.5E3"]) { source in
            XCTAssertTrue(try last(source).error?.contains("Scientific notation") == true, source)
        }
    }
    func testExplicitEulerAndAUserVariableNamedEStillWork() throws {
        MathSheet.inRange(try double("integral(2*e, 0, 1)"), 2 * M_E - 1e-9, 2 * M_E + 1e-9)
        XCTAssertEqual(try value("e = 2\nsolve x = 3e").display, "x = 6")
    }
}
