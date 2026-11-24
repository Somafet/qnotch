import XCTest
import CalculatorEngine

/// The public surface the Mac app uses (no @testable import here on purpose).
final class CalculatorAPITests: XCTestCase {
    func testSheetLinesPresentRoundedAnswersAndKeepExactValues() throws {
        let sheet = CalculatorSheet()
        let result = try sheet.evaluate("a = 1/3\na * 3\nnotes\n2 +", format: CalculatorFormat(locale: Locale(identifier: "en_US")))
        XCTAssertEqual(result.lines.map(\.answer), ["≈ 0.3333", "1", "", "Expected expression"])
        XCTAssertEqual(result.lines[0].copy, "0.3333"); XCTAssertEqual(result.lines[0].exact, "1/3")
        XCTAssertTrue(result.lines[0].hasValue); XCTAssertEqual(result.lines[1].dependencies, [0])
        XCTAssertTrue(result.lines[2].isBlank); XCTAssertNotNil(result.lines[3].error)
        XCTAssertFalse(result.lines[1].explanation.isEmpty)
    }
    func testAmortizationRowsReachTheStepDetails() throws {
        let line = try CalculatorSheet().evaluate("amortize 3000 at 0% for 30 months", format: CalculatorFormat(locale: Locale(identifier: "en_US"))).lines[0]
        XCTAssertEqual(line.explanation.first { !$0.details.isEmpty }?.details, [
            "Year 1 (12 payments): interest 0, principal 1200, balance 1800",
            "Year 2 (12 payments): interest 0, principal 1200, balance 600",
            "Year 3 (6 payments): interest 0, principal 600, balance 0",
        ])
    }
    func testFixedDecimalsAndStyleFollowTheFormat() throws {
        let format = CalculatorFormat(styleId: "period", decimalPlaces: 2, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(try CalculatorSheet().evaluate("1234567/3", format: format).lines[0].answer, "411.522,33")
    }
    func testQuickAnswersOnlyRealCalculations() {
        let quick = CalculatorQuick()
        XCTAssertTrue(CalculatorQuick.looksLikeCalculation("2+2"))
        XCTAssertTrue(CalculatorQuick.looksLikeCalculation("sqrt(16)"))
        XCTAssertTrue(CalculatorQuick.looksLikeCalculation("5 km in miles"))
        XCTAssertFalse(CalculatorQuick.looksLikeCalculation("safari"))
        XCTAssertFalse(CalculatorQuick.looksLikeCalculation("http://a.b/1+2"))
        XCTAssertFalse(CalculatorQuick.looksLikeCalculation("12"))
        XCTAssertEqual(quick.answer("2+2")?.answer, "4")
        XCTAssertEqual(quick.answer("10/4")?.copy, "2.5")
        XCTAssertNil(quick.answer("2+"))
        XCTAssertNil(quick.answer("4"))
    }

    func testRenameFindsTheVariableChecksTheNameAndListsEveryUse() {
        let text = "rent = 1450\nmonthly rent = 10\nrent / 2 // rent"
        let target = CalculatorRename.find(in: text, selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(target?.name, "rent"); XCTAssertEqual(target?.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(CalculatorRename.find(in: text, selection: NSRange(location: 1, length: 3))?.name, nil)
        XCTAssertNil(CalculatorRename.find(in: "1 + 2", selection: NSRange(location: 1, length: 0)))
        // Multi-word names match greedily and comments are left alone.
        XCTAssertEqual(CalculatorRename.occurrences(of: "rent", in: text), [NSRange(location: 0, length: 4), NSRange(location: 30, length: 4)])
        XCTAssertNil(CalculatorRename.check(text, renaming: "rent", to: "  flat   rent "))
        XCTAssertEqual(CalculatorRename.check(text, renaming: "rent", to: "monthly rent"), .taken)
        XCTAssertEqual(CalculatorRename.check(text, renaming: "rent", to: "2x"), .invalid)
        XCTAssertEqual(CalculatorRename.normalize("  flat   rent "), "flat rent")
    }
    func testCsvPastesBecomeTabSeparatedRows() {
        XCTAssertEqual(CalculatorPaste.normalize("name,amount\nrent,1450\nfood,300\n"), "name\tamount\nrent\t1450\nfood\t300\n")
        XCTAssertEqual(CalculatorPaste.normalize("1, 2 + 3"), "1, 2 + 3")
    }
    func testFiguresExposeTheirDataWithoutTheEngineTypes() throws {
        let lines = try CalculatorSheet().evaluate("plot x^2 from 0 to 2\nbar chart of [10, -20, 30]\npie chart of [1, 3]\nt:\nname\tcost\nrent\t5\nfood\t7\n2 + 2",
                                                   format: CalculatorFormat(locale: Locale(identifier: "en_US"))).lines
        guard case .plot(let plot)? = lines[0].figure else { return XCTFail("no plot: \(lines[0])") }
        XCTAssertEqual(plot.lower, 0); XCTAssertEqual(plot.upper, 2); XCTAssertEqual(plot.x.count, plot.y.count)
        XCTAssertEqual(plot.segments.first?.lowerBound, 0); XCTAssertEqual(plot.segments.last?.upperBound, plot.x.count)
        XCTAssertTrue(plot.accessibilityDescription.hasPrefix("Plot of x^2"))
        XCTAssertEqual(CalculatorPlot.number(4.00000000000001), "4")
        guard case .chart(let bars)? = lines[1].figure else { return XCTFail("no chart") }
        XCTAssertEqual(bars.kind, .bar); XCTAssertEqual(bars.items.map(\.magnitude), [10, -20, 30]); XCTAssertEqual(bars.items.map(\.label), ["1", "2", "3"])
        guard case .chart(let pie)? = lines[2].figure else { return XCTFail("no pie") }
        XCTAssertEqual(pie.kind, .pie); XCTAssertTrue(lines[2].figure!.isDrawn)
        let table = lines.compactMap { line -> CalculatorTable? in if case .table(let table)? = line.figure { return table }; return nil }.first
        XCTAssertEqual(table?.columnCount, 2); XCTAssertEqual(table?.rowCount, 2); XCTAssertEqual(table?.header, ["name", "cost"])
        XCTAssertEqual(table?.text(row: 1, column: 0), "food"); XCTAssertEqual(table?.isNumeric(row: 1, column: 1), true)
        XCTAssertNil(lines.last?.figure)
    }
}
