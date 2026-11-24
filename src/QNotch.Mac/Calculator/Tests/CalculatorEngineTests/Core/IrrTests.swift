import XCTest
@testable import CalculatorEngine

final class IrrTests: XCTestCase {
    private func last(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let result = try SheetEvaluator.evaluate(source, context: context).last!
        XCTAssertNil(result.error, source, file: file, line: line); return result
    }
    private func evidence(_ result: LineResult, file: StaticString = #filePath, line: UInt = #line) throws -> IrrEvidence {
        let steps = result.explanation.filter { $0.irr != nil }
        XCTAssertEqual(steps.count, 1, file: file, line: line)
        guard let evidence = steps.first?.irr else { throw CalcError.format("no IRR evidence") }
        return evidence
    }
    private func real(_ value: Rational) -> Double { value.numerator.toDouble() / value.denominator.toDouble() }
    private func contains(_ interval: IrrRootInterval, _ root: Rational, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(interval.lowerRate.numerator * root.denominator <= root.numerator * interval.lowerRate.denominator, file: file, line: line)
        XCTAssertTrue(interval.upperRate.numerator * root.denominator >= root.numerator * interval.upperRate.denominator, file: file, line: line)
    }
    private func oracleRational(_ text: String) throws -> Rational {
        let parts = text.netSplit("/")
        return try Rational(BigInt(parts[0])!, parts.count == 2 ? BigInt(parts[1])! : .one)
    }

    func testIndependentSympyIntervalsVerifyCountsAndEverySelectedRoot() throws {
        let document = try JSONNode.parse(try Fixtures.data("irr-oracle-v1.json"))
        try theory(try document.property("cases").arrayItems()) { entry in
            let cash = try entry.property("cash").arrayItems().map { try String($0.int()) }.joined(separator: ",")
            let expected = try entry.property("distinctPositiveDiscountRoots").int()
            if expected == 0 {
                XCTAssertTrue(try SheetEvaluator.evaluate("irr([\(cash)])")[0].error?.contains("No admissible IRR") == true, cash); return
            }
            let roots = try entry.property("roots").arrayItems()
            for (i, root) in roots.enumerated() {
                let lower = try root.property("lower").string(), upper = try root.property("upper").string()
                let answer = try last("irr([\(cash)],(\(lower)))"); let evidence = try evidence(answer)
                XCTAssertEqual(evidence.distinctRoots, expected, cash); XCTAssertEqual(evidence.selectedRoot, i, cash)
                contains(evidence.roots[i], try oracleRational(lower)); contains(evidence.roots[i], try oracleRational(upper))
                XCTAssertEqual(evidence.roots.count, expected, cash)
            }
        }
    }
    func testFinancialFunctionSyntaxDoesNotConsumeTheIranianCurrencyCode() throws {
        XCTAssertEqual(try last("IRR 100").display, "100 IRR"); XCTAssertEqual(try last("100 IRR").display, "100 IRR")
        XCTAssertEqual(try last("(40+60) IRR").display, "100 IRR"); XCTAssertEqual(try last("IRR(-100,110)").display, "10%")
    }
    func testScalarListAndRepeatedRootCases() throws {
        try theory([
            ("irr(-1000,300,400,500)", "≈ 8.8963%"), ("irr([-1000,300,400,500])", "≈ 8.8963%"), ("irr(-100,110)", "10%"), ("irr([-100,50])", "-50%"),
            ("irr([-100,100])", "0%"), ("irr([0,-100,110,0])", "10%"), ("irr([-100,200,-100])", "0%"), ("irr([1,-4,6,-4,1])", "0%"),
            ("irr([-100 EUR,110 EUR])", "10%"), ("f(x)=irr([-100,x])\nf(110)", "10%"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testAllRootsAreCountedAndGuessSelectionIsExplicit() throws {
        let first = try last("irr([-100,230,-132])"); let evidence = try evidence(first)
        XCTAssertEqual(evidence.distinctRoots, 2); XCTAssertEqual(evidence.selectedRoot, 0)
        contains(evidence.roots[0], try Rational(1, 10)); contains(evidence.roots[1], try Rational(1, 5))
        XCTAssertTrue(first.display.contains("10%")); XCTAssertTrue(first.explanation.contains { $0.assumption?.contains("Sturm") == true })
        let second = try self.evidence(try last("irr([-100,230,-132],19%)")); XCTAssertEqual(second.selectedRoot, 1)
        let tie = try self.evidence(try last("irr([-100,230,-132],15%)")); XCTAssertTrue(tie.toleranceTie); XCTAssertEqual(tie.selectedRoot, 0)
        let repeated = try self.evidence(try last("irr([-2,5,-4,1],-60%)"))
        XCTAssertEqual(repeated.distinctRoots, 2); contains(repeated.roots[0], try Rational(-1, 2)); contains(repeated.roots[1], .zero)
        XCTAssertEqual(repeated.selectedRoot, 0)
    }
    func testSelectedIntervalAndNpvIndependentlyVerifyThePublishedRoot() throws {
        let result = try last("irr([-1000,300,400,500])"); let evidence = try evidence(result); let interval = evidence.roots[evidence.selectedRoot]
        let rate = real(try result.value!.scalar)
        XCTAssertTrue(rate >= 0.0889633946933 && rate <= 0.0889633946935, "\(rate)")
        XCTAssertTrue(real(interval.upperRate) - real(interval.lowerRate) <= 1e-14)
        let npv = -1000 + 300 / (1 + rate) + 400 / pow(1 + rate, 2) + 500 / pow(1 + rate, 3)
        XCTAssertTrue(npv >= -1e-9 && npv <= 1e-9, "\(npv)")
        XCTAssertTrue(try result.value!.number.isApproximate)
        XCTAssertTrue(result.explanation.contains { $0.assumption?.contains("time 0") == true && $0.assumption!.contains("not automatically annualized") })
    }
    func testMaximumCashFlowCountAndSparseHighDegreeRootsAreNotArtificiallyTruncated() throws {
        let zeros = "[-100," + Array(repeating: "0", count: 1022).joined(separator: ",") + ",110]"
        let result = try last("irr(" + zeros + ")")
        let rate = real(try result.value!.scalar)
        let grown = pow(1 + rate, 1023)
        XCTAssertTrue(grown >= 1.1 - 1e-10 && grown <= 1.1 + 1e-10, "\(grown)")
        XCTAssertEqual(try evidence(result).distinctRoots, 1)
        var cash = [Int](repeating: 0, count: 101); cash[0] = 2; cash[50] = -3; cash[100] = 1
        let multiple = try last("irr([" + cash.map(String.init).joined(separator: ",") + "],-1%)")
        let evidence = try evidence(multiple); XCTAssertEqual(evidence.distinctRoots, 2)
        let lower = real(evidence.roots[0].lowerRate), expected = pow(2, -1.0 / 50) - 1
        XCTAssertTrue(lower >= expected - 1e-12 && lower <= expected + 1e-12, "\(lower)")
        contains(evidence.roots[1], .zero)
    }
    func testDecimalHalfwayRootsHaveVerifiedDisplayRounding() throws {
        // (q - 2) * (2000001*q - 2000000) has rate 0.0000005, a four-decimal percentage halfway.
        let result = try last("irr([4000000,-6000002,2000001],0)")
        XCTAssertTrue(result.display.hasSuffix("0.0001%"), result.display); contains(try evidence(result).roots.last!, try Rational(1, 2000000))
    }
    func testSeededTwoPeriodFlowsHaveExactInverseRatesAndScaleInvariance() throws {
        var random = NetRandom(11097)
        for _ in 0..<200 {
            let outlay = random.next(1, 10000); let income = random.next(1, 20000); let scale = random.next(1, 100)
            let expected = try Rational(income - outlay, outlay)
            let first = try last("irr([-\(outlay),\(income)])"); XCTAssertEqual(try first.value!.scalar, expected)
            XCTAssertFalse(try first.value!.number.isApproximate); XCTAssertTrue(try evidence(first).roots[0].exact)
            XCTAssertEqual(try last("irr([\(outlay * scale),-\(income * scale)])").value!.scalar, expected)
        }
    }
    private func snapshot(_ dollars: Int, _ date: DateOnly = DateOnly(2026, 10, 30)!) throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: "Fixture", baseCurrency: "EUR", asOf: date, retrievedAt: .utc(2026, 10, 31), rates: [("EUR", .one), ("USD", Rational(dollars))])
    }
    func testCurrencyContextAndApproximateInputsRetainTheirProvenance() throws {
        let context = EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(try snapshot(2), []))
        let result = try last("irr([-100 EUR,220 USD])", context); XCTAssertEqual(result.display, "10%")
        XCTAssertTrue(result.explanation.contains { $0.assumption?.contains("Fixture") == true })
        let approximate = try last("x=loan 250000 at 4.99% for 30 years\nirr([-x,x*1.1])")
        XCTAssertTrue(try evidence(approximate).inputApproximate); XCTAssertTrue(approximate.display.hasPrefix("≈ "))
        let session = SheetEvaluationSession(); let noWork = try session.evaluateWithFunctions("irr([-100,110])\n7", .empty, [])
        XCTAssertFalse(noWork.usesCurrencyRates); XCTAssertFalse(noWork.usesCurrentDate); XCTAssertFalse(noWork.usesCurrentInstant)
    }
    func testDependenciesAndSavedFunctionsReuseUnrelatedResults() throws {
        let session = SheetEvaluationSession(); var source = "outlay=100\nf(x)=irr([-outlay,x])\n7"
        // Functions remain parameter-only; a captured sheet operand is not a financial closure.
        XCTAssertNotNil(try session.evaluateWithFunctions(source, .empty, []).results[1].error)
        source = "outlay=100\nf(x,y)=irr([-x,y])\nf(outlay,110)\n7"
        _ = try session.evaluateWithFunctions(source, .empty, [])
        let next = try session.evaluateWithFunctions(source.replacingOccurrences(of: "outlay=100", with: "outlay=200"), .empty, [])
        XCTAssertEqual(next.results[2].display, "-45%"); XCTAssertEqual(session.lastStatistics.parsedLines, 1); XCTAssertTrue(session.lastStatistics.reusedResults > 0)
    }
    func testRateChangesInvalidateOnlyTheConsumerAndConflictingDatesAreRefused() throws {
        let current = try snapshot(2), historic = try snapshot(3, DateOnly(2023, 12, 29)!)
        let context = EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(current, [(DateOnly(2024, 1, 1)!, historic)]))
        let session = SheetEvaluationSession(); let source = "flows=[-100 EUR,220 USD]\nirr(flows)\n7"
        _ = try session.evaluateWithFunctions(source, .empty, [], context: context)
        let changed = try session.evaluateWithFunctions(source, .empty, [], context: context.with { $0.currencyRates = try? CurrencyRateBook(try snapshot(4), []) })
        XCTAssertEqual(changed.results[1].display, "-45%"); XCTAssertEqual(session.lastStatistics.parsedLines, 0)
        XCTAssertEqual(session.lastStatistics.evaluatedLines, 1); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let bad = try SheetEvaluator.evaluate("a=100 EUR in USD on 2024-01-01\nb=110 EUR in USD\nirr([-a,b])", context: context).last!
        XCTAssertTrue(bad.error?.contains("different currency snapshots") == true, bad.error ?? "")
    }
    func testInvalidOrNoRootInputsDoNotPublishGuesses() throws {
        try theory([
            "irr([])", "irr([0,0,0])", "irr([1,2,3])", "irr([-1,-2,-3])", "irr([1,-1,1])", "irr(1)", "irr()", "irr([-100,110],-100%)", "irr([-100,110],1 m)",
            "irr([-100,110],sqrt(2))", "irr([-100,110],10%,20%)", "irr(-100,[110])", "irr([-100 EUR,110])", "irr([-100 EUR/h,110 EUR/h])", "irr([-100,unknown])",
            "irr([-100,10%])",
        ]) { source in XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source) }
    }
    func testCancellationAndCostlyIsolationRemainBounded() throws {
        let cancel = CancellationToken(); cancel.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("irr([-1000,300,400,500])", cancel)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        var random = NetRandom(3072)
        let dense = "irr([" + (0..<300).map { _ in String(random.next(-1000000, 1000001)) }.joined(separator: ",") + "])"
        XCTAssertNotNil(try SheetEvaluator.evaluate(dense)[0].error)
        XCTAssertThrowsError(try SheetEvaluator.evaluate(Array(repeating: "irr([-1000,300,400,500])", count: 7000).joined(separator: "\n"))) {
            XCTAssertEqual($0 as? CalcError, .computationLimit)
        }
    }
}
