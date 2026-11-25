import XCTest
@testable import CalculatorEngine

final class DateTests: XCTestCase {
    private let clock = EvaluationContext(today: DateOnly(2026, 10, 30))
    private func isArithmetic(_ error: Error) -> Bool { (error as? CalcError)?.isArithmetic == true }

    func testGregorianFixturesUseAnExplicitSnapshot() throws {
        let cases = try JSONNode.parse(Fixtures.data("dates-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let source = try item.property("source").string(), expected = try item.property("expected").string()
            let result = try SheetEvaluator.evaluate(source, context: clock)
            for value in result { XCTAssertNil(value.error, source) }
            let last = result[result.count - 1]
            XCTAssertEqual(last.display, expected, source)
            let pasted = try SheetEvaluator.evaluate(last.display, context: clock)[0]
            XCTAssertNil(pasted.error, source); XCTAssertEqual(last.value, pasted.value, source)
        }
    }
    func testDatesAndPeriodsCannotPretendToBeNumbers() throws {
        let date = try XCTUnwrap(try SheetEvaluator.evaluate("2024-02-29")[0].value)
        XCTAssertEqual(date.kind, .date); XCTAssertFalse(date.isRational); XCTAssertFalse(date.isPercentage)
        XCTAssertThrowsError(try date.scalar) { XCTAssertTrue(self.isArithmetic($0)) }
        XCTAssertThrowsError(try date.exact) { XCTAssertTrue(self.isArithmetic($0)) }
        XCTAssertThrowsError(try date.unit) { XCTAssertTrue(self.isArithmetic($0)) }
        // new SheetValue(new Rational(0,1)) == default(SheetValue)
        XCTAssertEqual(SheetValue.number(NumericValue(Rational.zero)), SheetValue.number(NumericValue()))
        XCTAssertNotNil(try SheetEvaluator.evaluate("today")[0].error)
        XCTAssertEqual(try SheetEvaluator.evaluate("today", context: clock)[0].display, "2026-10-30")
    }
    func testCurrentDateChangesInvalidateResultsAndCallsWithoutChangingSource() throws {
        let session = SheetEvaluationSession(); let source = "start=today\nstart+1day\n7"
        _ = try session.evaluate(source, context: clock)
        XCTAssertEqual(try session.evaluate(source, context: EvaluationContext(today: DateOnly(2026, 10, 31)))[1].display, "2026-11-01")
        XCTAssertEqual(session.lastStatistics.parsedLines, 0)
        let missing = try session.evaluate(source); XCTAssertNil(missing[0].value); XCTAssertNil(missing[1].value)
        XCTAssertEqual(try session.evaluate(source, context: clock)[1].display, "2026-10-31")
        let functions = try FunctionUpdate.prepare("f()=g()\ng()=today", .empty, [])
        XCTAssertFalse(try session.evaluateWithFunctions("1+1", functions.library, [], context: clock).usesCurrentDate)
        XCTAssertTrue(try session.evaluateWithFunctions("f()", functions.library, [], context: clock).usesCurrentDate)
        XCTAssertEqual(try session.evaluateWithFunctions("f()", functions.library, [], context: EvaluationContext(today: DateOnly(2026, 11, 1))).results[0].display, "2026-11-01")
    }
    func testAClockDependentErrorStillSchedulesItsFutureReevaluation() throws {
        let session = SheetEvaluationSession(); let source = "age of 2026-11-01"
        let early = try session.evaluateWithFunctions(source, .empty, [], context: clock)
        XCTAssertNil(early.results[0].value); XCTAssertNotNil(early.results[0].error); XCTAssertTrue(early.usesCurrentDate)
        let reached = try session.evaluateWithFunctions(source, .empty, [], context: EvaluationContext(today: DateOnly(2026, 11, 1)))
        XCTAssertEqual(reached.results[0].display, "0"); XCTAssertTrue(reached.usesCurrentDate); XCTAssertEqual(session.lastStatistics.parsedLines, 0)
    }
    func testExistingNamesAndCallsRemainNamesAndCalls() throws {
        let result = try SheetEvaluator.evaluate("today=7\ntoday+1\nin box=9\nin box+1\nage(x)=x+2\nage(3)\nf(today)=today+1day\nf(2024-02-28)")
        XCTAssertEqual(result[1].display, "8"); XCTAssertEqual(result[3].display, "10"); XCTAssertEqual(result[5].display, "5"); XCTAssertEqual(result[7].display, "2024-02-29")
        let session = SheetEvaluationSession()
        XCTAssertFalse(try session.evaluateWithFunctions("today=7\ntoday+1", .empty, [], context: clock).usesCurrentDate)
        let previous = try FunctionUpdate.prepare("f()=2024 - 01 - 01", .empty, [])
        let changed = try session.evaluateWithFunctions("f()=2024-01-01\nf()", previous.library, previous.receipts)
        XCTAssertTrue(changed.functions.hasChanges); XCTAssertEqual(changed.results[1].display, "2024-01-01")
    }
    func testDayDifferencesMatchAnIndependentGregorianCount() throws {
        func count(_ year: Int, _ month: Int, _ day: Int) -> Int {
            let y = year - 1; var count = 365 * y + y / 4 - y / 100 + y / 400 + day - 1
            let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            for m in 1..<month { count += lengths[m - 1] + (m == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 1 : 0) }
            return count
        }
        var random = NetRandom(7047)
        for _ in 0..<500 {
            let y = random.next(1, 10000), m = random.next(1, 13), d = random.next(1, 29)
            let source = pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2) + " - 0001-01-01"
            let answer = try SheetEvaluator.evaluate(source)[0]; XCTAssertNil(answer.error, source)
            XCTAssertEqual(try XCTUnwrap(answer.value).exact.rational, Rational(Int64(count(y, m, d)) * 86400), source)
        }
        XCTAssertEqual(try SheetEvaluator.evaluate("2001-01-01 - 1601-01-01")[0].display, "146097 day")
    }
    func testMonthEndsMatchIndependentIntegerCalendarArithmetic() throws {
        func length(_ y: Int, _ m: Int) -> Int { m == 2 ? (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 29 : 28) : [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1] }
        var random = NetRandom(7031)
        for _ in 0..<500 {
            let y = random.next(200, 9800), m = random.next(1, 13), d = length(y, m), shift = random.next(-240, 241)
            let index = y * 12 + m - 1 + shift, targetY = index / 12, targetM = index % 12 + 1, targetD = min(d, length(targetY, targetM))
            let value = try SheetEvaluator.evaluate(pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2) + " + (\(shift) months)")[0]
            XCTAssertNil(value.error); XCTAssertEqual(value.display, pad(targetY, 4) + "-" + pad(targetM, 2) + "-" + pad(targetD, 2))
        }
    }
    func testCalendarLimitsAndCancellationDoNotCommitPartialResults() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("today+1month", context: clock); let before = session.lastStatistics
        let cancel = CancellationToken(); cancel.cancel()
        XCTAssertThrowsError(try session.evaluate("today+2months", cancel, context: clock)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(session.lastStatistics, before)
        XCTAssertEqual(try session.evaluate("today+1month", context: clock)[0].display, "2026-11-30")
        XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        XCTAssertNotNil(try SheetEvaluator.evaluate("today+120001months", context: clock)[0].error)
        XCTAssertNotNil(try SheetEvaluator.evaluate(String(repeating: "in ", count: 20) + "1day", context: clock)[0].error)
    }
    func testInvalidCalendarDomainsHaveNoNumericFallback() throws {
        try theory(["2023-02-29", "1900-02-29", "2024-13-01", "2024-2-3", "2024-02-3", "2024-000-01", "0000-01-01", "31 apr 2024", "29 feb 24", "today+1",
                    "today+1 h", "today+0.5 day", "today+1 m", "today+tomorrow", "2 day-today", "today*2", "-today", "today%", "sqrt(today)",
                    "today to 2 decimals", "today in day", "today #x\ntomorrow #x\nsum #x", "9999-12-31+1 day", "0001-01-01-1day", "1 month / 2",
                    "100% month", "1 month*1month", "today ago", "age of tomorrow", "days between 1 and 2", "next 0"]) { source in
            let results = try SheetEvaluator.evaluate(source, context: clock), result = results[results.count - 1]
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
}
