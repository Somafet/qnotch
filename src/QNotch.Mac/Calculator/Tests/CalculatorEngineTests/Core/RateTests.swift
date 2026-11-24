import XCTest
@testable import CalculatorEngine

final class RateTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let row = try SheetEvaluator.evaluate(source).last!
        XCTAssertNil(row.error, source, file: file, line: line); XCTAssertNotNil(row.value, source, file: file, line: line)
        return row
    }
    private static func isFormat(_ error: Error) -> Bool { (error as? CalcError)?.isFormat == true }

    func testIndependentExactRateOracle() throws {
        let cases = try JSONNode.parse(try Fixtures.data("developer-rates-v1.json")).property("cases").arrayItems()
        func read(_ pair: JSONNode) throws -> Rational { let items = try pair.arrayItems(); return try Rational(BigInt(try items[0].string())!, BigInt(try items[1].string())!) }
        for row in cases {
            CaseCounter.record(file: #filePath)
            let source = try row.property("source").string()
            do {
                let value = try XCTUnwrap(try last(source).value)
                let expected = try read(try row.property("exact"))
                switch try row.property("kind").string() {
                case "uptime":
                    XCTAssertEqual(expected, try value.uptimeBudget.downtimeSeconds, source)
                    XCTAssertEqual(try read(try row.property("interval")), try value.uptimeBudget.intervalSeconds, source)
                case "cost": XCTAssertEqual(expected, try value.money.magnitude.exact.rational, source)
                default: XCTAssertEqual(expected, try value.exact.rational, source)
                }
            } catch { XCTFail("\(source): \(error)") }
        }
    }

    func testPublicExamplesAndExistingAtMeanings() throws {
        try theory([("5 GB at 100 Mbps", "6 min 40 s"), ("transfer(5 GB,100 Mbit/s)", "6 min 40 s"), ("1 TB / 3 h in MB/s", "92.59 MB/s"), ("throughput(1 TB,3 h)", "92.59 MB/s"),
                    ("99.9% uptime", "43 min 50 s"), ("99.9% uptime for 30 days", "43 min 12 s"), ("downtime(99.9%,30 days)", "43 min 12 s"), ("1.2M tokens at $3/M", "3.6 USD"),
                    ("100 req/s at $0.20/M for 30 days", "51.84 USD"), ("$0.0832/h for 30 days", "59.9 USD"), ("100 Mbps for 1 h", "360000 Mbit"),
                    ("n=1.2M tokens\np=$3/M\nn at p", "3.6 USD"), ("1000 at 10% for 1 year", "1100"), ("2027-01-02 at 12:00", "2027-01-02T12:00:00")]) { source, expected in
            XCTAssertEqual(expected, try last(source).display, source)
        }
    }

    func testExactStoredValuesAndTypedCopies() throws {
        let throughput = try XCTUnwrap(try last("1 TB / 3 h in MB/s").value); XCTAssertEqual(try Rational(BigInt(20_000_000_000), BigInt(27)), try throughput.exact.rational)
        let uptime = try XCTUnwrap(try last("99.9% uptime").value); XCTAssertEqual(try Rational(13149, 5), try uptime.uptimeBudget.downtimeSeconds)
        for source in ["100 req/s", "1.2M tokens", "$0.00001/M tokens", "99.9% uptime", "99.9% uptime for 30 days"] {
            let value = try XCTUnwrap(try last(source).value); XCTAssertEqual(value, try last(try value.copyText).value, source)
        }
    }

    func testDomainsAndDimensionsFail() throws {
        try theory(["5 GB at 0 Mbps", "5 GB at -100 Mbps", "transfer(-1 GB,1 Mbps)",
                    "throughput(1 GB,0 s)", "downtime(101%,1 day)", "downtime(99.9%,0 s)",
                    "uptime(99.9)", "1 tokens+1 requests", "1 requests at tokenPrice(3 USD,1000000)",
                    "tokenPrice(3 USD,0)", "tokenPrice(-3 USD,100)", "$1/month for 30 days",
                    "100 req/s at $1/M for 1 month", "$1/h for -1 s"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source)
        }
    }

    func testRatesComposeAndExistingNamesKeepPriority() throws {
        try theory([("100 req/s in requests/h", "360000 requests/h"), ("100 req/s for 1 h", "360000 requests"), ("$6/M / 2", "3 USD/M"), ("2 * ($3/M)", "6 USD/M"),
                    ("$3/M + $2/M", "5 USD/M"), ("$6 / tokenPrice(3 USD,1000000)", "2000000 tokens"), ("100 tokens + 10%", "110 tokens"), ("100 tokens / 25 tokens", "4"),
                    ("1 tokens\n3 tokens\naverage", "2 tokens"), ("$2/M\n$4/M\naverage", "3 USD/M"), ("(123.45 tokens) to 1 decimal", "123.5 tokens"),
                    ("(99.9% uptime) in s", "2629.8 s"), ("tokens=7\ntokens+1", "8"), ("M=2\n6 USD/M", "3 USD"), ("1 MBps in Mbit/s", "8 Mbit/s"),
                    ("1 MiBps in Mbit/s", "8.388608 Mbit/s"), ("2027-01-02 at (12:00) GB in UTC", "2027-01-02T12:00:00Z")]) { source, expected in
            XCTAssertEqual(expected, try last(source).display, source)
        }
    }

    func testConvertedUsageAggregatesRemainExcludedFromLaterTotals() throws {
        let rows = try SheetEvaluator.evaluate("100 req/s\n200 req/s\nsum in requests/h\nsum in requests/h")
        for row in rows { XCTAssertNil(row.error) }
        XCTAssertEqual("1080000 requests/h", rows[2].display); XCTAssertEqual(rows[2].display, rows[3].display)
    }

    func testRatesSurviveSavedFunctionsAndCaseSensitiveFingerprinting() throws {
        let slow = try FunctionLibrary([FunctionDefinition(name: "wire", parameters: [], body: "1 Mbps")])
        let fast = try FunctionLibrary([FunctionDefinition(name: "wire", parameters: [], body: "1 MBps")])
        XCTAssertNotEqual(slow.fingerprint, fast.fingerprint); XCTAssertEqual(3, slow.minimumCatalogVersion)
        let engine = SheetEvaluationSession()
        let a = try XCTUnwrap(try engine.evaluateWithFunctions("wire()", slow, []).results[0].value)
        let b = try XCTUnwrap(try engine.evaluateWithFunctions("wire()", fast, []).results[0].value)
        XCTAssertEqual(try a.exact.rational * Rational(8), try b.exact.rational)
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "transfer", parameters: [], body: "1")])) { XCTAssertTrue(RateTests.isFormat($0)) }
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "bad", parameters: [], body: "usageCost(1)")])) { XCTAssertTrue(RateTests.isFormat($0)) }
    }

    func testCurrencyPricesUseExplicitSnapshotsAndKeepProvenance() throws {
        let snapshot = try CurrencyRateSnapshot(provider: "Test daily rates", baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: Instant.utc(2026, 10, 30, 17),
                                                rates: [("EUR", Rational(1)), ("USD", Rational(2))])
        let context = EvaluationContext(currencyRates: try CurrencyRateBook(snapshot, []))
        let row = try SheetEvaluator.evaluate("p=tokenPrice(3 EUR,1000000) in USD\n1.2M tokens at p", context: context).last!
        XCTAssertNil(row.error); XCTAssertEqual("7.2 USD", row.display); XCTAssertNotNil(try row.value!.money.rateStamp)
        let missing = try SheetEvaluator.evaluate("tokenPrice(3 EUR,1000000) in USD")[0]; XCTAssertNotNil(missing.error)
    }

    func testTracesRetainExactRatesAndAssumptionsAndRespectCancellation() throws {
        let row = try last("1 TB / 3 h in MB/s"); XCTAssertTrue(row.explanation.contains { $0.assumption?.contains("20000000000/27") == true })
        let uptime = try last("99.9% uptime"); XCTAssertTrue(uptime.explanation.contains { $0.assumption?.contains("a mean-month convention") == true })
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("5 GB at 100 Mbps", cancelled)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
