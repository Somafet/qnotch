import XCTest
@testable import CalculatorEngine

final class HealthTests: XCTestCase, PracticalTesting {
    func testPublishedReferenceExamples() throws {
        try theory([
            ("bmi(80 kg, 180 cm)", "24.7"), ("bmr 80 kg 180 cm 30 years male", "1780 kcal"), ("tdee 80 kg 180 cm 30 years male moderate", "2759 kcal"),
            ("tdee 80 kg 180 cm 30 years male moderate\nprev - 500 kcal", "2259 kcal"),
            ("hr zones age 30", "Z1 95–114 · Z2 114–133 · Z3 133–152 · Z4 152–171 · Z5 171–190"), ("hr zones max 185", "Z1 93–111 · Z2 111–130 · Z3 130–148 · Z4 148–167 · Z5 167–185"),
        ]) { source, display in XCTAssertEqual(try last(source).display, display, source) }
    }
    func testBmiIsMassOverHeightSquaredWithExactValueKept() throws {
        let value = try self.value("bmi(80 kg, 180 cm)")
        XCTAssertEqual(try Rational(2000, 81), try canonical(value))
        XCTAssertEqual(try value.display, "24.7")
        // Another route: converting the arguments through other units leaves the exact index unchanged.
        XCTAssertEqual(try Rational(2000, 81), try canonical(try self.value("bmi(80 kg in lb, 180 cm in in)")))
        XCTAssertEqual(try show("bmi(70 kg, 175 cm)"), "22.9")
        XCTAssertEqual(try canonical(try self.value("bmi(70 kg, 175 cm)")), try canonical(try self.value("bmi(70 kg in lb, 1.75 m)")))
        // Composite stone/pound and foot/inch quantities against the exact definitions.
        let mass = try r("12") * r("6.35029318") + r("9") * r("0.45359237"), height = try r("71") * r("0.0254")
        XCTAssertEqual(try mass / (height * height), try canonical(try self.value("bmi(12 stone 9 lb, 5 ft 11 in)")))
    }
    func testBmiRejectsNonpositiveImplausibleAndUntypedInputs() throws {
        try theory(["bmi(0 kg, 180 cm)", "bmi(80 kg, 0 cm)", "bmi(-80 kg, 180 cm)", "bmi(80 kg, -1 m)", "bmi(1001 kg, 180 cm)", "bmi(80 kg, 3.01 m)", "bmi(80, 180)",
                    "bmi(80 cm, 180 kg)", "bmi(80 kg)", "bmi(80 kg, 180 cm, 3)", "bmi(80 %, 180 cm)"]) { source in XCTAssertNotNil(try last(source).error, source) }
    }
    func testBmiCarriesNoCategoryAndItsExplanationStatesTheFormula() throws {
        let result = try last("bmi(80 kg, 180 cm)")
        let assumption = try XCTUnwrap(result.explanation.last?.assumption)
        XCTAssertFalse((result.display + assumption).lowercased().contains("overweight"))
        XCTAssertTrue(assumption.lowercased().contains("no category"))
        XCTAssertTrue(assumption.contains("mass (kg) / height (m)^2"))
    }
    func testMifflinStJeorMatchesAnIndependentDecimalComputation() throws {
        // 10 * 80 + 6.25 * 180 - 5 * 30 + 5 = 1780 and the female constant is -161.
        XCTAssertEqual(try r("1780") * r("4184"), try canonical(try value("bmr 80 kg 180 cm 30 years male")))
        XCTAssertEqual(try r("1780") * r("4184") - r("166") * r("4184"), try canonical(try value("bmr 80 kg 180 cm 30 years female")))
        // 65 kg, 165 cm, 40 years, female: 650 + 1031.25 - 200 - 161 = 1320.25 kcal, displayed to whole kcal.
        let woman = try value("bmr 65 kg 165 cm 40 years female")
        XCTAssertEqual(try r("1320.25"), try inOwnUnit(woman)); XCTAssertEqual(try woman.display, "1320 kcal")
        // 176 lb and 5 ft 11 in with the exact pound and inch definitions.
        let imperial = try value("bmr 176 lb 5 ft 11 in 30 years male")
        XCTAssertEqual(try r("10") * r("176") * r("0.45359237") + r("6.25") * r("71") * r("2.54") - r("150") + r("5"), try inOwnUnit(imperial))
        XCTAssertEqual(try r("10") * r("176.37") * r("0.45359237") + r("6.25") * r("180") - r("150") + r("5"), try inOwnUnit(try value("bmr 176.37 lb 180 cm 30 years male")))
    }
    func testUnitsAreInterchangeableAndAgeUnitWordIsOptional() throws {
        let metric = try canonical(try value("bmr 80 kg 180 cm 30 years male"))
        XCTAssertEqual(metric, try canonical(try value("bmr 80000 g 1.8 m 30 yr male")))
        XCTAssertEqual(metric, try canonical(try value("bmr 80 kg 180 cm 30 male")))
        XCTAssertEqual(metric, try canonical(try value("bmr (80 kg in lb) (180 cm in in) 30 years male")))
        XCTAssertEqual(metric, try canonical(try value("w = 80 kg\nh = 180 cm\nbmr w h 30 years male")))
        XCTAssertEqual(metric, try canonical(try value("bmr 80 kg 1 m 80 cm 30 years male")))
    }
    func testActivityMultipliersScaleTheRestingRateExactly() throws {
        try theory([("sedentary", "1.2"), ("light", "1.375"), ("moderate", "1.55"), ("active", "1.725"), ("very active", "1.9")]) { level, factor in
            let tdee = try value("tdee 80 kg 180 cm 30 years male " + level)
            XCTAssertEqual(try r("1780") * r(factor), try inOwnUnit(tdee), level)
            XCTAssertEqual(try tdee.number.unit!.symbol, "kcal")
        }
    }
    func testRoundingIsDisplayOnlyAndTheExactValueFeedsLaterLines() throws {
        // 1780 * 1.375 = 2447.5 shows as 2448 kcal yet later arithmetic keeps the half.
        let lines = try SheetEvaluator.evaluate("tdee 80 kg 180 cm 30 years male light\nprev - 0.5 kcal\nprev * 2", context: clock)
        XCTAssertEqual(lines[0].display, "2448 kcal"); XCTAssertEqual(lines[1].display, "2447 kcal"); XCTAssertEqual(lines[2].display, "4894 kcal")
        XCTAssertEqual(try show("tdee 80 kg 180 cm 30 years male light to 1 decimals"), "2447.5 kcal")
        XCTAssertEqual(try show("tdee 80 kg 180 cm 30 years male light in cal"), "2447500 cal")
        XCTAssertEqual(try show("tdee 80 kg 180 cm 30 years male moderate to 0 decimals"), "2759 kcal")
    }
    func testKilocalorieQuantityConvertsAndStatesTheDailySemantics() throws {
        XCTAssertEqual(try r("1780") * r("4.184"), try inOwnUnit(try value("bmr 80 kg 180 cm 30 years male in kJ")))
        let step = try last("bmr 80 kg 180 cm 30 years male").explanation.last!
        XCTAssertTrue(step.assumption!.contains("kilocalories per day")); XCTAssertTrue(step.assumption!.contains("Mifflin-St Jeor")); XCTAssertTrue(step.assumption!.contains("not medical advice"))
        XCTAssertTrue(try last("tdee 80 kg 180 cm 30 years male moderate").explanation.last!.assumption!.contains("1.55"))
    }
    func testBodyInputsAreBounded() throws {
        try theory(["bmr 0 kg 180 cm 30 years male", "bmr 80 kg 0 cm 30 years male", "bmr 80 kg 180 cm 0 years male", "bmr -80 kg 180 cm 30 years male",
                    "bmr 80 kg 180 cm -3 years male", "bmr 80 kg 180 cm 151 years male", "bmr 1001 kg 180 cm 30 years male", "bmr 80 kg 4 m 30 years male",
                    "bmr 80 180 30 years male", "bmr 80 cm 180 kg 30 years male", "bmr 0.5 kg 50 cm 100 years female"]) { source in XCTAssertNotNil(try last(source).error, source) }
    }

    private func expected(_ maximum: Int) -> [Int] { (5...10).map { tenths in (2 * maximum * tenths + 10) / 20 } }
    func testHeartRateZonesRoundEachBoundaryHalfUpAndShareEdges() throws {
        // Independent integer route: edge = floor(max * k / 10 + 1/2) for k = 5..10; reproduces both published lines.
        for age in 1...120 {
            let zones = try value("hr zones age \(age)").practical.zones; let edges = expected(220 - age)
            XCTAssertEqual(zones.count, 5)
            for i in 0..<5 { XCTAssertEqual(zones[i].number, i + 1); XCTAssertEqual(zones[i].low, edges[i]); XCTAssertEqual(zones[i].high, edges[i + 1]) }
        }
        for maximum in [150, 171, 185, 199, 200, 207] {
            let zones = try value("hr zones max \(maximum)").practical.zones; let edges = expected(maximum)
            XCTAssertEqual(edges, zones.map(\.low) + [zones[zones.count - 1].high])
            XCTAssertEqual(maximum, zones[zones.count - 1].high)
        }
        XCTAssertEqual(try show("hr zones max 185 bpm"), "Z1 93–111 · Z2 111–130 · Z3 130–148 · Z4 148–167 · Z5 167–185")
        XCTAssertEqual(try show("hr zones age 30"), try show("hr zones max 190"))
        XCTAssertEqual(try show("hr zones age 30"), try show("hr zones age 30 years"))
        XCTAssertEqual(try show("hr zones age 30"), try show("hr zones age (25 + 5)"))
    }
    func testHeartRateZonesCopyExplainAndStayOutOfArithmeticAndTotals() throws {
        let result = try last("hr zones age 30"); let value = try XCTUnwrap(result.value)
        XCTAssertEqual(value.kind, .practical); XCTAssertEqual(result.display, try value.copyText)
        let assumption = try XCTUnwrap(result.explanation.last?.assumption)
        XCTAssertTrue(assumption.contains("220 - age")); XCTAssertTrue(assumption.contains("50-60%")); XCTAssertTrue(assumption.contains("halves up"))
        let lines = try SheetEvaluator.evaluate("10\nhr zones age 30\n20\nsum", context: clock)
        XCTAssertEqual(lines[3].display, "30"); XCTAssertNil(lines[3].error)
        XCTAssertNotNil(try last("z = hr zones age 30\nz + 1").error); XCTAssertNotNil(try last("hr zones age 30\nprev * 2").error)
        XCTAssertEqual(try show("hr zones age 30 kg"), "30 kg")
        XCTAssertEqual(try SheetEvaluator.evaluate("hr zones age 30\n10\n20\naverage", context: clock)[3].display, "15")
    }
    func testHeartRateZoneInputsAreBounded() throws {
        try theory(["hr zones age 0", "hr zones age 151", "hr zones age 221", "hr zones max 0", "hr zones max 301", "hr zones max -5", "hr zones", "hr zones age",
                    "hr zones age 30 max 190"]) { source in XCTAssertNil(try last(source).value, source) }
    }
    func testHeartRateZoneBoundsAreInclusive() throws {
        XCTAssertEqual(try show("hr zones age 150"), "Z1 35–42 · Z2 42–49 · Z3 49–56 · Z4 56–63 · Z5 63–70")
        XCTAssertEqual(try show("hr zones max 300"), "Z1 150–180 · Z2 180–210 · Z3 210–240 · Z4 240–270 · Z5 270–300")
    }
    func testWordsKeepTheirProseMeaning() throws {
        try theory(["bmr", "tdee", "hr", "hr zones", "bmr and tdee are estimates", "my bmr today", "hr zones are useful"]) { source in
            let result = try SheetEvaluator.evaluate(source, context: clock)[0]
            XCTAssertNil(result.value, source); XCTAssertNil(result.error, source)
        }
    }
    func testLabelsAndVariablesWinOverTheSentenceHeads() throws {
        XCTAssertEqual(try show("bmr 1780"), "1780")
        XCTAssertEqual(try show("hr 60"), "60")
        XCTAssertEqual(try show("bmr = 5\nbmr * 2"), "10")
        XCTAssertEqual(try show("hr = 60\nhr * 2"), "120")
        XCTAssertEqual(try show("tdee = 3\ntdee + tdee"), "6")
        // The sentence is not attempted when its head is a user variable; the rest then has no meaning.
        XCTAssertNotNil(try last("bmr = 5\nbmr 80 kg 180 cm 30 years male").error)
        // A variable that shares a keyword inside the sentence does not disturb it.
        XCTAssertEqual(try show("male = 2\nbmr 80 kg 180 cm 30 years male"), "1780 kcal")
        XCTAssertEqual(try show("zones = 5\nhr zones age 30"), "Z1 95–114 · Z2 114–133 · Z3 133–152 · Z4 152–171 · Z5 171–190")
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("body(w, h) = bmi(w, h)\nrest(w, h, a) = bmr w h a years female\nburn(w, h, a) = tdee w h a years male active\nzones(a) = hr zones age a", .empty, [])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, update.library.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("body(80 kg, 180 cm)\nrest(65 kg, 165 cm, 40)\nburn(80 kg, 180 cm, 30)\nzones(30)", update.library, [], context: clock).results
        XCTAssertEqual(results.map(\.display), ["24.7", "1320 kcal", "3071 kcal", "Z1 95–114 · Z2 114–133 · Z3 133–152 · Z4 152–171 · Z5 171–190"])
        XCTAssertEqual(update.library.fingerprint, try FunctionLibrary(update.library.definitions).fingerprint)
        let upper = try FunctionUpdate.prepare("body(w, h) = BMI(w, h)", .empty, [])
        XCTAssertFalse(try FunctionUpdate.prepare("Body(W, H) = bmi(W, H)", upper.library, upper.receipts).hasChanges)
        XCTAssertEqual(try FunctionLibrary([FunctionDefinition(name: "plain", parameters: ["v"], body: "v + 1")]).minimumCatalogVersion, 1)
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "bmi", parameters: ["a", "b"], body: "a + b")])) { XCTAssertTrue(($0 as? CalcError)?.isFormat == true) }
    }
}
