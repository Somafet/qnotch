import XCTest
@testable import CalculatorEngine

final class LanguageTests: XCTestCase {
    func testExactCases() throws {
        try theory([("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-3", "0.125"), ("5! + 0!", "121"), ("sqrt(81/16)", "2.25"), ("15%", "15%"),
                    ("150 + 20%", "180"), ("150 - 10%", "135"), ("20% of 150", "30"), ("50 is what % of 200", "25%"), ("30 is 15% of what", "200"),
                    ("120 is 20% off what", "150"), ("change(80,100)", "25%"), ("change(100,80)", "-20%"), ("margin(80,100)", "20%"), ("markup(80,100)", "25%"),
                    ("10% + 5%", "15%"), ("12%/3", "4%"), ("100 + (10% * 2)", "100.2"), ("\"Lunch = // #no\" 12.50 + 2.50 #food", "15"), ("Rent 1200 #home", "1200")]) { source, expected in
            let result = try evaluate(source)[0]
            XCTAssertNil(result.error, source); XCTAssertEqual(result.display, expected, source)
            XCTAssertFalse(result.explanation.isEmpty, source)
        }
    }
    func testPercentageVariablesRemainTyped() throws {
        let result = try evaluate("price = 1200\ndiscount = 15%\nprice - discount\nL3 * 2\nprev / 4")
        XCTAssertEqual(result.map(\.display), ["1200", "15%", "1020", "2040", "510"])
        XCTAssertTrue(result[1].value!.isPercentage)
        XCTAssertTrue(result[2].explanation.contains { $0.assumption?.contains("relative") == true })
    }
    func testMultiwordForwardAndReassignedVariables() throws {
        let result = try evaluate("total cost = unit price * 3\nunit price = 7\nunit price = unit price + 1\ntotal cost + unit price")
        XCTAssertEqual(result.map(\.display), ["21", "7", "8", "29"])
        XCTAssertEqual(result[0].dependencies, [1])
    }
    func testMultiwordVariablesCanContainOperatorWords() throws {
        let results = try evaluate("cost of goods=80\nthis is price=100\nthis is price - cost of goods\n20% of cost of goods")
        XCTAssertEqual(results.map(\.display), ["80", "100", "20", "16"])
    }
    func testForwardLineReferencesAndCycles() throws {
        let result = try evaluate("L3 + 1\nL1 * 2\n5\nL5\nL4\nL4 + 1")
        XCTAssertEqual(result[0].display, "6"); XCTAssertEqual(result[1].display, "12")
        for r in result.dropFirst(3) { XCTAssertEqual(r.error, "Circular dependency") }
        XCTAssertEqual(try evaluate("a = a + 1")[0].error, "Circular dependency")
        XCTAssertEqual(try evaluate("# Heading\nprev+1")[1].error, "Dependency L1 unavailable")
    }
    func testBlocksAndWholeSheetTagTotalsExcludeAggregateResults() throws {
        let result = try evaluate("Rent 1200 #home\nInternet 40 #home\nsum\naverage\n\n# Travel\nTrip 600 #travel\nsum #home\nDinner 60 #home\nsum #home")
        XCTAssertEqual(result[2].display, "1240"); XCTAssertEqual(result[3].display, "620")
        XCTAssertEqual(result[7].display, "1300"); XCTAssertEqual(result[9].display, "1300")
        XCTAssertEqual(result[7].dependencies, [0, 1, 8])
    }
    func testProseAndCommentsAreBlankButMisspelledOperandsAreErrors() throws {
        let result = try evaluate("Budget notes\n# Week\n\"comment only\"\na = 2\na 3\nmisspelled + 3\n// comment")
        for r in result.prefix(3) { XCTAssertNil(r.value); XCTAssertNil(r.error) }
        XCTAssertNotNil(result[4].error); XCTAssertNotNil(result[5].error); XCTAssertNil(result[6].error)
    }
    func testDomainAndSyntaxFailuresAreExplicit() throws {
        try theory(["sqrt(-1 m^2)", "2^(1/3)", "2^2048", "(-1)!", "501!", "1/0", "120 is 100% off what", "share(1,0)", "prev", "L0", "\"unclosed", "sum #one #two"]) { source in
            XCTAssertNotNil(try evaluate(source)[0].error, source)
        }
    }
    func testDeepDependencyChainsDoNotUseCallStack() throws {
        let source = "1\n" + Array(repeating: "prev+1", count: 9999).joined(separator: "\n")
        XCTAssertEqual(try evaluate(source).last!.display, "10000")
    }
    func testTotalsDoNotSilentlyExcludeMalformedCalculations() throws {
        let results = try evaluate("10 #cost\n2+ #cost\nsum #cost\nsum")
        XCTAssertEqual(results[2].error, "Dependency L2 unavailable")
        XCTAssertEqual(results[3].error, "Dependency L2 unavailable")
    }
    func testDefaultRationalIsCanonicalZero() throws {
        XCTAssertEqual(Rational.zero, try Rational(0, 1))
        XCTAssertEqual(Rational.zero.description, "0")
    }
    func testLongLabelsAndIdentifierErrorsStayBounded() throws {
        let label = Array(repeating: "word", count: 2000).joined(separator: " ")
        XCTAssertEqual(try evaluate(label + " 2")[0].display, "2")
        XCTAssertEqual(try evaluate(label + "+2")[0].error, "Identifier limit exceeded")
        XCTAssertThrowsError(try Rational.parse("1.2.3")) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
    }
    func testParserFuzzAndAggregateExpansionAreBounded() throws {
        var random = NetRandom(719)
        let alphabet = Array("0123ab +-*^!%()/\"#=_.,")
        for _ in 0..<500 {
            let length = random.next(1, 120)
            let source = String((0..<length).map { _ in alphabet[random.next(alphabet.count)] })
            let result = try evaluate(source)[0]
            XCTAssertLessThanOrEqual(result.explanation.count, 64)
            XCTAssertLessThanOrEqual(result.display.netLength, 2048)
        }
        let many = try evaluate((Array(repeating: "1 #x", count: 1000) + Array(repeating: "sum #x", count: 1000)).joined(separator: "\n"))
        XCTAssertTrue(many.contains { $0.error == "Sheet dependency limit exceeded" })
    }
}
