import XCTest
@testable import CalculatorEngine

final class EarningsInvoiceTests: XCTestCase {
    private func context(_ region: String = "DE", _ year: Int = 2026) -> EvaluationContext {
        EvaluationContext(today: DateOnly(year, 10, 31), workdayRegion: region)
    }
    private func last(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let value = try SheetEvaluator.evaluate(source, context: context ?? self.context()).last!
        XCTAssertNil(value.error, source, file: file, line: line); return value
    }
    private func amount(_ result: LineResult) throws -> SheetValue {
        if case .earnings(let rate) = result.value! { return rate.amount }
        return result.value!
    }
    private func magnitude(_ result: LineResult) throws -> Rational {
        let value = try amount(result)
        return value.kind == .money ? try value.money.magnitude.scalar : try value.scalar
    }

    func testPublicAndTypedExamples() throws {
        try theory([
            ("5000 eur/month in yearly", "60000 EUR/year"), ("90000 eur/year in monthly", "7500 EUR/month"), ("60k/year in monthly", "5000/month"),
            ("100 eur/month", "100 EUR/month"), ("100 EUR per month in annually", "1200 EUR/year"), ("100 yearly in monthly", "8.3333/month"),
            ("$100/month in yearly", "1200 USD/year"), ("r=100/month\nr*2", "200/month"), ("r=100 EUR/month\nr+10%", "110 EUR/month"),
            ("r=100 EUR/month\nr*3 months", "300 EUR"), ("100 EUR/year * 6 months", "50 EUR"), ("100 EUR/month * 1 year", "1200 EUR"),
            ("100/month+1200/year", "200/month"), ("100/month / (1200/year)", "1"), ("abs(-100 EUR/month)", "100 EUR/month"),
            ("double 100 EUR/month", "200 EUR/month"), ("((100/3) EUR/month) to 1 decimal", "33.3 EUR/month"), ("100 EUR/h in daily", "800 EUR/workday"),
            ("800 EUR/day in hourly", "100 EUR/hour"), ("r=800 EUR/day in hourly\nr * 8 h", "800 EUR"), ("r=100 EUR/h in daily\nr * 8 h", "800 EUR"),
            ("100 EUR/h * 8 h", "800 EUR"), ("100 EUR/day * 2 days", "200 EUR"), ("100/month\n1200/year\nsum", "200/month"),
            ("100/month\n1200/year\naverage", "100/month"), ("f(x)=x EUR/month in yearly\nf(5000)", "60000 EUR/year"),
            ("5000 EUR/month\nprev in yearly", "60000 EUR/year"), ("5000 EUR/month\nL1 in yearly", "60000 EUR/year"),
            ("(loan 1200 at 0% for 1 year) to 2 decimals", "100"), ("1 mar 2027 net 30", "2027-03-31"), ("2028-02-28 net 2", "2028-03-01"),
            ("2027-12-20 net 10", "2027-12-30"), ("2027-03-26 net 1", "2027-03-27"), ("2027-03-26 net 0", "2027-03-26"),
            ("issued=2027-03-01\nterm=30\nissued net term", "2027-03-31"), ("f(d)=d net 30\nf(2027-03-01)", "2027-03-31"),
            ("(2027-03-01 net 30)+1 day", "2027-04-01"), ("late fee 1000 at 0.1%/day for 45 days", "45"),
            ("late fee 1000 EUR at 0.1% per day for 12 h", "0.5 EUR"), ("late fee 1000 at 0/day for 45 days", "0"), ("late fee 0 at 0.1%/day for 45 days", "0"),
            ("late fee 1000 at 0.1%/day for 0 days", "0"), ("f(p)=late fee p at 0.1%/day for 45 days\nf(1000 EUR)", "45 EUR"),
            ("(late fee 1000 at 0.1%/day for 45 days)+1000", "1045"), ("net=100\nnet+2", "102"), ("late fee=12\nlate fee+2", "14"), ("month=2\n100/month", "50"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testInvalidDomainsAreExplicit() throws {
        try theory([
            ("100/month+100", "DE"), ("100 EUR/month+100 EUR", "DE"), ("100/month * 1 day", "DE"), ("100/month * (1 year + 1 day)", "DE"),
            ("100/month+(100/h in hourly)", "DE"), ("100/month*100/month", "DE"), ("100/(100/month)", "DE"), ("100/month in hourly", "RO"),
            ("100 EUR in monthly", "DE"), ("10 kg/month", "DE"), ("10%/year", "DE"), ("100/year + 1 h", "DE"), ("100/month!", "DE"),
            ("2027-03-01 net -1", "DE"), ("2027-03-01 net 1.5", "DE"), ("2027-03-01 net 30 days", "DE"), ("9999-12-31 net 1", "DE"),
            ("100 net 30", "DE"), ("2027-03-01 net 10%", "DE"), ("late fee 1000 at -1%/day for 30 days", "DE"), ("late fee -1000 at 0.1%/day for 30 days", "DE"),
            ("late fee 1000 at 0.1%/month for 30 days", "DE"), ("late fee 1000 at 0.1%/day for -30 days", "DE"), ("late fee 1000 at 0.1%/day for 2 months", "DE"),
            ("late fee 1000 at 0.1%/day for 45", "DE"),
        ]) { source, region in XCTAssertNotNil(try SheetEvaluator.evaluate(source, context: context(region)).last!.error, source) }
    }
    func testAnnualHoursUseEnumeratedWorkdaysAndConversionsInvertExactly() throws {
        for region in ["DE", "US", "WEEKDAYS"] {
            for year in [2026, 2027, 2028, 2032] {
                let calendar = try WorkdayCalendar(region); let excluded = Set(try calendar.holidays(year).map(\.date))
                let start = DateOnly(year, 1, 1)!
                let days = (0..<(DateOnly.isLeapYear(year) ? 366 : 365)).map { start.addingDays($0)! }
                    .filter { $0.dayOfWeek != .saturday && $0.dayOfWeek != .sunday && !excluded.contains($0) }.count
                XCTAssertEqual(try magnitude(try last("60k/year in hourly", context(region, year))), try Rational(60000, days * 8), "\(region) \(year)")
                XCTAssertEqual(try magnitude(try last("450 EUR/day in monthly", context(region, year))), try Rational(450 * days, 12), "\(region) \(year)")
                XCTAssertEqual(try magnitude(try last("r=60k/year in hourly\nr in yearly", context(region, year))), Rational(60000), "\(region) \(year)")
            }
        }
    }
    func testCustomHolidaysAndContextChangesInvalidateOnlyConsumers() throws {
        let context = self.context("WEEKDAYS")
        XCTAssertEqual(try magnitude(try last("holidays=[2026-01-02]\n60k/year in hourly", context)), try Rational(60000, 260 * 8))
        let session = SheetEvaluationSession(); let source = "60k/year\nprev in hourly\n2+2"
        let before = try session.evaluateWithFunctions(source, .empty, [], context: context); XCTAssertNil(before.results[1].error)
        let after = try session.evaluateWithFunctions(source, .empty, [], context: context.with { $0.today = DateOnly(2028, 1, 1) })
        XCTAssertNotEqual(before.results[1].display, after.results[1].display)
        XCTAssertEqual(session.lastStatistics.parsedLines, 0); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let changed = try session.evaluateWithFunctions(source, .empty, [], context: context.with { $0.today = DateOnly(2028, 1, 1); $0.workdayRegion = "DE" })
        XCTAssertNotEqual(after.results[1].display, changed.results[1].display); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let noContext = try session.evaluateWithFunctions("5000 EUR/month in yearly\n100 EUR/h in daily\n2027-03-01 net 30\nlate fee 1000 at 0.1%/day for 45 days", .empty, [])
        for result in noContext.results { XCTAssertNil(result.error) }
        XCTAssertFalse(noContext.usesCurrentDate); XCTAssertFalse(noContext.usesCurrentInstant); XCTAssertFalse(noContext.usesCurrencyRates)
    }
    func testDueDatesMatchDayNumberArithmeticAcrossLeapAndYearBoundaries() throws {
        var random = NetRandom(817263)
        for _ in 0..<150 {
            let year = random.next(1900, 2090), month = random.next(1, 13), day = random.next(1, 29)
            let date = DateOnly(year, month, day)!; let days = random.next(0, 730)
            let result = try last("\(date) net \(days)")
            XCTAssertEqual(try result.value!.date.dayNumber, date.dayNumber + days)
        }
    }
    func testFeesAreLinearAndDisplayPrecisionDoesNotChangeAmounts() throws {
        XCTAssertEqual(try magnitude(try last("late fee 1 at 1/3/day for 1 min")), try Rational(1, 4320))
        var random = NetRandom(1729)
        for _ in 0..<50 {
            let principal = random.next(1, 100000); let bps = random.next(0, 100); let days = random.next(0, 730)
            XCTAssertEqual(try magnitude(try last("late fee \(principal) at \(bps)/10000/day for \(days) days")), try Rational(principal * bps * days, 10000))
        }
        XCTAssertEqual(try last("fee=late fee 1 EUR at 0.01%/day for 1 day\nfee*100").display, "0.01 EUR")
    }
    private func snapshot(_ dollars: Int, _ date: DateOnly = DateOnly(2026, 10, 30)!) throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: "Earnings fixture", baseCurrency: "EUR", asOf: date, retrievedAt: .utc(2026, 10, 31), rates: [("EUR", .one), ("USD", Rational(dollars))])
    }
    func testApproximationCurrencySnapshotsAndSavedCallsArePreserved() throws {
        XCTAssertTrue(try last("x=loan 250000 at 4.99% for 30 years\nx/month in yearly").display.hasPrefix("≈ "))
        let rates = try CurrencyRateBook(try snapshot(2), [])
        let context = self.context().with { $0.currencyRates = rates }
        XCTAssertEqual(try last("5000 EUR/month in USD in yearly", context).display, "120000 USD/year")
        XCTAssertEqual(try last("(100/month) EUR", context).display, "100 EUR/month")
        XCTAssertEqual(try last("100 EUR/month+100 USD/month", context).display, "150 EUR/month")
        let session = SheetEvaluationSession(); let result = try session.evaluateWithFunctions("f(x)=x/year in hourly\nf(60000)", .empty, [], context: context)
        XCTAssertNil(result.results[1].error); XCTAssertTrue(result.usesCurrentDate)
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("60k/year in hourly", cancellation, context: context)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
    func testSavedEarningsCallsConsumeTheCallersHolidayDeclarations() throws {
        let source = "f(x)=x/year in hourly\nholidays=[2026-01-02]\nf(60000)"
        XCTAssertEqual(try magnitude(try last(source, context("WEEKDAYS"))), try Rational(60000, 260 * 8))
        let session = SheetEvaluationSession(); let first = try session.evaluateWithFunctions(source, .empty, [], context: context("WEEKDAYS"))
        let changed = try session.evaluateWithFunctions(source.replacingOccurrences(of: "2026-01-02", with: "2026-01-03"), .empty, [], context: context("WEEKDAYS"))
        XCTAssertNil(changed.results.last!.error); XCTAssertNotEqual(first.results.last!.display, changed.results.last!.display)
        XCTAssertEqual(try changed.results.last!.value!.earnings.amount.scalar, try Rational(60000, 261 * 8))
    }
    func testDatedRateScopesAndConflictingEarningsSnapshotsRemainExplicit() throws {
        let rates = try CurrencyRateBook(try snapshot(2), [(DateOnly(2024, 1, 1)!, try snapshot(3, DateOnly(2023, 12, 29)!))])
        let context = self.context().with { $0.currencyRates = rates }
        XCTAssertEqual(try last("100 EUR/month in USD on 2024-01-01", context).display, "300 USD/month")
        let result = try SheetEvaluator.evaluate("a=100 EUR/month in USD on 2024-01-01\nb=100 EUR/month in USD\na+b", context: context).last!
        XCTAssertTrue(result.error?.contains("different rate snapshots") == true, result.error ?? "")
    }
    func testWorkingDayOutputCannotBeConfusedWithAnElapsedDayRate() throws {
        XCTAssertEqual(try last("100 EUR/day").display, "100 EUR/day")
        XCTAssertEqual(try last("100 EUR/day in daily").display, "100 EUR/workday")
        XCTAssertEqual(try last("r=100 EUR/day in daily\nr*8h").display, "100 EUR")
        XCTAssertEqual(try last("r=100 EUR/day in daily\nr*1day").display, "300 EUR")
    }
}
