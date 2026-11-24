import XCTest
@testable import CalculatorEngine

final class FuelTests: XCTestCase, PracticalTesting {
    private let usGallon = "0.003785411784", ukGallon = "0.00454609", mile = "1609.344"
    func testPublishedReferenceExamples() throws {
        try theory([("6.5 l/100km in mpg", "36.19 mpg"), ("450 km at 6.5 l/100km", "29.25 L")]) { source, display in XCTAssertEqual(try show(source), display, source) }
    }
    func testBareMpgIsTheUsGallonAndUkIsExplicit() throws {
        // 6.5 L per 100 km is 6.5e-3 m3 per 1e5 m; economy is the reciprocal, in miles per gallon.
        let perMetre = try r("0.0065") / r("100000")
        let usMpg = try r("1") / perMetre / (r(mile) / r(usGallon))
        let ukMpg = try r("1") / perMetre / (r(mile) / r(ukGallon))
        XCTAssertEqual(try show("6.5 l/100km in mpg"), "36.19 mpg")
        XCTAssertEqual(usMpg, try inOwnUnit(try value("6.5 l/100km in mpg")))
        XCTAssertEqual(try show("6.5 l/100km in mpg uk"), "43.46 mpg uk")
        XCTAssertEqual(ukMpg, try inOwnUnit(try value("6.5 l/100km in mpg uk")))
        // The same distance per litre: the imperial gallon is larger by 4.54609 / 3.785411784, so UK mpg is that much larger.
        XCTAssertEqual(try r(ukGallon) / r(usGallon), try ukMpg / usMpg)
        XCTAssertEqual(try show("6.5 l/100km in mpg us"), "36.19 mpg")
        XCTAssertEqual(try show("6.5 l/100km in mpg imp"), "43.46 mpg uk")
    }
    func testConsumptionAndEconomyAreReciprocalBothWays() throws {
        // 36 mpg US: litres per 100 km = 100 km * 3.785411784 L / (36 * 1.609344 km).
        let expected = try r("100000") * r(usGallon) / (r("36") * r(mile))
        XCTAssertEqual(expected, try canonical(try value("36 mpg in l/100km")) * r("100000"))
        XCTAssertEqual(try show("36 mpg in l/100km"), "6.53 l/100km")
        XCTAssertEqual(try r("36"), try inOwnUnit(try value("(36 mpg in l/100km) in mpg")))
        XCTAssertEqual(try r("7.5"), try inOwnUnit(try value("(7.5 l/100km in mpg uk) in l/100km")))
        // km/l is the same family as mpg: 12.5 km/l is 8 l/100km.
        XCTAssertEqual(try show("12.5 km/l in l/100km"), "8 l/100km")
        XCTAssertEqual(try show("8 l/100km in km/l"), "12.5 km/L")
        XCTAssertTrue(try fails("0 mpg in l/100km")); XCTAssertTrue(try fails("-5 l/100km in mpg"))
        XCTAssertTrue(try fails("6.5 l/100km in kg")); XCTAssertTrue(try fails("6.5 l/100km in m"))
    }
    func testDistanceAtConsumptionGivesFuelVolumeInTheMatchingVolumeUnit() throws {
        XCTAssertEqual(try r("450") * r("6.5") / r("100"), try inOwnUnit(try value("450 km at 6.5 l/100km")))
        // 100 miles at 25 mpg US = 4 US gallons.
        let gallons = try value("100 mi at 25 mpg")
        XCTAssertEqual(try r("4") * r(usGallon), try canonical(gallons))
        let imperial = try value("100 mi at 25 mpg uk")
        XCTAssertEqual(try r("4") * r(ukGallon), try canonical(imperial))
        XCTAssertEqual(try r("450") / r("15"), try inOwnUnit(try value("450 km at 15 km/l")))
        XCTAssertEqual(try show("450 km at 6.5 L/100km"), "29.25 L")
        XCTAssertTrue(try fails("450 kg at 6.5 l/100km")); XCTAssertTrue(try fails("0 km at 6.5 l/100km"))
        let step = try XCTUnwrap(try last("450 km at 6.5 l/100km").explanation.last?.assumption)
        XCTAssertTrue(step.contains("mpg is the US gallon")); XCTAssertTrue(step.contains("mpg uk the imperial gallon"))
    }
    func testFuelPriceGivesMoneyThroughExistingArithmetic() throws {
        // 29.25 L at 2 USD per litre.
        let cost = try last("450 km at 6.5 l/100km at 2 USD/L")
        XCTAssertNil(cost.error, cost.error ?? "")
        XCTAssertEqual(cost.display, "58.5 USD")
    }
    func testConversionExplanationsStateTheGallonConvention() throws {
        XCTAssertTrue(try last("6.5 l/100km in mpg").explanation.last!.assumption!.contains("US gallon"))
        XCTAssertTrue(try last("6.5 l/100km in mpg uk").explanation.last!.assumption!.contains("imperial gallon"))
    }
    func testTimeDifferenceIsSignedAndUsesTheEvaluationInstantSnapshot() throws {
        // 2026-10-31: London is on GMT (BST ended on 25 October), Tokyo is UTC+9 all year, New York is UTC-4 until 1 November.
        XCTAssertEqual(try show("time difference London to Tokyo"), "9 h")
        XCTAssertEqual(try show("time difference Tokyo to London"), "-(9 h)") // the existing negative compound-duration display
        XCTAssertEqual(try show("time difference from London to Tokyo"), "9 h")
        XCTAssertEqual(try show("time difference New York to London"), "4 h")
        let later = clock.with { $0.now = Practical.utc(2026, 11, 2, 12); $0.today = DateOnly(2026, 11, 2)! }
        XCTAssertEqual(try show("time difference New York to London", later), "5 h")
    }
    func testDatedFormUsesTheOffsetsOnThatDateAndNeedsNoClock() throws {
        XCTAssertEqual(try show("time difference London to Tokyo on 2026-07-01"), "8 h")
        XCTAssertEqual(try show("time difference London to Tokyo on 2026-12-01"), "9 h")
        let session = SheetEvaluationSession()
        let dated = try session.evaluateWithFunctions("time difference London to Tokyo on 2026-07-01", .empty, [], context: clock)
        XCTAssertFalse(dated.usesCurrentInstant); XCTAssertFalse(dated.usesCurrentDate)
        let undated = try session.evaluateWithFunctions("time difference London to Tokyo", .empty, [], context: clock)
        XCTAssertTrue(undated.usesCurrentInstant)
        XCTAssertFalse(try session.evaluateWithFunctions("2 + 2", .empty, [], context: clock).usesCurrentInstant)
    }
    func testTimeDifferenceRefreshesWhenTheInstantCrossesATransition() throws {
        let session = SheetEvaluationSession(); let source = "time difference New York to London"
        XCTAssertEqual(try session.evaluateWithFunctions(source, .empty, [], context: clock).results[0].display, "4 h")
        let after = clock.with { $0.now = Practical.utc(2026, 11, 2, 12) }
        XCTAssertEqual(try session.evaluateWithFunctions(source, .empty, [], context: after).results[0].display, "5 h")
    }
    func testTimeDifferenceNeedsAContextAndKnownZones() throws {
        XCTAssertTrue(try SheetEvaluator.evaluate("time difference London to Tokyo")[0].error?.contains("evaluation context") == true)
        XCTAssertNil(try last("time difference London to Nowhereville").value) // an unknown zone leaves the line as prose
        XCTAssertTrue(try last("time difference London to Tokyo").explanation.last?.assumption?.contains("UTC offsets") == true)
        XCTAssertTrue(try last("time difference London to Tokyo on 2026-07-01").explanation.last?.assumption?.contains("12:00 UTC on the given date") == true)
    }
    func testTimeAsProseKeepsItsMeaning() throws {
        try theory(["time difference between teams", "time difference"]) { source in XCTAssertNil(try last(source).value, source) }
    }
    func testFuelWordsAndVariablesKeepTheirMeaning() throws {
        XCTAssertEqual(try show("mpg = 5\nmpg"), "5")
        XCTAssertEqual(try show("mpg = 5\nmpg * 2"), "10")
        XCTAssertEqual(try show("at = 7\nat"), "7")
        XCTAssertEqual(try show("time = 3 h\ntime * 2"), "6 h")
    }
    func testSavedFunctionsParseCanonicalizeAndReload() throws {
        let update = try FunctionUpdate.prepare("tank(d) = d at 6.5 l/100km\neco(c) = c in mpg\ngap() = time difference London to Tokyo on 2026-07-01", .empty, [])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, update.library.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("tank(450 km)\neco(6.5 l/100km)\ngap()", update.library, [], context: clock).results
        XCTAssertEqual(results.map(\.display), ["29.25 L", "36.19 mpg", "8 h"])
        XCTAssertEqual(update.library.fingerprint, try FunctionLibrary(update.library.definitions).fingerprint)
    }
}
