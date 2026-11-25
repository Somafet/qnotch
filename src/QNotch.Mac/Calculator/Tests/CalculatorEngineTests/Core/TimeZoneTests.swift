import XCTest
@testable import CalculatorEngine

/// `new DateTimeOffset(y, m, d, h, mi, s, TimeSpan.Zero)` as an instant.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Instant {
    Instant(unixTicks: Int64(DateOnly(year, month, day)!.dayNumber) * Ticks.perDay - Ticks.unixEpoch +
        Int64(hour) * Ticks.perHour + Int64(minute) * Ticks.perMinute + Int64(second) * Ticks.perSecond)
}
extension Instant {
    /// DateTimeOffset.AddSeconds / AddTicks.
    func adding(seconds: Int64 = 0, ticks: Int64 = 0) -> Instant { Instant(unixTicks: unixTicks + seconds * Ticks.perSecond + ticks) }
}
extension NetRandom {
    /// Random.NextInt64(minValue, maxValue) for a seeded Random (.NET's CompatPrng): 64 bits from three Next calls,
    /// rejection-sampled to the smallest power-of-two range covering maxValue - minValue.
    mutating func nextInt64(_ minValue: Int64, _ maxValue: Int64) -> Int64 {
        let range = UInt64(bitPattern: maxValue &- minValue)
        guard range > 1 else { return minValue }
        let bits = 64 - (range - 1).leadingZeroBitCount
        while true {
            let random = UInt64(next(1 << 22)) | UInt64(next(1 << 22)) << 22 | UInt64(next(1 << 20)) << 44
            let result = random >> (64 - bits)
            if result < range { return Int64(bitPattern: result) &+ minValue }
        }
    }
}

final class TimeZoneTests: XCTestCase {
    static let clock = EvaluationContext(today: DateOnly(2026, 10, 30), now: utc(2026, 10, 30, 12))

    func testPinnedZoneAndExactTimestampExamples() throws {
        try theory([
            ("2026-10-30 15:00 London in Tokyo", "2026-10-31T00:00:00+09:00"),
            ("15:00 London in Tokyo", "2026-10-31T00:00:00+09:00"),
            ("2026-07-01 at 15:00 Europe/London in Asia/Tokyo", "2026-07-01T23:00:00+09:00"),
            ("2026-10-30T15:00Z in New York", "2026-10-30T11:00:00-04:00"),
            ("now", "2026-10-30T12:00:00Z"),
            ("now in New York", "2026-10-30T08:00:00-04:00"),
            ("now in unix", "1793361600"),
            ("unix 0", "1970-01-01T00:00:00Z"),
            ("unix -0.0000001", "1969-12-31T23:59:59.9999999Z"),
            ("unix 0.0000001 in unix", "0.0000001"),
            ("unix -0.5 in Tokyo", "1970-01-01T08:59:59.5+09:00"),
            ("1970-01-01T05:30:00+05:30 in unix", "0"),
            ("1970-01-01T00:00:00Z in Kathmandu", "1970-01-01T05:30:00+05:30"),
            ("2026-10-30 12:00 UTC in Kathmandu", "2026-10-30T17:45:00+05:45"),
            ("2026-10-30 12:00 UTC in Pacific/Chatham", "2026-10-31T01:45:00+13:45"),
            ("2026-10-30 24:00 UTC", "2026-10-31T00:00:00Z"),
            ("2026-03-08 01:59:59 New York + 1s", "2026-03-08T03:00:00-04:00"),
            ("2026-03-08 01:00 New York + 24h", "2026-03-09T02:00:00-04:00"),
            ("2026-03-07 12:00 New York + 1day", "2026-03-08T13:00:00-04:00"),
            ("2026-02-08 12:00 New York + 1month", "2026-03-08T12:00:00-04:00"),
            ("2026-03-08 03:00 New York - 2026-03-08 01:00 New York", "1 h"),
            ("2026-03-08 03:00 - 2026-03-08 01:00", "2 h"),
            ("2026-10-25 02:30 Budapest earlier in UTC", "2026-10-25T00:30:00Z"),
            ("2026-10-25 02:30 Budapest later in UTC", "2026-10-25T01:30:00Z"),
            ("2026-11-01 01:30 New York earlier in UTC", "2026-11-01T05:30:00Z"),
            ("2026-11-01 01:30 New York later in UTC", "2026-11-01T06:30:00Z"),
            ("2026-03-15 12:00 London in New York", "2026-03-15T08:00:00-04:00"),
            ("2026-10-30T12:00:00.1234567-02:30 in UTC", "2026-10-30T14:30:00.1234567Z"),
            ("2026-10-30 12:00 UTC+18:00 in UTC-18:00", "2026-10-29T00:00:00-18:00"),
            ("1890-01-01 12:00 Europe/Paris in unix", "-2524478961"),
            ("1890-01-01 12:00 Europe/Paris", "1890-01-01T12:00:00+00:09:21"),
            ("d=2026-10-30\nt=15:00\nz=d at t Europe/Budapest\nz in Tokyo", "2026-10-30T23:00:00+09:00"),
            ("f(d,t)=d at t Europe/Budapest\nf(2026-10-30,15:00) in UTC", "2026-10-30T14:00:00Z"),
            ("f()=now\ng()=f() in unix\ng()", "1793361600"),
            ("1970-01-01 at 00:00", "1970-01-01T00:00:00"),
            ("2024-01-31T23:00+1month", "2024-02-29T23:00:00"),
            ("2026-10-30T12:00Z + 0.0000001s", "2026-10-30T12:00:00.0000001Z"),
        ]) { source, expected in
            let answers = try SheetEvaluator.evaluate(source, context: TimeZoneTests.clock)
            for answer in answers { XCTAssertNil(answer.error, source) }
            let result = answers[answers.count - 1]; XCTAssertEqual(result.display, expected, source)
            let pasted = try SheetEvaluator.evaluate(result.display, context: TimeZoneTests.clock)[0]; XCTAssertNil(pasted.error, source)
            let value = try XCTUnwrap(result.value), pastedValue = try XCTUnwrap(pasted.value)
            XCTAssertEqual(value.kind, pastedValue.kind, source)
            if value.kind == .zonedMoment { XCTAssertEqual(try value.moment.instant, try pastedValue.moment.instant, source) }
            else if value.kind == .number { XCTAssertEqual(try value.exact, try pastedValue.exact, source); XCTAssertEqual(try value.unit?.dimension, try pastedValue.unit?.dimension, source) }
            else { XCTAssertEqual(value, pastedValue, source) }
        }
    }
    func testAmbiguityGapsTypeAndRangeErrorsAreExplicit() throws {
        try theory(["2026-03-29 02:30 Budapest", "2026-10-25 02:30 Budapest", "2026-03-08 02:30 New York", "2026-11-01 01:30 New York", "2011-12-30 12:00 Pacific/Apia",
                    "2026-03-29 02:30 Budapest earlier", "2026-03-29 02:30 Budapest later", "2026-02-28 02:30 Budapest + 1month 1day", "2026-10-30 12:00 UTC+18:01",
                    "2026-10-30 12:00 UTC+2:00", "2026-10-30T12:00+02:60", "2026-10-30T12:00+02:00:60", "2026-10-30T12:00+02:00:00.1", "2026-10-30 12:00 CST",
                    "now in IST", "unix 0.00000001", "unix 10^1000", "unix 100%", "unix 1s", "2026-10-30 12:00 in Tokyo", "now + 1", "now + today", "now * 2",
                    "now in h", "sqrt(now)", "-now", "2026-10-30T12:00Z - 2026-10-30T12:00", "9999-12-31T24:00 UTC", "0001-01-01T00:00+18:00",
                    "9999-12-31T23:59:59.9999999Z+0.0000001s", "9999-12-31T23:59:59 UTC-18:00", "unix 253402300799.9999999 in UTC+18:00"]) { source in
            let results = try SheetEvaluator.evaluate(source, context: TimeZoneTests.clock), result = results[results.count - 1]
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
    func testContextMustBeProvidedAndErrorDependenciesRefresh() throws {
        let session = SheetEvaluationSession(); let source = "now in unix\n15:00 London in Tokyo\n2+2"
        let missing = try session.evaluateWithFunctions(source, .empty, [])
        XCTAssertTrue(missing.usesCurrentInstant); XCTAssertTrue(missing.usesCurrentDate); XCTAssertNotNil(missing.results[0].error); XCTAssertNotNil(missing.results[1].error)
        let fixedClock = try session.evaluateWithFunctions(source, .empty, [], context: TimeZoneTests.clock)
        XCTAssertEqual(fixedClock.results[0].display, "1793361600"); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let next = try session.evaluateWithFunctions(source, .empty, [], context: TimeZoneTests.clock.with { $0.now = $0.now!.adding(seconds: 1) })
        XCTAssertEqual(next.results[0].display, "1793361601"); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let midnight = try session.evaluate(source, context: TimeZoneTests.clock.with { $0.today = $0.today!.addingDays(1) })
        XCTAssertEqual(midnight[1].display, "2026-11-01T00:00:00+09:00")
    }
    func testNestedClockFunctionsRefreshWithoutActivatingUnusedFunctions() throws {
        let update = try FunctionUpdate.prepare("f()=now\ng()=f() in unix", .empty, [])
        let session = SheetEvaluationSession()
        XCTAssertFalse(try session.evaluateWithFunctions("2+2", update.library, [], context: TimeZoneTests.clock).usesCurrentInstant)
        let first = try session.evaluateWithFunctions("g()\n2+2", update.library, [], context: TimeZoneTests.clock)
        XCTAssertTrue(first.usesCurrentInstant); XCTAssertFalse(first.usesCurrentDate)
        let next = try session.evaluateWithFunctions("g()\n2+2", update.library, [], context: TimeZoneTests.clock.with { $0.now = $0.now!.adding(seconds: 1) })
        XCTAssertEqual(next.results[0].display, "1793361601"); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        XCTAssertFalse(try session.evaluateWithFunctions("2026-10-30 12:00 London in Tokyo", update.library, [], context: TimeZoneTests.clock).usesCurrentDate)
    }
    /// C#'s DateTimeZoneCache over a source with one id ("Europe/London") mapped to a fixed offset.
    private final class SingleZoneProvider: TimeZoneProvider {
        let versionId: String, rules: ZoneRules
        init(_ rules: ZoneRules, _ version: String) { self.rules = rules; versionId = version }
        func zone(_ id: String) -> ZoneRules? { id == "Europe/London" ? rules : nil }
    }
    func testZoneRuleSnapshotChangesInvalidateOnlyZoneReaders() throws {
        func provider(_ hours: Int) -> TimeZoneProvider { SingleZoneProvider(FixedZone(offset: hours * 3600), "test-" + String(hours)) }
        let session = SheetEvaluationSession(); let source = "2026-10-30T12:00 Europe/London in unix\nnow in unix\n2+2"
        let a = try session.evaluate(source, context: TimeZoneTests.clock.with { $0.timeZones = provider(1) })
        let b = try session.evaluate(source, context: TimeZoneTests.clock.with { $0.timeZones = provider(2) })
        XCTAssertEqual(try XCTUnwrap(a[0].value).scalar - Rational(3600), try XCTUnwrap(b[0].value).scalar); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
    }
    func testEveryManifestZoneAndCityResolvesAndCarriesThePinnedVersion() throws {
        let root = try JSONNode.parse(CalculatorEngine.resource("TimeZones.json"))
        XCTAssertEqual(try root.property("version").string(), Tzdb.provider.versionId)
        for item in try root.property("ids").arrayItems() {
            let id = try item.string()
            let result = try SheetEvaluator.evaluate("2026-01-15 12:00 " + id, context: TimeZoneTests.clock)[0]; XCTAssertNil(result.error, id + ": " + (result.error ?? ""))
        }
        for (name, value) in try root.property("aliases").objectProperties() {
            let result = try SheetEvaluator.evaluate("2026-01-15 12:00 " + name, context: TimeZoneTests.clock)[0]; XCTAssertNil(result.error, name + ": " + (result.error ?? ""))
            XCTAssertEqual(try value.string(), try result.value?.moment.zoneId, name)
        }
    }
    func testDeclaredNamesCallsAndReceiptsKeepTheirRoles() throws {
        let results = try SheetEvaluator.evaluate("now=7\nnow+1\nunix=9\nunix+1\nnow(x)=x+2\nnow(3)\nf(now)=now+1\nf(4)\nLondon=4\nLondon+1", context: TimeZoneTests.clock)
        XCTAssertEqual(results[1].display, "8"); XCTAssertEqual(results[3].display, "10"); XCTAssertEqual(results[5].display, "5"); XCTAssertEqual(results[7].display, "5"); XCTAssertEqual(results[9].display, "5")
        let update = try FunctionUpdate.prepare("f()=2026-10-30 12:00 Etc/GMT+2", .empty, [])
        let changed = try FunctionUpdate.prepare("f()=2026-10-30 12:00 Etc/GMT-2", update.library, update.receipts)
        XCTAssertTrue(changed.hasChanges)
        let attached = try FunctionUpdate.prepare("f()=2026-10-30T12:00UTC+02:00", .empty, [])
        XCTAssertTrue(try FunctionUpdate.prepare("f()=2026-10-30T12:00UTC +02:00", attached.library, attached.receipts).hasChanges)
    }
    func testCancellationCannotReplaceThePreviousClockSnapshot() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("now in unix\n2+2", context: TimeZoneTests.clock); let before = session.lastStatistics
        let canceled = CancellationToken(); canceled.cancel()
        XCTAssertThrowsError(try session.evaluate("now in Tokyo", canceled, context: TimeZoneTests.clock)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(session.lastStatistics, before)
        XCTAssertEqual(try session.evaluate("now in unix\n2+2", context: TimeZoneTests.clock)[0].display, "1793361600"); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
    }
    func testSeededUnixOffsetsMatchIndependentIntegerTickArithmetic() throws {
        var random = NetRandom(8031)
        for _ in 0..<500 {
            let seconds = random.nextInt64(-2_208_988_800, 4_102_444_800); let offset = random.next(-72, 73) * 900
            let absolute = abs(offset); let zone = "UTC" + (offset < 0 ? "-" : "+") + pad(absolute / 3600, 2) + ":" + pad(absolute / 60 % 60, 2)
            let result = try SheetEvaluator.evaluate("unix \(seconds) in \(zone)")[0]; XCTAssertNil(result.error)
            let expected = DateOnly(1970, 1, 1)!.midnight.addingTicks((seconds + Int64(offset)) * Ticks.perSecond)!
            let moment = try XCTUnwrap(result.value).moment
            XCTAssertEqual(FixedZone(offset: offset).localTicks(moment.instant), expected.ticks)
            XCTAssertEqual(try XCTUnwrap(try SheetEvaluator.evaluate(result.display + " in unix")[0].value).scalar.numerator, BigInt(seconds))
        }
    }
}
