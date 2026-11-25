import XCTest
@testable import CalculatorEngine

/// Port of tests/QNotch.CalculatorTests/Core/GermanPayrollTests.cs.
final class GermanPayrollTests: XCTestCase {
    private let context = PayrollTest.context(region: "DE")
    private func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try PayrollTest.last(source, context ?? self.context) }
    private func evidence(_ result: LineResult) throws -> PayrollEvidence { try PayrollTest.payroll(result) }
    /// `(cents / 100m).ToString(CultureInfo.InvariantCulture)`.
    private func euros(_ cents: Int64) throws -> String { try (NetDecimal(cents) / NetDecimal(100)).description }
    private func e(_ cents: Int64) throws -> NetDecimal { try NetDecimal(cents) / NetDecimal(100) }
    private func options(_ profile: JSONNode) throws -> String {
        var text = ""
        if let klass = profile.optionalProperty("taxClass") { text += " with tax class \(try klass.int())" }
        if let children = profile.optionalProperty("children") { text += " with \(try children.int()) children" }
        if let allowance = profile.optionalProperty("childAllowance") { text += " with child allowance \(try allowance.string())" }
        if let church = profile.optionalProperty("churchTax") { text += " with church tax \(try church.int())%" }
        if let saxony = profile.optionalProperty("saxony"), try saxony.bool() { text += " with Saxony" }
        if let surcharge = profile.optionalProperty("healthSurcharge") { text += " with health surcharge \(try surcharge.string())%" }
        if let childless = profile.optionalProperty("childlessSurcharge"), !(try childless.bool()) { text += " without childless surcharge" }
        return text
    }
    private func amount(_ cents: Int64, _ period: String) throws -> String { period == "month" ? try euros(cents) + " EUR/month" : try euros(cents) }

    func testOfficialBmfTestTableMatchesThroughSheetGrammar() throws {
        let rows = try PayrollTest.fixture("de-lohnsteuer-2026-pruftabelle.json").property("general").property("rows").arrayItems()
            .filter { try $0.property("annualGross").int() > 24000 }
        try theory(rows) { row in
            // Pruftabelle footnotes: ALV=KRV=PKV=0, KVZ=2.90 (the default), PVZ=0 in class II and 1 otherwise.
            let gross = try row.property("annualGross").int(); let expected = try row.property("annualWageTaxByClass").arrayItems().map { try $0.int() }
            for klass in 1...6 {
                let source = "\(gross) gross in DE for 2026 with tax class \(klass)" + (klass == 2 ? " without childless surcharge" : "")
                let german = try evidence(try last(source)).german!
                XCTAssertEqual(NetDecimal(expected[klass - 1]), german.wageTax, source)
                XCTAssertEqual("annual", german.period)
            }
        }
    }

    func testForwardMatchesOfficialPseudoCodeOracle() throws {
        let groups = try PayrollTest.fixture("german-payroll-oracle-v1.json").property("groups").arrayItems()
        try theory(groups) { group in
            let period = try group.property("period").string(); let tail = " gross in DE for 2026" + (try options(try group.property("profile")))
            for item in try group.property("cases").arrayItems() {
                func l(_ name: String) throws -> Int64 { try item.property(name).int64() }
                func value(_ name: String) throws -> NetDecimal { try e(try l(name)) }
                let result = try last(try amount(try l("gross"), period) + tail); let evidence = try evidence(result); let german = evidence.german!
                XCTAssertEqual(try amount(try l("net"), period), result.display)
                XCTAssertEqual(try value("gross"), german.gross); XCTAssertEqual(try value("net"), german.net)
                XCTAssertEqual(try value("wageTax"), german.wageTax); XCTAssertEqual(try value("solidarity"), german.solidarity)
                XCTAssertEqual(try value("churchBase"), german.churchTaxBase); XCTAssertEqual(try value("churchTax"), german.churchTax)
                XCTAssertEqual(try value("pension"), german.pension); XCTAssertEqual(try value("unemployment"), german.unemployment)
                XCTAssertEqual(try value("health"), german.health); XCTAssertEqual(try value("care"), german.care)
                let periods = NetDecimal(period == "month" ? 12 : 1)
                XCTAssertEqual(try Rational.parse((try value("net") * periods).description), evidence.annualNet)
                XCTAssertEqual(try Rational.parse((try value("wageTax") * periods).description), try PayrollTest.single(evidence.deductions) { $0.name == "Wage tax" }.annualAmount)
                XCTAssertEqual(7, evidence.deductions.count)
            }
        }
    }

    func testInverseReturnsLowestGrossFromExhaustiveEnumeration() throws {
        let windows = try PayrollTest.fixture("german-payroll-oracle-v1.json").property("inverse").arrayItems()
        try theory(windows) { window in
            let period = try window.property("period").string(); let tail = " net in gross in DE for 2026" + (try options(try window.property("profile")))
            for target in try window.property("targets").arrayItems() {
                let net = try target.property("net").int64()
                let result = try PayrollTest.line(try amount(net, period) + tail, context)
                if try target.property("lowestGross").isNull { XCTAssertTrue(result.error?.contains("exact net") == true, result.error ?? "no error"); continue }
                let gross = try target.property("lowestGross").int64()
                XCTAssertNil(result.error)
                XCTAssertEqual(period == "month" ? try euros(gross) + " EUR/month" : try euros(gross), result.display)
                XCTAssertEqual(try e(net), try evidence(result).german!.net)
            }
        }
    }

    func testExamplesInferenceAndSavedCalls() throws {
        try theory([("60000 gross in DE for 2026", "37561"), ("60000 brutto in DE", "37561"), ("60000 EUR gross for 2026", "37561 EUR"), ("60000 gross for 2026", "37561"),
                    ("6000 EUR/month gross in DE for 2026", "3641.58 EUR/month"), ("37561 net in gross in DE for 2026", "59998.72"),
                    ("60000 gross in DE for 2026 in monthly", "3130.0833/month"),
                    ("60000 gross in DE for 2026-12-31 with tax class 3 with 2 children with child allowance 2 with church tax 9%", "42465.32"),
                    ("f(x)=x gross in DE for 2026 with tax class 1\nf(60000)", "37561")]) { source, expected in
            XCTAssertEqual(try last(source).display, expected, source)
        }
    }

    func testUnsupportedAndIneligibleInputsFailExplicitly() throws {
        try theory(["60000 gross in DE for 2025", "60000 gross in DE for 2027-01-01", "24000 gross in DE for 2026", "2000 EUR/month gross in DE for 2026",
                    "60000.001 gross in DE for 2026", "100000000.01 gross in DE for 2026", "-1 gross in DE for 2026", "60000 kg gross in DE for 2026", "60000% gross in DE for 2026",
                    "60000 gross in DE for 2026 with tax class 7", "60000 gross in DE for 2026 with tax class 0", "60000 gross in DE for 2026 with church tax 10%",
                    "60000 gross in DE for 2026 with child allowance 0.3", "60000 gross in DE for 2026 with tax class 5 with child allowance 1",
                    "60000 gross in DE for 2026 with health surcharge 11%", "60000 gross in DE for 2026 with health surcharge 2.5",
                    "60000 gross in DE for 2026 with tax class 1 with tax class 3", "60000 gross in DE for 2026 with 2 dependants", "60000 gross in DE for 2026 in employer cost",
                    "60000 gross in DE for 2026 with youth relief", "100000 gross in US for 2026 with tax class 1", "5000 gross in RO for 2026-07-01 with church tax",
                    "5000 EUR/h gross in DE for 2026", "1 net in gross in DE for 2026", "100000000 net in gross in DE for 2026"]) { source in
            XCTAssertNotNil(try PayrollTest.line(source, context).error, source)
        }
    }

    func testExplanationDisclosesProfileComponentsAndSources() throws {
        let result = try last("6000 EUR/month gross in DE for 2026")
        let detail = try PayrollTest.payrollStep(result).assumption ?? ""
        for text in ["DE-employee-2026-v1", "PAP LZZ 2", "tax class 1", "2.9% Zusatzbeitrag (2026 average)", "childless care surcharge", "no church tax",
                     "wage tax 1074.33 EUR", "pension 558.00 EUR", "health 508.59 EUR", "care 139.50 EUR", "Übergangsbereich", "bmf-steuerrechner.de"] {
            XCTAssertTrue(detail.contains(text), text)
        }
        let evidence = try evidence(result)
        XCTAssertEqual("DE", evidence.country); XCTAssertEqual(2026, evidence.taxYear); XCTAssertEqual(5, evidence.sources.count)
        XCTAssertEqual(try Rational.parse("72000"), evidence.annualGross)
    }

    func testContributionCeilingsAndCareRatesFollowProfile() throws {
        func m(_ text: String) -> NetDecimal { NetDecimal.parse(text)! }
        let below = try evidence(try last("5812.5 EUR/month gross in DE for 2026")).german!
        let above = try evidence(try last("9000 EUR/month gross in DE for 2026")).german!
        XCTAssertEqual(m("508.59"), below.health); XCTAssertEqual(m("508.59"), above.health) // 5812.50 * 8.75 %, half up
        XCTAssertEqual(m("785.85"), above.pension); XCTAssertEqual(m("109.85"), above.unemployment) // 8450 * 9.3 % / 1.3 %
        XCTAssertEqual(m("139.50"), above.care) // 5812.50 * 2.4 %
        let parent = try evidence(try last("5000 EUR/month gross in DE for 2026 with 1 children")).german!
        XCTAssertEqual(m("90"), parent.care); XCTAssertFalse(parent.childlessSurcharge)
        let three = try evidence(try last("5000 EUR/month gross in DE for 2026 with 3 children")).german!
        XCTAssertEqual(m("65"), three.care) // 1.8 % - 2 x 0.25 %
        let saxony = try evidence(try last("5000 EUR/month gross in DE for 2026 with Saxony")).german!
        XCTAssertEqual(m("145"), saxony.care) // 2.3 % + 0.6 %
        let surcharge = try evidence(try last("5000 EUR/month gross in DE for 2026 with health surcharge 1.7%")).german!
        XCTAssertEqual(m("407.50"), surcharge.health)
    }

    func testInverseStaysWithinExpressionBudgetAcrossBrackets() throws {
        // C# passes the target as a double; its invariant text ("2000000", "1500.37") is what the row replaces.
        try theory([("2000000 net in gross in DE for 2026", "2000000"), ("50000000 net in gross in DE for 2026 with tax class 6", "50000000"),
                    ("400000 EUR/month net in gross in DE for 2026 with church tax 8%", "400000"),
                    ("1500.37 EUR/month net in gross in DE for 2026 with tax class 3 with 2 children", "1500.37")]) { source, target in
            let result = try PayrollTest.line(source, context)
            if let error = result.error { XCTAssertTrue(error.contains("exact net"), error); return }
            let german = try evidence(result).german!; XCTAssertEqual(NetDecimal.parse(target)!, german.net)
            let lowerGross = try german.gross - NetDecimal(1, scale: 2)
            let lower = try PayrollTest.line(source.netReplace(" net in gross", " gross").netReplace(target, lowerGross.description), context)
            XCTAssertNotEqual(NetDecimal.parse(target)!, try evidence(lower).german!.net)
        }
    }

    func testSpecificationExamplesEvaluate() throws {
        let lines = try PayrollTest.specBlock("## German 2026 employee model"); XCTAssertEqual(8, lines.count)
        for line in lines { XCTAssertNil(try PayrollTest.line(line, context).error, line) }
    }

    func testExpensiveGermanSheetsShareTheExistingComputationLimit() throws {
        XCTAssertThrowsError(try SheetEvaluator.evaluate(Array(repeating: "2000000 net in gross in DE for 2026", count: 2000).joined(separator: "\n"), context: context)) {
            XCTAssertEqual($0 as? CalcError, .computationLimit)
        }
    }

    func testCurrentYearDependencyAndPinnedYearAreSeparate() throws {
        let session = SheetEvaluationSession(); let source = "60000 gross in DE\n60000 gross in DE for 2026\n7"
        let before = try session.evaluate(source, context: context)
        XCTAssertNil(before[0].error)
        let after = try session.evaluate(source, context: context.with { $0.today = DateOnly(2027, 1, 1) })
        XCTAssertNotNil(after[0].error); XCTAssertTrue(PayrollTest.same(before[1], after[1]))
        XCTAssertEqual(try last("60000 gross", context.with { $0.payrollRegion = "DE" }).display, "37561")
        XCTAssertEqual(try last("60000 EUR gross for 2026", context.with { $0.payrollRegion = "US" }).display, "37561 EUR")
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("37561 net in gross in DE for 2026", cancelled, context: context)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
