import XCTest
@testable import CalculatorEngine

final class StoreTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-tests")
    override func tearDown() { TestFiles.delete(directory) }

    func testSavesSourceAndIdentityAcrossRestart() throws {
        var doc: SheetDocument
        do {
            let store = try SheetStore(directory)
            doc = try store.load().document.with { $0.source = "α = 120\nα * 15%"; $0.dark = true }
            try store.save(doc)
            store.dispose()
        }
        let reopened = try SheetStore(directory); defer { reopened.dispose() }
        XCTAssertEqual(doc, try reopened.load().document)
    }
    func testCorruptPrimaryRecoversLastGoodAndPreservesRejectedFile() throws {
        let store = try SheetStore(directory); defer { store.dispose() }
        let original = try store.load().document
        try store.save(original); try store.save(original.with { $0.source = "new" })
        try TestFiles.writeText(TestFiles.path(directory, "sheet.json"), "{bad")
        let loaded = try store.load()
        XCTAssertTrue(loaded.recovered); XCTAssertEqual(original, loaded.document)
        XCTAssertEqual(1, TestFiles.files(directory, "*.corrupt-*").count)
        try store.save(loaded.document)
    }
    func testInvalidPrimaryWithoutBackupIsNeverOverwritten() throws {
        try NetFile.createDirectory(directory)
        let file = TestFiles.path(directory, "sheet.json"); try TestFiles.writeText(file, "{bad")
        let store = try SheetStore(directory); defer { store.dispose() }
        // A damaged primary sends Load to the backup; with no backup, that read's FileNotFoundException (an IOException) surfaces.
        assertThrows(.anyIO, try store.load())
        assertThrows(.invalidOperation, try store.save(SheetDocument(1, UUID(), "", false)))
        XCTAssertEqual("{bad", try TestFiles.readText(file))
    }
    func testFutureSchemaIsNotReplacedWithOlderBackup() throws {
        let store = try SheetStore(directory); defer { store.dispose() }
        let doc = try store.load().document; try store.save(doc); try store.save(doc)
        let file = TestFiles.path(directory, "sheet.json")
        let future = try TestFiles.readText(file).replacingOccurrences(of: "\"Version\":1", with: "\"Version\":3")
        try TestFiles.writeText(file, future)
        assertThrows(.unsupportedVersion, try store.load())
        assertThrows(.invalidOperation, try store.save(doc))
        XCTAssertEqual(future, try TestFiles.readText(file))
    }
    /// Windows: an open FileStream with FileShare.Read makes File.Replace fail. Mac: the holder's shared flock does.
    func testFailedReplacementPreservesPrimary() throws {
        let store = try SheetStore(directory); defer { store.dispose() }
        let original = try store.load().document; try store.save(original)
        let file = TestFiles.path(directory, "sheet.json")
        do {
            let locked = try TestFiles.holdShared(file)
            assertThrows(.anyIO, try store.save(original.with { $0.source = "replacement" }))
            locked.close()
        }
        XCTAssertEqual(original, try store.load().document)
        XCTAssertTrue(TestFiles.files(directory, "*.tmp").isEmpty)
    }
    /// Windows: session.lock is opened with FileShare.None. Mac: an exclusive flock on session.lock.
    func testSecondWriterIsRejected() throws {
        let store = try SheetStore(directory); defer { store.dispose() }
        assertThrows(.io, try SheetStore(directory))
    }
}
