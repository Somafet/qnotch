import XCTest
@testable import CalculatorEngine

final class FinancialPlanningTests: XCTestCase {
    private func last(_ source: String, _ context: EvaluationContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let result = try SheetEvaluator.evaluate(source, context: context).last!
        XCTAssertNil(result.error, source, file: file, line: line); return result
    }
    private func magnitude(_ result: LineResult) throws -> Rational {
        let value = result.value!
        return value.kind == .money ? try value.money.magnitude.scalar : try value.scalar
    }
    private func real(_ value: Rational) -> Double { value.numerator.toDouble() / value.denominator.toDouble() }
    private func explain(_ value: LineResult) -> String { value.explanation.map { $0.assumption ?? "" }.joined(separator: "\n") }

    func testPublicExamplesAndTypedBoundaries() throws {
        try theory([
            ("roi(1000,1500)", "50%"), ("ROI(1000 EUR,1500 EUR)", "50%"), ("roi(100,0)", "-100%"), ("cagr(1000,2500,5 years)", "≈ 20.1124%"),
            ("cagr(100,144,2)", "20%"), ("cagr(100,200,2 years)", "41.4214%"), ("cagr(100,121,6 months)", "46.41%"), ("cagr(100,121,1/2)", "46.41%"),
            ("cagr(100,0,5)", "-100%"), ("cagr(100,80,1)", "-20%"), ("realreturn(5%,3%)", "1.9417%"), ("5% minus 3% inflation", "1.9417%"),
            ("5% - 3% inflation", "1.9417%"), ("realreturn(-100%,5%)", "-100%"), ("fire(40000)", "1000000"), ("fire 40k/year", "1000000"),
            ("fire 3000/month at 4%", "900000"), ("fire 3000 EUR per month at 3%", "1200000 EUR"), ("fire $1000 monthly", "300000 USD"),
            ("fire 1000 yearly at 100%", "1000"), ("fire(0,4%)", "0"), ("breakeven(5000,50,30)", "250"), ("break even fixed 5000, price 50, cost 30", "250"),
            ("breakeven(10 EUR,8 EUR,5 EUR)", "3.3333"), ("breakeven(0,0,0)", "0"), ("depreciate 10000 over 5 years", "2000"),
            ("depreciate 10000 EUR over 5 years salvage 1000 EUR", "1800 EUR"), ("depreciate 1200 over 12 months", "100"), ("sln(30000,7500,10)", "2250"),
            ("sln(100,0,2.5)", "40"), ("ddb(10000,1000,5,1)", "4000"), ("ddb(2400,300,10,2,1.5)", "306"), ("ddb(2400,300,10,10)", "22.1225"),
            ("ddb(2400,300,120,1)", "40"), ("ddb(100,20,2,2,10)", "0"), ("syd(10000,1000,5,1)", "3000"), ("syd(30000,7500,10,1)", "4090.9091"),
            ("syd(30000,7500,10,10)", "409.0909"), ("f(x)=fire x/month at 4%\nf(3000)", "900000"), ("f(x)=depreciate x over 5 years\nf(10000)", "2000"),
            ("fire=12\nfire+2", "14"), ("fire budget=12\nfire budget+2", "14"), ("(fire 3000/month at 4%)/1000", "900"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testInvalidInputsAreExplicit() throws {
        try theory([
            "roi(0,100)", "roi(-100,100)", "roi(100,-1)", "cagr(100,110,0)", "cagr(100,110,1201 months)", "cagr(100,110,1 day)", "cagr(100,110,1/100)",
            "cagr(100,110,1 year + 1 day)", "realreturn(5%,-100%)", "realreturn(-101%,3%)", "fire(100,0)", "fire(-1)", "fire(100,101%)", "fire 3000",
            "fire 3000/day", "breakeven(100,20,20)", "breakeven(100,10,20)", "breakeven(-1,10,5)", "breakeven(100,-10,5)", "sln(100,101,5)", "sln(100,0,0)",
            "sln(100,0,1201)", "ddb(100,10,5,6)", "ddb(100,10,5,0)", "ddb(100,10,5,1,-1)", "ddb(100,10,5.5,1)", "syd(100,10,5,1.5)", "syd(100,10,5,6)",
            "fire(100 EUR,4 EUR)", "roi(100 EUR,110)", "sln(100 m,0,5)", "cagr(100,110)",
        ]) { source in XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source) }
    }
    func testExactReturnAndQuadraticRootsSurviveDependentArithmetic() throws {
        XCTAssertEqual(try magnitude(try last("realreturn(5%,3%)")), try Rational(2, 103))
        XCTAssertEqual(try magnitude(try last("r=roi(3,4)\nr")), try Rational(1, 3))
        XCTAssertEqual(try last("r=cagr(1,2,2)\n(r+100%)^2*2").display, "4")
        XCTAssertFalse(try last("cagr(1,2,2)").value!.number.isApproximate)
        XCTAssertTrue(explain(try last("breakeven(10,8,5)")).contains("whole-unit coverage threshold 4"))
        XCTAssertTrue(explain(try last("ddb(100,0,5,5)")).contains("no automatic straight-line switch"))
        XCTAssertTrue(explain(try last("fire 3000/month at 4%")).contains("annualized by 12"))
    }
    func testSeededExactGrowthCasesInvertTheForwardCompoundEquation() throws {
        var random = NetRandom(5831)
        for _ in 0..<60 {
            let numerator = random.next(1, 20); let denominator = random.next(1, 20); let years = random.next(1, 16)
            let growth = try Rational(numerator, denominator)
            let ending = try Rational(BigInt.pow(BigInt(numerator), years), BigInt.pow(BigInt(denominator), years))
            let answer = try last("cagr(1,(\(ending)),\(years))")
            XCTAssertEqual(try magnitude(answer), try growth - .one)
            XCTAssertFalse(try answer.value!.number.isApproximate)
        }
    }
    func testNonrationalCagrCertificateEnclosesAnIndependentForwardPowerCrossing() throws {
        for (start, end, months) in [(1000, 2500, 60), (1000, 300, 84), (100, 999, 119), (100, 101, 1199)] {
            let answer = try last("cagr(\(start),\(end),\(months) months)")
            let growthSteps = answer.explanation.filter { $0.growth != nil }
            XCTAssertEqual(growthSteps.count, 1)
            let evidence = growthSteps[0].growth!
            XCTAssertEqual(evidence.years, try Rational(months, 12))
            XCTAssertEqual(evidence.root!.roots.count, 1)
            let interval = evidence.root!.roots[0]
            let expected = pow(Double(end) / Double(start), 12.0 / Double(months)) - 1
            XCTAssertLessThanOrEqual(abs(real(interval.lowerRate) - expected), 1e-12)
            XCTAssertLessThanOrEqual(abs(real(interval.upperRate) - expected), 1e-12)
            // Exact rational endpoint powers verify the forward equation independently of IRR's discount polynomial.
            func forwardSign(_ r: Rational, _ degree: Int, _ target: Rational) -> BigInt {
                BigInt.pow(r.numerator + r.denominator, degree) * target.denominator - BigInt.pow(r.denominator, degree) * target.numerator
            }
            XCTAssertTrue(forwardSign(interval.lowerRate, evidence.rootDegree, evidence.poweredRatio).sign <= 0)
            XCTAssertTrue(forwardSign(interval.upperRate, evidence.rootDegree, evidence.poweredRatio).sign >= 0)
        }
    }
    func testDepreciationSchedulesConserveBasisAndRespectSalvage() throws {
        var random = NetRandom(8374)
        for _ in 0..<25 {
            let cost = random.next(100, 10000); let salvage = random.next(0, cost); let life = random.next(1, 16)
            var syd = Rational.zero, ddb = Rational.zero, balance = Rational(cost)
            for period in 1...life {
                let sumDigits = (1...life).reduce(0, +)
                let expected = try Rational((cost - salvage) * (life - period + 1), sumDigits)
                var actual = try magnitude(try last("syd(\(cost),\(salvage),\(life),\(period))"))
                XCTAssertEqual(actual, expected); syd = try syd + actual
                let available = try balance - Rational(salvage); var expectedDdb = try balance * Rational(2, life)
                if (try expectedDdb - available).sign > 0 { expectedDdb = available }
                actual = try magnitude(try last("ddb(\(cost),\(salvage),\(life),\(period))"))
                XCTAssertEqual(actual, expectedDdb); XCTAssertTrue(actual.sign >= 0)
                balance = try balance - actual; ddb = try ddb + actual; XCTAssertTrue((try balance - Rational(salvage)).sign >= 0)
            }
            XCTAssertEqual(Rational(cost - salvage), syd)
            XCTAssertEqual(Rational(cost), try ddb + balance)
        }
        XCTAssertEqual(try magnitude(try last("ddb(100,0,5,5)")), try Rational(648, 125)) // Remains above zero; no catch-up.
    }
    func testApproximateProvenanceAndIncrementalDependenciesArePreserved() throws {
        for expression in ["roi(x,x*2)", "cagr(x,x*2,5)", "fire(x)", "sln(x,0,5)", "ddb(x,0,5,2)", "syd(x,0,5,2)", "breakeven(x,50,30)"] {
            XCTAssertTrue(try last("x=loan 250000 at 4.99% for 30 years\n" + expression).display.hasPrefix("≈ "), expression)
        }
        let session = SheetEvaluationSession()
        let before = try session.evaluate("spend=3000\nfire spend/month at 4%\n2+2")
        let after = try session.evaluate("spend=4000\nfire spend/month at 4%\n2+2")
        XCTAssertEqual(before[1].display, "900000"); XCTAssertEqual(after[1].display, "1200000")
        XCTAssertTrue(session.lastStatistics.reusedResults > 0); XCTAssertEqual(session.lastStatistics.parsedLines, 1)
        let cancel = CancellationToken(); cancel.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("cagr(100,101,1199 months)", cancel)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
    func testMixedCurrencyInputsTrackSnapshotChangesAndStaticModelsRequestNoContext() throws {
        func snapshot(_ dollars: Int) throws -> CurrencyRateSnapshot {
            try CurrencyRateSnapshot(provider: "Planning fixture", baseCurrency: "EUR", asOf: DateOnly(2026, 10, 30)!, retrievedAt: .utc(2026, 10, 31), rates: [("EUR", .one), ("USD", Rational(dollars))])
        }
        let context = EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(try snapshot(2), []))
        XCTAssertEqual(try last("roi(100 EUR,300 USD)", context).display, "50%")
        XCTAssertEqual(try last("sln(10000 EUR,4000 USD,4)", context).display, "2000 EUR")
        XCTAssertTrue(explain(try last("roi(100 EUR,300 USD)", context)).contains("Planning fixture"))
        let session = SheetEvaluationSession(); let source = "roi(100 EUR,300 USD)\n7"
        _ = try session.evaluateWithFunctions(source, .empty, [], context: context)
        let changed = try session.evaluateWithFunctions(source, .empty, [], context: context.with { $0.currencyRates = try? CurrencyRateBook(try snapshot(4), []) })
        XCTAssertEqual(changed.results[0].display, "-25%"); XCTAssertEqual(session.lastStatistics.parsedLines, 0)
        XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let staticModels = try session.evaluateWithFunctions("fire 3000 EUR/month\ncagr(100,110,5)\nddb(1000,100,5,1)", .empty, [])
        for result in staticModels.results { XCTAssertNil(result.error) }
        XCTAssertFalse(staticModels.usesCurrencyRates); XCTAssertFalse(staticModels.usesCurrentDate); XCTAssertFalse(staticModels.usesCurrentInstant)
    }
    func testSentenceExplanationRetainsOriginalMonthlyInput() throws {
        let steps = try last("fire 3000/month at 4%").explanation.filter { $0.operation == "fire" }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].operands[0], "3000"); XCTAssertTrue(steps[0].assumption?.contains("annualized by 12") == true)
        XCTAssertEqual(try last("cagr(1000,2500,5 years) to 4 decimals").display.replacingOccurrences(of: "≈ ", with: ""), "20.1124%")
    }
}
