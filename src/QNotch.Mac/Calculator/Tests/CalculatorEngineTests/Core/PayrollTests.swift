import XCTest
@testable import CalculatorEngine

/// Port of tests/QNotch.CalculatorTests/Core/PayrollTests.cs.
final class PayrollTests: XCTestCase {
    private func context(_ today: DateOnly? = nil, region: String? = nil) -> EvaluationContext { PayrollTest.context(today ?? PayrollTest.today, region: region) }
    private func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try PayrollTest.last(source, context ?? self.context()) }
    private func evidence(_ result: LineResult) throws -> PayrollEvidence { try PayrollTest.payroll(result) }

    func testIndependentAnnualOracleChecksEveryDeductionAndExactInverse() throws {
        let cases = try PayrollTest.fixture("payroll-oracle-v1.json").property("cases").arrayItems()
        try theory(cases) { entry in
            let country = try entry.property("country").string(), gross = try entry.property("grossAnnual").string(), net = try entry.property("netAnnual").string()
            let result = try last("(\(gross)) gross in \(country) for 2026"); let evidence = try evidence(result)
            XCTAssertEqual(try PayrollTest.rational(net), try PayrollTest.amount(result)); XCTAssertEqual(try PayrollTest.rational(gross), evidence.annualGross)
            XCTAssertEqual(try PayrollTest.rational(try entry.property("allowanceAnnual").string()), evidence.annualAllowance)
            XCTAssertEqual(try PayrollTest.rational(try entry.property("taxableAnnual").string()), evidence.annualTaxableIncome)
            for (name, value) in try entry.property("deductionsAnnual").objectProperties() {
                XCTAssertEqual(try PayrollTest.rational(try value.string()), try PayrollTest.single(evidence.deductions) { $0.name == name }.annualAmount)
            }
            let inverse = try last("(\(net)) net in gross in \(country) for 2026")
            XCTAssertEqual(try PayrollTest.rational(gross), try PayrollTest.amount(inverse)); XCTAssertTrue(try self.evidence(inverse).inverse)
        }
    }

    func testPublishedAndTypedExamples() throws {
        try theory([("100000 gross in US", "79180"), ("50000 gross in UK", "39519.6"), ("100k USD gross", "79180 USD"), ("50k GBP brut", "39519.6 GBP"),
                    ("50000 brutto in GB for 2026", "39519.6"), ("79180 net in gross in US for 2026", "100000"), ("39519.6 GBP net in gross for 2026", "50000 GBP"),
                    ("100000 gross in US for 2026 in monthly", "6598.3333/month"), ("5000 GBP/month gross in UK for 2026", "3779.78 GBP/month"),
                    ("50000 GBP/year gross in UK for 2026", "39519.6 GBP/year"), ("(100000 gross in US for 2026)*2", "158360"), ("r=100000\nr gross in US for 2026", "79180"),
                    ("f(x)=x gross in US for 2026\nf(100000)", "79180"), ("f(x)=x net in gross in UK for 2026\nf(39519.6)", "50000"), ("gross=12\ngross+2", "14"),
                    ("net=12\nnet+2", "14"), ("2027-03-01 net 30", "2027-03-31"), ("0 gross in US for 2026", "0"), ("0 net in gross in UK for 2026", "0")]) { source, expected in
            XCTAssertEqual(try last(source).display, expected, source)
        }
    }

    func testUnsupportedInputsDoNotGuess() throws {
        try theory(["-1 gross in US for 2026", "100000001 gross in US for 2026", "100000000 net in gross in US for 2026", "10000 gross in RO for 2026",
                    "60000 gross in DE for 2025", "100000 gross in US for 2025", "50000 gross in UK for 2027", "100 kg gross in US for 2026", "100% gross in US for 2026",
                    "100 GBP/h gross in UK for 2026", "(100 GBP/h in hourly) gross in UK for 2026", "100000 gross in US for 2026 for 2026", "100000 gross in US in UK for 2026",
                    "100000 gross in US for 2026 nonsense", "100000 net in gross in ZZ for 2026"]) { source in
            XCTAssertNotNil(try PayrollTest.line(source, context()).error, source)
        }
    }

    func testTaxYearBoundaryAndCountryFallbackHavePreciseContextDependencies() throws {
        XCTAssertNotNil(try SheetEvaluator.evaluate("50000 GBP gross", context: context(DateOnly(2026, 4, 5)))[0].error)
        XCTAssertEqual(try last("50000 GBP gross", context(DateOnly(2026, 4, 6))).display, "39519.6 GBP")
        XCTAssertEqual(try last("50000 GBP gross", context(DateOnly(2027, 4, 5))).display, "39519.6 GBP")
        XCTAssertNotNil(try SheetEvaluator.evaluate("50000 GBP gross", context: context(DateOnly(2027, 4, 6)))[0].error)
        let session = SheetEvaluationSession(); let source = "100000 gross for 2026\n2+2"
        let first = try session.evaluateWithFunctions(source, .empty, [], context: context(region: "US"))
        let changed = try session.evaluateWithFunctions(source, .empty, [], context: context(region: "UK"))
        XCTAssertEqual(first.results[0].display, "79180"); XCTAssertEqual(changed.results[0].display, "68557.4")
        XCTAssertEqual(session.lastStatistics.parsedLines, 0); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let pinned = try session.evaluateWithFunctions("100000 gross in US for 2026\n50000 GBP gross for 2026", .empty, [])
        for result in pinned.results { XCTAssertNil(result.error) }
        XCTAssertFalse(pinned.usesCurrentDate); XCTAssertFalse(pinned.usesCurrencyRates); XCTAssertFalse(pinned.usesCurrentInstant)
        XCTAssertEqual(try last("100000 gross", context(region: "US")).display, "79180")
        XCTAssertEqual(try last("100000 USD gross", context(region: "UK")).display, "79180 USD")
    }

    func testMoneyConversionApproximationAndSalaryPeriodArePreserved() throws {
        let snapshot = try PayrollTest.snapshot("Salary fixture", DateOnly(2026, 10, 30)!, .utc(2026, 10, 31), [("EUR", Rational(1)), ("USD", Rational(2)), ("GBP", Rational(1))])
        var rated = context(); rated.currencyRates = try CurrencyRateBook(snapshot, [])
        XCTAssertEqual(try last("50000 EUR gross in US for 2026", rated).display, "79180 USD")
        let approximate = try last("x=loan 250000 at 4.99% for 30 years\nx USD gross in US for 2026")
        XCTAssertTrue(approximate.display.hasPrefix("≈ ")); XCTAssertTrue(try evidence(approximate).inputApproximate)
        let hourly = try last("100000 USD gross in US for 2026 in hourly")
        XCTAssertEqual(try Rational(79180, 254 * 8), try PayrollTest.amount(hourly))
        let saved = try last("f(x)=x gross in US for 2026 in hourly\nholidays=[2026-01-02]\nf(100000 USD)")
        XCTAssertEqual(try Rational(79180, 253 * 8), try PayrollTest.amount(saved))
    }

    func testGrossNetConservationAndIncrementalUpdatesRetainExactInputs() throws {
        let session = SheetEvaluationSession(); let source = "gross amount=100000\ngross amount gross in US for 2026\n7"
        let first = try session.evaluate(source, context: context()); let changed = try session.evaluate(source.netReplace("=100000", "=200000"), context: context())
        XCTAssertEqual(first[1].display, "79180"); XCTAssertNil(changed[1].error)
        XCTAssertEqual(session.lastStatistics.parsedLines, 1); XCTAssertTrue(session.lastStatistics.reusedResults > 0)
        let evidence = try evidence(changed[1]); var total = Rational.zero
        for row in evidence.deductions { total = try total + row.annualAmount }
        XCTAssertEqual(evidence.annualGross, try evidence.annualNet + total)
        XCTAssertEqual(Rational(100000), try PayrollTest.amount(try last("n=100000 gross in US for 2026\nn net in gross in US for 2026")))
        let cancel = CancellationToken(); cancel.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("79180 net in gross in US for 2026", cancel)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }

    func testRuleManifestAndPublicEvidenceIdentifyOnlyAuditedModels() throws {
        let document = try PayrollTest.fixture("spec/payroll-rules.json")
        let models = try document.property("models").arrayItems()
        for model in models {
            let country = try model.property("country").string()
            let date = country == "RO" ? try model.property("validFrom").string() : "2026"
            let flat = try model.property("id").string() == "HU-atalanyado-2026-v1"
            let evidence = try evidence(try last("100000 gross in \(country) for \(date)" + (flat ? " with átalányadó" : "")))
            XCTAssertEqual(try model.property("id").string(), evidence.ruleVersion)
            XCTAssertEqual(try model.property("taxYear").int(), evidence.taxYear)
            let listed = try model.property("sources").arrayItems().map { try $0.string() }
            for source in evidence.sources { XCTAssertTrue(listed.contains(source), source) }
            if country == "RO" {
                let minimum = try model.property("minimumMonthlyGross").int()
                let relief = try model.property("minimumRelief").int()
                let ceiling = try model.property("minimumReliefGrossCeiling").int()
                let atMinimum = try self.evidence(try last("\(minimum) gross in RO for \(date)")).romanian!
                XCTAssertEqual(Rational(relief), atMinimum.minimumRelief)
                XCTAssertEqual(Rational(minimum - relief), atMinimum.contributionBase)
                let atCeiling = try self.evidence(try last("\(ceiling) gross in RO for \(date) with basic salary \(minimum)")).romanian!
                let afterCeiling = try self.evidence(try last("\(ceiling + 1) gross in RO for \(date) with basic salary \(minimum)")).romanian!
                XCTAssertEqual(Rational(relief), atCeiling.minimumRelief)
                XCTAssertEqual(Rational.zero, afterCeiling.minimumRelief)
            }
        }
        let german = try PayrollTest.single(models) { try $0.property("country").string() == "DE" }
        let ceilings = try german.property("annualCeilings"), rates = try german.property("employeeRatesPercent")
        func rate(_ name: String) throws -> NetDecimal { try NetDecimal.parse(try rates.property(name).string())! / NetDecimal(100) }
        func ceiling(_ name: String) throws -> NetDecimal { NetDecimal(try ceilings.property(name).int()) }
        let high = try evidence(try last("200000 gross in DE for 2026")).german!
        XCTAssertEqual((try ceiling("pensionAndUnemployment") * rate("pension")).rounded(2, awayFromZero: true), high.pension)
        XCTAssertEqual((try ceiling("healthAndCare") * (try rate("healthGeneral") + (try rate("healthSurchargeDefaultFull") / NetDecimal(2)))).rounded(2, awayFromZero: true), high.health)
        XCTAssertEqual((try ceiling("healthAndCare") * (try rate("care") + rate("childlessCareSurcharge"))).rounded(2, awayFromZero: true), high.care)
        let hu = try PayrollTest.single(models) { try $0.property("id").string() == "HU-atalanyado-2026-v1" }
        XCTAssertEqual(HungarianPayrollRules.taxFreeIncome, try hu.property("taxFreeIncome").int64())
        XCTAssertEqual(HungarianPayrollRules.revenueCeiling, try hu.property("revenueCeiling").int64())
        XCTAssertEqual(HungarianPayrollRules.retailRevenueCeiling, try hu.property("retailRevenueCeiling").int64())
        let employee = try PayrollTest.single(models) { try $0.property("id").string() == "HU-employee-2026-v1" }
        XCTAssertEqual(HungarianPayrollRules.minimumWage, try employee.property("minimumWage").int64())
        XCTAssertEqual(HungarianPayrollRules.guaranteedMinimumWage, try employee.property("guaranteedMinimumWage").int64())
        XCTAssertEqual(HungarianPayrollRules.youthMonthlyCap, try employee.property("monthlyAllowances").property("youthCap").int64())
        XCTAssertEqual(7, models.count)
    }

    func testExpensiveSalarySheetsShareTheExistingComputationLimit() throws {
        XCTAssertThrowsError(try SheetEvaluator.evaluate(Array(repeating: "79180 net in gross in US for 2026", count: 5000).joined(separator: "\n"))) {
            XCTAssertEqual($0 as? CalcError, .computationLimit)
        }
    }
}
