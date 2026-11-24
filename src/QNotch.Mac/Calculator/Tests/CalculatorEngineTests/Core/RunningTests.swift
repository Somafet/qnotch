import XCTest
@testable import CalculatorEngine

final class RunningTests: XCTestCase, PracticalTesting {
    /// The exact magnitude a pace or clock result keeps (C# `value.Practical.Original!.Value`).
    private func original(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> Rational {
        try canonical(.number(try XCTUnwrap(try value(source, file: file, line: line).practical.original, file: file, line: line)))
    }
    func testPublishedReferenceExamples() throws {
        try theory([("pace 5 km in 27 min", "5:24 /km · 8:41 /mi"), ("10 km at 5:30/km", "55:00"), ("race 10 km in 50 min to marathon", "≈ 3:50:01"),
                    ("5 km / 27 min in km/h to 2 decimals", "11.11 km/h"), ("3 sets * 8 reps * 60 kg", "1440 kg")]) { source, display in XCTAssertEqual(try show(source), display, source) }
    }
    func testSpeedInKilometresPerHourIsExactAndNeedsNoNewSyntax() throws {
        XCTAssertEqual(try show("5 km / 27 min in km/h"), "(100/9) km/h")
        XCTAssertEqual(try r("100") / r("9"), try inOwnUnit(try value("5 km / 27 min in km/h")))
        XCTAssertEqual(try r("5000") / r("1620") * r("3.6"), try inOwnUnit(try value("5 km / 27 min in km/h")))
    }
    func testPaceIsTimePerDistanceShownPerKilometreAndPerMile() throws {
        let pace = try value("pace 5 km in 27 min")
        XCTAssertEqual(pace.kind, .practical); XCTAssertEqual(try pace.practical.kind, .pace)
        let perMetre = try canonical(.number(try XCTUnwrap(try pace.practical.original)))
        XCTAssertEqual(try r("1620") / r("5000"), perMetre) // seconds per metre
        // 324 s/km * 1.609344 km/mi = 521.427456 s/mi, which is 8:41 to the second.
        XCTAssertEqual(try r("324") * r("1.609344"), try perMetre * r("1609.344"))
        XCTAssertEqual(try show("pace 5 mi in 40 min"), "4:58 /km · 8:00 /mi")
        XCTAssertEqual(try show("pace 5 km in 27:30"), "5:30 /km · 8:51 /mi")
        XCTAssertEqual(try show("pace 5 km 27:30"), "5:30 /km · 8:51 /mi")
        XCTAssertEqual(try show("pace 10 km in 50 min"), "5:00 /km · 8:03 /mi")
        XCTAssertEqual(try show("pace 5000 m in 0:27:00"), "5:24 /km · 8:41 /mi")
        XCTAssertEqual(try show("pace 5 km in 1620 s"), "5:24 /km · 8:41 /mi")
        XCTAssertEqual(try show("pace 5 km in (20 + 7) min"), "5:24 /km · 8:41 /mi")
        XCTAssertEqual(try show("pace 5 km in 27 min"), try show("pace (5 km in mi) in 27 min"))
        XCTAssertEqual(try show("pace 5 km in 1 h"), "12:00 /km · 19:19 /mi")
        XCTAssertEqual(try show("pace 1 km in 1 h"), "1:00:00 /km · 1:36:34 /mi")
    }
    func testDistanceAtPaceGivesElapsedTimeInClockForm() throws {
        XCTAssertEqual(try show("10 km at 5:30/km"), "55:00")
        XCTAssertEqual(try show("10 km at 5:30 per km"), "55:00")
        XCTAssertEqual(try show("10 km at 5:30 /km"), "55:00")
        XCTAssertEqual(try show("1 mi at 8:00/mi"), "8:00")
        XCTAssertEqual(try show("10 km at 6:00/km"), "1:00:00")
        XCTAssertEqual(try show("21.0975 km at 5:00/km"), "1:45:29")
        XCTAssertEqual(try show("5 km at 4.5 min/km"), "22:30")
        XCTAssertEqual(try show("1 km at 59:59.6/km"), "1:00:00")
        XCTAssertEqual(try show("1000 m at 5:00/km"), "5:00")
        XCTAssertEqual(try show("10 km at 5:30/km"), try show("(10 km in mi) at 5:30/km"))
        XCTAssertEqual(try r("3300"), try original("10 km at 5:30/km"))
        // Time over a pace is the inverse of pace from time: distance * pace = elapsed time.
        XCTAssertEqual(try r("1620"), try canonical(try value("p = pace 5 km in 27 min\n5 km * p")))
        XCTAssertEqual(try show("p = pace 5 km in 27 min\n5 km * p"), "1620 s")
    }
    func testClockTimesAreArithmeticOperandsWithTheirExactMagnitude() throws {
        XCTAssertEqual(try show("10 km at 5:30/km\n10 km at 5:30/km\nsum"), "6600 s")
        XCTAssertEqual(try show("10 km at 5:30/km\nprev + 5 min"), "3600 s")
        XCTAssertEqual(try r("3599.6") / r("60"), try inOwnUnit(try value("1 km at 59:59.6/km in min")))
        XCTAssertEqual(try r("3599.6"), try original("1 km at 59:59.6/km"))
        let step = try last("10 km at 5:30/km").explanation.last!
        XCTAssertTrue(step.assumption!.contains("distance * pace")); XCTAssertTrue(step.assumption!.contains("m:ss below one hour"))
        XCTAssertTrue(try last("10 km at 5:30/km\nprev + 5 min").explanation.contains { $0.operation == "practical magnitude" })
    }
    func testRiegelMatchesIndependentlyComputedConstants() throws {
        // 2^1.06 = 2.084931521682243 and 4.2195^1.06 were computed outside this repository (Python, double precision).
        XCTAssertEqual(try r("2501.91782602"), try original("race 5 km in 20 min to 10 km"))
        XCTAssertEqual(try r("13800.5979998"), try original("race 10 km in 50 min to marathon"))
        XCTAssertEqual(try r("6619.20924321"), try original("race 10 km in 50 min to half marathon"))
        XCTAssertEqual(try show("race 5 km in 20 min to 10 km"), "≈ 41:42")
        XCTAssertEqual(try show("race 10 km in 50 min to half marathon"), "≈ 1:50:19")
        XCTAssertTrue(try value("race 5 km in 20 min to 10 km").practical.isApproximate)
    }
    func testRiegelHasItsStructuralIdentities() throws {
        // Same distance: exact and unmarked. Round trip: scaling out and back returns the input time.
        let same = try value("race 10 km in 50 min to 10 km")
        XCTAssertEqual(try same.display, "50:00"); XCTAssertFalse(try same.practical.isApproximate)
        let back = try value("t = race 5 km in 20 min to 10 km\nrace 10 km in t to 5 km")
        let seconds = try canonical(.number(try XCTUnwrap(try back.practical.original)))
        XCTAssertTrue(abs(seconds.numerator.toDouble() / seconds.denominator.toDouble() - 1200) < 1e-6)
        XCTAssertEqual(try back.display, "≈ 20:00")
        // The same distance expressed in other units, and the named targets, give the same prediction.
        let marathon = try original("race 10 km in 50 min to marathon")
        XCTAssertEqual(marathon, try original("race 10000 m in 3000 s to 42.195 km"))
        XCTAssertEqual(marathon, try original("race 10 km in 50:00 to 42195 m"))
        XCTAssertEqual(marathon, try original("race 10 km in 0:50:00 to marathon"))
        XCTAssertEqual(try original("race 10 km in 50 min to 5 km"), try original("race 10 km in 50 min to 5k"))
        XCTAssertEqual(try original("race 10 km in 50 min to 10 km"), try original("race 10 km in 50 min to 10k"))
        XCTAssertEqual(try original("race 10 km in 50 min to half marathon"), try original("race 10 km in 50 min to half-marathon"))
        XCTAssertEqual(try original("race 10 km in 50 min to 21.0975 km"), try original("race 10 km in 50 min to half marathon"))
        // Longer distances take longer per kilometre.
        XCTAssertTrue(try (original("race 5 km in 20 min to 10 km") - r("2400")).sign > 0)
        let explanation = try XCTUnwrap(try last("race 10 km in 50 min to marathon").explanation.last?.assumption)
        XCTAssertTrue(explanation.contains("T2 = T1 * (D2 / D1)^1.06")); XCTAssertTrue(explanation.contains("1.06")); XCTAssertTrue(explanation.contains("Riegel"))
        XCTAssertTrue(explanation.hasPrefix("Approximate input/result;"))
    }
    func testRunningInputsMustBePositiveWithTheRightDimensions() throws {
        try theory(["race 1 km in 5 min to 200 km", "race 200 km in 20 h to 1 km", "race 0 km in 50 min to marathon", "race 10 km in 0 min to marathon",
                    "race 10 km in 50 min to 0 km", "race 10 kg in 50 min to marathon", "race 10 km in 50 kg to marathon", "race 10 km in 50 min to 5 kg",
                    "pace 0 km in 27 min", "pace 5 km in 0 min", "pace 5 min in 27 km", "pace -5 km in 27 min",
                    "0 km at 5:30/km", "10 min at 5:30/km", "10 at 5:30/km", "10 km at 0:00/km"]) { source in XCTAssertNil(try last(source).value, source) }
    }
    func testInvalidClockLiteralsAreNotPaces() throws {
        try theory(["10 km at 5:75/km", "pace 5 km in 27:75", "pace 5 km in 1:75:00", "10 km at 5:30/kg"]) { source in XCTAssertNil(try last(source).value, source) }
    }
    func testPaceAndRaceWordsKeepTheirOrdinaryMeanings() throws {
        for prose in ["pace", "race", "pace yourself", "race to the finish", "race car", "pace and race"] {
            let result = try last(prose); XCTAssertNil(result.value, prose); XCTAssertNil(result.error, prose)
        }
        XCTAssertEqual(try show("race car 2"), "2")
        XCTAssertEqual(try show("pace = 5\npace * 2"), "10")
        XCTAssertEqual(try show("race = 5\nrace + race"), "10")
        XCTAssertEqual(try show("pace 5"), "5")
        XCTAssertEqual(try show("race 10 km"), "10 km")
        XCTAssertNotNil(try last("pace = 5\npace 5 km in 27 min").error)
        XCTAssertNil(try last("marathon = 42\nrace 10 km in 50 min to marathon").value)
    }
    func testExistingClockLiteralsAndRatesAreUnchanged() throws {
        // Regression anchors for behaviour that shares tokens with the new sentences (clock literals, "at" and "to").
        XCTAssertEqual(try show("9:30 + 45 min"), "10:15")
        XCTAssertEqual(try show("from 9:00 to 16:00"), "7 h")
        XCTAssertEqual(try show("5:30 pm"), "17:30")
        XCTAssertEqual(try show("10:00 - 9:30"), "30 min")
        XCTAssertEqual(try show("5:30"), "05:30")
        XCTAssertEqual(try show("Meeting at 5:30"), "05:30")
        XCTAssertEqual(try show("2026-10-31 at 12:00"), "2026-10-31T12:00:00")
        XCTAssertEqual(try show("5 GB at 10 Mbit/s"), "1 h 6 min 40 s")
        XCTAssertEqual(try show("100 GB at 50 Mbit/s"), "4 h 26 min 40 s")
    }
    func testSetsAndRepsAreDimensionlessCountsThatDoNotDisturbIdentifiers() throws {
        XCTAssertEqual(try r("1440"), try inOwnUnit(try value("3 sets * 8 reps * 60 kg")))
        XCTAssertEqual(try r("3") * r("8") * r("60"), try canonical(try value("3 sets * 8 reps * 60 kg")))
        XCTAssertEqual(try show("5 reps * 100 lb"), "500 lb")
        XCTAssertEqual(try show("3 sets"), "3"); XCTAssertEqual(try show("1.5 reps"), "1.5"); XCTAssertEqual(try show("3 set"), "3"); XCTAssertEqual(try show("1 rep"), "1")
        XCTAssertEqual(try show("Bench press 3 sets * 8 reps * 60 kg"), "1440 kg")
        XCTAssertEqual(try show("w = 60 kg\n3 sets * 8 reps * w"), "1440 kg")
        XCTAssertEqual(try show("sets = 4\nsets * 2"), "8")
        XCTAssertEqual(try show("set = 3\nset * 2"), "6")
        XCTAssertNotNil(try last("reps = 5\n3 reps").error)
        XCTAssertNotNil(try last("sets(2)").error)
        XCTAssertEqual(try show("sets = 4\nreps = 2\n8 / sets"), "2")
        XCTAssertTrue(try last("3 sets").explanation.last!.assumption!.contains("Dimensionless count"))
        let lines = try SheetEvaluator.evaluate("3 sets * 8 reps * 60 kg\n3 sets * 8 reps * 100 kg\nsum", context: clock)
        XCTAssertEqual(lines[2].display, "3840 kg")
    }
    func testRunningHelpersNeedNoClockOrTimerAndSaveAsFunctions() throws {
        let session = SheetEvaluationSession()
        let evaluated = try session.evaluateWithFunctions("pace 5 km in 27 min\n10 km at 5:30/km\nrace 10 km in 50 min to marathon\n3 sets * 8 reps * 60 kg", .empty, [], context: clock)
        XCTAssertFalse(evaluated.usesCurrentDate); XCTAssertFalse(evaluated.usesCurrentInstant); XCTAssertFalse(evaluated.requiresSecondRefresh)
        let update = try FunctionUpdate.prepare("eta(d) = d at 5:30/km\nforecast(t) = race 10 km in t to marathon\nsplit(t) = pace 5 km in t\nvolume(w) = 3 sets * 8 reps * w", .empty, [])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, update.library.minimumCatalogVersion)
        let results = try SheetEvaluationSession().evaluateWithFunctions("eta(10 km)\nforecast(50 min)\nsplit(27 min)\nvolume(60 kg)", update.library, [], context: clock).results
        XCTAssertEqual(results.map(\.display), ["55:00", "≈ 3:50:01", "5:24 /km · 8:41 /mi", "1440 kg"])
        XCTAssertEqual(update.library.fingerprint, try FunctionLibrary(update.library.definitions).fingerprint)
        XCTAssertEqual(try FunctionLibrary([FunctionDefinition(name: "plain", parameters: ["v"], body: "v + 1")]).minimumCatalogVersion, 1)
    }
}
