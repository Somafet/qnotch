import XCTest
@testable import CalculatorEngine

final class DiceTests: XCTestCase {
    /// C# `new Guid(index, 0, 0, new byte[8])`.
    private static func node(_ index: Int) -> UUID { UUID(uuidString: String(format: "%08x-0000-0000-0000-000000000000", index))! }
    private static func rolls(_ lines: Int, _ rolls: (line: Int, formula: String, faces: [Int])...) throws -> StableUuidContext {
        try StableUuidContext((1...lines).map(node), [], rolls.map { DiceBinding(statement: node($0.line + 1), formula: $0.formula, faces: $0.faces) })
    }
    private static func context(_ rolls: StableUuidContext?) -> EvaluationContext { EvaluationContext().with { $0.uuids = rolls } }
    private func evaluate(_ source: String, _ rolls: StableUuidContext? = nil) throws -> [LineResult] {
        try SheetEvaluator.evaluate(source, context: DiceTests.context(rolls))
    }

    func testParsesNotation() throws {
        try theory([("10d6+4", "10d6+4", 10), ("2d6+1d8", "2d6+1d8", 3), ("d20", "1d20", 1), ("1D20 + 5", "1d20+5", 1), ("d%", "1d100", 1),
                    ("2d20kh1", "2d20kh1", 2), ("2d20k1", "2d20kh1", 2), ("2d20kl1-1", "2d20kl1-1", 2), ("4d6dl1", "4d6dl1", 4), ("-1d4 + 2", "-1d4+2", 1),
                    ("crit 2d6+3", "crit 2d6+3", 4), ("crit! 2d6+3", "crit! 2d6+3", 2), ("CRIT!2d6", "crit! 2d6", 2), ("Smite crit! 2d8 + 4d8 + 3", "crit! 2d8+4d8+3", 6),
                    ("Fireball 8d6", "8d6", 8), ("Longsword crit 1d8 + 3", "crit 1d8+3", 2)]) { text, notation, dice in
            let formula = try XCTUnwrap(try DiceSyntax.tryParse(text), text)
            XCTAssertEqual(notation, formula.notation, text); XCTAssertEqual(dice, formula.sides.count, text)
        }
    }

    func testRejectsNonDice() throws {
        try theory(["2d6x", "2d", "d", "4", "2d6 3", "4d6d1",
                    "2d20kh3", "4d6dl4", "0d6", "2d0", "1001d6", "1d10001",
                    "I rolled 2d6 today", "2d6*2", "crit", "crit 4", "crit!", "crit2d6", "crit 600d6", "2d6+1000001"]) { text in
            XCTAssertNil(try DiceSyntax.tryParse(text), text)
        }
    }

    func testSheetVariablesShadowCountlessDice() throws {
        XCTAssertNil(try DiceSyntax.tryParse("d6 + 2", NetHashSet.ignoringCase(["d6"])))
        XCTAssertNil(try DiceSyntax.tryParse("d%", NetHashSet.ignoringCase(["d"])))
        XCTAssertNotNil(try DiceSyntax.tryParse("2d6", NetHashSet.ignoringCase(["d6", "d"])))
        let rows = try evaluate("d6 = 4\nd6 + 2\nd = 3\nd%")
        XCTAssertEqual("6", rows[1].display); XCTAssertEqual("3%", rows[3].display)
    }

    func testUnrolledLinesPreviewTheirRangeAndHaveNoValue() throws {
        let rows = try evaluate("10d6+4\nd20\ncrit 2d6+3\n4d6dl1\nx = 2d6\nx + 1\nsum\n\ncrit! 2d6+3")
        XCTAssertEqual("14–64", rows[0].display); XCTAssertNil(rows[0].value); XCTAssertNil(rows[0].error)
        XCTAssertTrue(rows[0].explanation.last!.assumption!.contains("average 39"))
        XCTAssertEqual("1–20", rows[1].pending); XCTAssertTrue(rows[1].explanation.last!.assumption!.contains("average 10.5"))
        // A crit rolls the dice twice (4d6+3); a crunchy crit adds their maximum to one roll (12 + 2d6 + 3).
        XCTAssertEqual("7–27", rows[2].pending); XCTAssertTrue(rows[2].explanation.last!.assumption!.contains("average 17"))
        XCTAssertEqual("17–27", rows[8].pending); XCTAssertTrue(rows[8].explanation.last!.assumption!.contains("average 22"))
        XCTAssertEqual("3–18", rows[3].pending); XCTAssertTrue(rows[3].explanation.last!.assumption!.contains("average ≈12.24"))
        XCTAssertEqual("L5 not rolled yet", rows[5].error)
        XCTAssertNotNil(rows[6].error)
    }

    func testRolledLinesTotalTheirFacesAndFeedDependents() throws {
        let rolls = try DiceTests.rolls(8, (0, "10d6+4", [1, 4, 5, 3, 1, 2, 2, 5, 3, 5]), (1, "2d6+1d8", [6, 4, 3]), (2, "2d20kh1+5", [7, 15]),
                                        (3, "4d6dl1", [5, 2, 5, 2]), (4, "crit! 2d6+3", [3, 6]), (6, "crit 2d6+1d8+3", [3, 6, 1, 2, 5, 4]), (7, "crit 2d20kh1", [4, 9, 12, 2]))
        let rows = try evaluate("10d6+4\n2d6 + 1d8\nattack = 2d20kh1+5\n4d6dl1\ncrit! 2d6+3\nattack * 2\ncrit 2d6 + 1d8 + 3\ncrit 2d20kh1", rolls)
        XCTAssertEqual(["35", "13", "20", "12", "24", "40", "24", "21"], rows.map(\.display))
        XCTAssertTrue(rows[0].explanation.last!.assumption!.contains("[1, 4, 5, 3, 1, 2, 2, 5, 3, 5] + 4"))
        XCTAssertTrue(rows[2].explanation.last!.assumption!.contains("[(7), 15] + 5"))
        XCTAssertTrue(rows[3].explanation.last!.assumption!.contains("[5, 2, 5, (2)]"))
        XCTAssertTrue(rows[4].explanation.last!.assumption!.contains("12 + [3, 6] + 3"))
        // Each group's second roll follows it: 2d6 twice, then 1d8 twice.
        XCTAssertTrue(rows[6].explanation.last!.assumption!.contains("[3, 6] + [1, 2] + [5] + [4] + 3"))
        XCTAssertTrue(rows[7].explanation.last!.assumption!.contains("[(4), 9] + [12, (2)]"))
    }

    func testStaleOrMismatchedRollsAreIgnored() throws {
        // A roll for another formula, or with impossible faces, leaves the line unrolled.
        XCTAssertEqual("2–16", try evaluate("2d8", try DiceTests.rolls(1, (0, "2d6", [3, 4])))[0].display)
        func isArgument(_ error: Error) -> Bool { (error as? CalcError)?.isArgument == true }
        XCTAssertThrowsError(try DiceTests.rolls(1, (0, "2d6", [3, 7]))) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try DiceTests.rolls(1, (0, "2d6", [3]))) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try DiceTests.rolls(1, (0, "2D6", [3, 4]))) { XCTAssertTrue(isArgument($0)) }
    }

    func testCacheFollowsRollChanges() throws {
        let session = SheetEvaluationSession()
        let first = try session.evaluateWithFunctions("2d6\nL1 + 1", .empty, [], context: DiceTests.context(try DiceTests.rolls(2, (0, "2d6", [1, 2]))))
        XCTAssertEqual("4", first.results[1].display)
        let second = try session.evaluateWithFunctions("2d6\nL1 + 1", .empty, [], context: DiceTests.context(try DiceTests.rolls(2, (0, "2d6", [6, 6]))))
        XCTAssertEqual("13", second.results[1].display)
        let unrolled = try session.evaluateWithFunctions("2d6\nL1 + 1", .empty, [], context: DiceTests.context(try DiceTests.rolls(2)))
        XCTAssertEqual("2–12", unrolled.results[0].display)
    }

    func testFacesExposeKeptDiceForPresentation() throws {
        let formula = try XCTUnwrap(try DiceSyntax.tryParse("2d20kh1+1d4"))
        XCTAssertEqual([DieFace(sides: 20, face: 3, kept: false), DieFace(sides: 20, face: 17, kept: true), DieFace(sides: 4, face: 2, kept: true)], try DiceSyntax.faces(formula, [3, 17, 2]))
        // Ties keep the earlier die.
        XCTAssertEqual([true, false], try DiceSyntax.faces(try XCTUnwrap(try DiceSyntax.tryParse("2d6kh1")), [4, 4]).map(\.kept))
    }

    func testIdentityIgnoresLabelsSpacingAndCaseButNotDice() throws {
        XCTAssertEqual(try UuidSyntax.expressionIdentity("2d6 + 3"), try UuidSyntax.expressionIdentity("Hit 2D6+3"))
        XCTAssertEqual(try UuidSyntax.expressionIdentity("dmg = 2d6+3"), try UuidSyntax.expressionIdentity("damage = 2d6+3 // sword"))
        XCTAssertNotEqual(try UuidSyntax.expressionIdentity("2d6+3"), try UuidSyntax.expressionIdentity("2d8+3"))
    }
}
