import XCTest
@testable import CalculatorEngine

/// Port of tests/QNotch.CalculatorTests/Core/RomanianPayrollTests.cs.
final class RomanianPayrollTests: XCTestCase {
    private let context = PayrollTest.context(region: "RO")
    private func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try PayrollTest.last(source, context ?? self.context) }
    private func evidence(_ result: LineResult) throws -> PayrollEvidence { try PayrollTest.payroll(result) }
    private func r(_ n: Int) -> Rational { Rational(n) }
    private func options(_ profile: JSONNode, _ minimum: Int) throws -> String {
        var text = ""
        if let dependants = profile.optionalProperty("dependants") { text += " with \(try dependants.int()) dependants" }
        if let children = profile.optionalProperty("schoolChildren") { text += " with \(try children.int()) school children" }
        if let youth = profile.optionalProperty("youthRelief"), try youth.bool() { text += " with youth relief" }
        if let main = profile.optionalProperty("mainJob"), !(try main.bool()) { text += " without main job" }
        if let relief = profile.optionalProperty("minimumRelief"), !(try relief.bool()) { text += " without minimum relief" }
        if let basic = profile.optionalProperty("basicAtMinimum"), try basic.bool() { text += " with basic salary \(minimum)" }
        return text
    }

    func testOfficialTableDecimalOracleAndExhaustiveInverseAgree() throws {
        let groups = try PayrollTest.fixture("romanian-payroll-oracle-v1.json").property("groups").arrayItems()
        try theory(groups) { group in
            let tail = " in RO for \(try group.property("month").string())" + (try options(try group.property("profile"), try group.property("minimum").int()))
            for item in try group.property("cases").arrayItems() {
                func i(_ name: String) throws -> Int { try item.property(name).int() }
                let result = try last("\(try i("gross")) gross" + tail); let evidence = try evidence(result); let ro = try XCTUnwrap(evidence.romanian)
                XCTAssertEqual(r(try i("net")), try result.value!.scalar)
                XCTAssertEqual(r(try i("gross")), ro.monthlyGross); XCTAssertEqual(r(try i("net")), ro.monthlyNet)
                XCTAssertEqual(r(try i("basicSalary")), ro.monthlyBasicSalary); XCTAssertEqual(r(try i("contributionBase")), ro.contributionBase)
                XCTAssertEqual(r(try i("minimumRelief")), ro.minimumRelief); XCTAssertEqual(r(try i("baseDeduction")), ro.baseDeduction)
                XCTAssertEqual(r(try i("youthDeduction")), ro.youthDeduction); XCTAssertEqual(r(try i("childDeduction")), ro.childDeduction)
                XCTAssertEqual(r(try i("appliedDeduction")), ro.appliedDeduction); XCTAssertEqual(r(try i("taxableIncome")), ro.taxableIncome)
                XCTAssertEqual(r(try i("employerContribution")), ro.employerContribution); XCTAssertEqual(r(try i("employerCost")), ro.employerCost)
                for (name, key) in [("CAS employee pension", "cas"), ("CASS employee health", "cass"), ("Income tax", "incomeTax")] {
                    XCTAssertEqual(r(try i(key) * 12), try PayrollTest.single(evidence.deductions) { $0.name == name }.annualAmount)
                }
                XCTAssertEqual(r(try i("gross") * 12), evidence.annualGross); XCTAssertEqual(r(try i("net") * 12), evidence.annualNet)
                XCTAssertEqual(r(try i("appliedDeduction") * 12), evidence.annualAllowance)
                let inverse = try last("\(try i("net")) net in gross" + tail)
                XCTAssertEqual(r(try i("lowestInverseGross")), try inverse.value!.scalar)
                XCTAssertEqual(r(try i("net")), try self.evidence(inverse).romanian!.monthlyNet)
            }
        }
    }

    func testPublishedExamplesTypedPeriodsAndProfileOptions() throws {
        try theory([("5000 gross in RO", "2981"), ("10000 brut in RO", "5850"), ("4325 gross in RO", "2699"), ("3000 net in gross in RO", "5036"), ("5000 lei gross", "2981 RON"),
                    ("5000 RON/month gross for 2026-07-01", "2981 RON/month"), ("60000 RON/year gross for 2026-07-01", "35772 RON/year"),
                    ("5000 RON gross in RO for 2026-07-01 in yearly", "35772 RON/year"), ("5000 gross in RO in employer cost", "5113"),
                    ("4325 RON gross in employer cost", "4418 RON"), ("4050 gross in RO for 2026-06-30", "2574"), ("4050 gross in RO for 2026-06-01 in employer cost", "4134"),
                    ("4325 gross in RO without minimum relief", "2616"), ("5000 gross in RO with 1 school child", "3013"),
                    ("5000 gross in RO with 2 dependants and 1 school child", "3034"), ("5000 gross in RO with youth relief", "3046"), ("5000 gross in RO without main job", "2925"),
                    ("f(x)=x gross in RO for 2026-07-01 with 1 school child\nf(5000)", "3013"), ("net=3\ngross=4\nnet+gross", "7"),
                    ("100000 gross in US for 2026-06-01", "79180"), ("50000 gross in UK for 2027-04-05", "39519.6")]) { source, expected in
            XCTAssertEqual(try last(source).display, expected, source)
        }
    }

    func testAmbiguousUnsupportedAndIneligibleInputsFailExplicitly() throws {
        try theory(["5000 gross in RO for 2026", "5000 gross in RO for 2025-12-31", "5000 gross in RO for 2027-01-01", "4050 gross in RO for 2026-07-01", "4324 gross in RO",
                    "5000.5 gross in RO", "3000.5 net in gross in RO", "60001 RON/year gross in RO", "8333334 gross in RO", "5000 gross in RO with -1 dependants",
                    "5000 gross in RO with 101 dependants", "5000 gross in RO with 1 dependants and 2 school children", "5000 gross in RO with 1 school child without main job",
                    "5000 gross in RO with youth relief without main job", "5000 gross in RO with basic salary 5100", "5000 gross in RO with basic salary 4000",
                    "5000 gross in RO with 1 dependants with 2 dependants", "5000 gross in RO with age 25", "5000 gross in RO without deductions",
                    "5000 gross in RO for 2026-07-01 for 2026", "5000 gross in RO for 2026-02-30", "5000 gross in US for 2026 with 1 school child",
                    "5000 gross in UK for 2026 in employer cost", "1 net in gross in RO", "8333333 net in gross in RO", "5000 kg gross in RO", "5000% gross in RO"]) { source in
            XCTAssertNotNil(try PayrollTest.line(source, context).error, source)
        }
    }

    func testMonthRolloverRegionInferenceAndPinnedCallsInvalidateOnlyConsumers() throws {
        let session = SheetEvaluationSession(); let source = "5000 RON gross\n5000 RON gross for 2026-06-01\n7"
        let before = try session.evaluate(source, context: context.with { $0.today = DateOnly(2026, 6, 30) })
        let after = try session.evaluate(source, context: context.with { $0.today = DateOnly(2026, 7, 1) })
        XCTAssertNotEqual(before[0].display, after[0].display); XCTAssertTrue(PayrollTest.same(before[1], after[1]))
        XCTAssertEqual(0, session.lastStatistics.parsedLines); XCTAssertEqual(2, session.lastStatistics.reusedResults)
        XCTAssertTrue(try session.evaluateWithFunctions(source, .empty, [], context: context.with { $0.today = DateOnly(2026, 7, 1) }).usesCurrentDate)
        let pinned = try session.evaluateWithFunctions("f(x)=x gross in RO for 2026-06-01\nf(5000 RON)", .empty, [])
        XCTAssertNil(pinned.results.last!.error); XCTAssertFalse(pinned.usesCurrentDate)
        XCTAssertEqual(try last("5000 gross for 2026-07-01").display, "2981")
        XCTAssertEqual(try last("5000 RON gross for 2026-07-01", context.with { $0.payrollRegion = "US" }).display, "2981 RON")
        XCTAssertNotNil(try SheetEvaluator.evaluate("5000 gross", context: context.with { $0.payrollRegion = String(repeating: "X", count: 100000) })[0].error)
    }

    func testRoundingJumpsUseLowestExactInverseAndNeverGlobalMonotoneSearch() throws {
        XCTAssertEqual(try last("4325 gross in RO").display, "2699")
        XCTAssertEqual(try last("4326 gross in RO").display, "2614")
        XCTAssertEqual(try last("2614 net in gross in RO").display, "4326")
        XCTAssertEqual(try last("2699 net in gross in RO").display, "4325")
        let edge = try last("6325 gross in RO with 4 dependants and youth relief")
        let after = try last("6326 gross in RO with 4 dependants and youth relief")
        XCTAssertTrue(try edge.value!.scalar.numerator > after.value!.scalar.numerator)
        XCTAssertEqual(try after.value!.scalar, try evidence(try last("\(after.display) net in gross in RO with 4 dependants and youth relief")).romanian!.monthlyNet)
    }

    func testPinnedRuleMonthRemainsGregorianAcrossDisplayCultures() throws {
        // C# switches CurrentCulture to ar-SA; the Swift engine never reads a display culture, so the same line
        // must give the same Gregorian month without one.
        let result = try last("5000 RON gross in RO for 2026-07-01")
        XCTAssertEqual("2981 RON", result.display)
        XCTAssertTrue((try PayrollTest.payrollStep(result).assumption ?? "").contains("payroll month 2026-07"))
    }

    func testCurrencyContextSourceEvidenceAndSharedBoundsRemainExplicit() throws {
        let snapshot = try PayrollTest.snapshot("Test only", DateOnly(2026, 10, 30)!, .utc(2026, 10, 31), [("EUR", r(1)), ("RON", r(5))])
        let result = try last("1000 EUR gross in RO for 2026-07-01", context.with { $0.currencyRates = try? CurrencyRateBook(snapshot, []) })
        XCTAssertEqual("2981 RON", result.display); XCTAssertTrue((try PayrollTest.payrollStep(result).assumption ?? "").contains("not statutory BNR"))
        let evidence = try evidence(result); XCTAssertEqual("RO-employee-2026-H2-v1", evidence.ruleVersion)
        XCTAssertEqual(DateOnly(2026, 7, 1)!, evidence.romanian!.payrollMonth)
        XCTAssertEqual(4, evidence.sources.count); XCTAssertTrue(evidence.basis.contains("Whole-leu"))
        let cap = try last("8333333 gross in RO for 2026-07-01"); XCTAssertEqual(r(8333333 * 12), try self.evidence(cap).annualGross)
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("3000 net in gross in RO", cancelled, context: context)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
