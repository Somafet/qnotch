import XCTest
@testable import CalculatorEngine

final class GeneratedUuidTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-uuid-tests")
    override func tearDown() { TestFiles.delete(directory) }
    private static func context(_ session: GeneratedUuidSession) throws -> EvaluationContext { var c = EvaluationContext(); c.uuids = try session.context; return c }
    private static func values(_ session: GeneratedUuidSession, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let engine = SheetEvaluationSession(); let context = try context(session)
        var evaluated = try engine.evaluateWithFunctions(session.source, .empty, [], context: context)
        if !evaluated.uuidRequests.isEmpty {
            try session.supply(evaluated.uuidRequests, context.uuids!)
            evaluated = try engine.evaluateWithFunctions(session.source, .empty, [], context: try Self.context(session))
        }
        for r in evaluated.results { XCTAssertNil(r.error, file: file, line: line) }
        return try evaluated.results.filter { $0.value?.kind == .text }.map { try $0.value!.text.value }
    }

    func testEditsUndoReplayCopiesAndDocumentIsolation() throws {
        let session = try GeneratedUuidSession("uuid\nuuid\n2+2"); XCTAssertFalse(session.enabled); XCTAssertNil(session.snapshot); XCTAssertNil(try session.context)
        XCTAssertTrue(session.enable()); XCTAssertFalse(session.enable()); let before = try Self.values(session)
        let edit = try session.apply("uuid\nuuid\nuuid\n2+2", 0, 0, 5); let after = try Self.values(session)
        XCTAssertEqual(before, Array(after.dropFirst())); XCTAssertFalse(before.contains(after.first ?? ""))
        try edit.undo(); session.replaySource("uuid\nuuid\n2+2"); XCTAssertEqual(before, try Self.values(session))
        try edit.redo(); session.replaySource("uuid\nuuid\nuuid\n2+2"); XCTAssertEqual(after, try Self.values(session))
        var snapshot = session.snapshot!; let loaded = try GeneratedUuidSession(session.source, snapshot); XCTAssertEqual(after, try Self.values(loaded))
        snapshot.statements[0] = UUID(); XCTAssertEqual(after, try Self.values(loaded))
        let independent = try GeneratedUuidSession(session.source); independent.enable(); XCTAssertFalse(after.contains(try Self.values(independent).first ?? ""))
    }
    func testVersionOneMigratesOnlyWhenGenerationIsUsedAndSurvivesRestart() throws {
        let values: [String], id: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            id = try store.load().workspace.activeSheetId; let doc = try store.open(id).document; XCTAssertEqual(1, doc.version); XCTAssertNil(doc.generatedUuids)
            let session = try GeneratedUuidSession("uuid\nuuid()"); session.enable(); values = try Self.values(session)
            try store.save(doc.with { $0.version = 2; $0.source = session.source; $0.generatedUuids = session.snapshot })
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let saved = try reopened.open(id).document
        XCTAssertEqual(2, saved.version); XCTAssertNotNil(saved.generatedUuids); XCTAssertEqual(values, try Self.values(try GeneratedUuidSession(saved.source, saved.generatedUuids)))
    }
    func testFunctionJournalCommitsUuidStateWithSourceAndFunctions() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }; let ws = try store.load().workspace; let doc = try store.open(ws.activeSheetId).document
        let session = try GeneratedUuidSession("saved()=uuid\nsaved()"); session.enable(); let expected = try Self.values(session)
        let next = doc.with { $0.version = 2; $0.source = session.source; $0.generatedUuids = session.snapshot }
        let update = try FunctionUpdate.prepare(next.source, try store.loadFunctions(), []); try store.saveWithFunctions(next, update)
        XCTAssertEqual(2, try JSONNode.parse(Data(try TestFiles.readBytes(TestFiles.path(directory, "functions.json")))).property("Version").int())
        let loaded = try store.open(doc.id).document
        var context = EvaluationContext(); context.uuids = try GeneratedUuidSession(loaded.source, loaded.generatedUuids).context
        let result = try SheetEvaluationSession().evaluateWithFunctions(loaded.source, try store.loadFunctions(), try store.loadFunctionReceipts(doc.id), context: context)
        XCTAssertNil(result.results[1].error); XCTAssertEqual(expected.first, result.results[1].display)
    }
    func testCorruptionRecoversPairedStateAndFutureSchemaIsPreserved() throws {
        let store = try SheetStore(directory); defer { store.dispose() }; let original = try store.load().document; let session = try GeneratedUuidSession("uuid"); session.enable()
        _ = try Self.values(session); let doc = original.with { $0.version = 2; $0.source = session.source; $0.generatedUuids = session.snapshot }; try store.save(doc); try store.save(doc.with { $0.dark = true })
        let path = TestFiles.path(directory, "sheet.json"); try TestFiles.writeText(path, "{bad"); let recovered = try store.load(); XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(try Self.values(session), try Self.values(try GeneratedUuidSession(recovered.document.source, recovered.document.generatedUuids)))
        let future = doc.with { $0.version = 3 }.json; try TestFiles.writeText(path, future); assertThrows(.unsupportedVersion, try store.load()); XCTAssertEqual(future, try TestFiles.readText(path))
    }
    func testBadMetadataCannotOverwriteAValidSheet() throws {
        let store = try SheetStore(directory); defer { store.dispose() }; let doc = try store.load().document; try store.save(doc); let path = TestFiles.path(directory, "sheet.json"); let before = try TestFiles.readText(path)
        assertThrows(.invalidData, try store.save(doc.with { $0.version = 2 }))
        assertThrows(.invalidData, try store.save(doc.with { $0.generatedUuids = GeneratedUuidState(1, [UUID()], []) }))
        assertThrows(.invalidData, try store.save(doc.with { $0.version = 2; $0.generatedUuids = GeneratedUuidState(1, [.netEmpty], []) })); XCTAssertEqual(before, try TestFiles.readText(path))
    }
    func testMaximumDocumentLinesRemainBoundedThroughUndo() throws {
        let session = try GeneratedUuidSession("uuid"); session.enable(); let before = try Self.values(session)
        let source = String(repeating: "\n", count: 10000) + "uuid"; let edit = try session.apply(source, 0, 0, 10000); XCTAssertEqual(10000, session.snapshot!.statements.count)
        try GeneratedUuidSession.validate(source, session.snapshot!); try edit.undo(); session.replaySource("uuid"); XCTAssertEqual(before, try Self.values(session))
    }
    func testMaximumUnicodeSourceAndMetadataCanBeSavedAndReopened() throws {
        let source = String(repeating: "中", count: 190001) + String(repeating: "\n", count: 9999); let ids = (0..<10000).map { _ in UUID() }
        let values = (0..<1024).map { UuidBinding(statement: ids[0], site: String(repeating: "中", count: 59) + String(format: "%03x", $0), value: UUID()) }
        let store = try SheetStore(directory); defer { store.dispose() }; let original = try store.load().document
        try store.save(original.with { $0.version = 2; $0.source = source; $0.generatedUuids = GeneratedUuidState(1, ids, values) })
        XCTAssertEqual(source, try store.load().document.source); XCTAssertEqual(1024, try store.load().document.generatedUuids!.bindings.count)
        XCTAssertTrue((2_000_001...Int64(SheetStore.maxDocumentBytes)).contains(NetFile.info(TestFiles.path(directory, "sheet.json")).length))
    }
    func testStaleRequestsAndMismatchedEditsCannotChangeBindings() throws {
        let session = try GeneratedUuidSession("uuid\n2"); session.enable(); let observed = try session.context!
        var context = EvaluationContext(); context.uuids = observed
        let requests = try SheetEvaluationSession().evaluateWithFunctions(session.source, .empty, [], context: context).uuidRequests
        try session.apply(" uuid\n2", 0, 0, 1)
        assertThrows(.invalidOperation, try session.supply(requests, observed)); XCTAssertTrue(session.snapshot!.bindings.isEmpty)
        let current = session.source; assertThrows(.argument, try session.apply(" uuid\n3", 0, 1, 1)); XCTAssertEqual(current, session.source)
    }
    func testUuidFunctionCatalogDoesNotDowngradeAndFutureVersionIsPreserved() throws {
        let path = TestFiles.path(directory, "functions.json")
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            let ws = try store.load().workspace; let doc = try store.open(ws.activeSheetId).document
            var source = "saved()=uuid"; var update = try FunctionUpdate.prepare(source, try store.loadFunctions(), []); try store.saveWithFunctions(doc.with { $0.source = source }, update)
            source = "forget saved"; update = try FunctionUpdate.prepare(source, try store.loadFunctions(), try store.loadFunctionReceipts(doc.id)); try store.saveWithFunctions(doc.with { $0.source = source }, update)
            XCTAssertEqual(2, try JSONNode.parse(Data(try TestFiles.readBytes(path))).property("Version").int())
        }
        let future = "{\"Version\":\(FunctionLibrary.latestCatalogVersion + 1),\"Definitions\":[]}"; try TestFiles.writeText(path, future)
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); assertThrows(.unsupportedVersion, try reopened.loadFunctions()); XCTAssertEqual(future, try TestFiles.readText(path))
    }
    func testVersionOneUuidCatalogMigratesWithoutRecoveringAwayDefinitions() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }; _ = try store.load(); let path = TestFiles.path(directory, "functions.json")
        let text = FunctionCatalog(1, [FunctionDefinition(name: "saved", parameters: [], body: "uuid")]).json; try TestFiles.writeText(path, text); try TestFiles.writeText(path + ".bak", FunctionCatalog(1, []).json)
        let definitions = try store.loadFunctions().definitions; XCTAssertEqual(1, definitions.count); XCTAssertEqual("saved", definitions.first?.name)
        XCTAssertEqual(2, try JSONNode.parse(Data(try TestFiles.readBytes(path))).property("Version").int())
        XCTAssertEqual(text, try TestFiles.readText(path + ".bak")); XCTAssertFalse(store.functionsRecovered); XCTAssertTrue(TestFiles.files(directory, "*.corrupt-*").isEmpty)
    }
}
