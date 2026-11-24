import XCTest
@testable import CalculatorEngine

final class DefaultCurrencyTests: XCTestCase {
    private func latest() throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: "Test daily rates", baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: .utc(2026, 10, 30, 17),
                                 rates: [("EUR", .one), ("USD", Rational(2)), ("RON", Rational(5))])
    }
    private func context(_ display: String? = "RON", rates: Bool = true) throws -> EvaluationContext {
        let book = rates ? try CurrencyRateBook(try latest(), []) : CurrencyRateBook.empty
        return EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: book).with { $0.displayCurrency = display }
    }
    private func shown(_ result: LineResult) throws -> String { try ResultFormatter.format(result, .default) }

    func testPlainMoneyIsShownInTheDefaultCurrencyUnlessTheLineNamesItsTarget() throws {
        try theory([
            ("800 usd", "2000 RON"), ("$10 + €2", "35 RON"), ("800 usd in eur", "400 EUR"), ("(800 usd in eur) * 2", "800 EUR"), ("50 ron", "50 RON"),
            ("100 eur in usd on 2024-01-01", "Historical currency rates unavailable for 2024-01-01"), ("800", "800"),
        ]) { source, expected in
            let result = try SheetEvaluator.evaluate(source, context: try context()).last!
            XCTAssertEqual(try result.error ?? shown(result), expected, source)
        }
    }
    func testConversionIsDisplayOnlySoReferencesKeepTheirCurrency() throws {
        let results = try SheetEvaluator.evaluate("x = 800 usd\nx + 1 usd\nx / 2 usd", context: try context())
        XCTAssertEqual(results[0].display, "800 USD"); XCTAssertEqual(try shown(results[0]), "2000 RON")
        XCTAssertEqual(try results[1].value!.display, "801 USD"); XCTAssertEqual(try shown(results[1]), "2002.5 RON")
        XCTAssertEqual(try shown(results[2]), "400"); XCTAssertNil(results[2].shown)
        XCTAssertTrue(results[0].explanation.contains { $0.operation == "show in default currency" && $0.assumption!.contains("references keep USD") })
    }
    func testNoDefaultOrMissingRatesLeaveTheOriginalAmount() throws {
        let off = try SheetEvaluator.evaluate("800 usd", context: try context(nil))[0]
        XCTAssertNil(off.shown); XCTAssertEqual(try shown(off), "800 USD")
        let evaluation = try SheetEvaluationSession().evaluateWithFunctions("800 usd", .empty, [], context: try context(nil))
        XCTAssertFalse(evaluation.usesCurrencyRates) // No default currency: a plain amount needs no rates.
        let missing = try SheetEvaluationSession().evaluateWithFunctions("800 usd", .empty, [], context: try context(rates: false))
        XCTAssertNil(missing.results[0].error); XCTAssertEqual(try shown(missing.results[0]), "800 USD")
        XCTAssertTrue(missing.usesCurrencyRates) // The host shows rate status and may refresh only under its existing consent.
    }
    func testCachedResultsFollowDefaultCurrencyAndRateChanges() throws {
        let session = SheetEvaluationSession()
        XCTAssertEqual(try shown(try session.evaluate("800 usd", context: try context(nil))[0]), "800 USD")
        XCTAssertEqual(try shown(try session.evaluate("800 usd", context: try context())[0]), "2000 RON")
        XCTAssertEqual(try shown(try session.evaluate("800 usd", context: try context("EUR"))[0]), "400 EUR")
        XCTAssertEqual(try shown(try session.evaluate("800 usd", context: try context(rates: false))[0]), "800 USD")
        XCTAssertEqual(try shown(try session.evaluate("800 usd", context: try context())[0]), "2000 RON")
        XCTAssertEqual(try shown(try session.evaluate("5", context: try context("EUR"))[0]), "5")
    }
}
