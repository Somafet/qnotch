import XCTest
@testable import CalculatorEngine

/// Mac-only checks (no C# counterpart) for System.Text.Json behaviours the rate providers reproduce, found by
/// diffing the providers against the C# engine: Mac and Windows share the cache file.
final class RateJsonCompatibilityTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Calc-json-tests").appendingPathComponent(UUID().uuidString).path
    private var filePath: String { (directory as NSString).appendingPathComponent("currency-rates.json") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: directory) }
    private func cache(_ bytes: [UInt8]) throws -> CurrencyRateCache {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(fileURLWithPath: filePath)); return CurrencyRateCache(directory)
    }
    private func snapshot(_ retrievedAt: String) -> String {
        "{\"Version\":1,\"Snapshots\":[{\"Provider\":\"ECB via Frankfurter\",\"Base\":\"EUR\",\"AsOf\":\"2026-10-30\",\"RetrievedAt\":\"\(retrievedAt)\",\"Rates\":[{\"Code\":\"EUR\",\"Value\":\"1\"}]}]}"
    }

    func testByteOrderMarksFailWhereCSharpReadsSpansButNotStreams() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        XCTAssertThrowsError(try EcbRateClient.parse(Data(bom + Array("[{\"date\":\"2026-10-30\",\"base\":\"EUR\",\"quote\":\"EUR\",\"rate\":1}]".utf8)), nil, .utc(2026, 10, 31, 12))) {
            XCTAssertEqual($0 as? CalcError, .invalidData("Invalid rate response"))
        }
        // Load (JsonSerializer over bytes) rejects it; Save's version check (JsonDocument over a stream) skips it.
        let cache = try self.cache(bom + Array("{\"Version\":2,\"Snapshots\":[]}".utf8))
        XCTAssertEqual(try cache.load().warning, "Cached currency rates unavailable")
        XCTAssertThrowsError(try cache.save(.empty)) { XCTAssertTrue($0 is CurrencyRateCacheVersionError) }
    }
    func testRepeatedPropertiesUseTheLastValue() throws {
        let newer = try cache(Array("{\"Version\":1,\"Version\":2,\"Snapshots\":[]}".utf8))
        XCTAssertEqual(try newer.load().warning, "Unsupported rate-cache version; original preserved")
        XCTAssertThrowsError(try newer.save(.empty)) { XCTAssertTrue($0 is CurrencyRateCacheVersionError) }
        let current = try cache(Array("{\"Version\":2,\"Version\":1,\"Snapshots\":[]}".utf8))
        XCTAssertNil(try current.load().warning); XCTAssertNoThrow(try current.save(.empty))
    }
    func testTimestampsAcceptTheIsoForms() throws {
        for (text, expected) in [("2026-10-31T12:00:00+00:00", Instant.utc(2026, 10, 31, 12)), ("2026-10-31T14:00:00+02", .utc(2026, 10, 31, 12)),
                                 ("2026-10-31T12:00Z", .utc(2026, 10, 31, 12)), ("2026-10-31T12:00:00.123456789Z", Instant(unixTicks: Instant.utc(2026, 10, 31, 12).unixTicks + 1234567))] {
            XCTAssertEqual(try cache(Array(snapshot(text).utf8)).load().book.latest?.retrievedAt, expected, text)
        }
        for text in ["2026-10-31t12:00:00z", "2026-10-31T24:00:00+00:00", "2026-10-31T12:00:00+0000"] {
            XCTAssertEqual(try cache(Array(snapshot(text).utf8)).load().warning, "Cached currency rates unavailable", text)
        }
        XCTAssertEqual(CurrencyRateCache.isoText(Instant(unixTicks: Instant.utc(2026, 10, 31, 12).unixTicks + 1234500)), "2026-10-31T12:00:00.12345+00:00")
    }
}
