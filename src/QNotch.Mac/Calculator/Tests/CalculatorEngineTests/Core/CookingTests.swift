import XCTest
@testable import CalculatorEngine

final class CookingTests: XCTestCase, PracticalTesting {
    func testPublishedReferenceExamples() throws {
        try theory([("2.5 cups in ml to 2 decimals", "591.47 mL"), ("250 g * 6 / 4", "375 g"), ("scale 250 g from 4 to 6 servings", "375 g")]) { source, display in
            XCTAssertEqual(try show(source), display, source)
        }
    }
    func testCupToMillilitreIsExactAndFlourIsOneTwentyFiveGrams() throws {
        // 1 US customary cup = 236.5882365 mL exactly; the unit catalog already holds it, the sentence code reads it back.
        XCTAssertEqual(try r("591.47059125"), try inOwnUnit(try value("2.5 cups in ml")))
        XCTAssertEqual(try show("2.5 cups in ml"), "591.47059125 mL")
        let flour = try value("1 cup flour in g")
        XCTAssertEqual(try r("125"), try inOwnUnit(flour)); XCTAssertEqual(try flour.number.unit!.symbol, "g")
        XCTAssertTrue(try flour.number.isApproximate); XCTAssertEqual(try flour.display, "≈ 125 g")
        XCTAssertEqual(try show("1 cup in cup"), "1 cup"); XCTAssertEqual(try show("1 cup in tbsp"), "16 tbsp"); XCTAssertEqual(try show("3 tsp in tbsp"), "1 tbsp")
    }
    func testDensityIsRecomputedBySecondRouteForOtherVolumesAndMasses() throws {
        // grams = volume / 236.5882365 mL * 125 g, with the rational arithmetic done here rather than by the evaluator.
        let cupMl = try r("236.5882365")
        XCTAssertEqual(try r("100") * r("125") / cupMl, try inOwnUnit(try value("100 ml flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("16 tbsp flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("48 tsp flour in g")))
        XCTAssertEqual(try r("62.5"), try inOwnUnit(try value("0.5 cup flour in g")))
        XCTAssertEqual(try r("250"), try inOwnUnit(try value("2 cups flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("236.5882365 ml flour in g")))
        XCTAssertEqual(try r("62.5"), try inOwnUnit(try value("4 floz flour in g")))
    }
    func testMassToVolumeIsTheInverse() throws {
        XCTAssertEqual(try r("1"), try inOwnUnit(try value("125 g flour in cups")))
        XCTAssertEqual(try r("16"), try inOwnUnit(try value("125 g flour in tbsp")))
        XCTAssertEqual(try r("236.5882365"), try inOwnUnit(try value("125 g flour in ml")))
        XCTAssertEqual(try r("1"), try inOwnUnit(try value("0.125 kg flour in cup")))
        XCTAssertEqual(try r("0.24"), try inOwnUnit(try value("30 g flour in cup")))
        for ingredient in IngredientCatalog.ingredients {
            let name = ingredient.names[0]
            XCTAssertEqual(ingredient.gramsPerCup, try inOwnUnit(try value("1 cup " + name + " in g")), name)
            XCTAssertEqual(try r("1"), try inOwnUnit(try value(ingredient.gramsPerCup.description + " g " + name + " in cup")), name)
            XCTAssertEqual(try r("2") * ingredient.gramsPerCup / r("1000"), try inOwnUnit(try value("2 cups " + name + " in kg")), name)
        }
    }
    func testCatalogHoldsAboutThirtyPinnedIngredientsWithAnExplicitSourceEach() throws {
        let items = IngredientCatalog.ingredients
        XCTAssertTrue((30...40).contains(items.count)); XCTAssertEqual(items.count, Set(items.map(\.id)).count)
        for item in items {
            XCTAssertFalse(item.source.netTrim.isEmpty); XCTAssertTrue(item.gramsPerCup.sign > 0); XCTAssertTrue(item.names.contains(item.id), item.id)
        }
        let flour = items.filter { $0.id == "flour" }; XCTAssertEqual(flour.count, 1)
        XCTAssertEqual(try r("125"), flour[0].gramsPerCup); XCTAssertTrue(flour[0].source.contains("fdcId 168894")); XCTAssertEqual(flour[0].note, "")
        for item in items { XCTAssertTrue(item.source.hasPrefix("USDA FoodData Central SR Legacy fdcId "), item.id) }
        XCTAssertTrue(IngredientCatalog.dataset.contains("USDA")); XCTAssertTrue(IngredientCatalog.basis.lowercased().contains("estimate"))
    }
    func testEveryUsdaValueMatchesTheRetainedSourceExtract() throws {
        // StreamReader.ReadLine splits on \n, \r\n and \r.
        let lines = try Fixtures.text("ingredient-usda-sr-legacy-2018.csv").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let rows = lines.filter { !$0.isEmpty }.map(CookingTests.csvFields)
        XCTAssertEqual(rows[0], ["id", "fdcId", "description", "portion", "gramWeight"])
        XCTAssertEqual(IngredientCatalog.ingredients.count, rows.count - 1)
        for row in rows.dropFirst() {
            let matches = IngredientCatalog.ingredients.filter { $0.id == row[0] }; XCTAssertEqual(matches.count, 1, row[0])
            guard let item = matches.first else { continue }
            XCTAssertEqual(try r(row[4]), item.gramsPerCup, row[0]); XCTAssertTrue(item.source.contains("fdcId " + row[1] + ":"), row[0]); XCTAssertTrue(item.source.contains(row[2]), row[0])
        }
    }
    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = [], current: [UInt16] = [], quoted = false
        let u = line.units; var i = 0
        while i < u.count {
            if u[i] == 0x22 { if quoted && i + 1 < u.count && u[i + 1] == 0x22 { current.append(0x22); i += 1 } else { quoted.toggle() } }
            else if u[i] == 0x2C && !quoted { fields.append(current.string); current.removeAll() }
            else { current.append(u[i]) }
            i += 1
        }
        fields.append(current.string); return fields
    }
    func testIngredientNamesAreCaseInsensitiveMultiWordAndHyphenTolerant() throws {
        XCTAssertEqual(try r("220"), try inOwnUnit(try value("1 cup brown sugar in g")))
        XCTAssertEqual(try r("200"), try inOwnUnit(try value("1 cup sugar in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("1 cup all purpose flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("1 cup all-purpose flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("1 cup of flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("1 cup Flour to g")))
        XCTAssertEqual(try r("137"), try inOwnUnit(try value("1 cup bread flour in g")))
        XCTAssertEqual(try r("216"), try inOwnUnit(try value("1 cup olive oil in g")))
        XCTAssertEqual(try r("218"), try inOwnUnit(try value("1 cup oil in g")))
        XCTAssertEqual(try r("0.25"), try inOwnUnit(try value("2 cups flour in kg")))
        XCTAssertEqual(try r("250"), try inOwnUnit(try value("(1 + 1) cups flour in g")))
        XCTAssertEqual(try r("125"), try inOwnUnit(try value("cupful = 1 cup\ncupful flour in g")))
    }
    func testResultsAreApproximateEstimatesWhoseExplanationNamesTheDensityAndSource() throws {
        let step = try last("1 cup brown sugar in g").explanation.last!
        XCTAssertEqual(step.operation, "ingredient conversion")
        let assumption = try XCTUnwrap(step.assumption)
        XCTAssertTrue(assumption.contains("brown sugar = 220 g per US cup")); XCTAssertTrue(assumption.contains("236.5882365 mL"))
        XCTAssertTrue(assumption.contains("fdcId 168833")); XCTAssertTrue(assumption.contains("brand, moisture, sifting and packing"))
        XCTAssertTrue(assumption.hasPrefix("Approximate input/result;"))
        XCTAssertTrue(try last("1 cup flour in g").explanation.last!.assumption!.contains("fdcId 168894"))
        XCTAssertEqual(try show("1 tbsp flour in g"), "≈ 7.81 g")
        XCTAssertEqual(try show("1 tbsp flour in g to 2 decimals"), "≈ 7.81 g")
    }
    func testUnknownIngredientIsAnErrorNamingIt() throws {
        let result = try last("1 cup unobtainium in g")
        XCTAssertEqual(result.error, "Unknown ingredient: unobtainium")
        XCTAssertEqual(try last("2 cups dragon fruit in g").error, "Unknown ingredient: dragon fruit")
        XCTAssertEqual(try last("100 g stardust in cups").error, "Unknown ingredient: stardust")
        // Without the opposite-dimension target the words keep their ordinary (unsupported) meaning rather than becoming an ingredient error.
        XCTAssertNotEqual(try last("1 cup unobtainium").error, "Unknown ingredient: unobtainium")
        XCTAssertNotEqual(try last("1 cup sugar").error, "Unknown ingredient: sugar")
        XCTAssertNil(try last("1 cup flour").value)
    }
    func testSameDimensionTargetsUseThePlainUnitConversion() throws {
        let millilitres = try last("1 cup flour in ml")
        XCTAssertEqual(try r("236.5882365"), try inOwnUnit(try XCTUnwrap(millilitres.value)))
        XCTAssertFalse(try millilitres.value!.number.isApproximate); XCTAssertTrue(millilitres.explanation.last!.assumption!.contains("density not used"))
        XCTAssertEqual(try show("1 cup flour in cups"), "1 cup")
        XCTAssertEqual(try r("0.1") / r("0.028349523125"), try inOwnUnit(try value("100 g flour in oz")))
    }
    func testOnlyVolumeAndMassMeasuresConvert() throws {
        try theory(["1 cup flour in m", "1 cup flour in s", "1 m flour in g", "1 s flour in g", "5 flour in g", "1 degC flour in g", "1 cup flour in 5"]) { source in
            XCTAssertNil(try last(source).value, source)
        }
    }
    func testNegationAppliesAfterTheConversion() throws { XCTAssertEqual(try show("-1 cup flour in g"), "≈ -125 g") }
    func testVariablesAndProseKeepTheirMeaning() throws {
        XCTAssertNotNil(try last("flour = 3\n1 cup flour in g").error)
        XCTAssertEqual(try show("flour = 3\nflour"), "3")
        XCTAssertEqual(try show("sugar = 200\nsugar"), "200")
        XCTAssertEqual(try show("water = 5\nwater"), "5")
        XCTAssertEqual(try show("3 cups"), "3 cup")
        XCTAssertNil(try last("a cup of flour is a lot").value)
        XCTAssertEqual(try show("Flour for the cake 2 cups"), "2 cup")
    }
    func testExistingCupTablespoonAndTeaspoonUnitsAreUntouched() throws {
        XCTAssertEqual(try r("236.5882365"), try inOwnUnit(try value("1 cup in ml")))
        XCTAssertEqual(try r("14.78676478125"), try inOwnUnit(try value("1 tbsp in ml")))
        XCTAssertEqual(try r("4.92892159375"), try inOwnUnit(try value("1 tsp in ml")))
        XCTAssertEqual(try show("1 tbsp in tsp"), "3 tsp")
        XCTAssertEqual(try show("8 tbsp in cups"), "0.5 cup")
    }
    func testServingScalingIsLinearAndRejectsNonpositiveServings() throws {
        XCTAssertEqual(try r("375"), try inOwnUnit(try value("scale 250 g from 4 to 6 servings")))
        XCTAssertEqual(try r("375"), try inOwnUnit(try value("scale 250 g from 4 to 6")))
        XCTAssertEqual(try r("1"), try inOwnUnit(try value("scale 2 cups from 8 to 4 portions")))
        XCTAssertEqual(try show("250 g * 6 / 4"), try show("scale 250 g from 4 to 6 servings"))
        XCTAssertEqual(try show("base = 4\nguests = 6\nscale 1 cup from base to guests"), "1.5 cup")
        XCTAssertEqual(try show("scale 1 from 2 to 5"), "2.5")
        XCTAssertEqual(try show("scale 50% from 4 to 5"), "62.5%")
        XCTAssertEqual(try show("scale (1 cup flour in g) from 4 to 6 servings"), "≈ 187.5 g")
        let step = try last("scale 250 g from 4 to 6 servings").explanation.last!
        XCTAssertTrue(step.assumption!.contains("6/4")); XCTAssertTrue(step.assumption!.contains("linearly"))
        XCTAssertNotNil(try last("scale 250 g from 0 to 6 servings").error); XCTAssertNotNil(try last("scale 250 g from 4 to 0 servings").error)
        XCTAssertNotNil(try last("scale 250 g from 4 to -2 servings").error)
        XCTAssertNotNil(try last("scale 250 g from 4 kg to 6 servings").error)
    }
    func testScaleAsProseStaysProse() throws {
        try theory(["scale", "scale the recipe", "scale up"]) { source in
            let result = try last(source)
            XCTAssertNil(result.value, source); XCTAssertNil(result.error, source)
        }
    }
    func testScaleBeforeAQuantityIsALabel() throws {
        try theory([("scale 250 g", "250 g")]) { source, display in XCTAssertEqual(try show(source), display) }
    }
    func testScaleAsAVariableAndAsLabelStillWork() throws {
        XCTAssertEqual(try show("scale = 3\nscale * 2"), "6")
        XCTAssertEqual(try show("scale 250 g"), "250 g")
        XCTAssertNotNil(try last("scale = 3\nscale 250 g from 4 to 6 servings").error)
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("grams(v) = v flour in g\ncups(m) = m sugar in cups\nbatch(a, n) = scale a from 4 to n servings", .empty, [])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, update.library.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("grams(1 cup)\ncups(200 g)\nbatch(250 g, 6)", update.library, [], context: clock).results
        XCTAssertEqual(results.map(\.display), ["≈ 125 g", "≈ 1 cup", "375 g"])
        XCTAssertEqual(update.library.fingerprint, try FunctionLibrary(update.library.definitions).fingerprint)
        let changed = try FunctionUpdate.prepare("grams(v) = v sugar in g", update.library, update.receipts)
        XCTAssertTrue(changed.hasChanges)
        XCTAssertEqual(try SheetEvaluationSession().evaluateWithFunctions("grams(1 cup)", changed.library, [], context: clock).results[0].display, "≈ 200 g")
    }
    func testIngredientResultsAddAndTotalAsMeasuredQuantities() throws {
        let lines = try SheetEvaluator.evaluate("1 cup flour in g\n1 cup sugar in g\nsum", context: clock)
        XCTAssertEqual(try r("325"), try inOwnUnit(try XCTUnwrap(lines[2].value))); XCTAssertTrue(lines[2].display.contains("g"))
    }
}
