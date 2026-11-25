import XCTest
@testable import CalculatorEngine

final class OfflineTests: XCTestCase {
    private let now = Instant.utc(2026, 10, 31, 12)
    private func evaluate(_ source: String) throws -> SheetEvaluation {
        try SheetEvaluationSession().evaluateWithFunctions(source, .empty, [], context: EvaluationContext(today: DateOnly(2026, 10, 31)))
    }
    private func due(_ enabled: Bool, _ evaluated: SheetEvaluation) -> Instant? {
        CurrencyRefreshPolicy.next(enabled, true, false, evaluated.usesCurrencyRates && evaluated.currencyRequests.contains { $0.date == nil }, false, nil, now, nil)
    }

    func testAutomaticDownloadNeedsExplicitConsentEvenWithLatestRateDemand() throws {
        let demand = try evaluate("100 USD in EUR")
        XCTAssertTrue(demand.usesCurrencyRates)
        XCTAssertNil(due(false, demand))
        XCTAssertEqual(due(true, demand), now)
    }
    func testNoProviderRunsForASheetWithoutCurrencyDemand() throws {
        try theory(["", "price = 120\ndiscount = 15%\nprice * (1 - discount)", "10 km in m\n2026-10-31 + 30 days\nsolve x^2 = 4\n192.0.2.0/24", "rate(x) = x * 2\nrate(4)"]) { source in
            let evaluated = try evaluate(source)
            XCTAssertFalse(evaluated.usesCurrencyRates); XCTAssertTrue(evaluated.currencyRequests.isEmpty)
            XCTAssertNil(due(true, evaluated)) // Even an enabled preference has nothing to do.
        }
    }
    func testConversionWithoutCachedRatesIsExplicitlyUnavailableAndOtherLinesCalculate() throws {
        let results = try evaluate("1 + 1\n100 USD in EUR\n2 * 3").results
        XCTAssertEqual(results[0].display, "2"); XCTAssertEqual(results[2].display, "6")
        XCTAssertNil(results[1].value)
        XCTAssertTrue(results[1].error?.contains("unavailable") == true)
        XCTAssertFalse(results[1].display.contains("0"))
    }
    func testHistoricalConversionWithoutCachedRatesNamesTheMissingDate() throws {
        let result = try evaluate("100 USD in EUR on 2023-12-29").results[0]
        XCTAssertNil(result.value)
        XCTAssertTrue(result.error?.contains("unavailable") == true)
    }
    func testARequestCarriesOnlyTheFixedBaseAndAnOptionalDate() throws {
        XCTAssertEqual(EcbRateClient.requestUri(nil).absoluteString, "https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR")
        XCTAssertEqual(EcbRateClient.requestUri(DateOnly(2023, 12, 29)).absoluteString, "https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR&date=2023-12-29")
    }
}
