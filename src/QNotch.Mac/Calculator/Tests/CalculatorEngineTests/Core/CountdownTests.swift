import XCTest
@testable import CalculatorEngine

final class CountdownTests: XCTestCase {
    static let clock = EvaluationContext(today: DateOnly(2026, 10, 30), now: utc(2026, 10, 30, 12), localZone: try! LocalZoneSnapshot(FixedZone.utc, version: "test UTC"))
    private var clock: EvaluationContext { CountdownTests.clock }

    func testExactCountdownAndRelatedLocalZoneExamples() throws {
        try theory([
            ("until 13:30", "1 h 30 min"), ("until 09:00", "0 s"), ("until 12:00", "0 s"), ("until 24:00", "12 h"), ("until today", "0 s"),
            ("until tomorrow", "12 h"), ("until monday", "2 day 12 h"), ("until friday", "0 s"), ("until next friday", "6 day 12 h"),
            ("until last monday", "0 s"), ("until Christmas", "55 day 12 h"), ("until new year", "62 day 12 h"), ("until New Years Day", "62 day 12 h"),
            ("until 25 dec", "55 day 12 h"), ("until dec 25", "55 day 12 h"), ("days until christmas", "56 day"), ("until 2026-11-01", "1 day 12 h"),
            ("until 2026-10-30 13:00", "1 h"), ("until 2026-10-30T13:00Z", "1 h"), ("until 2026-10-30T13:00+01:00", "0 s"),
            ("until 2026-10-30 22:00 Tokyo", "1 h"), ("until 2026-10-30 22:00 in Tokyo", "1 h"), ("until 22:00 in Tokyo in min", "60 min"),
            ("until now in Tokyo", "0 s"), ("until 2026-10-30 in Tokyo", "0 s"), ("until 2026-10-30 15:00 London", "3 h"),
            ("until tomorrow at 13:00", "1 day 1 h"), ("until today+2day", "1 day 12 h"), ("until Christmas 18:00", "56 day 6 h"),
            ("until 2026-10-30T12:00:00.0000001Z", "0.0000001 s"), ("until 2020-01-01", "0 s"), ("until 13:00 in min", "60 min"),
            ("(until 13:00) * 2", "2 h"), ("(until 13:00) / 7", "(8 min + (240/7) s)"), ("deadline=tomorrow\nuntil deadline", "12 h"),
            ("f(d)=until d\nf(2026-11-01)", "1 day 12 h"), ("f()=until Christmas\nf()", "55 day 12 h"), ("a=until 13:00\nb=until 15:00\nsum", "4 h"),
            ("a=until 2026-11-01\nb=until 2026-11-02\naverage", "2 day"), ("until 2026-10-30T12:00:01.555Z to 2 decimals", "1.56 s"),
            ("15:00 in Tokyo", "2026-10-31T00:00:00+09:00"), ("2026-10-30T15:00 in Tokyo", "2026-10-31T00:00:00+09:00"),
            ("2026-10-30 15:00 local in Tokyo", "2026-10-31T00:00:00+09:00"),
        ]) { source, expected in
            let answers = try SheetEvaluator.evaluate(source, context: clock)
            for answer in answers { XCTAssertNil(answer.error, source) }
            let result = answers[answers.count - 1]; XCTAssertEqual(result.display, expected, source)
            let pasted = try SheetEvaluator.evaluate(result.display, context: clock)[0]; XCTAssertNil(pasted.error, source)
            let value = try XCTUnwrap(result.value), pastedValue = try XCTUnwrap(pasted.value)
            if value.kind == .number { XCTAssertEqual(try value.exact, try pastedValue.exact, source); XCTAssertEqual(try value.unit?.dimension, try pastedValue.unit?.dimension, source) }
            else { XCTAssertEqual(try value.moment.instant, try pastedValue.moment.instant, source) }
        }
    }
    func testPublishedChristmasExampleHasAnIndependentElapsedTimeDerivation() throws {
        let context = clock.with { $0.today = DateOnly(2026, 10, 15); $0.now = utc(2026, 10, 15, 20, 40) }
        XCTAssertEqual(try SheetEvaluator.evaluate("days until christmas", context: context)[0].display, "71 day")
        XCTAssertEqual(try SheetEvaluator.evaluate("until Christmas", context: context)[0].display, "70 day 3 h 20 min")
    }
    func testInvalidEndpointsAndSkippedOrAmbiguousWallTimesFail() throws {
        try theory(["until 1", "until 1month", "until 1h", "until 50%", "until", "until 2026-03-29 02:30 Budapest", "until 2026-10-25 02:30 Budapest",
                    "until 2011-12-30 Pacific/Apia", "until 31 feb", "until 29 feb 2025", "until 9999-12-31T24:00Z"]) { source in
            let results = try SheetEvaluator.evaluate(source, context: clock), result = results[results.count - 1]
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
    func testExpiredFixedDeadlineRetainsClockDependencyWithoutSecondTicks() throws {
        let session = SheetEvaluationSession(); let source = "until 2026-10-30T12:00:01Z\n2+2"
        let active = try session.evaluateWithFunctions(source, .empty, [], context: clock)
        XCTAssertTrue(active.usesCurrentInstant); XCTAssertTrue(active.requiresSecondRefresh); XCTAssertFalse(active.usesCurrentDate); XCTAssertFalse(active.usesLocalTimeZone)
        let expired = try session.evaluateWithFunctions(source, .empty, [], context: clock.with { $0.now = $0.now!.adding(seconds: 2) })
        XCTAssertEqual(expired.results[0].display, "0 s"); XCTAssertTrue(expired.usesCurrentInstant); XCTAssertFalse(expired.requiresSecondRefresh); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let cached = try session.evaluateWithFunctions(source, .empty, [], context: clock.with { $0.now = $0.now!.adding(seconds: 2) })
        XCTAssertFalse(cached.requiresSecondRefresh); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let rollback = try session.evaluateWithFunctions(source, .empty, [], context: clock)
        XCTAssertEqual(rollback.results[0].display, "1 s"); XCTAssertTrue(rollback.requiresSecondRefresh)
        XCTAssertTrue(expired.results[0].explanation.contains { $0.operation == "countdown" && $0.assumption!.contains("Expired") })
    }
    func testMidnightAndAnnualOrWeekdayOccurrencesUseDateSnapshots() throws {
        let session = SheetEvaluationSession(); let source = "until 01:00\nuntil Christmas\n2+2"
        let expired = try session.evaluateWithFunctions(source, .empty, [], context: clock)
        XCTAssertTrue(expired.usesCurrentDate); XCTAssertTrue(expired.usesLocalTimeZone)
        let midnight = clock.with { $0.today = DateOnly(2026, 10, 31); $0.now = utc(2026, 10, 31) }
        XCTAssertEqual(try session.evaluate(source, context: midnight)[0].display, "1 h"); XCTAssertTrue(session.lastStatistics.reusedResults > 0)
        let christmasDay = clock.with { $0.today = DateOnly(2026, 12, 25); $0.now = utc(2026, 12, 25, 12) }
        XCTAssertEqual(try session.evaluate("until Christmas", context: christmasDay)[0].display, "0 s")
        XCTAssertEqual(try session.evaluate("until Christmas", context: christmasDay.with { $0.today = DateOnly(2026, 12, 26); $0.now = utc(2026, 12, 26, 12) })[0].display, "363 day 12 h")
        XCTAssertEqual(try SheetEvaluator.evaluate("29 feb", context: clock)[0].display, "2028-02-29")
        XCTAssertEqual(try SheetEvaluator.evaluate("29 feb", context: clock.with { $0.today = DateOnly(1896, 3, 1) })[0].display, "1904-02-29")
        XCTAssertNotNil(try SheetEvaluator.evaluate("29 feb", context: clock.with { $0.today = DateOnly(9997, 1, 1) })[0].error)
    }
    func testDstElapsedIntervalsAndStrictLocalResolutionUseInjectedRules() throws {
        let zone = try LocalZoneSnapshot(XCTUnwrap(Tzdb.provider.zone("America/New_York")), version: Tzdb.provider.versionId)
        let spring = clock.with { $0.today = DateOnly(2026, 3, 8); $0.now = utc(2026, 3, 8, 5); $0.localZone = zone }
        XCTAssertEqual(try SheetEvaluator.evaluate("until tomorrow", context: spring)[0].display, "23 h")
        XCTAssertEqual(try SheetEvaluator.evaluate("until 03:00", context: spring)[0].display, "2 h")
        XCTAssertNotNil(try SheetEvaluator.evaluate("until 02:30", context: spring)[0].error)
        let autumn = spring.with { $0.today = DateOnly(2026, 11, 1); $0.now = utc(2026, 11, 1, 4) }
        XCTAssertEqual(try SheetEvaluator.evaluate("until tomorrow", context: autumn)[0].display, "1 day 1 h")
        XCTAssertNotNil(try SheetEvaluator.evaluate("until 01:30", context: autumn)[0].error)
        XCTAssertEqual(try SheetEvaluator.evaluate("until 01:30 local earlier", context: autumn)[0].display, "1 h 30 min")
        XCTAssertEqual(try SheetEvaluator.evaluate("until 01:30 local later", context: autumn)[0].display, "2 h 30 min")
        XCTAssertEqual(try SheetEvaluator.evaluate("until 01:30 in local later", context: autumn)[0].display, "2 h 30 min")
    }
    func testLocalRuleChangesAndMissingSnapshotsInvalidateOnlyReaders() throws {
        let session = SheetEvaluationSession(); let source = "until 2026-10-30T14:00\nnow in unix\n2+2"
        let missing = try session.evaluateWithFunctions(source, .empty, [], context: clock.with { $0.localZone = nil })
        XCTAssertTrue(missing.usesLocalTimeZone); XCTAssertNotNil(missing.results[0].error)
        let a = try session.evaluate(source, context: clock); XCTAssertEqual(a[0].display, "2 h"); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let b = try session.evaluate(source, context: clock.with { $0.localZone = try! LocalZoneSnapshot(FixedZone(offset: 3600), version: "test UTC+1") })
        XCTAssertEqual(b[0].display, "1 h"); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let noNow = try session.evaluateWithFunctions("until 2026-11-01", .empty, [], context: clock.with { $0.now = nil })
        XCTAssertNotNil(noNow.results[0].error); XCTAssertTrue(noNow.usesCurrentInstant); XCTAssertFalse(noNow.requiresSecondRefresh)
        XCTAssertEqual(try session.evaluate("until 2026-11-01", context: clock)[0].display, "1 day 12 h")
    }
    func testSavedFunctionsOnlyRefreshWhenCalledAndDeclaredNamesRemainNames() throws {
        let update = try FunctionUpdate.prepare("f(d)=until d\ng()=f(2026-11-01)", .empty, [])
        let session = SheetEvaluationSession()
        XCTAssertFalse(try session.evaluateWithFunctions("2+2", update.library, [], context: clock).usesCurrentInstant)
        let active = try session.evaluateWithFunctions("g()\n2+2", update.library, [], context: clock); XCTAssertTrue(active.requiresSecondRefresh)
        XCTAssertTrue(active.results[0].explanation.contains { $0.operation == "countdown" && $0.assumption!.contains("2026-11-01T00:00:00Z") && $0.assumption!.contains("test UTC") })
        let next = try session.evaluateWithFunctions("g()\n2+2", update.library, [], context: clock.with { $0.now = $0.now!.adding(seconds: 1) })
        XCTAssertEqual(next.results[0].display, "1 day 11 h 59 min 59 s"); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let names = try SheetEvaluator.evaluate("until=7\nuntil+1\nChristmas=9\nChristmas+1\nfriday=3\nfriday+1\nuntil(x)=x+2\nuntil(4)\nf(christmas)=christmas+1\nf(5)", context: clock)
        XCTAssertEqual(names[1].display, "8"); XCTAssertEqual(names[3].display, "10"); XCTAssertEqual(names[5].display, "4"); XCTAssertEqual(names[7].display, "6"); XCTAssertEqual(names[9].display, "6")
    }
    func testExactPositiveCountdownsMatchIndependentTickSubtraction() throws {
        var random = NetRandom(9031)
        for _ in 0..<500 {
            let ticks = random.nextInt64(-Ticks.perDay, Ticks.perDay * 100)
            let target = try XCTUnwrap(clock.now!.adding(ticks: ticks).utcDateTime)
            // target.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'")
            let text = target.date.description + "T" + target.timeOfDay.hhmmss7 + "Z"
            let result = try SheetEvaluator.evaluate("until " + text, context: clock)[0]
            XCTAssertNil(result.error, text); XCTAssertEqual(try XCTUnwrap(result.value).exact.rational, try Rational(BigInt(max(0, ticks)), BigInt(Ticks.perSecond)), text)
        }
    }
    func testCancelledCountdownDoesNotReplaceThePreviousClockCache() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("until tomorrow", context: clock); let before = session.lastStatistics
        let canceled = CancellationToken(); canceled.cancel()
        XCTAssertThrowsError(try session.evaluate("until Christmas", canceled, context: clock)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(session.lastStatistics, before)
        XCTAssertEqual(try session.evaluate("until tomorrow", context: clock)[0].display, "12 h"); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
    }
    /// C# builds two synthetic TimeZoneInfo zones (base UTC-5 and UTC-4, both with US-style 2026 DST: second Sunday of
    /// March to first Sunday of November at 02:00) and converts them with LocalZoneSnapshot.FromTimeZoneInfo. The Mac
    /// cannot create custom host zones and never converts host rules: its snapshot comes from the embedded TZDB by IANA
    /// id (LocalZoneSnapshot.fromIdentifier, without reading the OS zone). So this port uses America/New_York, whose 2026
    /// rules equal the synthetic UTC-5 zone, checks that equal ids give equal versions and different rules different
    /// versions, and checks the fallback for an id the embedded TZDB does not know.
    func testCapturedBclRulesResolveSyntheticDstAndVersionChangesWithoutReadingTheOsZone() throws {
        let local = LocalZoneSnapshot.fromIdentifier("America/New_York", currentOffsetSeconds: -5 * 3600)
        XCTAssertEqual(local.version, LocalZoneSnapshot.fromIdentifier("America/New_York", currentOffsetSeconds: -5 * 3600).version)
        XCTAssertNotEqual(local.version, LocalZoneSnapshot.fromIdentifier("America/Halifax", currentOffsetSeconds: -4 * 3600).version)
        let unknown = LocalZoneSnapshot.fromIdentifier("test-local", currentOffsetSeconds: -5 * 3600)
        XCTAssertEqual(unknown.version, "TimeZone:test-local:not in TZDB: 2026f (mapping: 49); fixed UTC-05"); XCTAssertEqual(unknown.rules.id, "UTC-05")
        XCTAssertNotEqual(unknown.version, LocalZoneSnapshot.fromIdentifier("test-local", currentOffsetSeconds: -4 * 3600).version)
        let context = clock.with { $0.today = DateOnly(2026, 3, 8); $0.now = utc(2026, 3, 8, 5); $0.localZone = local }
        XCTAssertEqual(try SheetEvaluator.evaluate("until tomorrow", context: context)[0].display, "23 h")
        XCTAssertNotNil(try SheetEvaluator.evaluate("until 02:30", context: context)[0].error)
    }
}
