import XCTest
@testable import CalculatorEngine

final class EquationTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try MathSheet.line(source) }
    private func value(_ source: String) throws -> SheetValue { try MathSheet.value(source) }
    private func double(_ value: SheetValue) throws -> Double {
        try MathSheet.double(try value.number.with { $0.isApproximate = false; $0.displayDecimalPlaces = nil }.display)
    }

    func testPublishedReferenceExamples() throws {
        try theory([("solve 2x + 3 = 11", "x = 4"), ("solve x^2 - 5x + 6 = 0", "x = 2 or x = 3"), ("solve cos(x) = x", "x ≈ 0.7391")]) { source, display in
            XCTAssertEqual(try value(source).display, display, source)
        }
    }
    func testDottieNumberIsBracketedToPublishedDigits() throws {
        let root = try value("roots = solve cos(x) = x\nsolutionRoot(roots, 1)")
        XCTAssertTrue(try root.number.isApproximate); MathSheet.inRange(try double(root), 0.7390851332 - 1e-9, 0.7390851332 + 1e-9)
        let equation = try value("solve cos(x) = x").equation
        XCTAssertEqual(equation.scope, .bracketedRoots); XCTAssertEqual(try equation.copyText, "x ≈ 0.739085133215")
        XCTAssertTrue(equation.details.netLower.contains("claim of completeness")); XCTAssertTrue(equation.summary.hasPrefix("Approximate:"))
        XCTAssertTrue(try last("solve cos(x) = x").explanation.last!.assumption!.hasPrefix("Approximate input/result"))
    }
    func testVietaAndSubstitutionHoldForExactRoots() throws {
        let values = try SheetEvaluator.evaluate("q = solve x^2 - 5x + 6 = 0\nsolutionRoot(q,1) + solutionRoot(q,2)\nsolutionRoot(q,1) * solutionRoot(q,2)\nsolutionCount(q)\nr = solve x^2 = 2\nsolutionRoot(r,2)^2\nr")
        XCTAssertEqual(values[1...3].map(\.display), ["5", "6", "2"])
        XCTAssertEqual(values[5].display, "2"); XCTAssertEqual(values[6].display, "x = -sqrt(2) or x = sqrt(2)")
        XCTAssertTrue(values[1].dependencies.map { $0 + 1 }.contains(1)); XCTAssertEqual(values[0].display, "x = 2 or x = 3")
    }
    func testPolynomialNumericAndSentenceContracts() throws {
        try theory([
            ("solve x^3 - 6x^2 + 11x - 6 = 0", "x = 1 or x = 2 or x = 3"), ("solve x^2 - 2x + 1 = 0", "x = 1"), ("solve x^3 - 4x^2 + 5x - 2 = 0", "x = 1 or x = 2"),
            ("solve x^3 = 2", "x ≈ 1.2599"), ("solve x^4 - 5x^2 + 4 = 0", "x = -2 or x = -1 or x = 1 or x = 2"), ("solve x^2 + 1 = 0", "No real solutions"),
            ("solve x = x", "All real x"), ("solve 1 = 2", "No real solutions"), ("solve 2(x+1) = 8", "x = 3"), ("solve x(x - 1) = 0", "x = 0 or x = 1"),
            ("solve 3t = 12 for t", "t = 4"), ("solve 2y + 1 = 7 for y from 0 to 10", "y = 3"), ("solve y^2 = 9 for y from 0 to 5", "y = 3"),
            ("solve x^2 = 4 from 0 to 5", "x = 2"), ("solve x^2 = 2 from 0 to 2", "x = sqrt(2)"), ("solve sin(x) = 0 from 1 to 4", "x ≈ 3.1416"),
            ("solve exp(x) = 0", "No root found"), ("solve tan(x) = 0 from 1 to 2", "No root found"), ("solve x = pi", "x ≈ 3.1416"), ("x = 5\nsolve x^2 = 9", "x = -3 or x = 3"),
            ("a = 3\nb = 12\nsolve a*x = b", "x = 4"), ("solve = 5\nsolve + 1", "6"), ("1\nsolve x = 2\n3\nsum", "4"), ("pi", "≈ 3.14159265358979"), ("e = 2\n2*e", "4"),
        ]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testCubeRootIsEnclosedAndMarkedApproximate() throws {
        let equation = try value("solve x^3 = 2").equation
        XCTAssertEqual(equation.roots.count, 1); let root = equation.roots[0]
        XCTAssertTrue(root.value.isApproximate); XCTAssertNotNil(root.lower)
        MathSheet.inRange(try double(.number(root.value)), 1.25992104989 - 1e-9, 1.25992104989 + 1e-9)
        XCTAssertEqual(equation.scope, .allRealRoots)
    }
    func testNumericScanReportsCountTruncationAndNotProof() throws {
        let values = try SheetEvaluator.evaluate("s = solve sin(x) = 0\nsolutionCount(s)\nmany = solve sin(100x) = 0\nsolutionCount(many)\nnone = solve exp(x) = 0")
        XCTAssertEqual(values[1].display, "7"); XCTAssertTrue(values[0].display.hasPrefix("x ≈ -9.4248 or")); XCTAssertTrue(values[0].display.hasSuffix("… (7 roots)"))
        XCTAssertEqual(values[3].display, "16"); XCTAssertTrue(try XCTUnwrap(values[2].value).equation.truncated)
        XCTAssertTrue(try XCTUnwrap(values[2].value).equation.details.contains("narrow the domain"))
        XCTAssertTrue(try XCTUnwrap(values[4].value).equation.details.contains("not proof"))
    }
    func testSheetVariablesAreDependenciesAndProseIsUntouched() throws {
        let values = try SheetEvaluator.evaluate("rate = 0.5\nsolve rate * x = 3\nsolve the problem")
        XCTAssertEqual(values[1].display, "x = 6"); XCTAssertEqual(values[1].dependencies, [0])
        XCTAssertNil(values[2].error); XCTAssertNil(values[2].value)
        // A user variable named solve wins: the sentence is disabled for that sheet and the line is an ordinary error.
        let shadowed = try SheetEvaluator.evaluate("solve = 7\nsolve 2x = 4\nsolve * 2")
        XCTAssertNotNil(shadowed[1].error); XCTAssertEqual(shadowed[2].display, "14")
    }
    func testInvalidEquationsAreErrors() throws {
        try theory([
            "solve x =", "solve x = 1 = 2", "solve foo(x) = 1", "solve x = 1 from 5 to 1", "solve x^2 = 4 for 2", "solve 1/0 = x", "solve x = 1 m", "solve x! = 1",
            "r = solve x = 2\nr + 1", "solutionRoot(1, 1)", "r = solve x = 2\nsolutionRoot(r, 2)", "r = solve x = x\nsolutionCount(r)", "solutionCount()", "solve x = 2 for x from 0",
        ]) { source in XCTAssertNotNil(try last(source).error, source) }
    }
    func testSavedFunctionsSolveAndCanonicalize() throws {
        let update = try FunctionUpdate.prepare("roots(c) = solve x^2 = c\nfirstRoot(c) = solutionRoot(roots(c), 1)", .empty, [])
        XCTAssertEqual(update.library.minimumCatalogVersion, FunctionLibrary.formulaCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("roots(9)\nfirstRoot(9)", update.library, []).results
        XCTAssertEqual(results[0].display, "x = -3 or x = 3"); XCTAssertEqual(results[1].display, "-3")
        XCTAssertEqual(update.library.fingerprint, try FunctionLibrary(update.library.definitions).fingerprint)
        MathSheet.throwsFormat { try FunctionLibrary([FunctionDefinition(name: "bad", parameters: ["c"], body: "solve x^2 = d")]) }
    }
    func testCancellationAndSharedBudgetApply() throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        MathSheet.throwsError(.cancelled) { try SheetEvaluator.evaluate("solve cos(x) = x", cancellation) }
        MathSheet.throwsError(.computationLimit) { try SheetEvaluator.evaluate(Array(repeating: "solve sin(x) = 0.1", count: 300).joined(separator: "\n")) }
        XCTAssertEqual(try value("solve 2x + 3 = 11").display, "x = 4")
    }
    // sqrt(10^-10) = 10^-5, ln(1.00001) = 9.99995e-6 and cbrt(2) * 10^-5 = 1.259921e-5, each shown to four significant digits.
    func testSmallApproximateRootsKeepSignificantDigits() throws {
        try theory([("solve x^2 = 10^-10", "x ≈ -0.00001 or x ≈ 0.00001"), ("solve exp(x) = 1.00001", "x ≈ 0.00001"), ("solve x^3 = 2/10^15", "x ≈ 0.0000126"),
                    ("solve x^3 = 2", "x ≈ 1.2599")]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
    func testEmptyDomainResultNamesTheDomain() throws {
        try theory([("solve 2x = 4 from 0 to 1", "No real solutions in the domain"), ("solve x = 5 from 0 to 10%", "No real solutions in the domain"),
                    ("solve 2x = 4", "x = 2"), ("solve x^2 + 1 = 0", "No real solutions")]) { source, display in XCTAssertEqual(try value(source).display, display, source) }
    }
}
