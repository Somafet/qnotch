import XCTest
@testable import CalculatorEngine

final class CurrencyTests: XCTestCase {
    private func latest(_ usd: Int = 2) throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: "Test daily rates", baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: .utc(2026, 10, 30, 17),
                                 rates: [("EUR", .one), ("USD", Rational(usd)), ("GBP", try Rational(1, 2)), ("JPY", Rational(100)), ("RON", Rational(5))])
    }
    private func historical() throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: "ECB via Frankfurter", baseCurrency: "EUR", asOf: DateOnly(2023, 12, 29)!, retrievedAt: .utc(2026, 10, 31),
                                 rates: [("EUR", .one), ("USD", try Rational.parse("1.1050")), ("GBP", try Rational.parse("0.86905")), ("JPY", try Rational.parse("156.33"))])
    }
    private func context(_ usd: Int = 2) throws -> EvaluationContext {
        EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(try latest(usd), [(DateOnly(2024, 1, 1)!, try historical())]))
    }
    private func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult {
        try SheetEvaluator.evaluate(source, context: context ?? self.context()).last!
    }

    func testMonetaryExamplesUseExactSnapshots() throws {
        try theory([
            ("100 usd", "100 USD"), ("$100", "100 USD"), ("US$100", "100 USD"), ("USD 100", "100 USD"), ("US dollars 100", "100 USD"), ("€100 in $", "200 USD"),
            ("100 usd in eur", "50 EUR"), ("49 usd + 19 eur in gbp", "21.75 GBP"), ("dinner=84 eur/3\ndinner in usd", "56 USD"), ("100 EUR+10%", "110 EUR"),
            ("100 EUR-10%", "90 EUR"), ("20% of 100 EUR", "20 EUR"), ("100 EUR/50 USD", "4"), ("20 USD/h * (9:15–17:40 - 45 min)", "153.33 USD"),
            ("20 USD/h * 8 h", "160 USD"), ("20 USD/h in EUR/h", "10 EUR/h"), ("20 USD/h in EUR/min", "0.17 EUR/min"), ("100 JPY in USD", "2 USD"),
            ("100 EUR in USD on 1 jan 2024", "110.5 USD"), ("100 USD + 100 EUR in USD on 2024-01-01", "210.5 USD"),
            ("f(x)=x+1 EUR\nf(2 USD) in USD on 2024-01-01", "3.11 USD"), ("f(x,y)=x+y\nf(100 EUR in USD on 2024-01-01, 2 USD)", "112.5 USD"),
            ("holidays=[]\n1 cup in ml", "236.5882365 mL"), ("1 CUP", "1 CUP"),
        ]) { source, expected in
            let result = try last(source); XCTAssertNil(result.error, source); XCTAssertEqual(result.display, expected, source)
        }
    }
    func testConversionKeepsExactValuesInsteadOfRepeatedDisplayRounding() throws {
        let thirds = try last("1 USD/3"); XCTAssertEqual(thirds.display, "0.33 USD")
        XCTAssertEqual(try thirds.value!.money.magnitude.scalar, try Rational(1, 3))
        XCTAssertEqual(try last("third=1 USD/3\nthird*3").display, "1 USD")
        XCTAssertEqual(try last("2.675 USD").display, "2.68 USD")
        XCTAssertEqual(try last("-2.675 USD").display, "-2.68 USD")
        XCTAssertEqual(try last("1234.5 JPY").display, "1235 JPY")
        XCTAssertEqual(try last("1.2345 KWD").display, "1.235 KWD")
        XCTAssertEqual(try last("12.34564 USD to 4 decimals").display, "12.3456 USD")
        XCTAssertEqual(try last("0.012345 USD to 4 sig figs").display, "0.01235 USD")
        XCTAssertEqual(try last("12.37 USD to nearest 0.05 USD").display, "12.35 USD")
    }
    func testIdentityCurrencyAndSameCurrencyArithmeticNeedNoDownloadedData() throws {
        let session = SheetEvaluationSession()
        let result = try session.evaluateWithFunctions("f(x)=x in USD\n100 USD+20 USD\nf(10 USD)\n3", .empty, [])
        XCTAssertFalse(result.usesCurrencyRates); XCTAssertTrue(result.hasMoney); XCTAssertFalse(result.usesCurrentDate)
        XCTAssertTrue(result.currencyRequests.isEmpty); XCTAssertEqual(result.results[1].display, "120 USD"); XCTAssertEqual(result.results[2].display, "10 USD")
    }
    func testMissingAndChangedRatesInvalidateTheirReadersWithoutReparsingStaticMoney() throws {
        let session = SheetEvaluationSession(); let source = "price=100 EUR\nprice in USD\n4"
        let missing = try session.evaluateWithFunctions(source, .empty, [])
        XCTAssertNotNil(missing.results[1].error); XCTAssertTrue(missing.usesCurrencyRates); XCTAssertTrue(missing.currencyRequests.contains { $0.date == nil })
        XCTAssertEqual(try session.evaluate(source, context: try context())[1].display, "200 USD")
        XCTAssertEqual(session.lastStatistics.parsedLines, 0); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        XCTAssertEqual(try session.evaluate(source, context: try context(3))[1].display, "300 USD")
        XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let reused = try session.evaluateWithFunctions(source, .empty, [], context: try context(3))
        XCTAssertTrue(reused.usesCurrencyRates); XCTAssertEqual(reused.currencyRequests.count, 1); XCTAssertEqual(session.lastStatistics.reusedResults, 3)
    }
    func testHistoricalScopeAppliesToMixedArithmeticAndNestedSavedFunctions() throws {
        let result = try last("g(x)=x USD+1 EUR\nf(x)=g(x)\nf(2) in USD on 2024-01-01")
        XCTAssertNil(result.error); XCTAssertEqual(result.display, "3.11 USD")
        XCTAssertTrue(result.explanation.contains { $0.assumption?.contains("2023-12-29") == true && $0.assumption!.contains("2024-01-01") })
        XCTAssertNotNil(try last("converted=1 EUR in USD\nconverted in EUR on 2024-01-01").error)
        XCTAssertNotNil(try last("converted=1 EUR in USD\nconverted in USD on 2024-01-01").error)
    }
    func testAggregatesFunctionsAndRatesRemainTyped() throws {
        XCTAssertEqual(try last("100 USD\n10 EUR\nsum").display, "120 USD")
        XCTAssertEqual(try last("100 USD\n10 EUR\naverage").display, "60 USD")
        XCTAssertEqual(try last("share(1 EUR,4 USD)").display, "50%")
        XCTAssertEqual(try last("change(1 EUR,4 USD)").display, "100%")
        XCTAssertEqual(try last("abs(-1 USD)").display, "1 USD")
        XCTAssertNotNil(try last("1 USD\n2\nsum").error)
        XCTAssertThrowsError(try last("1 USD").value!.number) { XCTAssertTrue(($0 as? CalcError)?.isArithmetic == true) }
    }
    func testPinnedCodesAreWiredWithoutClaimingRateAvailability() throws {
        XCTAssertEqual(CurrencyCatalog.definitions.count, 245)
        for currency in CurrencyCatalog.definitions {
            let value = try last("1 " + currency.code)
            XCTAssertNil(value.error, currency.code); XCTAssertEqual(try value.value?.money.currency, currency.code)
            for alias in currency.aliases {
                let aliased = try last("1 " + alias); XCTAssertNil(aliased.error, alias); XCTAssertEqual(try aliased.value?.money.currency, currency.code, alias)
            }
        }
        XCTAssertNotNil(try last("1 BTC in USD").error)
        XCTAssertNotNil(try last("1 RUB in USD").error)
        XCTAssertNotNil(try last("1 XAU in USD").error)
        XCTAssertNotNil(try last("100¥").error)
        XCTAssertEqual(try last("USD=1\nUSD+1").display, "2")
    }
    func testRateReciprocityAndRoundTripsUseIndependentIntegerRatios() throws {
        var random = NetRandom(73128)
        for _ in 0..<500 {
            let euro = random.next(1, 10000); let dollar = random.next(1, 10000); let amount = random.next(-10000, 10000)
            let snapshot = try CurrencyRateSnapshot(provider: "synthetic oracle", baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: Instant(unixTicks: 0),
                                                    rates: [("EUR", .one), ("USD", try Rational(dollar, euro))])
            let rates = try CurrencyRateBook(snapshot, [])
            let context = try self.context().with { $0.currencyRates = rates }
            let converted = try last("\(amount) EUR in USD", context).value!.money
            XCTAssertEqual(try converted.magnitude.scalar, try Rational(amount * dollar, euro))
            XCTAssertEqual(try last("x=\(amount) EUR in USD\nx in EUR", context).value!.money.magnitude.scalar, Rational(amount))
        }
    }
    func testInvalidMoneyAndUnavailableCoverageFailExplicitly() throws {
        try theory(["1 USD + 2", "sqrt(1 USD)", "1 USD*2 EUR", "1 USD^2", "1 USD!", "1% USD", "1 USD in EUR on 3000-01-01", "1 USD in USD on 3000-01-01",
                    "1 USD in EUR on 1", "1 USD in XYZ"]) { source in XCTAssertNotNil(try last(source).error, source) }
    }
    func testTooManyHistoricalDatesFailWithoutCommittingAPartialSheetCache() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("7", context: try context())
        let source = (0..<65).map { "1 EUR in USD on \(DateOnly(2024, 1, 1)!.addingDays($0)!)" }.joined(separator: "\n")
        XCTAssertThrowsError(try session.evaluate(source, context: try context())) { XCTAssertTrue(($0 as? CalcError)?.isArgument == true, "\($0)") }
        XCTAssertEqual(try session.evaluate("7", context: try context())[0].display, "7"); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
    }
}
