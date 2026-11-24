import XCTest
@testable import CalculatorEngine

/// Port of tests/QNotch.CalculatorTests/Core/RomanianTaxTests.cs.
final class RomanianTaxTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try PayrollTest.last(source, nil) }
    private func amount(_ result: LineResult) throws -> Rational {
        let value = result.value!
        return value.kind == .money ? try value.money.magnitude.scalar : try value.scalar
    }
    private func evidence(_ result: LineResult) throws -> RomanianTaxEvidence { try PayrollTest.romanianTax(result) }

    func testIndependentExactTaxAndContributionOracle() throws {
        let cases = try PayrollTest.fixture("romanian-tax-oracle-v1.json").property("cases").arrayItems()
        try theory(cases) { item in
            let result = try last(try item.property("source").string()); let evidence = try evidence(result)
            XCTAssertEqual(try PayrollTest.rational(try item.property("output").string()), try amount(result))
            XCTAssertEqual(try PayrollTest.rational(try item.property("taxable").string()), evidence.taxableAmount)
            if try item.property("total").isNull { XCTAssertNil(evidence.totalLiability) }
            else { XCTAssertEqual(try PayrollTest.rational(try item.property("total").string()), evidence.totalLiability) }
            for (name, value) in try item.property("charges").objectProperties() {
                XCTAssertEqual(try PayrollTest.rational(try value.string()), try PayrollTest.single(evidence.charges) { $0.name == name }.amount)
            }
            XCTAssertEqual(try item.property("charges").objectProperties().count, evidence.charges.count)
            func optional(_ name: String, _ actual: Rational?) throws {
                if try item.property(name).isNull { XCTAssertNil(actual, name) } else { XCTAssertEqual(try PayrollTest.rational(try item.property(name).string()), actual, name) }
            }
            try optional("remaining", evidence.remainingCash); try optional("pensionBase", evidence.pensionBase)
            try optional("healthBase", evidence.healthBase); try optional("deductibleHealth", evidence.deductibleHealth)
            XCTAssertTrue(evidence.basis.contains("BEFORE")); XCTAssertFalse(evidence.inputApproximate)
        }
    }

    func testDeclaredProfilesComposeWithListsMoneyAndSavedCalls() throws {
        try theory([("pfaNetRO(120000,20000,2026)", "59130"), ("pfaTaxRO(120000 RON,20000 RON,2026)", "40870 RON"), ("pfaNetRO(10000,0,2026)", "6670"),
                    ("pfaNetRO(10000,0,2026,0,1)", "8100"), ("pfaNetRO(100000,0,2026,1,0)", "81000"), ("pfaNetRO(0,1000,2026)", "-1000"),
                    ("microTaxRO([10000 RON,20000 RON],50000 EUR,2026)", "300 RON"), ("microTaxRO(100000,100000,2026)", "1000"), ("dividendTaxRO(100000 RON,2026)", "16000 RON"),
                    ("dividendCashRO(100000 RON,2026)", "84000 RON"), ("investmentCassRO(dividendCashRO(100000 RON,2026),2026)", "4860 RON"),
                    ("investmentCassRO([12000 RON,12300 RON],2026)", "2430 RON"), ("stockTaxRO([1000,-900],2026)", "16"), ("stockTaxRO(1000,2026,1000)", "48"),
                    ("brokerTaxRO([1000,-900],365,2026)", "30"), ("brokerTaxRO([1000 RON,1000 RON],[364,365],2026)", "90 RON"), ("brokerGainsRO([1000 RON,-900 RON],2026)", "1000 RON"),
                    ("cryptoTaxRO([199,199,199],2026)", "0"), ("cryptoTaxRO([200,200,200],2026)", "96"), ("cryptoTaxRO([199,199,199,4,-1000],2026)", "96.16"),
                    ("cash=dividendCashRO(100000 RON,2026)\ncash-investmentCassRO(cash,2026)", "79140 RON"), ("f(x)=pfaNetRO(x,20000 RON,2026)\nf(120000 RON)", "59130 RON"),
                    ("f(x)=brokerTaxRO(x,365,2026)\nf([1000,-900])", "30")]) { source, expected in
            XCTAssertEqual(try last(source).display, expected, source)
        }
    }

    func testUnsupportedAmbiguousAndOutOfBoundInputsFail() throws {
        try theory(["pfaNetRO(10000,0)", "pfaNetRO(10000,0,2025)", "pfaNetRO(10000,0,2027)", "pfaNetRO(-1,0,2026)", "pfaNetRO(0,-1,2026)", "pfaNetRO(100000001,0,2026)",
                    "pfaNetRO(10000,0,2026,2)", "pfaNetRO(10000,0,2026,0,-1)", "pfaNetRO(10000 EUR,0,2026)", "pfaNetRO(10000 RON/year,0,2026)", "pfaNetRO([10000],0,2026)",
                    "pfaNetRO(10000 kg,0,2026)", "pfaNetRO(10000%,0,2026)", "microTaxRO(1000,100001,2026)", "microTaxRO(1000,-1,2026)", "microTaxRO(1000,1000 RON,2026)",
                    "microTaxRO(-1,1000,2026)", "microTaxRO([1,2,3,4,5],1000,2026)", "dividendTaxRO(-1,2026)", "dividendTaxRO(1000,2025)", "investmentCassRO([-1,24300],2026)",
                    "investmentCassRO([100000000,1],2026)", "brokerTaxRO([1000,2000],[1,2,3],2026)", "brokerTaxRO(1000,-1,2026)", "brokerTaxRO(1000,365.5,2026)",
                    "brokerTaxRO(1000,365 days,2026)", "brokerTaxRO(1000,100001,2026)", "brokerTaxRO(1000,[],2026)", "brokerTaxRO([100000000,100000000,-100000000],365,2026)",
                    "cryptoTaxRO(1000 USD,2026)", "stockTaxRO(1000,2026,-1)", "stockTaxRO(1000,2026,100000001)"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source)
        }
    }

    func testEvidenceDistinguishesPfaFloorAndInvestmentAggregationWithoutClockOrRates() throws {
        let pfa = try evidence(try last("pfaNetRO(10000,0,2026)"))
        XCTAssertEqual(Rational(1000), pfa.deductibleHealth)
        XCTAssertEqual(Rational(1430), try PayrollTest.single(pfa.charges) { $0.name.contains("top-up") }.amount)
        XCTAssertEqual(Rational(900), try PayrollTest.single(pfa.charges) { $0.name == "Income tax" }.amount)
        let session = SheetEvaluationSession()
        let source = "pfaNetRO(120000 RON,20000 RON,2026)\ninvestmentCassRO([12000 RON,12300 RON],2026)"
        let evaluated = try session.evaluateWithFunctions(source, .empty, [], context: EvaluationContext(today: DateOnly(2027, 1, 1)))
        for row in evaluated.results { XCTAssertNil(row.error) }
        XCTAssertFalse(evaluated.usesCurrentDate); XCTAssertFalse(evaluated.usesCurrentInstant); XCTAssertFalse(evaluated.usesCurrencyRates)
        let unchanged = try session.evaluateWithFunctions(source, .empty, [], context: EvaluationContext(today: DateOnly(2030, 7, 1)))
        XCTAssertEqual(0, session.lastStatistics.evaluatedLines); XCTAssertEqual(2, session.lastStatistics.reusedResults)
        XCTAssertEqual(evaluated.results.count, unchanged.results.count)
        for (a, b) in zip(evaluated.results, unchanged.results) { XCTAssertTrue(PayrollTest.same(a, b)) }
        XCTAssertEqual(try last("investmentCassRO(12000,2026)").display, "0")
        XCTAssertEqual(try last("investmentCassRO([12000,12300],2026)").display, "2430")
        let helper = try last("brokerGainsRO([1000,-900],2026)")
        XCTAssertNil(try evidence(helper).totalLiability)
        XCTAssertTrue((try PayrollTest.single(helper.explanation) { $0.romanianTax != nil }.assumption ?? "").contains("tax liability not calculated"))
    }

    func testCurrencySnapshotsAndUpstreamApproximationArePreservedWithoutImplicitConversion() throws {
        let rates = try PayrollTest.snapshot("Test only", DateOnly(2026, 10, 30)!, .utc(2026, 10, 31), [("EUR", Rational(1)), ("RON", Rational(5))])
        let result = try SheetEvaluator.evaluate("dividendTaxRO(100 EUR in RON,2026)", context: EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(rates, [])))[0]
        XCTAssertNil(result.error); XCTAssertEqual("80 RON", result.display); XCTAssertNotNil(try result.value!.money.rateStamp)
        XCTAssertTrue((try PayrollTest.single(result.explanation) { $0.romanianTax != nil }.assumption ?? "").contains("not a statutory BNR"))
        let earlier = try PayrollTest.snapshot("Earlier test only", DateOnly(2025, 12, 31)!, .utc(2026, 1, 1), [("EUR", Rational(1)), ("RON", Rational(4))])
        let mixed = try SheetEvaluator.evaluate("a=100 EUR in RON on 2025-12-31\nb=100 EUR in RON\ndividendTaxRO([a,b],2026)",
                                                context: EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(rates, [(earlier.asOf, earlier)])))
        XCTAssertNil(mixed[0].error); XCTAssertNil(mixed[1].error); XCTAssertTrue(mixed[2].error?.contains("conflicting currency snapshots") == true, mixed[2].error ?? "no error")
        let approximate = try last("x=loan 250000 at 4.99% for 30 years\ndividendTaxRO(x RON,2026)")
        XCTAssertTrue(approximate.display.hasPrefix("≈ ")); XCTAssertTrue(try evidence(approximate).inputApproximate)
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("pfaNetRO(120000,0,2026)", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }

    func testListTaxCallsShareTheWholeSheetComputationLimit() throws {
        let source = "g=[" + (1...256).map(String.init).joined(separator: ",") + "]\n" + Array(repeating: "cryptoTaxRO(g,2026)", count: 500).joined(separator: "\n")
        XCTAssertTrue(source.netLength < 200000)
        XCTAssertThrowsError(try SheetEvaluator.evaluate(source)) { XCTAssertEqual($0 as? CalcError, .computationLimit) }
    }

    func testRuleManifestEnumeratesEveryImplementedModelAndOfficialSources() throws {
        let root = try PayrollTest.fixture("spec/romanian-tax-rules.json")
        XCTAssertEqual(2026, try root.property("taxYear").int()); XCTAssertEqual(4050, try root.property("januaryMinimum").int())
        let examples = ["pfanetro": "120000,20000,2026", "pfataxro": "120000,20000,2026", "microtaxro": "100000,100000,2026", "dividendtaxro": "100000,2026",
                        "dividendcashro": "100000,2026", "stocktaxro": "1000,2026", "brokertaxro": "1000,365,2026", "brokergainsro": "1000,2026", "cryptotaxro": "1000,2026",
                        "investmentcassro": "24300,2026"]
        var seen = Set<String>()
        for model in try root.property("models").arrayItems() {
            for function in try model.property("functions").arrayItems() {
                let name = try function.string().netLower; XCTAssertTrue(seen.insert(name).inserted, name)
                let evidence = try evidence(try last(name + "(" + examples[name]! + ")"))
                XCTAssertEqual(try model.property("id").string(), evidence.ruleVersion)
                let listed = try model.property("sources").arrayItems().map { try $0.string() }
                for url in evidence.sources { XCTAssertTrue(listed.contains(url), url) }
            }
        }
        XCTAssertEqual(examples.keys.sorted(), seen.sorted())
    }

    func testBuiltinsCannotBeOverriddenAndInvalidSavedAritiesFailBeforeInvocation() throws {
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "pfaNetRO", parameters: ["x"], body: "x")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true, "\($0)") }
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "f", parameters: ["x"], body: "pfaNetRO(x,2026)")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true, "\($0)") }
        XCTAssertNotNil(try SheetEvaluator.evaluate("f(x)=microTaxRO(x,2026)")[0].error)
        let session = SheetEvaluationSession(); let before = try session.evaluate("x=10000\npfaNetRO(x,0,2026)\n2+2")
        let changed = try session.evaluate("x=20000\npfaNetRO(x,0,2026)\n2+2")
        XCTAssertNotEqual(before[1].display, changed[1].display); XCTAssertEqual(1, session.lastStatistics.parsedLines); XCTAssertTrue(session.lastStatistics.reusedResults > 0)
    }
}
