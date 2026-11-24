import XCTest
@testable import CalculatorEngine

/// xUnit `Assert.Equal(double expected, double actual, int precision)`: both sides rounded with Math.Round(value, precision).
func assertEqual(_ expected: Double, _ actual: Double, precision: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(NetMath.round(expected, precision), NetMath.round(actual, precision), "expected \(expected), actual \(actual) \(message)", file: file, line: line)
}

final class PlotTests: XCTestCase {
    private func last(_ source: String, _ token: CancellationToken = .none) throws -> LineResult { try SheetEvaluator.evaluate(source, token).last! }
    private func plot(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> PlotValue {
        let result = try last(source)
        XCTAssertNil(result.error, source, file: file, line: line)
        guard let value = result.value else { throw AssertionFailure(description: "\(source): no value") }
        return try value.plot
    }
    private func segments(_ plot: PlotValue) -> [(start: Double, end: Double)] {
        plot.segmentStarts.enumerated().map { i, start in (plot.x[start], plot.x[(i + 1 < plot.segmentStarts.count ? plot.segmentStarts[i + 1] : plot.x.count) - 1]) }
    }

    func testPublishedFormsPlotTheirDomain() throws {
        try theory([("plot sin(x)", -10.0, 10.0), ("plot x^2 from -2 to 2", -2, 2), ("plot X^2 FROM 0 TO 1", 0, 1)]) { source, lower, upper in
            let plot = try plot(source)
            XCTAssertEqual(lower, plot.x[0]); XCTAssertEqual(upper, plot.x[plot.x.count - 1])
            XCTAssertEqual("plot", try last(source).display)
        }
    }
    func testPointsStayBoundedOrderedAndFinite() throws {
        try theory(["plot sin(x)", "plot tan(x)", "plot 1/x", "plot sin(20x)", "plot tan(100x)", "plot ln(x)"]) { source in
            let plot = try plot(source)
            MathSheet.inRange(Double(plot.x.count), 2, Double(PlotValue.maxPoints), source)
            XCTAssertEqual(plot.x.count, plot.y.count)
            XCTAssertTrue(plot.y.allSatisfy(\.isFinite))
            XCTAssertTrue(zip(plot.x, plot.x.dropFirst()).allSatisfy { $0 < $1 })
            XCTAssertEqual(0, plot.segmentStarts[0])
        }
    }
    func testSamplesLieOnTheFormula() throws {
        let plot = try plot("plot x^2 from -2 to 2")
        for (x, y) in zip(plot.x, plot.y) { assertEqual(x * x, y, precision: 12) }
        XCTAssertEqual([0], plot.segmentStarts)
        assertEqual(0, plot.yLower, precision: 12); assertEqual(4, plot.yUpper, precision: 12)
        XCTAssertFalse(plot.yLimited)
    }
    func testTangentBreaksAtEachPoleAndKeepsUsableLimits() throws {
        let plot = try plot("plot tan(x)")
        // Poles of tan on [-10, 10] are (k + 1/2)pi for k from -3 to 2.
        let poles = (-3..<3).map { (Double($0) + 0.5) * Double.pi }
        let segments = segments(plot)
        XCTAssertEqual(poles.count + 1, segments.count)
        guard segments.count == poles.count + 1 else { return }
        for i in poles.indices { XCTAssertTrue(segments[i].end < poles[i] && poles[i] < segments[i + 1].start, "pole \(poles[i])") }
        XCTAssertTrue(plot.yLimited)
        MathSheet.inRange(plot.yUpper, 1, 20); MathSheet.inRange(plot.yLower, -20, -1)
        XCTAssertTrue(plot.y.max()! > plot.yUpper * 10)
    }
    func testReciprocalBreaksAtZero() throws {
        let segments = segments(try plot("plot 1/x from -1 to 3"))
        XCTAssertEqual(2, segments.count)
        XCTAssertTrue(segments[0].end < 0 && segments[1].start > 0)
    }
    func testJumpWithoutPoleBreaksOnce() throws {
        // abs(x)/x is the sign function: -1 below zero, +1 above, undefined at zero.
        let plot = try plot("plot abs(x)/x from -1 to 2")
        XCTAssertEqual(2, plot.segmentStarts.count)
        assertEqual(-1, plot.yLower, precision: 12); assertEqual(1, plot.yUpper, precision: 12)
    }
    func testContinuousSteepCurvesStayOneSegment() throws {
        try theory(["plot atan(1000x) from -1 to 1", "plot tanh(50x) from -1 to 1", "plot abs(x) from -1 to 1", "plot exp(x)"]) { source in
            XCTAssertEqual(1, try plot(source).segmentStarts.count, source)
        }
    }
    func testContinuousGrowthKeepsItsWholeRange() throws {
        let plot = try plot("plot exp(x)")
        XCTAssertFalse(plot.yLimited)
        assertEqual(Foundation.exp(10), plot.yUpper, precision: 6)
    }
    func testDomainEdgeIsRefinedTowardItsLimit() throws {
        let plot = try plot("plot sqrt(x) from -4 to 4")
        XCTAssertEqual(1, plot.segmentStarts.count)
        // The grid step is 1/32; eight halvings reach 1/8192 from the true edge at zero.
        MathSheet.inRange(plot.x[0], 0, 1.0 / 4096)
        assertEqual(2, plot.yUpper, precision: 12)
    }
    func testConstantCurveStillHasAVerticalRange() throws {
        let plot = try plot("plot x - x + 5 from 0 to 1")
        XCTAssertTrue(plot.yLower < 5 && plot.yUpper > 5)
    }
    func testSheetNamesAreConstantsAndRecalculate() throws {
        let plot = try plot("a = 3\nplot a*x from 0 to 2")
        assertEqual(6, plot.y[plot.y.count - 1], precision: 12)
        let session = SheetEvaluationSession()
        _ = try session.evaluate("a = 3\nb = 1\nplot a*x from 0 to 2")
        let changed = try session.evaluate("a = 4\nb = 1\nplot a*x from 0 to 2")
        let y = try changed[2].value!.plot.y
        assertEqual(8, y[y.count - 1], precision: 12)
    }
    func testVariableShadowsASheetVariableOfTheSameName() throws {
        let y = try plot("x = 100\nplot x^2 from 0 to 2").y
        assertEqual(4, y[y.count - 1], precision: 12)
    }
    func testDomainProblemsAreExplicitErrors() throws {
        try theory(["plot x from 2 to 1", "plot x from 1 to 1", "plot sqrt(-1 - x^2)", "plot x from 1 m to 2 m", "plot x from 0 to n"]) { source in
            let result = try last(source)
            XCTAssertNotNil(result.error, source); XCTAssertNil(result.value, source)
        }
    }
    func testAllUndefinedReadsAsSuch() throws { XCTAssertTrue(try last("plot ln(-1 - x^2)").error?.contains("undefined") == true) }
    func testProseStaysProse() throws {
        try theory(["plot twist", "plot the results", "plot x marks the spot", "plot"]) { source in
            let result = try last(source)
            XCTAssertNil(result.value, source); XCTAssertNil(result.error, source)
        }
    }
    func testLabelsAndVariablesWinOverTheSentence() throws {
        try theory([("plot 5", "5"), ("plot = 3\nplot + 1", "4"), ("plot = 3\nplot", "3")]) { source, display in XCTAssertEqual(display, try last(source).display, source) }
    }
    func testPlotLinesNeverJoinAggregates() throws {
        XCTAssertEqual("3", try last("1\n2\nplot x\nsum").display)
        XCTAssertEqual("3", try last("1\n2\nplot x from 2 to 1\nsum").display)
        XCTAssertEqual("3", try last("1\n2\np = plot x\nq = p\nsum").display)
    }
    func testArithmeticOnAPlotIsAnError() throws { XCTAssertNotNil(try last("p = plot x\np + 1").error) }
    func testExplanationDisclosesSamplingAndApproximation() throws {
        let result = try last("plot sin(x)")
        let assumption = result.explanation.last!.assumption!
        XCTAssertTrue(assumption.hasPrefix("Approximate"), assumption)
        XCTAssertTrue(assumption.contains("Sampled curve")); XCTAssertTrue(assumption.contains("radians"))
        let plot = try result.value!.plot
        XCTAssertTrue(plot.details.contains("257 uniform samples"))
        XCTAssertTrue(try result.value!.copyText.contains("\(plot.x.count) points"))
        XCTAssertTrue(plot.description.contains("sin(x)"))
    }
    func testEqualSourceGivesAnEqualValue() throws { XCTAssertEqual(try last("plot tan(x)").value, try last("plot tan(x)").value) }
    func testSavedFunctionBodiesParseCanonicalizeAndEvaluate() throws {
        let library = try FunctionLibrary([FunctionDefinition(name: "wave", parameters: ["a"], body: "plot a*sin(x) from 0 to 1")])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, library.minimumCatalogVersion)
        let result = try SheetEvaluationSession().evaluateWithFunctions("wave(2)", library, []).results[0]
        XCTAssertEqual(.plot, result.value!.kind)
        let y = try result.value!.plot.y
        assertEqual(2 * Foundation.sin(1), y[y.count - 1], precision: 12)
    }
    func testCancellationStopsSampling() throws {
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("plot sin(x)", cancelled)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
    func testManyPlotsShareTheSheetBudget() throws {
        // Each tan plot needs more than a thousand samples, so a thousand lines exceed the 500,000 step sheet budget.
        XCTAssertThrowsError(try SheetEvaluator.evaluate(Array(repeating: "plot tan(x)", count: 1000).joined(separator: "\n"))) { XCTAssertEqual($0 as? CalcError, .computationLimit) }
    }
}
