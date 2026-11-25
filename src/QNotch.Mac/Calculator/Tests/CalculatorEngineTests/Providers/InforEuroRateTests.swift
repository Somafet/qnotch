import XCTest
@testable import CalculatorEngine

final class InforEuroRateTests: XCTestCase {
    private let now = Instant.utc(2026, 11, 1, 12)

    func testRecordedResponseMatchesTheOfficialCommissionPublicationForEveryCode() throws {
        let snapshot = try InforEuroRateClient.parse(try Fixtures.data("inforeuro-2026-10-01.json"), nil, now)
        XCTAssertEqual(snapshot.asOf, DateOnly(2026, 10, 1)); XCTAssertTrue(snapshot.isMonthly)
        XCTAssertEqual(snapshot.rates.count, 152); XCTAssertEqual(snapshot.rates["EUR"], .one)
        // Independent oracle: the Commission's own InforEuro API for October 2026, retrieved separately.
        let official = try JSONNode.parse(try Fixtures.data("inforeuro-official-2026-10.json"))
        var rates: [String: Rational] = [:]
        for (name, value) in try official.property("rates").objectProperties() { rates[name == "ZIG" ? "ZWG" : name] = try Rational.parse(try value.string()) }
        XCTAssertEqual(rates.keys.sorted { String.ordinalCompare($0, $1) < 0 }, snapshot.rates.keys.sorted { String.ordinalCompare($0, $1) < 0 })
        for (code, value) in rates { XCTAssertEqual(snapshot.rates[code], value, code) }
        for code in snapshot.rates.keys { XCTAssertNotNil(CurrencyCatalog.tryCode(code), code) }
        XCTAssertTrue(snapshot.rates.count > (try EcbRateClient.parse(try Fixtures.data("ecb-2023-12-29.json"), DateOnly(2024, 1, 1), now)).rates.count * 4)
    }
    func testRequestsNameOnlyTheFixedProviderBaseAndOptionalDate() async throws {
        let body = try Fixtures.data("inforeuro-2026-10-01.json")
        let transport = FakeRateTransport { _, _ in CurrencyRateHTTPResponse(status: 200, data: body) }
        let result = try await InforEuroRateClient(transport).fetch(DateOnly(2026, 10, 17), now: now)
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), ["https://api.frankfurter.dev/v2/providers/INFOREURO/rates?base=EUR&date=2026-10-17"])
        XCTAssertEqual(result.provider, InforEuroRateClient.provider); XCTAssertEqual(result.asOf, DateOnly(2026, 10, 1))
        XCTAssertEqual(InforEuroRateClient.requestUri(nil).absoluteString, "https://api.frankfurter.dev/v2/providers/INFOREURO/rates?base=EUR")
        await assertThrowsAsync({ try await InforEuroRateClient(transport).fetch(DateOnly(2026, 11, 2), now: self.now) }) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)") }
        await assertThrowsAsync({ try await InforEuroRateClient(transport).fetch(DateOnly(1990, 1, 1), now: self.now) }) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)") }
    }
    func testInvalidMonthlyResponsesNeverBecomeRates() throws {
        try theory([
            "[{\"date\":\"2026-10-02\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]",   // monthly rates are dated on the first
            "[{\"date\":\"2026-08-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]",   // older than the monthly bound
            "[{\"date\":\"2026-12-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]",   // future
            "[{\"date\":\"2026-10-01\",\"base\":\"EUR\",\"quote\":\"USD\",\"rate\":1.1}]", // base identity missing
            "[]",
        ]) { value in
            XCTAssertThrowsError(try InforEuroRateClient.parse(Data(value.utf8), nil, now), value) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)") }
        }
    }
    func testMonthlySnapshotsRoundTripThroughTheCacheAndDescribeTheirCadence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calc-inforeuro-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let snapshot = try InforEuroRateClient.parse(try Fixtures.data("inforeuro-2026-10-01.json"), nil, now)
        let cache = CurrencyRateCache(directory); try cache.save(try CurrencyRateBook(snapshot, []))
        let loaded = try cache.load().book.latest!
        XCTAssertEqual(snapshot.key, loaded.key); XCTAssertTrue(loaded.isMonthly)
        let context = EvaluationContext(today: DateOnly(2026, 11, 1), currencyRates: try CurrencyRateBook(loaded, []))
        let result = try SheetEvaluator.evaluate("100 EUR in ZAR", context: context).last!
        XCTAssertNil(result.error)
        let detail = result.explanation.map { $0.assumption ?? "" }.joined(separator: " ")
        XCTAssertTrue(detail.contains("monthly accounting rates")); XCTAssertFalse(detail.contains("STALE"))
        let stale = try SheetEvaluator.evaluate("100 EUR in ZAR", context: context.with { $0.today = DateOnly(2026, 11, 30) }).last!
        XCTAssertTrue(stale.explanation.map { $0.assumption ?? "" }.joined(separator: " ").contains("STALE"))
    }
}
