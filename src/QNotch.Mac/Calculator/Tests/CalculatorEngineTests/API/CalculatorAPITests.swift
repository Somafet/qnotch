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
}
