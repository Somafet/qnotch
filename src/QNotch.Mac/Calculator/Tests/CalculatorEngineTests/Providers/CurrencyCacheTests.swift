import XCTest
@testable import CalculatorEngine

final class CurrencyCacheTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Calc-provider-tests").appendingPathComponent(UUID().uuidString).path
    private var filePath: String { (directory as NSString).appendingPathComponent("currency-rates.json") }
    private let now = Instant.utc(2026, 10, 31, 12)
    private func snapshot(_ usd: Int = 2) throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: EcbRateClient.provider, baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: now, rates: [("EUR", .one), ("USD", Rational(usd))])
    }
    private func book(_ usd: Int) throws -> CurrencyRateBook { try CurrencyRateBook(try snapshot(usd), []) }
    private func files(_ suffix: String = "") throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(suffix) } }
    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    private func text(_ path: String) throws -> String { String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self) }
    override func tearDown() { try? FileManager.default.removeItem(atPath: directory) }

    func testMissingCacheDoesNotCreateFilesAndRoundTripKeepsExactRatesAndDates() throws {
        let cache = CurrencyRateCache(directory); XCTAssertNil(try cache.load().book.latest); XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        let book = try CurrencyRateBook(try snapshot(), [(DateOnly(2026, 10, 31)!, try snapshot())])
        try cache.save(book); let loaded = try cache.load(); XCTAssertNil(loaded.warning); XCTAssertEqual(book.key, loaded.book.key)
        XCTAssertEqual(loaded.book.historical[DateOnly(2026, 10, 31)!]?.rates["USD"], Rational(2))
        // The file is the one C#'s System.Text.Json writes, so Mac and Windows can share the data folder.
        XCTAssertEqual(try text(filePath), "{\"Version\":1,\"Snapshots\":[" +
            "{\"Requested\":null,\"Provider\":\"ECB via Frankfurter\",\"Base\":\"EUR\",\"AsOf\":\"2026-10-30\",\"RetrievedAt\":\"2026-10-31T12:00:00+00:00\",\"Rates\":[{\"Code\":\"EUR\",\"Value\":\"1\"},{\"Code\":\"USD\",\"Value\":\"2\"}]}," +
            "{\"Requested\":\"2026-10-31\",\"Provider\":\"ECB via Frankfurter\",\"Base\":\"EUR\",\"AsOf\":\"2026-10-30\",\"RetrievedAt\":\"2026-10-31T12:00:00+00:00\",\"Rates\":[{\"Code\":\"EUR\",\"Value\":\"1\"},{\"Code\":\"USD\",\"Value\":\"2\"}]}]}")
    }
    func testCorruptPrimaryFallsBackWithoutOverwritingRejectedBytesOrSheets() throws {
        let cache = CurrencyRateCache(directory); try cache.save(try book(2)); try cache.save(try book(3))
        try write(filePath, "{bad"); let recovered = try cache.load()
        XCTAssertTrue(recovered.recovered); XCTAssertEqual(recovered.book.latest?.rates["USD"], Rational(2))
        XCTAssertEqual(try text(filePath), "{bad"); XCTAssertFalse(FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("workspace.json")))
    }
    func testFutureCacheVersionsAreUnavailableAndPreservedOnSave() throws {
        try theory(["{\"Version\":999,\"Snapshots\":[]}", "{\"Version\":\"future\",\"Snapshots\":[]}"]) { text in
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true); try write(filePath, text); let cache = CurrencyRateCache(directory)
            XCTAssertNil(try cache.load().book.latest); XCTAssertNotNil(try cache.load().warning)
            XCTAssertThrowsError(try cache.save(try book(2))) { XCTAssertTrue($0 is CurrencyRateCacheVersionError, "\($0)") }
            XCTAssertEqual(try self.text(filePath), text)
        }
    }
    func testLockedReplacementKeepsLastGoodRatesAndRemovesTemporaryFiles() throws {
        let cache = CurrencyRateCache(directory); try cache.save(try book(2))
        // C# holds the primary open (FileShare.Read) so Windows refuses File.Replace. Unix rename ignores open handles,
        // so on the Mac the replacement is made to fail where it can: the backup path is occupied by a directory.
        let blocker = filePath + ".bak"
        try FileManager.default.createDirectory(atPath: blocker, withIntermediateDirectories: true); try write((blocker as NSString).appendingPathComponent("keep"), "x")
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        XCTAssertThrowsError(try cache.save(try book(3))) { XCTAssertTrue(($0 as? CalcError)?.isIO == true, "\($0)") }
        try reader.close(); try FileManager.default.removeItem(atPath: blocker)
        XCTAssertEqual(try cache.load().book.latest?.rates["USD"], Rational(2)); XCTAssertTrue(try files(".tmp").isEmpty)
    }
    func testInterruptedStagingAndCompetingWritersCannotGrowTheCacheOrReplaceGoodData() throws {
        let cache = CurrencyRateCache(directory); try cache.save(try book(2))
        try write(filePath + ".tmp", "partial interrupted response")
        try cache.save(try book(3)); XCTAssertFalse(FileManager.default.fileExists(atPath: filePath + ".tmp"))
        // FileShare.None on the ownership file: .NET on Unix takes an exclusive flock, as the cache's own writer does.
        let lock = open(filePath + ".lock", O_RDWR); XCTAssertTrue(lock >= 0); XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try cache.save(try book(4))) { XCTAssertTrue(($0 as? CalcError)?.isIO == true, "\($0)") }
        close(lock)
        XCTAssertEqual(try cache.load().book.latest?.rates["USD"], Rational(3))
        XCTAssertTrue(try files().count <= 3) // primary, backup, zero-byte ownership file
    }
    func testRefreshPolicyHasNoDisabledHiddenComposingOrUnusedWork() throws {
        for flags in [(false, true, false, true, false), (true, false, false, true, false), (true, true, true, true, false), (true, true, false, false, false), (true, true, false, true, true)] {
            XCTAssertNil(CurrencyRefreshPolicy.next(flags.0, flags.1, flags.2, flags.3, flags.4, nil, now, nil))
        }
        XCTAssertEqual(CurrencyRefreshPolicy.next(true, true, false, true, false, nil, now, nil), now)
        XCTAssertEqual(CurrencyRefreshPolicy.next(true, true, false, true, false, try snapshot(), now, nil), Instant(unixTicks: now.unixTicks + Ticks.perDay))
        XCTAssertEqual(CurrencyRefreshPolicy.failed(now, Ticks.perSecond), Instant(unixTicks: now.unixTicks + 15 * Ticks.perMinute))
        XCTAssertEqual(CurrencyRefreshPolicy.failed(now, 5 * Ticks.perDay), Instant(unixTicks: now.unixTicks + Ticks.perDay))
        XCTAssertEqual(CurrencyRefreshPolicy.next(true, true, false, true, false, nil, now, Instant(unixTicks: now.unixTicks + Ticks.perHour)), Instant(unixTicks: now.unixTicks + Ticks.perHour))
    }
}
