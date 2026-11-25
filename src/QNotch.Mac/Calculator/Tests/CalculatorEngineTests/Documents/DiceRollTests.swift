import XCTest
@testable import CalculatorEngine

final class DiceRollTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-dice-tests")
    override func tearDown() { TestFiles.delete(directory) }
    private static func shown(_ session: GeneratedUuidSession) throws -> [String] {
        var context = EvaluationContext(); context.uuids = try session.context
        return try SheetEvaluator.evaluate(session.source, context: context).map(\.display)
    }

    func testEnterRollsOnceAndAgainRerollsWithinRange() throws {
        let session = try GeneratedUuidSession("10d6+4\nprose\n2+2")
        XCTAssertNil(try session.roll(1, false)); XCTAssertNil(try session.roll(2, true)); XCTAssertFalse(session.enabled)
        let first = try XCTUnwrap(try session.roll(0, false))
        XCTAssertTrue(session.enabled); XCTAssertEqual("10d6+4", first.formula); XCTAssertEqual(10, first.faces.count)
        for face in first.faces { XCTAssertTrue((1...6).contains(face)) }
        XCTAssertNil(try session.roll(0, false))
        XCTAssertEqual(String(first.faces.reduce(0, +) + 4), try Self.shown(session)[0])
        var faces = Set<String>()
        for _ in 0..<40 { faces.insert(try session.roll(0, true)!.faces.map(String.init).joined(separator: ",")) }
        XCTAssertTrue(faces.count > 1)
        XCTAssertEqual(String(session.rolled(0)!.faces.reduce(0, +) + 4), try Self.shown(session)[0])
    }
    func testRollFollowsItsStatementUntilTheDiceChange() throws {
        let session = try GeneratedUuidSession("2d6+3")
        let roll = try XCTUnwrap(try session.roll(0, false))
        // Enter at the end of the line, then a line inserted above: the roll moves with its statement.
        try session.apply("2d6+3\n", 5, 0, 1); try session.apply("x = 1\n2d6+3\n", 0, 0, 6)
        XCTAssertEqual(roll.faces, session.rolled(1)?.faces)
        // Labels and spacing keep it.
        try session.apply("x = 1\nHit 2d6 + 3\n")
        XCTAssertEqual(roll.faces, session.rolled(1)?.faces)
        // Changing the dice clears it; undo restores the earlier roll.
        let edit = try session.apply("x = 1\nHit 2d8 + 3\n")
        XCTAssertNil(session.rolled(1))
        XCTAssertEqual("5–19", try Self.shown(session)[1])
        try edit.undo(); session.replaySource("x = 1\nHit 2d6 + 3\n")
        XCTAssertEqual(roll.faces, session.rolled(1)?.faces)
    }
    func testRollsPersistAsStateVersionTwo() throws {
        let id: UUID, faces: [Int]
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            id = try store.load().workspace.activeSheetId; let doc = try store.open(id).document
            let session = try GeneratedUuidSession("uuid\ndmg = 3d8+2\ndmg * 2")
            faces = try XCTUnwrap(try session.roll(1, false)).faces
            let snapshot = session.snapshot!
            XCTAssertEqual(2, snapshot.version); XCTAssertEqual(1, snapshot.dice?.count)
            try store.save(doc.with { $0.version = 2; $0.source = session.source; $0.generatedUuids = snapshot })
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        let saved = try reopened.open(id).document
        let loaded = try GeneratedUuidSession(saved.source, saved.generatedUuids)
        XCTAssertEqual(faces, loaded.rolled(1)?.faces)
        XCTAssertEqual(String((faces.reduce(0, +) + 2) * 2), try Self.shown(loaded)[2])
    }
    func testCrunchyCritRollsSavedAsCritWaitForANewRoll() throws {
        // Before 18 November 2026 `crit 2d6+3` was the crunchy critical: two stored faces. It now means 4d6+3.
        let session = try GeneratedUuidSession("crit 2d6+3\n1d8")
        let kept = try XCTUnwrap(try session.roll(1, false))
        let id = session.snapshot!.statements[0]
        let old = session.snapshot!.with { $0.dice = [DiceBinding(statement: id, formula: "crit 2d6+3", faces: [3, 6]), kept] }
        try GeneratedUuidSession.validate(session.source, old)
        let loaded = try GeneratedUuidSession(session.source, old)
        XCTAssertNil(loaded.rolled(0)); XCTAssertEqual(kept.faces, loaded.rolled(1)?.faces)
        XCTAssertEqual("7–27", try Self.shown(loaded)[0])
        let crit = try XCTUnwrap(try loaded.roll(0, false))
        XCTAssertEqual(4, crit.faces.count)
        XCTAssertEqual(String(crit.faces.reduce(0, +) + 3), try Self.shown(loaded)[0])
        // Rewriting the line as `crit!` makes the crunchy critical: 12 + 2d6 + 3.
        try loaded.apply("crit! 2d6+3\n1d8")
        let crunchy = try XCTUnwrap(try loaded.roll(0, false))
        XCTAssertEqual(2, crunchy.faces.count)
        XCTAssertEqual(String(12 + crunchy.faces.reduce(0, +) + 3), try Self.shown(loaded)[0])
    }
    func testStateVersionMustMatchItsRolls() throws {
        let session = try GeneratedUuidSession("2d6"); try session.roll(0, false)
        let state = try XCTUnwrap(session.snapshot)
        try GeneratedUuidSession.validate("2d6", state)
        // A version-1 reader refuses rolls instead of discarding them; a version-2 claim without rolls is invalid.
        assertThrows(.invalidData, try GeneratedUuidSession.validate("2d6", state.with { $0.version = 1 }))
        assertThrows(.invalidData, try GeneratedUuidSession.validate("2d6", state.with { $0.dice = nil }))
        assertThrows(.unsupportedVersion, try GeneratedUuidSession.validate("2d6", state.with { $0.version = 3 }))
        // A roll that no longer fits its formula is dropped on load, never misread; the source and other rolls stay.
        guard let roll = state.dice?.first else { return XCTFail("no roll") }
        let impossible = state.with { $0.dice = [DiceBinding(statement: roll.statement, formula: roll.formula, faces: [9, 1])] }
        try GeneratedUuidSession.validate("2d6", impossible)
        XCTAssertNil(try GeneratedUuidSession("2d6", impossible).rolled(0))
        // C# sets Faces to null; a Swift DiceBinding cannot hold one, so the decoded form of that JSON is used.
        let nullFaces = try GeneratedUuidState.decode(try NetJSON.parseObject(Array(state.json.replacingOccurrences(of: "\"Faces\":[", with: "\"Faces\":null,\"X\":[").utf8))!)
        assertThrows(.invalidData, try GeneratedUuidSession.validate("2d6", nullFaces))
        // Deleting every rolled line returns to UUID-only state.
        try session.apply("")
        XCTAssertEqual(1, session.snapshot!.version); XCTAssertNil(session.snapshot!.dice)
    }
    func testRollAllAndAdoptRollsServeOneShotTotals() throws {
        let sheet = try GeneratedUuidSession("2d6\nd20+1\nprose"); sheet.enable()
        XCTAssertEqual(2, try sheet.rollAll()); XCTAssertEqual(0, try sheet.rollAll())
        let total = try GeneratedUuidSession("2d6\nd20+1\nprose\n\nL1\nL2\nsum"); total.enable(); try total.adoptRolls(sheet)
        XCTAssertEqual(sheet.rolled(0)?.faces, total.rolled(0)?.faces); XCTAssertEqual(sheet.rolled(1)?.faces, total.rolled(1)?.faces)
        let shown = try Self.shown(total)
        XCTAssertEqual(String((Int(shown[0]) ?? -1) + (Int(shown[1]) ?? -1)), shown.last)
    }
}
