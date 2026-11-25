import XCTest
@testable import CalculatorEngine

final class WorkdayTests: XCTestCase {
    private func context(_ region: String = "DE") -> EvaluationContext { EvaluationContext(today: DateOnly(2026, 10, 31), workdayRegion: region) }
    private func last(_ source: String, _ region: String = "DE") throws -> LineResult {
        let results = try SheetEvaluator.evaluate(source, context: context(region)); return results[results.count - 1]
    }
    private func dates(_ region: String, _ year: Int) throws -> [String] { try WorkdayCalendar(region).holidays(year).map(\.date.description) }

    func testCoverageManifestMatchesTheAvailableCalendarRegimes() throws {
        let json = try JSONNode.parse(Fixtures.data("spec/workday-calendars.json"))
        XCTAssertEqual(WorkdayCalendar.ruleVersion, try json.property("version").string())
        let entries = try json.property("calendars").arrayItems()
        XCTAssertEqual(WorkdayCalendar.supportedRegions, try entries.map { try $0.property("id").string() })
        for entry in entries {
            let calendar = try WorkdayCalendar(try entry.property("id").string())
            XCTAssertEqual(calendar.firstYear, try entry.property("firstYear").int())
            XCTAssertEqual(calendar.lastYear, try entry.property("lastYear").int())
        }
    }
    func testDocumentedAndBoundaryExamples() throws {
        try theory([
            ("1 mar 2027 + 10 working days", "2027-03-15"), ("1 jun 2027 - 15 working days", "2027-05-10"),
            ("workdays between 1 mar 2027 and 31 mar 2027", "21"), ("working days in march 2027", "21"), ("working days in december 2027", "23"),
            ("20 dec 2027 + 5 working days", "2027-12-27"), ("holidays=[24 dec,31 dec]\n20 dec 2027 + 5 working days", "2027-12-28"),
            ("holidays=[24 dec,31 dec]\nworking days in december 2027", "21"), ("holidays=[]\n20 dec 2027 + 5 business days", "2027-12-27"),
            ("holidays=[2027-12-24]\n20 dec 2028 + 5 workdays", "2028-12-29"), ("2027-03-27 + 0 working days", "2027-03-27"),
            ("2027-03-25 + 1 working day", "2027-03-30"), ("2027-03-30 - 1 working day", "2027-03-25"),
            ("workdays between 2027-03-31 and 2027-03-01", "-21"), ("workdays between 2027-03-01 and 2027-03-01", "1"),
            ("workdays between 2027-03-27 and 2027-03-27", "0"), ("in 2 working days", "2026-11-03"), ("2 working days ago", "2026-10-29"),
        ]) { source, expected in
            let result = try last(source); XCTAssertNil(result.error, source); XCTAssertEqual(result.display, expected, source)
        }
    }
    func testOfficialGermanAndFederalTablesAreIndependentDateOracles() throws {
        XCTAssertEqual(try dates("DE", 2026), ["2026-01-01", "2026-04-03", "2026-04-06", "2026-05-01", "2026-05-14", "2026-05-25", "2026-10-03", "2026-12-25", "2026-12-26"])
        XCTAssertEqual(try dates("DE", 2027), ["2027-01-01", "2027-03-26", "2027-03-29", "2027-05-01", "2027-05-06", "2027-05-17", "2027-10-03", "2027-12-25", "2027-12-26"])
        XCTAssertEqual(try dates("US", 2027), ["2027-01-01", "2027-01-18", "2027-02-15", "2027-05-31", "2027-06-18", "2027-07-05", "2027-09-06", "2027-10-11", "2027-11-11", "2027-11-25", "2027-12-24", "2027-12-31"])
        XCTAssertEqual(try dates("US", 2026), ["2026-01-01", "2026-01-19", "2026-02-16", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-10-12", "2026-11-11", "2026-11-26", "2026-12-25"])
        // OPM lists New Year 2028's observance under 2028; it belongs to calendar year 2027 above.
        XCTAssertEqual(try dates("US", 2028), ["2028-01-17", "2028-02-21", "2028-05-29", "2028-06-19", "2028-07-04", "2028-09-04", "2028-10-09", "2028-11-10", "2028-11-23", "2028-12-25"])
        XCTAssertEqual(try last("2027-12-23 + 1 working day", "US").display, "2027-12-27")
        XCTAssertEqual(try last("2027-12-30 + 1 working day", "US").display, "2028-01-03")
        XCTAssertEqual(try last("2027-12-30 + 1 working day", "DE").display, "2027-12-31")
    }
    func testCalendarContextAndCustomDateDependenciesInvalidateOnlyConsumers() throws {
        let session = SheetEvaluationSession()
        let source = "holidays=[24 dec]\nlead=1 working day\n2027-12-23+lead\n2+2"
        XCTAssertEqual(try session.evaluate(source, context: context())[2].display, "2027-12-27")
        let changed = try session.evaluate(source.replacingOccurrences(of: "24 dec", with: "23 dec"), context: context())
        XCTAssertEqual(changed[2].display, "2027-12-24"); XCTAssertEqual(changed[1].dependencies, [0])
        XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        XCTAssertEqual(try session.evaluate(source, context: context("US"))[2].display, "2027-12-27")
        let unchanged = try session.evaluate(source, context: context("US").with { $0.today = DateOnly(2026, 11, 1) })
        XCTAssertEqual(session.lastStatistics.reusedResults, 4)
        for value in unchanged { XCTAssertNil(value.error) }
        _ = try session.evaluate("2027-12-23+1 working day\n4", context: context("ZZ"))
        XCTAssertEqual(try session.evaluate("2027-12-23+1 working day\n4", context: context())[0].display, "2027-12-24")
    }
    func testHolidayScopeIsPrecedingSourceAndOffsetsCaptureTheirCalendar() throws {
        let results = try SheetEvaluator.evaluate("lead=1 working day\nholidays=[24 dec]\n2027-12-23+lead\n2027-12-23+1 working day\nholidays=[]\n2027-12-23+1 working day", context: context())
        for value in results { XCTAssertNil(value.error) }
        XCTAssertEqual(results[2].display, "2027-12-24"); XCTAssertEqual(results[3].display, "2027-12-27"); XCTAssertEqual(results[5].display, "2027-12-24")
        XCTAssertEqual(results[3].dependencies, [1]); XCTAssertEqual(results[5].dependencies, [4])
    }
    func testNestedFunctionsReadTheCallingLinesHolidayScopeAndCurrentRegion() throws {
        let source = "f(n)=g(n)\ng(n)=n working days\nholidays=[24 dec]\n2027-12-23+f(1)"
        let session = SheetEvaluationSession()
        let result = try session.evaluate(source, context: context()); XCTAssertEqual(result[result.count - 1].display, "2027-12-27")
        XCTAssertEqual(result[result.count - 1].dependencies, [2])
        XCTAssertTrue(result[result.count - 1].explanation.contains { $0.operation == "working days" && $0.assumption!.contains("Germany") })
        let withoutHolidays = source.replacingOccurrences(of: "[24 dec]", with: "[]")
        XCTAssertEqual(try session.evaluate(withoutHolidays, context: context()).last!.display, "2027-12-24")
        XCTAssertEqual(try session.evaluate(withoutHolidays, context: context("US")).last!.display, "2027-12-27")
    }
    func testRandomWeekdayCountsMatchAnIndependentDailyEnumerator() throws {
        var random = NetRandom(7331)
        for _ in 0..<500 {
            let start = DateOnly(2023, 1, 1)!.addingDays(random.next(1000))!; let end = start.addingDays(random.next(400))!
            let dates: Set<DateOnly> = [DateOnly(start.year, 12, 24)!, DateOnly(start.year + 1, 12, 24)!]
            let expected = (start.dayNumber...end.dayNumber).map(DateOnly.init(dayNumber:))
                .filter { $0.dayOfWeek != .saturday && $0.dayOfWeek != .sunday && !dates.contains($0) }.count
            let result = try last("holidays=[24 dec]\nworkdays between \(start) and \(end)", "WEEKDAYS")
            XCTAssertNil(result.error); XCTAssertEqual(result.display, String(expected))
        }
    }
    func testShiftsAndCountsMatchDailyEnumerationOfTheOfficial2027GermanDates() throws {
        // A fixed table from official publications; this oracle does not call the holiday generator.
        let closed: Set<DateOnly> = Set([(1, 1), (3, 26), (3, 29), (5, 1), (5, 6), (5, 17), (10, 3), (12, 25), (12, 26), (12, 24)].map { DateOnly(2027, $0.0, $0.1)! })
        func open(_ date: DateOnly) -> Bool { (1...5).contains(date.dayOfWeek.rawValue) && !closed.contains(date) }
        var random = NetRandom(2727)
        for _ in 0..<400 {
            let start = DateOnly(2027, 1, 31)!.addingDays(random.next(300))!; let amount = random.next(-20, 21)
            var expected = start, remaining = abs(amount)
            while remaining > 0 { expected = expected.addingDays(amount.signum())!; if open(expected) { remaining -= 1 } }
            let actual = try last("holidays=[24 dec]\n\(start) + (\(amount)) working days")
            XCTAssertNil(actual.error); XCTAssertEqual(try XCTUnwrap(actual.value).date, expected)
            let end = start.addingDays(random.next(90))!
            let count = (start.dayNumber...end.dayNumber).map(DateOnly.init(dayNumber:)).filter(open).count
            XCTAssertEqual(try last("holidays=[24 dec]\nworkdays between \(start) and \(end)").display, String(count))
        }
    }
    func testCustomDateSnapshotsPropagateClockReadsAndStaticFunctionsStayIndependent() throws {
        let session = SheetEvaluationSession()
        let source = "f(x)=x+1\nholidays=[today]\n2027-03-01+1 working day\nf(4)"
        let first = try session.evaluateWithFunctions(source, .empty, [], context: context().with { $0.today = DateOnly(2027, 3, 2) })
        XCTAssertTrue(first.usesCurrentDate); XCTAssertFalse(first.usesCurrentInstant); XCTAssertFalse(first.requiresSecondRefresh)
        XCTAssertEqual(first.results[2].display, "2027-03-03")
        let next = try session.evaluateWithFunctions(source, .empty, [], context: context().with { $0.today = DateOnly(2027, 3, 3) })
        XCTAssertEqual(next.results[2].display, "2027-03-02"); XCTAssertEqual(next.results[3].display, "5")
        XCTAssertEqual(session.lastStatistics.reusedResults, 1) // Only the static numeric call has a result to reuse.
        XCTAssertTrue(next.results[3].dependencies.isEmpty)
        let unavailable = try session.evaluateWithFunctions("f(x)=x+1\nholidays=[3]\nf(4)", .empty, [], context: context("ZZ"))
        XCTAssertEqual(unavailable.results.last!.display, "5")
    }
    func testInvalidOrUnavailableInputsAreExplicit() throws {
        try theory(["2027-01-01+1.5 working days", "2027-01-01+1% working days", "2027-01-01+10001 working days", "2021-01-01+1 working day",
                    "2099-12-31+1 working day", "1 working day in h", "1 working day+1 day", "holidays=[31 feb]\n2027-01-01+1 working day",
                    "holidays=[3]\n2027-01-01+1 working day", "holidays=[2027-02-29]\n2027-01-01+1 working day"]) { source in
            XCTAssertNotNil(try last(source).error, source)
        }
    }
    func testAnnualLeapDayIsSkippedInNonLeapYearsAndExactDatesDoNotRecur() throws {
        XCTAssertEqual(try last("holidays=[29 feb]\n2024-02-28+1 working day").display, "2024-03-01")
        XCTAssertEqual(try last("holidays=[29 feb]\n2023-02-28+1 working day").display, "2023-03-01")
        XCTAssertEqual(try last("holidays=[2027-12-24]\n2028-12-22+1 working day").display, "2028-12-27")
        let set = try XCTUnwrap(try last("[24 dec,2027-12-31,24 dec]").value).holidays
        XCTAssertEqual(set.dates.count, 2); XCTAssertEqual(set, try XCTUnwrap(try last(set.description).value).holidays)
    }
    func testCancellationAndOutputTypesRemainBounded() throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("2027-01-01+5000 working days", cancellation, context: context())) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertNotNil(try last("[" + Array(repeating: "24 dec", count: 257).joined(separator: ",") + "]").error)
        let period = try XCTUnwrap(try last("2 working days").value)
        XCTAssertEqual(period.kind, .workdayPeriod); XCTAssertThrowsError(try period.scalar) { XCTAssertTrue(($0 as? CalcError)?.isArithmetic == true) }
        XCTAssertEqual(try last("1 working day").display, "1 working day"); XCTAssertEqual(try last("-1 working day").display, "-1 working day")
        XCTAssertEqual(try last("lead=5 working days*2\n1 mar 2027+lead").display, "2027-03-15")
        XCTAssertNil(try last("holidays=[3]\n2+2").error)
    }
    func testHolidayDeclarationsAreNotDuplicatedAsResultsOrIncludedInNumericTotals() throws {
        let results = try SheetEvaluator.evaluate("holidays=[24 dec]\n2\n3\nsum", context: context())
        XCTAssertTrue(results[0].isDeclaration); XCTAssertEqual(results[0].display, ""); XCTAssertNotNil(results[0].value)
        XCTAssertEqual(results.last!.display, "5"); XCTAssertNotNil(try last("holidays=7").error)
        XCTAssertEqual(try last("f(x)=x\nf(workdays between 2027-03-01 and 2027-03-02)").display, "2")
    }
}
