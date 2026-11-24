import XCTest
@testable import CalculatorEngine

final class LocalizedKeywordTests: XCTestCase {
    func testIndependentArithmeticFixtures() throws {
        let cases = try JSONNode.parse(Fixtures.data("localized-keywords-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let language = try item.property("language").string(), source = try item.property("source").string(), expected = try item.property("expected").string()
            XCTAssertFalse(language.isEmpty)
            let results = try SheetEvaluator.evaluate(source)
            for result in results { XCTAssertNil(result.error, source) }
            XCTAssertEqual(results.last!.display, expected, source)
        }
    }
    func testCatalogExplicitlyCoversNineLanguagesAndCurrentRoles() throws {
        let root = try JSONNode.parse(CalculatorEngine.resource("LanguageKeywords.json"))
        XCTAssertEqual(try root.property("version").int(), 1)
        let languages = try root.property("languages").arrayItems()
        XCTAssertEqual(try languages.map { try $0.property("code").string() }, ["en", "ro", "de", "fr", "es", "it", "ja", "zh-Hans", "ko"])
        for language in languages {
            for role in ["Of", "Sum", "Average", "Half", "Double", "To", "Nearest"] { XCTAssertFalse(try language.property("keywords").property(role).arrayItems().isEmpty) }
        }
    }
    func testNamesAndCallsAreNotTranslatedOrSplit() throws {
        let results = try SheetEvaluator.evaluate("de=3\nmoyenne=7\n平均費用=8\n半分合成=9\nの金額=11\nde+1\nmoyenne\n平均費用+1\n半分合成+1\nの金額+1\n半分合成Fn(x)=x+2\nf(x)=半分合成Fn(x)\nf(3)\nsomme(x)=x+3\nsomme (4)")
        for result in results { XCTAssertNil(result.error) }
        XCTAssertEqual(results[5].display, "4"); XCTAssertEqual(results[6].display, "7"); XCTAssertEqual(results[7].display, "9")
        XCTAssertEqual(results[8].display, "10"); XCTAssertEqual(results[9].display, "12")
        XCTAssertEqual(results[12].display, "5"); XCTAssertEqual(results[14].display, "7")
    }
    func testFunctionParametersAndCanonicalReceiptsRemainSourceBased() throws {
        let update = try FunctionUpdate.prepare("f(金額)=20%の金額\ng(半分合成)=半分合成+1", .empty, [])
        let values = try SheetEvaluationSession().evaluateWithFunctions("f(150)\ng(3)", update.library, []).results
        XCTAssertEqual(values.map(\.display), ["30", "4"])
        XCTAssertFalse(try FunctionUpdate.prepare("F(金額) = 20% の 金額\nG(半分合成) = 半分合成 + 1", update.library, update.receipts).hasChanges)
        let ordinary = try FunctionUpdate.prepare("f(de)=de+1", .empty, [])
        XCTAssertFalse(try FunctionUpdate.prepare("F (DE) = DE + 1", ordinary.library, ordinary.receipts).hasChanges)
    }
    func testTaggedLocalizedAggregatesDoNotDoubleCountAndInvalidateCorrectly() throws {
        let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluate("1 #x\n2 #x\n合計 #x\nsomme #x")[3].display, "3")
        XCTAssertEqual(try session.evaluate("1 #x\n2 #x\n合計 #x\nsomme #x\nsomme=7")[3].display, "7")
        let results = try session.evaluate("1 #x\n2 #x\n合計 #x\nsomme #x")
        XCTAssertEqual(results[3].display, "3"); XCTAssertEqual(results[3].dependencies, [0, 1])
    }
    func testAccentedKeywordsAcceptCanonicalUnicodeCompositionWithoutRenamingIdentifiers() throws {
        let input = "jumătate din 10".decomposedStringWithCanonicalMapping
        XCTAssertEqual(try SheetEvaluator.evaluate(input)[0].display, "5")
        let variable = "preț".decomposedStringWithCanonicalMapping
        XCTAssertEqual(try SheetEvaluator.evaluate("\(variable)=10\n\(variable)+2")[1].display, "12")
        XCTAssertNotNil(try SheetEvaluator.evaluate("\(variable)=10\npreț+2")[1].error)
        let tag = "dépenses".decomposedStringWithCanonicalMapping
        XCTAssertEqual(try SheetEvaluator.evaluate("1 #\(tag)\n2 #\(tag)\nsomme #\(tag)")[2].display, "3")
    }
    func testSeededMixedLanguagePercentagesMatchIndependentDecimalArithmetic() throws {
        var random = NetRandom(5083)
        let operators = ["of", "din", "von", "de", "di", "の", "的", "의"]
        for _ in 0..<500 {
            let percent = random.next(-100, 101), amount = random.next(-10000, 10001)
            let source = "\(percent)% \(operators[random.next(operators.count)]) (\(amount))"
            let result = try SheetEvaluator.evaluate(source)[0]
            XCTAssertNil(result.error, source)
            XCTAssertEqual(try result.value?.scalar, try Rational(percent * amount, 100), source)
        }
    }
    func testInvalidLocalizedInputNeverPublishesANumber() throws {
        try theory(["2.675保留0位有效数字", "2.675を小数点以下-1桁", "2.675소수점257자리", "20% de typo", "150の間違い", "2.675を2桁", "2.675소수점2", "12.37 la cel mai apropiat multiplu de 0"]) { source in
            let result = try SheetEvaluator.evaluate(source)[0]
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
    func testUnspacedKeywordStreamsAndCancellationStayBounded() throws {
        XCTAssertNotNil(try SheetEvaluator.evaluate(String(repeating: "半分の", count: 5000) + "150")[0].error)
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("2.675を小数点以下2桁", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
    func testOnlyCompleteConversationalPhrasesChangeLeadingLabelHandling() throws {
        XCTAssertEqual(try SheetEvaluator.evaluate("das 10")[0].display, "10")
        XCTAssertEqual(try SheetEvaluator.evaluate("la 10")[0].display, "10")
        XCTAssertNotNil(try SheetEvaluator.evaluate("Budget das doppelte 10")[0].error)
        XCTAssertEqual(try SheetEvaluator.evaluate("\"Budget\" das doppelte 10")[0].display, "20")
    }
}
