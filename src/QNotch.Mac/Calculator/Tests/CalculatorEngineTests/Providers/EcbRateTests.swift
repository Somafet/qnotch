import XCTest
@testable import CalculatorEngine

final class EcbRateTests: XCTestCase {
    private let now = Instant.utc(2026, 10, 31, 12)
    private let valid = "[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1},{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"USD\",\"rate\":1.105}]"
    private func parse(_ text: String) throws -> CurrencyRateSnapshot { try EcbRateClient.parse(Data(text.utf8), nil, now) }
    private func assertInvalid(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), text, file: file, line: line) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)", file: file, line: line) }
    }

    func testRecordedHolidayRequestMatchesTheOfficialPublishedEcbDateAndRates() throws {
        let snapshot = try EcbRateClient.parse(try Fixtures.data("ecb-2023-12-29.json"), DateOnly(2024, 1, 1), now)
        XCTAssertEqual(snapshot.asOf, DateOnly(2023, 12, 29)); XCTAssertEqual(snapshot.rates.count, 31)
        XCTAssertEqual(snapshot.rates["USD"], try Rational.parse("1.1050")); XCTAssertEqual(snapshot.rates["JPY"], try Rational.parse("156.33"))
        XCTAssertEqual(snapshot.rates["GBP"], try Rational.parse("0.86905"))
        // C# checks the snapshot's dictionary rejects Add. Swift's `rates` is an immutable value: a mutated copy never reaches the snapshot.
        var copy = snapshot.rates; copy["XYZ"] = .one
        XCTAssertNil(snapshot.rates["XYZ"])
    }
    func testRequestsContainOnlyTheFixedBaseAndOptionalDate() async throws {
        let transport = FakeRateTransport { _, _ in CurrencyRateHTTPResponse(status: 200, data: Data(self.valid.utf8)) }
        let result = try await EcbRateClient(transport).fetch(nil, now: now)
        // The transport API has no request body or credentials to send; the URL and Accept header are all a request carries.
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), ["https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR"])
        XCTAssertEqual(transport.requests.map(\.accept), ["application/json"])
        XCTAssertEqual(result.provider, EcbRateClient.provider)
        XCTAssertEqual(EcbRateClient.requestUri(DateOnly(2024, 1, 1)).absoluteString, "https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR&date=2024-01-01")
    }
    func testInvalidResponsesNeverBecomeRates() throws {
        try theory([
            "[]", "{}", "<html>unavailable</html>",
            "[{\"date\":\"2026-10-30\",\"base\":\"USD\",\"quote\":\"USD\",\"rate\":1}]",
            "[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":0}]",
            "[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":2}]",
            "[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1,\"rate\":2}]",
            "[{\"date\":\"2026-11-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]",
            "[{\"date\":\"2026-01-01\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]",
            "[{\"date\":null,\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]",
        ]) { value in assertInvalid(value) }
    }
    func testDuplicateMixedDateAndScientificDecimalCasesAreExactAndBounded() throws {
        let scientific = valid.replacingOccurrences(of: "1.105}", with: "1.105e0}")
        XCTAssertEqual(try parse(scientific).rates["USD"], try Rational.parse("1.105"))
        assertInvalid(valid.replacingOccurrences(of: "1.105}", with: "1e999}"))
        assertInvalid(valid.replacingOccurrences(of: "\"quote\":\"USD\"", with: "\"quote\":\"EUR\""))
        assertInvalid(valid.replacingOccurrences(of: "\"quote\":\"USD\"", with: "\"quote\":\"XYZ\""))
        assertInvalid(valid.replacingOccurrences(of: "\"quote\":\"USD\"", with: "\"date\":\"2026-10-29\",\"quote\":\"USD\""))
    }
    func testHttpFailuresRetainStatusAndBoundRetryAdvice() async throws {
        await asyncTheory([429, 500, 404]) { status in
            let transport = FakeRateTransport { _, _ in CurrencyRateHTTPResponse(status: status, retryAfter: .delta(seconds: 10 * 86400), data: Data()) }
            await assertThrowsAsync({ try await EcbRateClient(transport).fetch(nil, now: self.now) }) { error in
                XCTAssertEqual(error as? CurrencyRateHttpError, CurrencyRateHttpError(status: status, retryAfterTicks: Ticks.perDay))
            }
        }
    }
    func testBothDeclaredAndStreamingOversizedBodiesAreRejected() async throws {
        for streaming in [false, true] {
            let size = EcbRateClient.maxResponseBytes + 1
            let transport = FakeRateTransport { _, _ in
                if !streaming { return CurrencyRateHTTPResponse(status: 200, contentLength: Int64(size), data: Data(count: size)) }
                // No declared length; the body arrives in 8 KiB chunks.
                return CurrencyRateHTTPResponse(status: 200, body: AsyncThrowingStream { continuation in
                    var sent = 0
                    while sent < size { let count = min(8192, size - sent); continuation.yield(Data(count: count)); sent += count }
                    continuation.finish()
                })
            }
            await assertThrowsAsync({ try await EcbRateClient(transport).fetch(nil, now: self.now) }) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)") }
        }
    }
    func testCancellationFutureDatesAndRedirectsCannotYieldSuccessfulSnapshots() async throws {
        let canceled = CancellationToken(); canceled.cancel()
        let transport = FakeRateTransport { _, token in
            try token.throwIfCancellationRequested(); return CurrencyRateHTTPResponse(status: 200, data: Data(self.valid.utf8))
        }
        await assertThrowsAsync({ try await EcbRateClient(transport).fetch(nil, now: self.now, token: canceled) }) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        await assertThrowsAsync({ try await EcbRateClient(transport).fetch(DateOnly(3000, 1, 1), now: self.now) }) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)") }
        let redirect = FakeRateTransport { _, _ in CurrencyRateHTTPResponse(status: 200, url: URL(string: "https://example.invalid/")!, data: Data(self.valid.utf8)) }
        await assertThrowsAsync({ try await EcbRateClient(redirect).fetch(nil, now: self.now) }) { XCTAssertTrue(($0 as? CalcError)?.isInvalidData == true, "\($0)") }
    }
}
