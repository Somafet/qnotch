import XCTest
@testable import CalculatorEngine

final class ChemistryPracticalTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let result = try SheetEvaluator.evaluate(source).last!
        XCTAssertNil(result.error, source, file: file, line: line); XCTAssertNotNil(result.value, source, file: file, line: line); return result
    }
    private func value(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> SheetValue {
        guard let value = try last(source, file: file, line: line).value else { throw CalcError.format("no value for " + source) }
        return value
    }
    /// C# Assert.Single(explanation, step => step.Chemistry is not null).Chemistry.
    private func evidence(_ result: LineResult, file: StaticString = #filePath, line: UInt = #line) throws -> ChemistryEvidence {
        let steps = result.explanation.compactMap(\.chemistry)
        XCTAssertEqual(steps.count, 1, file: file, line: line)
        return try XCTUnwrap(steps.first, file: file, line: line)
    }

    func testIndependentCompositionFractionAndDecimalOracle() throws {
        let cases = try JSONNode.parse(Fixtures.data("chemistry-practical-v1.json")).property("cases").arrayItems()
        try theory(cases) { row in
            let source = try row.property("source").string()
            let result = try last(source); let value = try XCTUnwrap(result.value, source)
            let expected = try fraction(try row.property("canonical").string())
            switch try row.property("kind").string() {
            case "chemistry":
                XCTAssertEqual(expected, try value.exact.rational, source); XCTAssertTrue(try value.number.isApproximate, source)
                let e = try evidence(result)
                XCTAssertEqual(try fraction(try row.property("gramsPerMole").string()), e.nominalGramsPerMole, source)
                let expectedComposition = try row.property("composition").objectProperties().map { ($0.0, try $0.1.int()) }.sorted { String.ordinalCompare($0.0, $1.0) < 0 }
                let actualComposition = e.composition.sorted { String.ordinalCompare($0.symbol, $1.symbol) < 0 }.map { ($0.symbol, $0.atoms) }
                XCTAssertEqual(expectedComposition.map(\.0), actualComposition.map(\.0), source); XCTAssertEqual(expectedComposition.map(\.1), actualComposition.map(\.1), source)
            case "grades":
                XCTAssertEqual(expected, try value.scalar, source); XCTAssertEqual(try row.property("percent").bool(), value.isPercentage, source)
            default:
                XCTAssertEqual(expected, try value.engineering.original.exact.rational, source); XCTAssertEqual(try row.property("display").string(), try value.display, source)
                XCTAssertEqual(try value.engineering.original.exact, try self.value(try value.copyText).engineering.original.exact, source)
            }
        }
    }
    func testPublishedAndTypedExamples() throws {
        try theory([
            ("molar mass H2SO4", "≈ 98.072 g/mol"), ("molar mass Ca(OH)2", "≈ 74.092 g/mol"), ("10 g H2O in mol", "≈ 0.5551 mol"), ("2 mol NaCl in g", "≈ 116.88 g"),
            ("moles(10 g,H2O)", "≈ 0.5551 mol"), ("massOf(2 mol,NaCl)", "≈ 116.88 g"), ("molarMass(CuSO4·5H2O)", "≈ 249.677 g/mol"), ("molarMass(CuSO4.5H2O)", "≈ 249.677 g/mol"),
            ("molar mass H₂O", "≈ 18.015 g/mol"), ("molar mass K4[Fe(CN)6]", "≈ 368.345 g/mol"), ("molar mass Co", "≈ 58.933 g/mol"), ("molar mass CO", "≈ 28.01 g/mol"),
            ("molarMass(Zr)", "≈ 91.222 g/mol"), ("2 mol NaCl in kg", "≈ 0.1169 kg"), ("grades 9 x3, 7 x2", "8.2"), ("grades (8+1) x 3, 7 x 2", "8.2"),
            ("weightedMean([90%,80%],[30%,70%])", "83%"), ("grades 9 x0, 7 x2", "7"), ("12345 in eng", "12.345 × 10³"), ("4700 ohm in eng", "4.7 kohm"),
            ("0.000012345 in eng", "12.345 × 10⁻⁶"), ("engineering(-999999.5)", "-1 × 10⁶"), ("engineering(0)", "0"), ("engineering(1/3)", "333.333 × 10⁻³"),
            ("engineering(sqrt(2))", "1.41421"), ("x=123456789 in eng\nx-123456789", "0"), ("1\n2\nsum in eng", "3"), ("molarMass=4\nmolarMass(H2O)", "≈ 18.015 g/mol"),
            ("principal=1200 in eng\nloan principal at 0% for 1 year", "100"), ("places=2 in eng\n12.345 to places decimals", "12.35"), ("f(x)=moles(x,H2O)\nf(10 g)", "≈ 0.5551 mol"),
            ("f(x)=weightedMean(x,[3,2])\nf([9,7])", "8.2"),
        ]) { source, expected in XCTAssertEqual(try last(source).display, expected, source) }
    }
    func testInvalidProfilesAndAmbiguousInputsFail() throws {
        try theory([
            "molar mass h2o", "molar mass Xx2", "molar mass Tc", "molarMass(Fe0)", "molarMass(Ca())", "molarMass(Ca(OH]2)", "molarMass(H2O·)",
            "molarMass(H2O+)", "molarMass([13]C)", "molarMass(D2O)", "molarMass(H1000001)", "molarMass((H1000)1001)", "molarMass(H500001O500000)",
            "moles(10,H2O)", "moles(-1 g,H2O)", "moles(10 USD,H2O)", "moles(1 m,H2O)", "molarMass()", "molarMass(H2O,2)",
            "weightedMean([],[])", "weightedMean([1],[1,2])", "weightedMean([1,2],[0,0])", "weightedMean([1,2],[1,-1])", "weightedMean([1,2],[1%,1])", "weightedMean([1%,2],[1,1])",
            "weightedMean([1 m],[1])", "weightedMean([1],[1 m])", "grades 9 x-1, 7 x2", "engineering(2 USD)", "engineering(20 °C)", "engineering(1,2)", "engineering(1,1%)",
        ]) { source in XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source) }
    }
    func testCatalogCoversEveryElementAndNeverSubstitutesIsotopeMassNumbers() throws {
        XCTAssertEqual(AtomicWeightCatalog.elements.count, 118); XCTAssertEqual(AtomicWeightCatalog.elements.filter { $0.weight != nil }.count, 84)
        for e in AtomicWeightCatalog.elements where e.weight == nil {
            XCTAssertTrue(try SheetEvaluator.evaluate("molarMass(" + e.symbol + ")")[0].error!.contains("unavailable"), e.symbol)
        }
        let evidence = try evidence(try last("molar mass H2O"))
        XCTAssertEqual(AtomicWeightCatalog.ruleId, evidence.ruleId)
        XCTAssertEqual(try Rational(1, 5000), evidence.composition.filter { $0.symbol == "H" }.first?.quotedUncertainty)
        XCTAssertEqual(evidence.composition.filter { $0.symbol == "H" }.count, 1)
        // C# checks that Composition is a read-only list. The Swift evidence is a value: changing a copy leaves the recorded step unchanged.
        var composition = evidence.composition; composition[0] = composition[1]
        XCTAssertEqual(try self.evidence(try last("molar mass H2O")).composition, evidence.composition)
        XCTAssertNotEqual(composition, evidence.composition)
    }
    func testEngineeringCopyPreservesExactRadicalsApproximationAndLargeLiterals() throws {
        for input in ["1/3", "sqrt(2)+sqrt(3)", "-123456789/7", "10^1000", "1/(10^1000)", "12345 m", "80%"] {
            let value = try self.value("engineering(" + input + ")"); let copy = try self.value(try value.copyText)
            XCTAssertEqual(try value.engineering.original.exact, try copy.engineering.original.exact, input); XCTAssertEqual(try value.display, try copy.display, input)
        }
        let approximate = try value("engineering(1/3,1)")
        XCTAssertTrue(try value(try approximate.copyText).engineering.original.isApproximate)
        XCTAssertEqual(try last(try approximate.copyText + "*2").display, "≈ 2/3") // retained original 1/3, ordinary arithmetic returns exact represented 2/3
    }
    func testChemicalConversionsAndFormulaExpansionHaveIndependentConservationIdentities() throws {
        for formula in ["H2O", "NaCl", "Ca(OH)2", "K4[Fe(CN)6]", "CuSO4·5H2O"] {
            let a = try value("massOf(moles(123 g," + formula + ")," + formula + ")")
            XCTAssertEqual(try Rational(123, 1000), try a.exact.rational, formula); XCTAssertTrue(try a.number.isApproximate, formula)
        }
        XCTAssertEqual(try value("molarMass(Ca(OH)2)").exact, try value("molarMass(CaO2H2)").exact)
        XCTAssertEqual(try value("molarMass(CuSO4·5H2O)").exact, try value("molarMass(CuSO9H10)").exact)
    }
    func testContextCachesFunctionsAndNameCollisionsStayDeterministic() throws {
        let s = SheetEvaluationSession(); let source = "x=10 g\nmoles(x,H2O)\n12345 in eng\n7"
        _ = try s.evaluateWithFunctions(source, .empty, []); let changed = try s.evaluateWithFunctions(source.netReplace("10 g", "20 g"), .empty, [])
        XCTAssertEqual(changed.results[1].display, "≈ 1.1102 mol"); XCTAssertEqual(s.lastStatistics.parsedLines, 1); XCTAssertEqual(s.lastStatistics.reusedResults, 2)
        let again = try s.evaluateWithFunctions(source.netReplace("10 g", "20 g"), .empty, [], context: EvaluationContext(today: DateOnly(2040, 1, 1)!, now: Practical.now))
        XCTAssertEqual(s.lastStatistics.reusedResults, 4); XCTAssertFalse(again.usesCurrentDate); XCTAssertFalse(again.usesCurrentInstant); XCTAssertFalse(again.usesCurrencyRates)
        let library = try FunctionLibrary([FunctionDefinition(name: "water", parameters: ["x"], body: "moles(x,H2O)"), FunctionDefinition(name: "displayEng", parameters: ["x"], body: "x in eng")])
        XCTAssertEqual(try s.evaluateWithFunctions("water(10 g)", library, []).results[0].display, "≈ 0.5551 mol")
        XCTAssertEqual(try s.evaluateWithFunctions("displayEng(12345)", library, []).results[0].display, "12.345 × 10³")
        XCTAssertEqual(try last("grades=4\ngrades").display, "4"); XCTAssertEqual(try last("molar mass=4\nmolar mass").display, "4")
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "weightedMean", parameters: ["x"], body: "x")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
    }
    func testDepthSizeCancellationAndSharedResourceBoundsAreEnforced() throws {
        XCTAssertNotNil(try SheetEvaluator.evaluate("molarMass(" + String(repeating: "(", count: 17) + "H" + String(repeating: ")", count: 17) + ")")[0].error)
        XCTAssertNotNil(try SheetEvaluator.evaluate("molarMass(" + String(repeating: "H", count: 513) + ")")[0].error)
        let values = "[" + Array(repeating: "1", count: 1024).joined(separator: ",") + "]"
        XCTAssertEqual(try last("x=" + values + "\nweightedMean(x,x)").display, "1")
        XCTAssertThrowsError(try SheetEvaluator.evaluate("x=" + values + "\n" + Array(repeating: "weightedMean(x,x)", count: 150).joined(separator: "\n"))) {
            XCTAssertEqual($0 as? CalcError, .computationLimit)
        }
        let c = CancellationToken(); c.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("molarMass(CuSO4·5H2O)", c)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
    func testChemicalCaseEditsInvalidateFunctionReceiptsAndCachedResults() throws {
        let session = SheetEvaluationSession()
        let initial = try session.evaluateWithFunctions("compound()=molarMass(Co)\ncompound()", .empty, [])
        XCTAssertEqual(initial.results[1].display, "≈ 58.933 g/mol")
        let changed = try session.evaluateWithFunctions("compound()=molarMass(CO)\ncompound()", initial.functions.library, initial.functions.receipts)
        XCTAssertTrue(changed.functions.hasChanges); XCTAssertNotEqual(initial.functions.library.fingerprint, changed.functions.library.fingerprint)
        XCTAssertEqual(changed.results[1].display, "≈ 28.01 g/mol")
        let restored = try session.evaluateWithFunctions("compound()=molarMass(Co)\ncompound()", changed.functions.library, changed.functions.receipts)
        XCTAssertEqual(restored.results[1].display, "≈ 58.933 g/mol")
    }
    func testPrimitiveDispatchKeepsTheDocumentedFunctionDepthInsteadOfOverflowingTheStack() throws {
        let definitions = (0..<33).map { FunctionDefinition(name: "depth\($0)", parameters: ["x"], body: $0 == 0 ? "x" : "depth\($0 - 1)(x)") }
        let library = try FunctionLibrary(Array(definitions.prefix(32))); let session = SheetEvaluationSession()
        XCTAssertEqual(try session.evaluateWithFunctions("depth31(1)", library, []).results[0].display, "1")
        XCTAssertThrowsError(try FunctionLibrary(definitions)) { error in
            XCTAssertTrue((error as? CalcError)?.isArithmetic == true); XCTAssertTrue((error as? CalcError)?.message.contains("depth limit") == true)
        }
    }
    func testDatedNestedFunctionConversionsUseSmallDispatchFramesAndTheSameContext() throws {
        let definitions = (0..<25).map { FunctionDefinition(name: "dated\($0)", parameters: ["x"], body: $0 == 0 ? "x USD in USD on 2024-01-01" : "dated\($0 - 1)(x) in USD on 2024-01-01") }
        let result = try SheetEvaluationSession().evaluateWithFunctions("dated24(1)", try FunctionLibrary(definitions), [], context: EvaluationContext(today: DateOnly(2026, 10, 31)!))
        XCTAssertEqual(result.results[0].display, "1 USD"); XCTAssertFalse(result.usesCurrencyRates)
    }
}
