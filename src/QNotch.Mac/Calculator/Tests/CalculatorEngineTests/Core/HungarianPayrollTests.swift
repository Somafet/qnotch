import XCTest
@testable import CalculatorEngine

/// Port of tests/QNotch.CalculatorTests/Core/HungarianPayrollTests.cs.
final class HungarianPayrollTests: XCTestCase {
    private let context = PayrollTest.context(workday: "HU", region: "HU")
    private func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try PayrollTest.last(source, context ?? self.context) }
    private func error(_ source: String) throws -> String { try PayrollTest.line(source, context).error ?? "" }
    private func evidence(_ result: LineResult) throws -> PayrollEvidence { try PayrollTest.payroll(result) }
    private func hu(_ source: String) throws -> HungarianPayrollEvidence { try evidence(try last(source)).hungarian! }
    private func options(_ profile: JSONNode) throws -> String {
        var text = ""
        if let children = profile.optionalProperty("children") { text += " with \(try children.int()) children" }
        if let dependants = profile.optionalProperty("dependants") { text += " with \(try dependants.int()) dependants" }
        if let youth = profile.optionalProperty("youth"), try youth.bool() { text += " with youth relief" }
        if let mothers = profile.optionalProperty("mothers"), try mothers.bool() { text += " with mothers exemption" }
        if let marriage = profile.optionalProperty("firstMarriage"), try marriage.bool() { text += " with first marriage" }
        if let guaranteed = profile.optionalProperty("guaranteed"), try guaranteed.bool() { text += " with guaranteed minimum" }
        if let ratio = profile.optionalProperty("costRatio") { text += " with cost ratio \(try ratio.int())%" }
        if let status = profile.optionalProperty("status") { text += try status.string() == "pensioner" ? " as pensioner" : " without main job" }
        return text
    }
    private func fraction(_ text: String) throws -> Rational {
        let parts = text.netSplit("/")
        return parts.count == 1 ? try Rational.parse(parts[0]) : try PayrollTest.rational(text)
    }

    func testIndependentOracleForwardAndLowestInverseAgree() throws {
        let groups = try PayrollTest.fixture("hungarian-payroll-oracle-v1.json").property("groups").arrayItems()
        try theory(groups) { group in
            let flat = try group.property("model").string() == "atalanyado"
            let tail = " in HU for 2026" + (flat ? " with átalányadó" : "") + (try options(try group.property("profile")))
            for item in try group.property("cases").arrayItems() {
                let gross = try item.property(flat ? "revenue" : "gross").int64(); let net = try item.property("net").int64()
                let hu = try hu("\(gross) gross" + tail)
                XCTAssertEqual(net, hu.net)
                XCTAssertEqual(try item.property("personalIncomeTax").int64(), hu.personalIncomeTax)
                XCTAssertEqual(try item.property("socialSecurity").int64(), hu.socialSecurity)
                XCTAssertEqual(try item.property("familyRelief").int64(), hu.familyContributionRelief)
                XCTAssertEqual(try fraction(try item.property("taxBase").string()), hu.taxBase)
                if flat {
                    XCTAssertEqual(try item.property("szocho").int64(), hu.socialContributionTax)
                    XCTAssertEqual(try fraction(try item.property("income").string()), hu.income)
                    XCTAssertEqual(try fraction(try item.property("contributionBase").string()), hu.socialSecurityBase)
                    // The monthly breakdown must add up exactly to the annual answer.
                    XCTAssertEqual(12, hu.months.count)
                    XCTAssertEqual(hu.socialSecurity, hu.months.reduce(0) { $0 + $1.socialSecurity })
                    XCTAssertEqual(hu.socialContributionTax, hu.months.reduce(0) { $0 + $1.socialContributionTax })
                    XCTAssertEqual(hu.personalIncomeTax, hu.months.reduce(0) { $0 + $1.incomeTaxAdvance })
                    for m in hu.months { XCTAssertTrue(m.incomeTaxAdvance >= 0 && (m.month % 3 == 0 || m.incomeTaxAdvance == 0)) }
                    XCTAssertEqual(Rational(hu.net - hu.familyContributionRelief), try hu.months.reduce(Rational.zero) { try $0 + $1.left })
                } else {
                    XCTAssertEqual(try item.property("employerSzocho").int64(), hu.socialContributionTax)
                    XCTAssertEqual(try item.property("employerCost").int64(), hu.employerCost)
                }
                if net < 0 { continue } // negative targets are not valid inputs
                let lowest = try item.property(flat ? "lowestInverseRevenue" : "lowestInverseGross").int64()
                XCTAssertEqual(lowest, try self.hu("\(net) net in gross" + tail).gross)
            }
        }
    }

    func testPublishedNavFiguresAndDefaults() throws {
        XCTAssertEqual("214662", try last("322800 gross in HU for 2026").display)
        XCTAssertEqual("248178", try last("373200 gross").display) // payroll region HU, monthly default
        XCTAssertEqual("214662 HUF", try last("322800 HUF gross for 2026", context.with { $0.payrollRegion = "US" }).display)
        XCTAssertEqual("2575944/year", try last("322800 gross in HU for 2026 in yearly").display)
        let nav = try hu("7000000 gross in HU for 2026 with átalányadó")
        XCTAssertEqual(Rational(3850000), nav.income); XCTAssertEqual(286980, nav.personalIncomeTax)
        XCTAssertEqual(Rational(12 * 322800), nav.socialSecurityBase); XCTAssertEqual(12 * 59718, nav.socialSecurity); XCTAssertEqual(12 * 41964, nav.socialContributionTax)
        XCTAssertEqual(5492836, nav.net)
        // Monthly revenue annualizes; the answer is the monthly share of the annual net.
        XCTAssertEqual(try hu("7200000 gross in HU for 2026 with atalanyado").net, try hu("600000 HUF/month gross in HU for 2026 with flat rate").net)
        XCTAssertEqual("473028 HUF/month", try last("600000 HUF/month gross in HU for 2026 with átalányadó").display)
        let employer = try hu("600000 gross in HU for 2026"); XCTAssertEqual(78000, employer.socialContributionTax); XCTAssertEqual(678000, employer.employerCost)
        XCTAssertEqual("678000", try last("600000 gross in HU for 2026 in employer cost").display)
    }

    func testBreakdownShowsSplitPeriodAndMonths() throws {
        let flat = try evidence(try last("600000 HUF/month gross in HU for 2026 with átalányadó"))
        XCTAssertEqual("SZJA 303 480 · TB járulék 716 616 · szocho 503 568 · net 5 676 336 HUF per year\nAnswer is per month", PayrollBreakdownText.summary(flat))
        let lines = PayrollBreakdownText.lines(flat)
        XCTAssertTrue(lines.contains("  Jun: base 322 800, TB 59 718, szocho 41 964, SZJA 6 480 (Q2), left 491 838"))
        XCTAssertTrue(lines.contains { $0.contains("(21.2% of revenue)") })
        XCTAssertTrue(PayrollBreakdownText.summary(try evidence(try last("7000000 gross in HU for 2026 with átalányadó")))?.hasSuffix("Answer is per year") == true)
        let employee = try evidence(try last("600000 gross in HU for 2026 with 2 children"))
        XCTAssertEqual("SZJA 10 002 · TB járulék 111 000 · net 478 998 HUF per month\nAnswer is per month", PayrollBreakdownText.summary(employee))
        XCTAssertTrue(PayrollBreakdownText.lines(employee).contains("  Deductions 121 002 HUF (20.2% of gross); net 478 998 HUF a month, 5 747 976 HUF a year"))
        XCTAssertTrue(try evidence(try last("600000 gross in HU for 2026")).hungarian!.months.isEmpty)
        let cli = try ExplanationText.render(try last("7000000 gross in HU for 2026 with átalányadó"))
        XCTAssertTrue(cli.netIndexOf("Breakdown for 2026") < cli.netIndexOf("Hungarian átalányadó revenue to net"))
        XCTAssertNil(PayrollBreakdownText.summary(try evidence(try last("60000 gross in DE for 2026", context.with { $0.payrollRegion = "DE" }))))
        XCTAssertNil(PayrollBreakdownText.rows(try evidence(try last("60000 gross in DE for 2026", context.with { $0.payrollRegion = "DE" }))))
    }

    func testHoverRowsListBaseDeductionsAndNet() throws {
        let flat = try XCTUnwrap(PayrollBreakdownText.rows(try evidence(try last("600000 HUF/month gross in HU for 2026 with átalányadó"))))
        XCTAssertEqual(["Revenue", "SZJA", "TB járulék", "szocho", "Net per year"], flat.rows.map(\.label))
        XCTAssertEqual(["−303 480", "−716 616", "−503 568", "5 676 336 HUF"], flat.rows.dropFirst().map(\.amount))
        XCTAssertEqual(PayrollBreakdownRowKind.total, flat.rows.last!.kind)
        XCTAssertEqual("Answer is per month", flat.footer)
        XCTAssertNil(try XCTUnwrap(PayrollBreakdownText.rows(try evidence(try last("7000000 gross in HU for 2026 with átalányadó")))).footer)
        let employee = try XCTUnwrap(PayrollBreakdownText.rows(try evidence(try last("600000 gross in HU for 2026 with 2 children"))))
        XCTAssertEqual(["Gross", "TB járulék", "SZJA", "Net per month", "Employer cost"], employee.rows.map(\.label))
        XCTAssertEqual(["600 000", "−111 000", "−10 002", "478 998 HUF"], employee.rows.prefix(4).map(\.amount))
        XCTAssertNil(employee.footer)
    }

    func testConvertedAmountsSettleToWholeForints() throws {
        // 1 EUR = 1.1 USD = 385.37 HUF, so 9000 USD = 3,153,027.27… HUF.
        let snapshot = try PayrollTest.snapshot("Fixture", DateOnly(2026, 10, 30)!, .utc(2026, 10, 31), [("EUR", Rational(1)), ("USD", try Rational(11, 10)), ("HUF", try Rational(38537, 100))])
        let rated = context.with { $0.currencyRates = try? CurrencyRateBook(snapshot, []) }
        let converted = try last("9000 usd gross in HU for 2026", rated)
        XCTAssertEqual(try last("3153027 gross in HU for 2026").value!.scalar, try converted.value!.money.magnitude.scalar)
        XCTAssertEqual("HUF", try converted.value!.money.currency)
        XCTAssertTrue((try PayrollTest.payrollStep(converted).assumption ?? "").contains("converted input rounded half up to 3153027 whole HUF per month"))
        XCTAssertTrue(try error("3153027.5 gross in HU for 2026").contains("whole-forint")) // typed amounts stay exact
    }

    func testAllowancesFollowStatutoryOrderAndRelief() throws {
        let youth = try hu("900000 gross in HU for 2026 with youth relief")
        XCTAssertEqual(Rational(715765), youth.allowances); XCTAssertEqual(27635, youth.personalIncomeTax)
        let mothers = try hu("600000 gross in HU for 2026 with mothers exemption with 2 children")
        XCTAssertEqual(0, mothers.personalIncomeTax); XCTAssertEqual(79998, mothers.familyContributionRelief); XCTAssertEqual(568998, mothers.net)
        let capped = try hu("200000 gross in HU for 2026 with 3 children")
        XCTAssertEqual(capped.socialSecurity, capped.familyContributionRelief); XCTAssertEqual(200000, capped.net)
        XCTAssertEqual(Rational(33335), try hu("600000 gross in HU for 2026 with first marriage").allowances)
        XCTAssertEqual(Rational(440000), try hu("1000000 gross in HU for 2026 with 1 children with 3 dependants").familyAllowanceUsed)
    }

    func testFlatRateStatusesAndLimits() throws {
        XCTAssertEqual(6713020, try hu("7000000 gross in HU for 2026 with átalányadó as pensioner").net)
        XCTAssertEqual(6110362, try hu("7000000 gross in HU for 2026 with átalányadó without main job").net)
        XCTAssertEqual(Rational(12 * 373200), try hu("7000000 gross in HU for 2026 with átalányadó with guaranteed minimum").socialSecurityBase)
        XCTAssertEqual(Rational(4000000), try hu("20000000 gross in HU for 2026 with átalányadó with cost ratio 80%").income)
        XCTAssertEqual(193680000, try hu("193680000 gross in HU for 2026 with átalányadó with cost ratio 90%").gross)
        XCTAssertTrue(try error("38736001 gross in HU for 2026 with átalányadó").contains("revenue limit is 38 736 000 HUF"))
        XCTAssertEqual("A plain Hungarian salary is monthly, and 35 000 000 HUF a month is above the 8 333 333 HUF limit. For a yearly salary add /year, for example x/year gross in HU",
                       try error("x = 35000000\nx gross in HU for 2026"))
        XCTAssertEqual("Hungarian salary is limited to 8 333 333 HUF a month", try error("9000000 HUF/month gross in HU for 2026"))
        XCTAssertEqual(try hu("35000000 HUF/year gross in HU for 2026").net * 12, try hu("2916667 gross in HU for 2026").net * 12) // yearly divides into whole months
        XCTAssertTrue(try last("x = 35000000 HUF\nx/year gross in HU for 2026").display.hasSuffix("HUF/year"))
        XCTAssertTrue(try error("1000000 gross in HU for 2026 with átalányadó with cost ratio 50%").contains("45%, 80% or 90%"))
        XCTAssertTrue(try error("1000000 gross in HU for 2026 with átalányadó in employer cost").contains("employee model"))
        XCTAssertTrue(try error("600000 gross in HU for 2026 as pensioner").contains("require with átalányadó"))
        XCTAssertTrue(try error("1000000 gross in HU for 2026 with átalányadó as pensioner without main job").contains("either pensioner"))
        XCTAssertTrue(try error("600000 gross in HU for 2026 with tax class 3").contains("German"))
        XCTAssertTrue(try error("600000 gross in HU for 2026 with 1 school child").contains("Romanian"))
        XCTAssertTrue(try error("60000 gross in DE for 2026 with átalányadó").contains("Hungarian"))
        XCTAssertTrue(try error("600000 gross in HU for 2027").contains("2026 only"))
        XCTAssertTrue(try error("600000.5 gross in HU for 2026").contains("whole-forint"))
        let explanation = try PayrollTest.payrollStep(try last("7000000 gross in HU for 2026 with átalányadó")).assumption ?? ""
        XCTAssertTrue(explanation.contains(HungarianPayrollRules.flatRateRule)); XCTAssertTrue(explanation.contains("before actual business costs"))
    }

    func testSpecExamplesEvaluate() throws {
        let lines = try PayrollTest.specBlock("## Hungarian 2026 models"); XCTAssertTrue(lines.count >= 10)
        for line in lines { XCTAssertNil(try PayrollTest.line(line, context).error, line) }
    }

    func testCurrentYearDependencyAndCancellation() throws {
        let session = SheetEvaluationSession(); let source = "600000 gross in HU\n600000 gross in HU for 2026\n7"
        let before = try session.evaluate(source, context: context); XCTAssertNil(before[0].error)
        let after = try session.evaluate(source, context: context.with { $0.today = DateOnly(2027, 1, 1) })
        XCTAssertNotNil(after[0].error); XCTAssertTrue(PayrollTest.same(before[1], after[1]))
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("4000000 net in gross in HU for 2026 with átalányadó", cancelled, context: context)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
