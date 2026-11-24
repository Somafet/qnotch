import XCTest
@testable import CalculatorEngine

final class UnitTests: XCTestCase {
    func testIndependentlyDefinedExactFixtures() throws {
        let cases = try JSONNode.parse(Fixtures.data("units-v1.json")).property("cases").arrayItems()
        try theory(cases) { item in
            let source = try item.property("source").string(), expected = try item.property("expected").string()
            let results = try SheetEvaluator.evaluate(source)
            for result in results { XCTAssertNil(result.error, source) }
            XCTAssertEqual(results.last!.display, expected, source)
            let pasted = try SheetEvaluator.evaluate(results.last!.display)[0]
            XCTAssertNil(pasted.error, source); XCTAssertEqual(pasted.value, results.last!.value, source)
        }
    }
    func testEveryCatalogEntryParsesAndRoundTripsWithItsDeclaredDimension() throws {
        XCTAssertEqual(NumericValue(), NumericValue(Rational.zero))
        XCTAssertEqual(UnitCatalog.units.count, 219)
        XCTAssertEqual(Set(UnitCatalog.units.map(\.id)).count, 219)
        for unit in UnitCatalog.units {
            XCTAssertTrue(unit.source.hasPrefix("https://"))
            let result = try SheetEvaluator.evaluate("1 " + unit.symbol)[0]
            XCTAssertNil(result.error, unit.symbol)
            let value = try XCTUnwrap(result.value, unit.symbol)
            XCTAssertEqual(try value.unit?.dimension, unit.dimension, unit.symbol)
            XCTAssertEqual(try value.exact.rational, try unit.factor + unit.offset, unit.symbol)
            XCTAssertEqual(try SheetEvaluator.evaluate(result.display)[0].value, value, unit.symbol)
            XCTAssertThrowsError(try value.scalar)
        }
    }
    func testSymbolsKeepCaseAndFunctionReceiptsCannotReuseADifferentUnit() throws {
        let first = try FunctionUpdate.prepare("f()=2 mV", .empty, [])
        let changed = try SheetEvaluationSession().evaluateWithFunctions("f()=2 MV\nf() in V", first.library, first.receipts)
        XCTAssertTrue(changed.functions.hasChanges); XCTAssertEqual(changed.results[1].display, "2000000 V")
        let byteFunction = try FunctionUpdate.prepare("g()=2 B", .empty, [])
        XCTAssertFalse(try FunctionUpdate.prepare("G()=2 bytes", byteFunction.library, byteFunction.receipts).hasChanges)
        let parameter = try FunctionUpdate.prepare("f(m)=m+1", .empty, [])
        XCTAssertFalse(try FunctionUpdate.prepare("F(M)=M+1", parameter.library, parameter.receipts).hasChanges)
        XCTAssertEqual(try SheetEvaluator.evaluate("m(x)=x+1\nm(2)")[1].display, "3")
    }
    func testNamesStayNamesAndConversionTargetsUseTheirUnitRole() throws {
        let result = try SheetEvaluator.evaluate("m=7\n2*m\n2 metres\n2 ft in m\n2m")
        XCTAssertEqual(result[1].display, "14"); XCTAssertEqual(result[2].display, "2 m"); XCTAssertEqual(result[3].display, "0.6096 m")
        XCTAssertNotNil(result[4].error)
    }
    func testSeededIndependentLengthAndAreaDefinitionsHold() throws {
        var random = NetRandom(3011)
        for _ in 0..<300 {
            let feet = random.next(-10000, 10001), inches = random.next(0, 12)
            let answer = try SheetEvaluator.evaluate("(\(feet) ft + \(inches) in) in m")[0]
            XCTAssertNil(answer.error)
            XCTAssertEqual(try answer.value?.exact.rational, try Rational(feet * 3048 + inches * 254, 10000))
            let square = try SheetEvaluator.evaluate("(\(feet) ft)^2 in m^2")[0]
            XCTAssertNil(square.error); XCTAssertEqual(try square.value?.exact.rational, try Rational(feet * feet * 145161, 1562500))
        }
    }
    func testSeededAffineConversionsAndDifferencesUseIndependentEquations() throws {
        for c in stride(from: -273, through: 300, by: 3) {
            let value = try SheetEvaluator.evaluate("\(c) °C in °F")[0]
            XCTAssertNil(value.error)
            XCTAssertEqual(value.display, "\(try Rational(c * 9, 5) + Rational(32)) °F")
            XCTAssertEqual(try SheetEvaluator.evaluate(value.display + " in °C")[0].display, "\(c) °C")
        }
        XCTAssertEqual(try SheetEvaluator.evaluate("30 °C - 68 °F")[0].display, "10 deltaC")
    }
    func testUnitMetadataInvalidatesDependentAndAggregateCaches() throws {
        let session = SheetEvaluationSession(); _ = try session.evaluate("x=1 m\nx in cm\n2 m #x\nx #x\nsum #x")
        let changed = try session.evaluate("x=1 ft\nx in cm\n2 m #x\nx #x\nsum #x")
        XCTAssertEqual(changed[1].display, "30.48 cm"); XCTAssertEqual(changed[4].display, "2.3048 m")
        XCTAssertGreaterThan(session.lastStatistics.reusedResults, 0)
        XCTAssertTrue(changed[1].explanation.contains { $0.operation == "convert unit" && $0.assumption!.contains("dimensions checked") })
        let failed = try session.evaluate("x=1 s\nx in cm\n2 m #x\nx #x\nsum #x")
        XCTAssertNil(failed[1].value); XCTAssertNil(failed[4].value)
    }
    func testInvalidDomainsNeverLoseTheirUnits() throws {
        try theory(["1 m + 1 s", "1 m in kg", "1 in nonsense", "sqrt(1 m)", "1 m^17", "1 m^1.5", "1 m^(", "1 m%", "1% m", "1 m!", "1 m to nearest 1", "1 m to nearest 1 s",
                    "1 m to 1 m decimals", "20 °C + 10 °C", "2 * 10 °C", "10 K / 2", "-1 K", "-274 °C", "1 °C/s", "1 °C in deltaC", "10 deltaC - 10 °C",
                    "1 °C #t\n2 °C #t\nsum #t", "1 m #t\n2 s #t\nsum #t", "1 m 2 s", "1 mb", "1 rad", "1 Gy in Sv", "1 Gy + 1 Sv", "(1 Gy in J/kg) in Sv", "1 Hz in Bq",
                    "1 J/kg #x\n1 Gy #x\n1 Sv #x\nsum #x"]) { source in
            let result = try SheetEvaluator.evaluate(source).last!
            XCTAssertNil(result.value, source); XCTAssertNotNil(result.error, source)
        }
    }
}
