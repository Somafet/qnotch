import XCTest
@testable import CalculatorEngine

final class ChartTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try SheetEvaluator.evaluate(source).last! }
    private func chart(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> ChartValue {
        let result = try last(source)
        XCTAssertNil(result.error, source, file: file, line: line)
        guard let value = result.value else { throw AssertionFailure(description: "\(source): no value") }
        return try value.chart
    }
    private func labels(_ chart: ChartValue) -> [String] { chart.items.map(\.label) }
    private func magnitudes(_ chart: ChartValue) -> [Double] { chart.items.map(\.magnitude) }

    func testListFormsShowTotalOrCount() throws {
        try theory([
            ("bar chart of [10, 20, 30]", ChartKind.bar, "60"), ("bar chart [10, 20, 30]", .bar, "60"), ("pie chart of [1, 3]", .pie, "4"),
            ("trend chart of [1, 3, 2]", .trend, "3 points"), ("line chart of [1, 3, 2]", .trend, "3 points"), ("BAR CHART OF [2, 2]", .bar, "4"),
            ("v = [1, 2]\nbar chart of v", .bar, "3"),
        ]) { source, kind, display in
            let result = try last(source)
            XCTAssertEqual(kind, try result.value!.chart.kind, source); XCTAssertEqual(display, result.display, source)
        }
    }
    func testMagnitudesFollowTheData() throws {
        let chart = try chart("bar chart of [10, -20, 30]")
        XCTAssertEqual([10, -20, 30], magnitudes(chart))
        XCTAssertEqual(["1", "2", "3"], labels(chart))
    }
    func testPrecedingLinesUseNamesAndProseLabels() throws {
        let chart = try chart("# Spending\nrent = 1200\nGroceries 300\n\"Going out\" 100\n50\nbar chart")
        XCTAssertEqual(["rent", "Groceries", "Going out", "L5"], labels(chart))
        XCTAssertEqual([1200, 300, 100, 50], magnitudes(chart))
        XCTAssertEqual("1650", try self.chart("rent = 1200\nGroceries 300\n\"Going out\" 100\n50\nbar chart").total)
    }
    func testBlocksBoundTheData() throws { XCTAssertEqual([3, 4], magnitudes(try chart("1\n2\n\n3\n4\npie chart"))) }
    func testTagsSelectLikeSum() throws { XCTAssertEqual([5, 7], magnitudes(try chart("5 #food\n6\n7 #food\n\nbar chart #food"))) }
    func testChartLinesNeverJoinAggregatesOrEachOther() throws {
        XCTAssertEqual("3", try last("1\n2\nbar chart\nsum").display)
        XCTAssertEqual("3", try last("1\n2\npie chart of [-1]\nsum").display)
        let second = try chart("1\n2\nbar chart\npie chart")
        XCTAssertEqual([1, 2], magnitudes(second))
    }
    func testListsAndSolveLinesInABlockAreSkipped() throws { XCTAssertEqual([2], magnitudes(try chart("[1, 2]\nsolve x = 1\n2\nbar chart"))) }
    func testUnitsAreConvertedToTheFirstAndKeptInLabels() throws {
        let chart = try chart("bar chart of [1 m, 50 cm]")
        XCTAssertEqual([1, 0.5], magnitudes(chart))
        XCTAssertEqual("1 m", chart.items[0].display); XCTAssertEqual("0.5 m", chart.items[1].display)
        XCTAssertEqual("1.5 m", chart.total)
    }
    func testMoneyKeepsItsCurrency() throws {
        let chart = try chart("bar chart of [$10, $5.50]")
        XCTAssertEqual([10, 5.5], magnitudes(chart))
        XCTAssertTrue(chart.total.contains("15.5"), chart.total)
    }
    func testApproximateInputsAreMarked() throws {
        XCTAssertTrue(try chart("bar chart of [sin(1), 1]").isApproximate)
        XCTAssertTrue(try last("bar chart of [sin(1), 1]").display.hasPrefix("≈"))
        XCTAssertFalse(try chart("bar chart of [1, 2]").isApproximate)
    }
    func testBadDataIsAnExplicitError() throws {
        try theory([
            "bar chart of [1 m, 2 s]", "bar chart of [1, $2]", "bar chart of [$1, EUR 2]", "pie chart of [1, -2]", "pie chart of [0, 0]", "trend chart of [1]",
            "bar chart of []", "bar chart of [[1, 2], [3, 4]]", "x = 5\nbar chart of x", "bar chart", "\n\npie chart", "2026-01-01\nbar chart",
        ]) { source in
            let result = try last(source)
            XCTAssertNotNil(result.error, source); XCTAssertNil(result.value, source)
        }
    }
    func testBoundsRefuseRatherThanTruncate() throws {
        func list(_ count: Int) -> String { "[" + Array(repeating: "1", count: count).joined(separator: ", ") + "]" }
        XCTAssertEqual(64, try chart("bar chart of " + list(64)).items.count)
        XCTAssertTrue(try last("bar chart of " + list(65)).error?.contains("at most 64") == true)
        XCTAssertEqual(512, try chart("trend chart of " + list(512)).items.count)
        XCTAssertTrue(try last("trend chart of " + list(513)).error?.contains("at most 512") == true)
    }
    func testProseStaysProse() throws {
        try theory(["bar chart monthly", "the bar chart", "pie chart of the month", "chart"]) { source in
            let result = try last(source)
            XCTAssertNil(result.value, source); XCTAssertNil(result.error, source)
        }
    }
    func testUnitsLabelsAndVariablesKeepWorking() throws {
        try theory([("bar chart 5", "5"), ("3 bar", "3 bar"), ("bar = 3\nbar + 1", "4"), ("bar = 3\nbar", "3")]) { source, display in XCTAssertEqual(display, try last(source).display, source) }
    }
    func testVariableNamedLikeTheSentenceDisablesIt() throws {
        let result = try last("1\nbar = 2\nbar chart")
        XCTAssertNotEqual(.chart, result.value?.kind)
    }
    func testChangingALabelRebuildsTheChart() throws {
        let session = SheetEvaluationSession()
        _ = try session.evaluate("Rent 100\nbar chart")
        let results = try session.evaluate("Lease 100\nbar chart")
        XCTAssertEqual("Lease", try results[1].value!.chart.items[0].label)
    }
    func testChangingAnUnrelatedLineReusesTheChart() throws {
        let session = SheetEvaluationSession()
        let first = try session.evaluate("1\n2\nbar chart\n\nnote 5")
        let second = try session.evaluate("1\n2\nbar chart\n\nnote 6")
        XCTAssertIdentical(first[2], second[2])
    }
    func testExplanationAndAccessibilityDescribeTheData() throws {
        let result = try last("Rent 10\nFood 30\nbar chart")
        let chart = try result.value!.chart
        XCTAssertTrue(result.explanation.last!.assumption!.contains("Bar chart of 2 values"))
        XCTAssertTrue(chart.details.contains("Rent: 10"))
        XCTAssertEqual("Rent: 10, Food: 30", try result.value!.copyText)
        XCTAssertEqual("Bar chart of 2 values, from Rent 10 to Food 30", chart.description)
    }
    func testSavedFunctionsChartTheirArgument() throws {
        let library = try FunctionLibrary([FunctionDefinition(name: "bars", parameters: ["v"], body: "bar chart of v")])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, library.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("bars([1, 2])", library, []).results
        XCTAssertEqual("3", results[0].display)
    }
}
