import XCTest
@testable import CalculatorEngine

final class NumberLanguageTests: XCTestCase {
    func testIndependentExactFixtures() throws {
        let cases = try JSONNode.parse(Fixtures.data("number-language-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let source = try item.property("input").string(), expected = try item.property("expected").string()
            let error = try item["error"]?.bool() ?? false
            let result = try SheetEvaluator.evaluate(source)[0]
            XCTAssertEqual(result.display, expected, source)
            if error { XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source) }
            else { XCTAssertNil(result.error, source); XCTAssertNotNil(result.value, source) }
        }
    }
    func testAmbiguousMalformedAndUnknownFormsDoNotPublishANumber() throws {
        try theory(["5mx", "5b", "5 M", "5 Bx", "5 k", "5kmx", "5mbps", "5kWhx", "5monthsx", "5millionaires", "5million2", "5kk", "5k2", "2kM", "2%k", "1万2万", "1万2億",
                    "1億10000万", "2万30000", "2.5万3000", "2万3k", "2万 3000", "2万億", "double typo", "half of", "Budget double 5", "double(5)"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
    func testDeclaredNamesAndExistingFunctionCallsRetainTheirMeaning() throws {
        let results = try SheetEvaluator.evaluate("double price=7\nhalf=3\nM=4\n万事=9\ndouble price\nhalf+1\n2*M\n万事+1\ndouble(x)=x+1\ndouble (5)\nhalf(x)=x+3\nhalf(5)\n2M")
        XCTAssertEqual(results[4].display, "7"); XCTAssertEqual(results[5].display, "4")
        XCTAssertEqual(results[6].display, "8"); XCTAssertEqual(results[7].display, "10")
        XCTAssertEqual(results[9].display, "6"); XCTAssertEqual(results[11].display, "8")
        XCTAssertEqual(results[12].display, "2000000")
        XCTAssertEqual(try SheetEvaluator.evaluate("double(5)")[0].error, "Unknown function: double")
    }
    func testVariablesReferencesFunctionScopeAndPercentagesWorkTogether() throws {
        let results = try SheetEvaluator.evaluate("cost=2.5k\ndouble cost\ncut(x)=half x\ncut(L2)\np=10%\ntwice p\n100+L6\n\"Budget\" double 2M")
        XCTAssertEqual(results.map(\.display), ["2500", "5000", "", "2500", "10%", "20%", "120", "4000000"])
        XCTAssertEqual(results[1].dependencies, [0]); XCTAssertEqual(results[3].dependencies, [1])
        XCTAssertTrue(results[5].value!.isPercentage)
        XCTAssertTrue(results[1].explanation.contains { $0.operation == "scale by double" && $0.operands[1] == "2" })
    }
    func testFunctionReceiptsPreserveSignificantWhitespaceAndOldCanonicalKeys() throws {
        let ordinary = try FunctionUpdate.prepare("f(x)=x+1", .empty, [])
        XCTAssertFalse(try FunctionUpdate.prepare("F ( X ) = X + 1", ordinary.library, ordinary.receipts).hasChanges)
        let shortForm = try FunctionUpdate.prepare("f()=2M", .empty, [])
        let invalidSpace = try SheetEvaluationSession().evaluateWithFunctions("f()=2 M\nf()", shortForm.library, shortForm.receipts)
        XCTAssertNotNil(invalidSpace.results[0].error); XCTAssertNil(invalidSpace.results[1].value)
        let changedUnit = try SheetEvaluationSession().evaluateWithFunctions("f()=2m\nf()", shortForm.library, shortForm.receipts)
        XCTAssertNil(changedUnit.results[0].error); XCTAssertEqual(changedUnit.results[1].display, "2 m")
        XCTAssertTrue(changedUnit.functions.hasChanges)
        let cjk = try FunctionUpdate.prepare("g()=2万3000", .empty, [])
        let invalidGroupSpace = try SheetEvaluationSession().evaluateWithFunctions("g()=2万 3000\ng()", cjk.library, cjk.receipts)
        XCTAssertNotNil(invalidGroupSpace.results[0].error); XCTAssertNil(invalidGroupSpace.results[1].value)
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("g()", cjk.library, []).results[0].display, "23000")
    }
    func testSeededCoefficientsMatchIndependentIntegerScaling() throws {
        var random = NetRandom(5541)
        let factors: [(String, Int)] = [("k", 3), ("M", 6), ("B", 9), (" thousand", 3), (" million", 6), (" billion", 9), ("万", 4), ("億", 8), ("亿", 8), ("만", 4), ("억", 8)]
        for _ in 0..<1000 {
            let numerator = random.next(-100_000_000, 100_000_001); let factor = factors[random.next(factors.count)]
            let coefficient = try Rational(numerator, 1000).description
            let expected = try Rational(BigInt(numerator) * BigInt.pow(10, factor.1), BigInt(1000))
            let actual = try SheetEvaluator.evaluate(coefficient + factor.0)[0]
            XCTAssertNil(actual.error, coefficient + factor.0); XCTAssertEqual(try actual.value?.scalar, expected)
        }
    }
    func testCjkCompoundNumbersMatchIndependentPlaceValues() throws {
        var random = NetRandom(8029)
        for (high, low) in [("億", "万"), ("亿", "万"), ("억", "만")] {
            for _ in 0..<100 {
                let a = random.next(1, 500), b = random.next(0, 10000), c = random.next(0, 10000)
                let result = try SheetEvaluator.evaluate("\(a)\(high)\(b)\(low)\(c)")[0]
                XCTAssertNil(result.error)
                XCTAssertEqual(try result.value?.scalar, Rational(a * 100_000_000 + b * 10000 + c))
            }
        }
    }
    func testKeywordBindingChangesInvalidateTheCurrentSheetCache() throws {
        let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluate("double 5\nnotes")[0].display, "10")
        XCTAssertNotNil(try session.evaluate("double 5\ndouble=3")[0].error)
        XCTAssertEqual(try session.evaluate("double 5\nnotes")[0].display, "10")
        XCTAssertEqual(try session.evaluate("p=10%\ntwice p")[1].display, "20%")
        XCTAssertEqual(try session.evaluate("p=15%\ntwice p")[1].display, "30%")
    }
    func testExpansionAndMalformedTokenStreamsStayBounded() throws {
        XCTAssertEqual(try SheetEvaluator.evaluate(String(repeating: "double ", count: 100) + "1")[0].error, "Expression depth limit exceeded")
        XCTAssertNotNil(try SheetEvaluator.evaluate("1" + String(repeating: "万1", count: 2000))[0].error)
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("2億300万4000", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        var random = NetRandom(7755)
        let pieces = ["2", "万", "億", "亿", "만", "억", "k", "M", "m", "B", "double ", "half of ", "twice ", "+", "-", "%", "(", ")", " "]
        for _ in 0..<500 {
            let count = random.next(1, 40)
            let text = (0..<count).map { _ in pieces[random.next(pieces.count)] }.joined()
            let item = try SheetEvaluator.evaluate(text)[0]
            XCTAssertLessThanOrEqual(item.display.netLength, 2048); XCTAssertLessThanOrEqual(item.explanation.count, 64)
        }
    }
}
