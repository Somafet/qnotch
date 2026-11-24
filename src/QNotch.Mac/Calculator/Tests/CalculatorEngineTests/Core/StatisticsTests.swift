import XCTest
@testable import CalculatorEngine

final class StatisticsTests: XCTestCase {
    private func last(_ source: String, _ context: EvaluationContext? = nil) throws -> LineResult { try MathSheet.last(source, context: context) }
    private func value(_ source: String, _ context: EvaluationContext? = nil) throws -> SheetValue { try MathSheet.value(source, context: context) }

    func testPublishedAndTypedExamples() throws {
        try theory([
            ("[1,2,3]", "[1, 2, 3]"), ("[]", "[]"), ("sum([120,340,89])", "549"), ("sum([])", "0"), ("count([])", "0"), ("count([1,2,3])", "3"),
            ("sum([1,2],3,[4,5])", "15"), ("sum([1/3,1/3])", "2/3"), ("mean(1,2,3,4)", "2.5"), ("average([1,2,3,4])", "2.5"), ("avg([1,2],[3,4])", "2.5"),
            ("median(1,3,2)", "2"), ("median([4,1,3,2])", "2.5"), ("median([7])", "7"), ("stdev(2,4,4,4,5,5,7,9)", "2.1381"), ("stddev([2,4,4,4,5,5,7,9])", "2.1381"),
            ("stdevp([2,4,4,4,5,5,7,9])", "2"), ("variancep([2,4,4,4,5,5,7,9])", "4"), ("variance([2,4,4,4,5,5,7,9])", "4.5714"), ("stdevp([7])", "0"),
            ("variance([1000000000000000000000000,1000000000000000000000001,1000000000000000000000002])", "1"), ("percentile([3,7,9,12],90)", "11.1"),
            ("percentile([3,7,9,12],90%)", "11.1"), ("percentile([3,7,9,12],0)", "3"), ("percentile([3,7,9,12],100)", "12"), ("percentile([10,20],0.5)", "10.05"),
            ("min([3,-1,2])", "-1"), ("max([3,-1,2])", "3"), ("min([2 m,100 cm])", "1 m"), ("max([1 m,200 cm])", "2 m"), ("mean([1 m,200 cm])", "1.5 m"),
            ("median([1 m,200 cm,3 m])", "2 m"), ("variancep([1 m,3 m])", "1 m^2"), ("stdev([1 m,3 m])", "1.4142 m"), ("mean([0 °C,68 °F])", "10 °C"),
            ("median([0 °C,20 °C])", "10 °C"), ("variancep([0 °C,20 °C])", "100 deltaC^2"), ("stdevp([0 °C,20 °C])", "10 deltaC"), ("mean([10%,20%])", "15%"),
            ("stdev([10%,20%])", "7.0711%"), ("variance([10%,20%])", "0.005"), ("percentile([10%,20%],50)", "15%"), ("x=[1,2,3]\nmean(x)", "2"),
            ("f(x)=mean(x)\nf([1,2,3])", "2"), ("f(x,y)=sum([x,y])\nf(2,3)", "5"), ("f()=[1,2,3]\nsum(f())", "6"), ("npv(10%,[100,200,300])", "481.5928"),
            ("npv(0,[100,200],300)", "600"), ("holidays=[]\n4\n5\nx=[1,2,3]\nsum", "9"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testStatisticsKeepExactUnderlyingFractionsAndRadicals() throws {
        XCTAssertEqual(try value("mean([0,1,1])").scalar, try Rational(2, 3))
        XCTAssertEqual(try value("variance([2,4,4,4,5,5,7,9])").scalar, try Rational(32, 7))
        let source = "x=stdev([2,4,4,4,5,5,7,9])\nx*x"
        XCTAssertEqual(try value(source).scalar, try Rational(32, 7))
        XCTAssertFalse(try value("stdev([1,3])").number.isApproximate)
        XCTAssertEqual(try last("stdev([1,3]) to 6 decimals").display, "1.414214")
        XCTAssertEqual(try value("x=[sqrt(8),sqrt(2),sqrt(18)]\nmedian(x)^2").scalar / Rational(4), Rational(2))
    }
    func testListsAreImmutableAndCompareByTheirTypedContents() throws {
        var source = [SheetValue(Rational(1)), SheetValue(Rational(2))]
        let list = try SheetList(source); source[0] = SheetValue(Rational(9))
        XCTAssertEqual(try list.values[0].scalar, Rational(1))
        XCTAssertEqual(list, try SheetList([SheetValue(Rational(1)), SheetValue(Rational(2))]))
        XCTAssertNotEqual(list, try SheetList([SheetValue(Rational(2)), SheetValue(Rational(1))]))
        // C# also checks that Values is a read-only list; Swift's `let values: [SheetValue]` cannot be mutated through the list at all.
    }
    func testMaximumListsHaveBoundedPreviewsAndCompleteFormattedCopies() throws {
        let literal = "[" + (1...1024).map(String.init).joined(separator: ",") + "]"
        let value = try value(literal)
        XCTAssertEqual(try value.list.values.count, 1024); XCTAssertTrue(try value.display.contains("…")); XCTAssertTrue(try value.display.netLength <= 516)
        XCTAssertFalse(try value.copyText.contains("…")); XCTAssertTrue(try value.copyText.hasSuffix("1023, 1024]"))
        XCTAssertEqual(try value.copyText.utf16.filter { $0 == 0x2C }.count, 1023)
        XCTAssertEqual(try last("data=" + literal + "\nsum(data)").display, "524800")
        XCTAssertEqual(try last("data=" + literal + "\nmedian(data)").display, "512.5")
        XCTAssertEqual(try last("data=" + literal + "\nnpv(0,data)").display, "524800")
        XCTAssertNotNil(try SheetEvaluator.evaluate("[" + (1...1025).map(String.init).joined(separator: ",") + "]")[0].error)
        XCTAssertNotNil(try MathSheet.line("data=" + literal + "\nsum(data,data)").error)
    }
    func testNumericListsAndEmptyListsDoNotChangeHolidayRules() throws {
        let context = EvaluationContext(workdayRegion: "WEEKDAYS")
        let result = try SheetEvaluator.evaluate("days=[24 dec]\nholidays=days\n2027-12-23+1 working day\nholidays=[]\n2027-12-23+1 working day", context: context)
        XCTAssertEqual(result[2].display, "2027-12-27"); XCTAssertEqual(result[4].display, "2027-12-24")
        XCTAssertEqual(result[3].value?.kind, .holidayList)
        XCTAssertEqual(try value("[]").kind, .list)
        XCTAssertNotNil(try SheetEvaluator.evaluate("holidays=[1,2]")[0].error)
        XCTAssertNil(try last("holidays=[1,2]\n5").error)
    }
    func testListDependenciesCacheInvalidationAndFunctionsAreTyped() throws {
        let session = SheetEvaluationSession(); let source = "x=1\ndata=[x,2,3]\nmean(data)\n7"
        _ = try session.evaluateWithFunctions(source, .empty, [])
        let changed = try session.evaluateWithFunctions(source.netReplace("x=1", "x=4"), .empty, [])
        XCTAssertEqual(changed.results[2].display, "3"); XCTAssertEqual(session.lastStatistics.parsedLines, 1)
        XCTAssertEqual(session.lastStatistics.reusedResults, 1); XCTAssertEqual(changed.results[2].dependencies, [1])
        XCTAssertEqual(try last("n=3\nf(x)=percentile(x,50)\nf([n,1,7])").display, "3")
        for result in try SheetEvaluator.evaluate("a=[b,1]\nb=mean(a)") { XCTAssertEqual(result.error, "Circular dependency") }
    }
    private func snapshot(_ provider: String, _ asOf: DateOnly, _ dollars: Int) throws -> CurrencyRateSnapshot {
        try CurrencyRateSnapshot(provider: provider, baseCurrency: "EUR", asOf: asOf, retrievedAt: MathSheet.utc(2026, 10, 31), rates: [("EUR", Rational(1)), ("USD", Rational(dollars))])
    }
    func testMixedMoneySamplesUseOneSnapshotAndDoNotLoseApproximation() throws {
        let snapshot = try snapshot("Fixture", DateOnly(2026, 10, 30)!, 2)
        let context = EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(snapshot, []))
        XCTAssertEqual(try last("sum([10 EUR,20 USD])", context).display, "20 EUR")
        XCTAssertEqual(try last("median([10 EUR,20 USD])", context).display, "10 EUR")
        XCTAssertEqual(try last("stdevp([10 EUR,40 USD])", context).display, "5 EUR")
        XCTAssertEqual(try last("npv(0,[10 EUR,20 USD])", context).display, "20 EUR")
        let converted = try last("mean([10 EUR,40 USD])", context)
        XCTAssertEqual(try XCTUnwrap(converted.value).money.rateSnapshotKey, snapshot.key)
        XCTAssertTrue(converted.explanation.contains { $0.assumption?.contains("Fixture") == true })
        for operation in ["mean(data)", "median(data)", "stdev(data)", "percentile(data,50)", "min(data)", "sum(data)", "npv(0,data)"] {
            XCTAssertTrue(try last("x=loan 250000 at 4.99% for 30 years\ndata=[x,2]\n" + operation).display.hasPrefix("≈ "), operation)
        }
        XCTAssertEqual(try last("x=loan 250000 at 4.99% for 30 years\ncount([x,2])").display, "2")
    }
    func testRatesInvalidateOnlyTheListConsumerAndHistoricalScopeReachesItsCashFlows() throws {
        let session = SheetEvaluationSession()
        let first = EvaluationContext(today: DateOnly(2026, 10, 31), currencyRates: try CurrencyRateBook(try snapshot("Fixture", DateOnly(2026, 10, 30)!, 2), []))
        let source = "data=[100 EUR,100 USD]\nmean(data)\n7"
        let initial = try session.evaluateWithFunctions(source, .empty, [], context: first)
        XCTAssertTrue(initial.usesCurrencyRates); XCTAssertTrue(initial.hasMoney)
        let fourDollars = try CurrencyRateBook(try snapshot("Fixture", DateOnly(2026, 10, 30)!, 4), [])
        let updated = try session.evaluateWithFunctions(source, .empty, [], context: first.with { $0.currencyRates = fourDollars })
        XCTAssertEqual(updated.results[1].display, "62.5 EUR")
        XCTAssertEqual(session.lastStatistics.parsedLines, 0); XCTAssertEqual(session.lastStatistics.evaluatedLines, 1); XCTAssertEqual(session.lastStatistics.reusedResults, 2)
        let historical = try snapshot("Historical", DateOnly(2023, 12, 29)!, 3)
        let book = try CurrencyRateBook(try snapshot("Fixture", DateOnly(2026, 10, 30)!, 2), [(DateOnly(2024, 1, 1)!, historical)])
        let context = first.with { $0.currencyRates = book }
        XCTAssertEqual(try last("f()=[100 EUR,100 USD]\nnpv(0,f()) in USD on 2024-01-01", context).display, "400 USD")
        let noWork = try SheetEvaluationSession().evaluateWithFunctions("sum([1 EUR,2 EUR])\n[3,4]", .empty, [])
        XCTAssertFalse(noWork.usesCurrencyRates); XCTAssertFalse(noWork.usesCurrentDate); XCTAssertFalse(noWork.usesCurrentInstant)
    }
    func testSeededSamplesMatchPairwiseVarianceAndIntegerOrderOracles() throws {
        var random = NetRandom(22054)
        for _ in 0..<250 {
            let count = random.next(2, 30)
            let values = (0..<count).map { _ in random.next(-1000, 1001) }
            let ordered = values.sorted(); let n = values.count
            let literal = "[" + values.map(String.init).joined(separator: ",") + "]"
            XCTAssertEqual(try value("mean(" + literal + ")").scalar, try Rational(values.reduce(0, +), n))
            let middle = n % 2 == 1 ? Rational(ordered[n / 2]) : try Rational(ordered[n / 2 - 1] + ordered[n / 2], 2)
            XCTAssertEqual(try value("median(" + literal + ")").scalar, middle)
            var pairs = BigInt.zero
            for a in 0..<n { for b in (a + 1)..<max(a + 1, n) { pairs += BigInt.pow(BigInt(values[a] - values[b]), 2) } }
            let variance = try Rational(pairs, BigInt(n * (n - 1)))
            XCTAssertEqual(try value("variance(" + literal + ")").scalar, variance)
            let percentile = random.next(0, 101); let rank = (n - 1) * percentile, index = rank / 100, weight = rank % 100
            let expected = weight == 0 ? Rational(ordered[index]) : try Rational(ordered[index] * (100 - weight) + ordered[index + 1] * weight, 100)
            XCTAssertEqual(try value("percentile(\(literal),\(percentile))").scalar, expected)
            let shifted = "[" + values.reversed().map { String($0 + 1000000) }.joined(separator: ",") + "]"
            XCTAssertEqual(try value("variance(" + shifted + ")").scalar, variance)
        }
    }
    func testInvalidSamplesAreErrorsInsteadOfSkippedData() throws {
        try theory([
            "mean([])", "min([])", "max([])", "median([])", "stdev([1])", "variance([1])", "percentile([],50)", "percentile([1,2],-1)", "percentile([1,2],101)",
            "percentile([1,2],50 m)", "percentile([1,2],sqrt(2))", "sum([1,unknown])", "mean([1 m,2 kg])", "mean([1%,2])", "mean([1 EUR,2])",
            "mean([0 °C,10 deltaC])", "sum([0 °C,10 °C])", "variance([1 EUR,2 EUR])", "sum([[1,2],[3,4]])", "[1,2026-10-31]", "count([1,today])", "mean()",
            "percentile([1,2])", "f(x)=percentile(x)\nf([1,2])", "npv(0,[])",
        ]) { source in XCTAssertNotNil(try MathSheet.line(source).error, source) }
    }
    func testListsRetainCancellationDepthAndSharedComputationBounds() throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        MathSheet.throwsError(.cancelled) { try SheetEvaluator.evaluate("mean([1,2,3])", cancellation) }
        let nested = String(repeating: "[", count: 70) + "1" + String(repeating: "]", count: 70)
        XCTAssertNotNil(try SheetEvaluator.evaluate(nested)[0].error)
        let data = "data=[" + (1...1024).map(String.init).joined(separator: ",") + "]\n"
        MathSheet.throwsError(.computationLimit) { try SheetEvaluator.evaluate(data + Array(repeating: "median(data)", count: 60).joined(separator: "\n")) }
    }
}
