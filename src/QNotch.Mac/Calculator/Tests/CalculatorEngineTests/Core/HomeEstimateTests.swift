import XCTest
@testable import CalculatorEngine

final class HomeEstimateTests: XCTestCase, PracticalTesting {
    func testPublishedReferenceExamples() throws {
        try theory([("paint 40 m2 2 coats", "8 L"), ("tiles 12 m2", "13.2 m^2"), ("concrete 2 m3", "184")]) { source, display in XCTAssertEqual(try show(source), display, source) }
    }
    private func ceiling(_ value: Rational) throws -> Rational { try Rational((value.numerator + value.denominator - 1) / value.denominator) }

    func testPaintIsAreaTimesCoatsOverCoverageWithDisclosedDefaults() throws {
        XCTAssertEqual(try r("8"), try inOwnUnit(try value("paint 40 m2 2 coats")))
        XCTAssertEqual(try show("paint 40 m2"), "4 L")
        XCTAssertEqual(try show("paint 40 m2 1 coat"), "4 L")
        XCTAssertEqual(try show("paint 40 m2 3 coats at 8 m2/l"), "15 L")
        // 40 m2 * 2 coats / 12 m2 per litre = 20/3 L: the exact value is kept, the display shows two decimals.
        let third = try value("paint 40 m2 2 coats at 12 m2/l")
        XCTAssertEqual(try r("40") * r("2") / r("12"), try inOwnUnit(third)); XCTAssertEqual(try third.display, "6.67 L")
        let step = try XCTUnwrap(try last("paint 40 m2 2 coats").explanation.last?.assumption)
        XCTAssertTrue(step.contains("10 m2 per litre")); XCTAssertTrue(step.contains("2 coats at 10 m2/l (default)")); XCTAssertTrue(step.contains("no allowance for openings"))
        XCTAssertTrue(try last("paint 40 m2 2 coats at 12 m2/l").explanation.last!.assumption!.contains("at 12 m2/l"))
        XCTAssertFalse(try last("paint 40 m2 2 coats at 12 m2/l").explanation.last!.assumption!.contains("(default)"))
    }
    func testPaintAcceptsAreaAndCoverageInOtherUnits() throws {
        // 400 ft2 = 400 * 0.3048^2 m2 exactly.
        XCTAssertEqual(try r("400") * r("0.3048") * r("0.3048") * r("2") / r("10"), try inOwnUnit(try value("paint 400 ft2 2 coats")))
        let coverage = try r("120") * r("0.3048") * r("0.3048") / r("0.003785411784") // 120 ft2 per US gallon, in m2 per m3
        XCTAssertEqual(try r("40") * r("2") / coverage * r("1000"), try inOwnUnit(try value("paint 40 m2 2 coats at 120 ft2/gal")))
        XCTAssertEqual(try show("paint 4000000 cm2"), "40 L")
        XCTAssertEqual(try show("paint 40 m2 2 coats"), try show("paint (40 m2) (2) coats"))
        XCTAssertEqual(try show("paint 40 m2 2 coats"), try show("paint 0.004 ha 2 coats"))
        XCTAssertEqual(try show("paint 40 m2 2 coats in ml"), "8000 mL")
    }
    func testPaintInputsAreBounded() throws {
        try theory(["paint 40 m2 0 coats", "paint 40 m2 2.5 coats", "paint 40 m2 21 coats", "paint 40 m2 -1 coats", "paint 0 m2", "paint 40 m2 2 coats at 0 m2/l",
                    "paint 40 m2 2 coats at 12 m", "paint 40 m 2 coats", "paint 40 kg", "paint -40 m2"]) { source in XCTAssertNil(try last(source).value, source) }
    }
    func testTilesAddWasteAndKeepTheAreaUnit() throws {
        XCTAssertEqual(try r("12") * r("1.1"), try inOwnUnit(try value("tiles 12 m2")))
        XCTAssertEqual(try show("tiles 12 m2 15% waste"), "13.8 m^2"); XCTAssertEqual(try show("tiles 12 m2 waste 15%"), "13.8 m^2"); XCTAssertEqual(try show("tiles 12 m2 with 15% waste"), "13.8 m^2")
        XCTAssertEqual(try show("tiles 12 m2 15 percent waste"), "13.8 m^2")
        XCTAssertEqual(try show("tiles 12 m2 0% waste"), "12 m^2"); XCTAssertEqual(try show("tiles 12 m2 100% waste"), "24 m^2"); XCTAssertEqual(try show("tiles 12 m2 10.5% waste"), "13.26 m^2")
        let feet = try value("tiles 129 ft2")
        XCTAssertEqual(try r("129") * r("1.1"), try inOwnUnit(feet)); XCTAssertEqual(try feet.display, "141.9 ft^2")
        XCTAssertEqual(try r("129") * r("0.3048") * r("0.3048") * r("1.1"), try canonical(feet))
        XCTAssertEqual(try r("12") * r("1.1") / (r("0.3048") * r("0.3048")), try inOwnUnit(try value("tiles 12 m2 in ft2")))
        XCTAssertEqual(try r("132000"), try inOwnUnit(try value("tiles 120000 cm2")))
        let step = try XCTUnwrap(try last("tiles 12 m2").explanation.last?.assumption)
        XCTAssertTrue(step.contains("default waste 10%")); XCTAssertTrue(step.contains("used 10% waste (default)")); XCTAssertTrue(step.contains("whole-tile counts"))
        XCTAssertTrue(try last("tiles 12 m2 15% waste").explanation.last!.assumption!.contains("used 15% waste"))
    }
    func testTileInputsAreBounded() throws {
        try theory(["tiles 12 m2 101% waste", "tiles 12 m2 15 waste", "tiles 0 m2", "tiles -12 m2", "tiles 12 m", "tiles 12 m3", "tiles 12 m2 -5% waste"]) { source in
            XCTAssertNil(try last(source).value, source)
        }
    }
    func testConcreteBagsAreVolumeTimesDensityOverBagMassRoundedUp() throws {
        XCTAssertEqual(try r("2") * r("2300") / r("25"), try canonical(try value("concrete 2 m3"))) // exactly 184 bags
        XCTAssertEqual(try show("concrete 1 m3"), "92")
        XCTAssertEqual(try show("concrete 2.0001 m3"), "185"); XCTAssertEqual(try show("concrete 1.99999 m3"), "184")
        XCTAssertEqual(try show("concrete 0.001 m3"), "1"); XCTAssertEqual(try show("concrete 0.0108 m3"), "1"); XCTAssertEqual(try show("concrete 0.0109 m3"), "2")
        XCTAssertEqual(try show("concrete 2 m3 40 kg bags"), "115"); XCTAssertEqual(try show("concrete 2 m3 at 2400 kg/m3"), "192"); XCTAssertEqual(try show("concrete 2 m3 40 kg bags at 2400 kg/m3"), "120")
        XCTAssertEqual(try show("concrete 2000 L"), "184"); XCTAssertEqual(try show("concrete 2000000 cm3"), "184")
        // Another unit system, computed with exact definitions and an independent ceiling.
        XCTAssertEqual(try ceiling(try r("2") * r("0.9144") * r("0.9144") * r("0.9144") * r("2300") / r("25")), try canonical(try value("concrete 2 yd3")))
        XCTAssertEqual(try show("concrete 2 yd3"), "141")
        XCTAssertEqual(try ceiling(try r("70") * r("0.3048") * r("0.3048") * r("0.3048") * r("2300") / r("25")), try canonical(try value("concrete 70 ft3")))
        XCTAssertEqual(try ceiling(try r("2") * r("2300") / (r("50") * r("0.45359237"))), try canonical(try value("concrete 2 m3 50 lb bags")))
        let step = try XCTUnwrap(try last("concrete 2 m3").explanation.last?.assumption)
        XCTAssertTrue(step.contains("2300 kg/m3")); XCTAssertTrue(step.contains("25 kg bags")); XCTAssertTrue(step.contains("(defaults)")); XCTAssertTrue(step.contains("rounded up"))
        XCTAssertTrue(step.contains("4600 kg of concrete"))
    }
    func testConcreteInputsAreBounded() throws {
        try theory(["concrete 0 m3", "concrete -2 m3", "concrete 2 m2", "concrete 2 m3 0 kg bags", "concrete 2 m3 40 m bags", "concrete 2 m3 at 0 kg/m3", "concrete 2 m3 at 2400 kg"]) { source in
            XCTAssertNil(try last(source).value, source)
        }
    }
    func testSentencesAreNotEstimatesWithoutTheirCompleteGrammar() throws {
        for prose in ["paint", "tiles", "concrete", "paint the wall", "tiles are cold", "concrete jungle", "paint and tiles and concrete"] {
            let result = try last(prose); XCTAssertNil(result.value, prose); XCTAssertNil(result.error, prose)
        }
        XCTAssertEqual(try show("paint 40"), "40"); XCTAssertEqual(try show("tiles 12"), "12"); XCTAssertEqual(try show("concrete 2"), "2")
        XCTAssertEqual(try show("walls 40 m2"), "40 m^2")
        XCTAssertEqual(try show("paint = 3\npaint * 2"), "6"); XCTAssertEqual(try show("tiles = 3\ntiles + tiles"), "6"); XCTAssertEqual(try show("concrete = 3\nconcrete * 2"), "6")
        XCTAssertNil(try last("tiles = 5\ntiles 12 m2").value); XCTAssertNil(try last("paint = 5\npaint 40 m2 2 coats").value)
        XCTAssertEqual(try show("coats = 5\nwaste = 3\npaint 40 m2 2 coats"), "8 L")
        XCTAssertEqual(try show("waste = 3\ntiles 12 m2"), "13.2 m^2")
        XCTAssertEqual(try show("w = 15%\ntiles 12 m2 w waste"), "13.8 m^2")
        XCTAssertEqual(try show("n = 2\npaint 40 m2 n coats"), "8 L")
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("cover(a, n) = paint a n coats\nflooring(a, w) = tiles a w waste\nbags(v) = concrete v\nmix(v, b, d) = concrete v b bags at d", .empty, [])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, update.library.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("cover(40 m2, 2)\nflooring(12 m2, 15%)\nbags(2 m3)\nmix(2 m3, 40 kg, 2400 kg/m3)", update.library, [], context: clock).results
        XCTAssertEqual(results.map(\.display), ["8 L", "13.8 m^2", "184", "120"])
        XCTAssertEqual(update.library.fingerprint, try FunctionLibrary(update.library.definitions).fingerprint)
        let session = SheetEvaluationSession()
        let evaluated = try session.evaluateWithFunctions("paint 40 m2 2 coats\ntiles 12 m2\nconcrete 2 m3", .empty, [], context: clock)
        XCTAssertFalse(evaluated.usesCurrentDate); XCTAssertFalse(evaluated.usesCurrentInstant); XCTAssertFalse(evaluated.requiresSecondRefresh)
    }
}
