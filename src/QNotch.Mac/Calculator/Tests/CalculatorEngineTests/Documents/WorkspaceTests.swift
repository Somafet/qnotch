import XCTest
@testable import CalculatorEngine

final class WorkspaceTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-tests")
    private var catalog: String { TestFiles.path(directory, "workspace.json") }
    private func body(_ id: UUID) -> String { TestFiles.path(directory, "sheets", id.netN + ".json") }
    override func tearDown() { TestFiles.delete(directory) }

    func testCreateRenameSwitchDeleteAndRestart() throws {
        let first: UUID, second: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            first = try store.load().workspace.activeSheetId
            let state = try store.create("Travel", "α = 20\nα*3"); second = state.activeSheetId
            try store.rename(second, "Trips")
            let sheet = try store.open(second).document
            try store.save(sheet.with { $0.source = "20*4" })
            try store.setDark(true); try store.select(first)
        }
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            var state = try store.load().workspace
            XCTAssertTrue(state.dark); XCTAssertEqual(first, state.activeSheetId)
            XCTAssertEqual("Trips", state.sheets[1].name)
            XCTAssertEqual("20*4", try store.open(second).document.source)
            state = try store.delete(first)
            XCTAssertEqual(second, state.activeSheetId); XCTAssertEqual(1, state.sheets.count)
            assertThrows(.invalidOperation, try store.delete(second))
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        XCTAssertEqual(second, try reopened.load().workspace.activeSheetId)
    }
    func testLegacyMigrationPreservesIdentityTextAppearanceAndOriginalBytes() throws {
        let original: SheetDocument
        do {
            let legacy = try SheetStore(directory); defer { legacy.dispose() }
            original = try legacy.load().document.with { $0.source = "// 😀 日本語\n120*15%"; $0.dark = true }
            try legacy.save(original)
        }
        let bytes = try TestFiles.readBytes(TestFiles.path(directory, "sheet.json"))
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            let result = try store.load()
            XCTAssertTrue(result.migrated); XCTAssertTrue(result.workspace.dark)
            XCTAssertEqual(original.id, result.workspace.activeSheetId)
            XCTAssertEqual(original, try store.open(original.id).document)
        }
        XCTAssertEqual(bytes, try TestFiles.readBytes(TestFiles.path(directory, "sheet.json")))
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        XCTAssertFalse(try reopened.load().migrated)
    }
    func testMigrationRetriesAfterCatalogCommitFailure() throws {
        do { let legacy = try SheetStore(directory); try legacy.save(try legacy.load().document.with { $0.source = "keep" }); legacy.dispose() }
        try NetFile.createDirectory(catalog) // prevents committing catalog after body was written
        do { let store = try WorkspaceStore(directory); assertThrows(.anyIO, try store.load()); store.dispose() }
        try NetFile.deleteDirectory(catalog)
        let retry = try WorkspaceStore(directory); defer { retry.dispose() }
        let loaded = try retry.load()
        XCTAssertTrue(loaded.migrated)
        XCTAssertEqual("keep", try retry.open(loaded.workspace.activeSheetId).document.source)
    }
    func testLazyCatalogDoesNotOpenUnselectedBodies() throws {
        let first: UUID, second: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            first = try store.load().workspace.activeSheetId
            second = try store.create("Broken").activeSheetId; try store.select(first)
        }
        try TestFiles.writeText(body(second), "{bad")
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        XCTAssertEqual(2, try reopened.load().workspace.sheets.count)
        XCTAssertNotNil(try reopened.open(first).document)
        assertThrows(.anyIO, try reopened.open(second))
        assertThrows(.invalidOperation, try reopened.save(SheetDocument(1, second, "overwrite", false)))
    }
    /// Windows: the catalog held open with FileShare.Read blocks File.Replace. Mac: the holder's shared flock blocks the replacement.
    func testFailedMetadataChangeKeepsExistingCatalogAndState() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        let first = try store.load().workspace.activeSheetId
        do {
            let locked = try TestFiles.holdShared(catalog)
            assertThrows(.anyIO, try store.create("New", "do not claim creation"))
            XCTAssertEqual(1, TestFiles.files(TestFiles.path(directory, "sheets"), "*.json").count)
            assertThrows(.anyIO, try store.rename(first, "Not saved"))
            locked.close()
        }
        let next = try store.select(first)
        XCTAssertEqual(1, next.sheets.count); XCTAssertEqual("Sheet", next.sheets[0].name)
        XCTAssertEqual(1, TestFiles.files(TestFiles.path(directory, "sheets"), "*.json").count)
    }
    func testCatalogRecoveryRetainsBodiesNeededByBackup() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        let first = try store.load().workspace.activeSheetId
        let second = try store.create("Second").activeSheetId
        try store.delete(first)
        XCTAssertTrue(TestFiles.exists(body(first)))
        try TestFiles.writeText(catalog, "{bad")
        let recovered = try store.load()
        XCTAssertTrue(recovered.recovered); XCTAssertEqual(2, recovered.workspace.sheets.count)
        XCTAssertNotNil(try store.open(first).document); XCTAssertNotNil(try store.open(second).document)
    }
    func testFutureCatalogAndFutureSheetCannotBeOverwritten() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        let first = try store.load().workspace.activeSheetId
        _ = try store.open(first)
        let futureBody = try TestFiles.readText(body(first)).replacingOccurrences(of: "\"Version\":1", with: "\"Version\":3")
        try TestFiles.writeText(body(first), futureBody)
        assertThrows(.unsupportedVersion, try store.open(first))
        assertThrows(.invalidOperation, try store.save(SheetDocument(1, first, "overwrite", false)))
        try TestFiles.writeText(catalog, try TestFiles.readText(catalog).replacingOccurrences(of: "\"Version\":1", with: "\"Version\":2"))
        assertThrows(.unsupportedVersion, try store.load())
        assertThrows(.invalidOperation, try store.create("no"))
        XCTAssertEqual(futureBody, try TestFiles.readText(body(first)))
    }
    func testCatalogValidationAndResultIsolation() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        var state = try store.load().workspace
        let id = state.activeSheetId
        state.sheets[0] = SheetEntry(UUID(), "tamper")
        XCTAssertEqual(id, try store.select(id).sheets[0].id)
        assertThrows(.invalidData, try store.rename(id, " "))
        assertThrows(.invalidData, try store.rename(id, "bad\nname"))
        assertThrows(.invalidData, try store.rename(id, String(repeating: "x", count: 81)))
        let invalid = WorkspaceDocument(1, id, false, [SheetEntry(id, "one"), SheetEntry(id, "two")])
        try TestFiles.writeText(catalog, invalid.json)
        try NetFile.delete(catalog + ".bak")
        assertThrows(.anyIO, try store.load())
    }
    func testFullUnicodeCatalogRoundtripsAndRejectsOverflow() throws {
        try NetFile.createDirectory(directory)
        let entries = (0..<WorkspaceStore.maxSheets).map { _ in SheetEntry(UUID(), String(repeating: "日", count: WorkspaceStore.maxNameLength)) }
        try TestFiles.writeText(catalog, WorkspaceDocument(1, entries[0].id, false, entries).json)
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        XCTAssertEqual(256, try store.load().workspace.sheets.count)
        assertThrows(.invalidData, try store.create("overflow"))
    }
    /// Windows: session.lock is opened with FileShare.None. Mac: an exclusive flock on session.lock, shared by both store kinds.
    func testCatalogAndLegacyStoreShareExclusiveOwnership() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        assertThrows(.io, try WorkspaceStore(directory))
        assertThrows(.io, try SheetStore(directory))
    }
}
