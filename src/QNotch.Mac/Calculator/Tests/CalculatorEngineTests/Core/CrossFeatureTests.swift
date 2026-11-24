import XCTest
@testable import CalculatorEngine

/// Interactions between the formula, complex/constant/prime, practical helper and worksheet features. Each expectation is derived by hand.
final class CrossFeatureTests: XCTestCase {
    private func last(_ source: String) throws -> LineResult { try SheetEvaluator.evaluate(source).last! }
    private func display(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let result = try last(source); XCTAssertNil(result.error, source, file: file, line: line); return result.display
    }
    private func schema(_ bodies: String...) throws -> Int { try FunctionUpdate.prepare(bodies.joined(separator: "\n"), .empty, []).library.minimumCatalogVersion }

    func testUserVariablesShadowConstantsUnitsAndSentenceWords() throws {
        try theory([("i = 2\ni * 3", "6"), ("c = 3\nc + 1", "4"), ("i = 2\nsolve x * i = 6", "x = 3"), ("c = 3\nintegral(c * x, 0, 2)", "6"),
                    ("pace = 3\npace * 2", "6"), ("plot = 4\nplot + 1", "5")]) { source, expected in XCTAssertEqual(try display(source), expected, source) }
    }
    func testSolveReadsSheetVariables() throws {
        try theory([("k = 9\nsolve x^2 = k", "x = -3 or x = 3"), ("k = 5\nsolve 2x + k = 11", "x = 3")]) { source, expected in XCTAssertEqual(try display(source), expected, source) }
    }
    func testCalculusResultsComposeWithArithmetic() throws {
        try theory([("2 * integral(x^2, 0, 3) + 1", "19"), ("integral(x, 0, 2) * (1 + i)", "2 + 2i"), ("derivative(x^2, 3) - 6", "0")]) { source, expected in
            XCTAssertEqual(try display(source), expected, source)
        }
    }
    func testFigureTableAndNonScalarLinesNeverReachBlockTotals() throws {
        let source = "10\n20\nplot x^2\nbar chart of [1, 2]\n3 + 4i\nisprime(7)\nfactor(12)\nhr zones age 30\nsolve x = 1\nsum"
        let results = try SheetEvaluator.evaluate(source)
        for result in results { XCTAssertNil(result.error) }
        XCTAssertEqual(results.last!.display, "30")
        XCTAssertEqual(try last(source.netReplace("\nsum", "\naverage")).display, "15")
        XCTAssertEqual(try last("1\n2\npie chart\nsum").display, "3")
    }
    func testChartsReadTableColumnsAndRows() throws {
        let table = "item\tcost\nrent\t1200\nfood\t300\nfun\t100"
        let column = try last(table + "\n\nbar chart of column(table1, \"cost\")")
        XCTAssertNil(column.error); XCTAssertEqual(column.value?.kind, .chart)
        XCTAssertEqual(column.display, "1600")
        XCTAssertEqual(try display(table + "\n\nsum(column(table1, 2))"), "1600")
    }
    func testSavedFunctionsCarryComplexHelperAndWorksheetSyntax() throws {
        let update = try FunctionUpdate.prepare("sq(z) = z^2\nrest(w) = bmr w 180 cm 30 years male\nwave(a) = plot a * sin(x) from 0 to 6", .empty, [])
        let reloaded = try FunctionLibrary(update.library.definitions)
        XCTAssertEqual(reloaded.fingerprint, update.library.fingerprint)
        let results = try SheetEvaluationSession().evaluateWithFunctions("sq(1 + i)\nrest(80 kg)\nwave(2)", reloaded, []).results
        for result in results { XCTAssertNil(result.error) }
        XCTAssertEqual(results[0].display, "2i")
        XCTAssertEqual(results[1].display, "1780 kcal")
        XCTAssertEqual(results[2].value?.kind, .plot)
    }
    func testCatalogSchemaFourStaysForFormulaOnlyBodiesAndFiveCoversEveryNewSyntax() throws {
        XCTAssertEqual(FunctionLibrary.formulaCatalogVersion, 4); XCTAssertEqual(FunctionLibrary.latestCatalogVersion, 5)
        XCTAssertEqual(try schema("plain(v) = v + 1"), 1)
        XCTAssertEqual(try schema("area(b) = integral(x^2, 0, b)"), 4)
        XCTAssertEqual(try schema("roots(c) = solve x^2 = c"), 4)
        XCTAssertEqual(try schema("circle(r) = pi * r^2"), 4)
        XCTAssertEqual(try schema("energy(m) = m * c^2"), 5)
        XCTAssertEqual(try schema("rot(z) = z * i"), 5)
        XCTAssertEqual(try schema("next(n) = nextprime(n)"), 5)
        XCTAssertEqual(try schema("rest(w) = bmr w 180 cm 30 years male"), 5)
        XCTAssertEqual(try schema("eco(v) = v in l/100km"), 5)
        XCTAssertEqual(try schema("wave(a) = plot a * sin(x) from 0 to 6"), 5)
        XCTAssertEqual(try schema("bars(v) = bar chart of v"), 5)
        XCTAssertEqual(try schema("first(t) = column(t, 1)"), 5)
        XCTAssertEqual(try schema("area(b) = integral(x^2, 0, b)", "rot(z) = z * i"), 5)
    }
    func testProseStaysProse() throws {
        try theory(["plot twist", "i think so", "bar chart monthly", "paint the fence"]) { source in
            let result = try last(source); XCTAssertNil(result.error, source); XCTAssertEqual(result.display, "", source)
        }
    }
}
