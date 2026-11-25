import XCTest
@testable import CalculatorEngine

final class TimeIntervalTests: XCTestCase {
    private func isArithmetic(_ error: Error) -> Bool { (error as? CalcError)?.isArithmetic == true }

    func testExactClockAndIntervalFixtures() throws {
        let cases = try JSONNode.parse(Fixtures.data("time-intervals-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let source = try item.property("source").string(), expected = try item.property("expected").string()
            let error = try item.optionalProperty("error")?.bool() ?? false
            let answers = try SheetEvaluator.evaluate(source); let result = answers[answers.count - 1]
            XCTAssertEqual(result.display, expected, source)
            if error { XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source); return }
            for answer in answers { XCTAssertNil(answer.error, source) }
            let pasted = try SheetEvaluator.evaluate(result.display)[0]; XCTAssertNil(pasted.error, source)
            let value = try XCTUnwrap(result.value), pastedValue = try XCTUnwrap(pasted.value)
            XCTAssertEqual(value.kind, pastedValue.kind, source)
            if value.kind == .time { XCTAssertEqual(value, pastedValue, source) }
            else {
                XCTAssertEqual(try value.exact, try pastedValue.exact, source)
                XCTAssertEqual(try value.unit?.dimension, try pastedValue.unit?.dimension, source)
                XCTAssertEqual(value.isPercentage, pastedValue.isPercentage, source)
            }
        }
    }
    func testClockValuesHaveNoImplicitNumericOrDateMeaning() throws {
        let value = try XCTUnwrap(try SheetEvaluator.evaluate("09:15")[0].value)
        XCTAssertEqual(value.kind, .time); XCTAssertFalse(value.isRational); XCTAssertFalse(value.isPercentage)
        XCTAssertThrowsError(try value.scalar) { XCTAssertTrue(self.isArithmetic($0)) }; XCTAssertThrowsError(try value.date) { XCTAssertTrue(self.isArithmetic($0)) }
        XCTAssertEqual(ClockTime(TimeOnly(ticks: 9 * Ticks.perHour + 15 * Ticks.perMinute)), try value.time)
        XCTAssertFalse(try SheetEvaluationSession().evaluateWithFunctions("09:15–17:40", .empty, []).usesCurrentDate)
    }
    func testSeededRangesMatchIndependentMinuteEnumeration() throws {
        var random = NetRandom(1107)
        for _ in 0..<1000 {
            let start = random.next(1440), end = random.next(1440); var expected = 0
            var minute = start; while minute != end { expected += 1; minute = (minute + 1) % 1440 }
            let source = pad(start / 60, 2) + ":" + pad(start % 60, 2) + "–" + pad(end / 60, 2) + ":" + pad(end % 60, 2)
            let result = try SheetEvaluator.evaluate(source)[0]; XCTAssertNil(result.error, source)
            XCTAssertEqual(try XCTUnwrap(result.value).exact.rational, Rational(expected * 60), source)
            let breakMinutes = random.next(0, expected + 1)
            XCTAssertEqual(try XCTUnwrap(try SheetEvaluator.evaluate(source + " - \(breakMinutes) min")[0].value).exact.rational, Rational((expected - breakMinutes) * 60), source)
            XCTAssertNotNil(try SheetEvaluator.evaluate(source + " - \(expected + 1) min")[0].error, source)
        }
    }
    func testSeededClockShiftsRetainEveryExplicitDay() throws {
        var random = NetRandom(1111)
        for _ in 0..<400 {
            let start = random.next(1440), shift = random.next(-10000, 10001), total = start + shift
            let day = total >= 0 ? total / 1440 : -((-total + 1439) / 1440), minute = total - day * 1440 // Math.Floor(total / 1440m)
            let result = try SheetEvaluator.evaluate(pad(start / 60, 2) + ":" + pad(start % 60, 2) + " + (\(shift) min)")[0]; XCTAssertNil(result.error)
            XCTAssertEqual(try XCTUnwrap(result.value).time.dayOffset, day)
            XCTAssertEqual(try XCTUnwrap(result.value).time.time, TimeOnly(ticks: Int64(minute / 60) * Ticks.perHour + Int64(minute % 60) * Ticks.perMinute))
        }
    }
    func testNamesFunctionsAndReceiptsRespectClockLiteralRoles() throws {
        let source = "from home=7\nfrom home+1\nfrom(x)=x+1\nfrom(2)\nf(h)=20/h\nf(4)"
        let result = try SheetEvaluator.evaluate(source); XCTAssertEqual(result[1].display, "8"); XCTAssertEqual(result[3].display, "3"); XCTAssertEqual(result[5].display, "5")
        let first = try FunctionUpdate.prepare("f()=9:15pm", .empty, [])
        XCTAssertFalse(try FunctionUpdate.prepare("F()=9:15 PM", first.library, first.receipts).hasChanges)
        let changed = try SheetEvaluationSession().evaluateWithFunctions("f()=9:15am\nf()", first.library, first.receipts)
        XCTAssertTrue(changed.functions.hasChanges); XCTAssertEqual(changed.results[1].display, "09:15")
    }
    func testIntervalChangesInvalidateDependentsAndExplanations() throws {
        let session = SheetEvaluationSession(); let source = "start=22:00\nfrom start to 06:00\nprev-30min\n2+2"
        _ = try session.evaluate(source); let changed = try session.evaluate(source.replacingOccurrences(of: "22:00", with: "21:00"))
        XCTAssertEqual(changed[1].display, "9 h"); XCTAssertEqual(changed[2].display, "8 h 30 min"); XCTAssertTrue(session.lastStatistics.reusedResults > 0)
        XCTAssertTrue(changed[1].explanation.contains { $0.operation == "clock interval" && $0.assumption!.contains("rolls over once") })
        let failed = try session.evaluate(source.replacingOccurrences(of: "22:00", with: "25:00")); XCTAssertNil(failed[1].value); XCTAssertNil(failed[2].value)
    }
    func testDurationFormattingRemainsExactForLargeOrFractionalResults() throws {
        let result = try SheetEvaluator.evaluate("(09:00–10:00)/7")[0]; XCTAssertNil(result.error)
        let pasted = try SheetEvaluator.evaluate(result.display)[0]; XCTAssertNil(pasted.error); XCTAssertEqual(try XCTUnwrap(result.value).exact, try XCTUnwrap(pasted.value).exact)
        let large = try SheetEvaluator.evaluate("(09:00–10:00)*10^1000")[0]; XCTAssertNil(large.error); XCTAssertTrue(large.display.netLength <= 2048)
        XCTAssertEqual(try XCTUnwrap(large.value).exact.rational, try Rational(BigInt.pow(10, 1000) * BigInt(3600)))
    }
    func testEquivalentRateUnitsCancelWithoutChangingCanonicalMagnitude() throws {
        for source in ["(09:00–10:30)*10km/h", "(09:00–10:30)*10000m/h", "(09:00–10:30)*250m/90s"] {
            let value = try SheetEvaluator.evaluate(source)[0]; XCTAssertNil(value.error, source)
            XCTAssertEqual(try XCTUnwrap(value.value).exact.rational, Rational(15000), source)
            XCTAssertEqual(try XCTUnwrap(value.value).unit?.dimension, Dimension(1, 0, 0, 0, 0, 0, 0, 0), source)
        }
    }
    func testCancellationAndPrecisionLimitsDoNotReplaceTheLastSnapshot() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("09:00–10:00"); let before = session.lastStatistics
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try session.evaluate("09:00–11:00", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(session.lastStatistics, before)
        XCTAssertEqual(try session.evaluate("09:00–10:00")[0].display, "1 h"); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        XCTAssertNotNil(try SheetEvaluator.evaluate("09:00+10^1000 s")[0].error)
    }
    func testInvalidClockDomainsNeverBecomePlausibleNumbers() throws {
        try theory(["9:5", "25:00", "24:01", "09:60", "09:00:60", "09:00:0", "09:00:00.00000001", "09:00.5", "13:00pm", "00:00am", "24:00pm", "09:00+10",
                    "09:00+1m", "09:00+1month", "09:00+0.00000001s", "09:00+09:00", "09:00*2", "-09:00", "09:00%", "sqrt(09:00)", "09:00 in h",
                    "09:00 to 2 decimals", "09:00–10:00-61min", "(09:00–10:00)*-1", "24:00–01:00", "1m–2m", "09:00–2026-10-30", "1h-09:00",
                    "09:00+3660001day", "from 09:00"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]; XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
}
