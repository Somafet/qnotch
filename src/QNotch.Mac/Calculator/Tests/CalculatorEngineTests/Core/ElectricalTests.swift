import XCTest
@testable import CalculatorEngine

final class ElectricalTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let result = try SheetEvaluator.evaluate(source).last!; XCTAssertNil(result.error, source, file: file, line: line); return result
    }
    private func value(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> SheetValue {
        guard let value = try last(source, file: file, line: line).value else { throw CalcError.format("no value for " + source) }
        return value
    }

    func testIndependentManufacturerTableAndNetworkOracle() throws {
        let cases = try JSONNode.parse(Fixtures.data("electrical-v1.json")).property("cases").arrayItems()
        try theory(cases) { row in
            let source = try row.property("source").string()
            let value = try self.value(source)
            if try row.property("kind").string() == "parallel" {
                XCTAssertEqual(try fraction(try row.property("ohms").string()), try value.number.exact.rational, source)
                XCTAssertEqual(try row.property("unitful").bool(), try value.number.unit != nil, source)
            } else {
                XCTAssertEqual(value.kind, .resistor, source); let resistor = try value.resistor
                XCTAssertEqual(try fraction(try row.property("ohms").string()), resistor.nominalOhms, source)
                XCTAssertEqual(try fraction(try row.property("tolerance").string()), resistor.tolerance, source)
                XCTAssertEqual(try fraction(try row.property("minimum").string()), try resistor.minimumOhms, source)
                XCTAssertEqual(try fraction(try row.property("maximum").string()), try resistor.maximumOhms, source)
                XCTAssertEqual(try row.property("digits").int(), resistor.significantDigits, source)
                XCTAssertEqual(try row.property("colors").bool(), resistor.showColors, source)
                XCTAssertEqual(try row.property("bands").arrayItems().map { try $0.string() }, resistor.bands, source)
                XCTAssertEqual(resistor.nominalOhms, try self.value(try value.copyText).resistor.nominalOhms, source)
                XCTAssertEqual(resistor.tolerance, try self.value(try value.copyText).resistor.tolerance, source)
            }
        }
    }
    func testPublishedSyntaxAndNominalCompositions() throws {
        try theory([
            ("12 V / 4 ohm", "3 A"), ("12 V * 2 A", "24 W"), ("2 A * 4 ohm", "8 V"), ("12 V / 2 A", "6 ohm"), ("10k || 4.7k", "3197.2789"),
            ("100 ohm || 100 ohm || 100 ohm", "33.3333 ohm"), ("1 kohm || 1000 ohm", "0.5 kohm"), ("parallel([100,200,300])", "54.5455"), ("parallel(5)", "5"),
            ("0 ohm || 100 ohm", "0 ohm"), ("10+10||10", "15"), ("10||10*2", "6.6667"), ("(10+10)||10", "6.6667"), ("brown black red gold", "1 kohm ±5%"),
            ("red orange violet black brown", "237 ohm ±1%"), ("green blue yellow gold", "560 kohm ±5%"), ("brown black silver silver", "0.1 ohm ±10%"),
            ("BROWN BLACK RED GOLD", "1 kohm ±5%"), ("grey red brown gold", "820 ohm ±5%"), ("brown black red", "1 kohm ±20%"), ("4.7k in colors", "yellow violet red"),
            ("4700 ohm to colours", "yellow violet red"), ("resistorColors(123 ohm,1%)", "brown red orange black brown"), ("resistor(1000,5,3)", "1 kohm ±5%"),
            ("resistor(1000,5%) in colors", "brown black red gold"), ("r=brown black red gold\nr in ohm", "1000 ohm"), ("r=brown black red gold\n12 V/r", "0.012 A"),
            ("r=brown black red gold\nr+r", "2 kohm"), ("r=brown black red gold\nparallel(r,r)", "0.5 kohm"), ("r=brown black red gold\nmean([r,r])", "1 kohm"),
            ("f(x)=x||x\nf(100 ohm)", "50 ohm"), ("f()=brown black red gold\nf()", "1 kohm ±5%"), ("brown black red gold=7\nbrown black red gold+4", "11"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testAmbiguousMarkingsUnsupportedProfilesAndInvalidNetworksFail() throws {
        try theory([
            "black black red gold", "gold black red gold", "brown silver red gold", "brown black red black", "brown black red orange", "brown black red white",
            "brown black black red brown blue", "resistor(0)", "resistor(-1)", "resistor(1.2345 ohm,5%)", "resistorColors(123 ohm)", "resistor(100 ohm,3%)",
            "resistor(100 ohm,0%)", "resistor(100 ohm,20%,3)", "resistor(100 ohm,5%,4)", "resistor(100 ohm,5%,2%)", "resistor(1 m)", "resistor(1 USD)",
            "resistor(100%)", "resistor(sqrt(2) ohm)", "resistor(100 ohm,5 ohm)", "parallel()", "parallel([])", "parallel(-1,0)", "parallel(0,-1)",
            "1 m||2 m", "1 ohm||2", "1%||2%", "today||2", "1 USD||2 USD", "1|||2", "resistorColors()",
        ]) { source in XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source) }
    }
    func testNominalUseNeverImpliesTolerancePropagation() throws {
        for operation in ["r+r", "12 V/r", "parallel(r,r)", "mean([r,r])", "r in ohm", "r to nearest 10 ohm", "-r", "double r"] {
            let result = try last("r=brown black red gold\n" + operation)
            XCTAssertTrue(result.explanation.contains { $0.assumption?.contains("tolerance intervals are not propagated") == true }, operation)
        }
        let mark = try last("brown black red gold")
        XCTAssertTrue(mark.explanation.contains { $0.assumption?.contains("950–1050 ohm") == true })
        XCTAssertTrue(mark.explanation.contains { $0.assumption?.contains(ResistorColorCatalog.ruleId) == true })
    }
    func testMarkingsAndCopiesAreImmutableTypedAndComplete() throws {
        let resistor = try value("resistor(237 ohm,1%,3)").resistor
        // C# checks that Bands is a read-only list. A Swift array is a value: writing to a copy leaves the marking unchanged.
        var bands = resistor.bands; bands[0] = "white"
        XCTAssertEqual(resistor.bands[0], "red")
        XCTAssertEqual(resistor, try value(try SheetValue.resistor(resistor).copyText).resistor)
        XCTAssertNotEqual(resistor, try value("resistor(237 ohm,2%,3)").resistor)
        XCTAssertEqual(ResistorColorCatalog.colors.count, 12)
        XCTAssertEqual(ResistorColorCatalog.colors.compactMap(\.digit), Array(0..<10))
        XCTAssertEqual(ResistorColorCatalog.colors.map(\.multiplierExponent).sorted(), Array(-2..<10))
    }
    func testIndependentCircuitIdentitiesRetainExactUnderlyingValues() throws {
        var random = NetRandom(90926)
        for _ in 0..<100 {
            let a = random.next(1, 10000), b = random.next(1, 10000), c = random.next(1, 10000)
            let setup = "a=\(a)\nb=\(b)\nc=\(c)\n"
            XCTAssertEqual(try last(setup + "(a||b)-(b||a)").display, "0")
            XCTAssertEqual(try last(setup + "((a||b)||c)-(a||(b||c))").display, "0")
            XCTAssertEqual(try last(setup + "(2*a||2*b)-2*(a||b)").display, "0")
            XCTAssertEqual(try Rational(a, 2), try value(setup + "a||a").exact.rational)
            let network = try value(setup + "a||b").exact.rational
            XCTAssertTrue(network.sign > 0); XCTAssertTrue(try (Rational(min(a, b)) - network).sign > 0)
        }
        XCTAssertEqual(try Rational(470000, 147), try value("10k||4.7k").scalar)
    }
    func testShapeCancellationAndSharedBudgetsBoundNetworks() throws {
        let branches = "[" + Array(repeating: "1", count: 1024).joined(separator: ",") + "]"
        XCTAssertEqual(try Rational(1, 1024), try value("parallel(" + branches + ")").scalar)
        let source = "r=" + branches + "\n" + Array(repeating: "parallel(r)", count: 150).joined(separator: "\n")
        XCTAssertThrowsError(try SheetEvaluator.evaluate(source)) { XCTAssertEqual($0 as? CalcError, .computationLimit) }
        XCTAssertNotNil(try SheetEvaluator.evaluate("parallel([" + Array(repeating: "1", count: 1025).joined(separator: ",") + "])")[0].error)
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("parallel(" + branches + ")", cancelled)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertEqual(try last("parallel(0,1/(10^1000),1/(10^999+1),1/(10^998+3))").display, "0")
        XCTAssertNotNil(try SheetEvaluator.evaluate("parallel(0,1/(10^1000),-1)")[0].error)
    }
    func testSavedFunctionsCacheDependenciesAndContextsStayStatic() throws {
        let library = try FunctionLibrary([FunctionDefinition(name: "divider", parameters: ["a", "b"], body: "a||b"), FunctionDefinition(name: "mark", parameters: ["x"], body: "resistorColors(x,1%,3)")])
        let session = SheetEvaluationSession(); let source = "r=100 ohm\ns=r||r\ns\n7"
        _ = try session.evaluateWithFunctions(source, library, [])
        let changed = try session.evaluateWithFunctions(source.netReplace("100", "200"), library, [])
        XCTAssertEqual(changed.results[2].display, "100 ohm"); XCTAssertEqual(session.lastStatistics.parsedLines, 1); XCTAssertEqual(session.lastStatistics.reusedResults, 1)
        let again = try session.evaluateWithFunctions(source.netReplace("100", "200"), library, [], context: EvaluationContext(today: DateOnly(2040, 1, 1)!, now: Practical.now))
        XCTAssertEqual(session.lastStatistics.reusedResults, 4); XCTAssertFalse(again.usesCurrentDate); XCTAssertFalse(again.usesCurrentInstant); XCTAssertFalse(again.usesCurrencyRates)
        XCTAssertEqual(try session.evaluateWithFunctions("divider(100 ohm,100 ohm)", library, []).results[0].display, "50 ohm")
        XCTAssertEqual(try session.evaluateWithFunctions("mark(123 ohm)", library, []).results[0].display, "brown red orange black brown")
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "parallel", parameters: ["x"], body: "x")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "wrong", parameters: ["x"], body: "resistor(x,1,2,3)")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
        for result in try SheetEvaluator.evaluate("a=b||1\nb=a||1") { XCTAssertEqual(result.error, "Circular dependency") }
    }
    func testApproximateNetworksKeepTheirProvenanceAndCannotInventColorCodes() throws {
        let setup = "x=-fv(1%/12,1200,0,1)\n"
        let result = try last(setup + "x||1"); XCTAssertTrue(try result.value?.number.isApproximate == true)
        XCTAssertTrue(result.explanation.contains { $0.assumption?.contains("Approximate") == true })
        XCTAssertNotNil(try SheetEvaluator.evaluate(setup + "resistorColors(x)").last!.error)
    }
}
