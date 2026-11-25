import XCTest
@testable import CalculatorEngine

final class VersionHistoryTests: XCTestCase {
    private var directory = TestFiles.temporary("Calc-tests")
    private static let start = DateTimeOffset(2026, 10, 31, 12, 0, 0)
    private let start = VersionHistoryTests.start
    override func tearDown() { TestFiles.delete(directory) }

    private func folder(_ id: UUID) -> String { TestFiles.path(directory, "versions", id.netN) }
    private func body(_ id: UUID) -> String { TestFiles.path(directory, "sheets", id.netN + ".json") }
    private func versionFiles(_ id: UUID) -> [String] { TestFiles.directoryExists(folder(id)) ? TestFiles.files(folder(id), "*.json") : [] }
    private func open() throws -> (store: WorkspaceStore, id: UUID) {
        let store = try WorkspaceStore(directory); let id = try store.load().workspace.activeSheetId; _ = try store.open(id)
        return (store, id)
    }
    private static func edit(_ store: WorkspaceStore, _ id: UUID, _ source: String) throws { try store.save(try store.open(id).document.with { $0.source = source }) }
    private static func editWithFunctions(_ store: WorkspaceStore, _ id: UUID, _ source: String) throws {
        let sheet = try store.open(id).document.with { $0.source = source }
        try store.saveWithFunctions(sheet, try FunctionUpdate.prepare(source, try store.loadFunctions(), try store.loadFunctionReceipts(id)))
    }
    private static func sources(_ store: WorkspaceStore, _ id: UUID) throws -> [String] { try store.loadVersions(id).versions.map(\.sheet.source) }
    private static func versionOf(_ store: WorkspaceStore, _ id: UUID, _ source: String) throws -> SheetVersion {
        let matches = try store.loadVersions(id).versions.filter { $0.sheet.source.ordinalEquals(source) }
        guard matches.count == 1 else { throw CalcError.invalidOperation("Expected one version of " + source) }
        return matches[0]
    }
    private static func run(_ store: WorkspaceStore, _ line: String) throws -> String {
        try SheetEvaluationSession().evaluateWithFunctions(line, try store.loadFunctions(), []).results[0].display
    }

    func testCapturesOnlyWhenSavedContentDiffersAndFiveMinutesPassed() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a")
        XCTAssertTrue(try store.captureVersion(id, start))
        try Self.edit(store, id, "b")
        XCTAssertFalse(try store.captureVersion(id, start.adding(minutes: 5).addingTicks(-1)))
        XCTAssertEqual(["a"], try Self.sources(store, id))
        XCTAssertTrue(try store.captureVersion(id, start.adding(minutes: 5)))
        XCTAssertEqual(["b", "a"], try Self.sources(store, id))
    }
    func testForcedCaptureSkipsTheIntervalButNeverStoresIdenticalContent() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a"); try store.captureVersion(id, start)
        XCTAssertTrue(try store.captureVersion(id, start.adding(seconds: 1), force: true))
        XCTAssertTrue(try store.captureVersion(id, start.adding(hours: 1)))
        XCTAssertEqual(1, versionFiles(id).count)
        try Self.edit(store, id, "b"); XCTAssertTrue(try store.captureVersion(id, start.adding(hours: 1).adding(seconds: 1), force: true))
        XCTAssertEqual(["b", "a"], try Self.sources(store, id))
    }
    func testRepeatedContentReturnsToTheTopInsteadOfBeingStoredTwice() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a"); try store.captureVersion(id, start)
        try Self.edit(store, id, "b"); try store.captureVersion(id, start.adding(hours: 1))
        try Self.edit(store, id, "a"); try store.captureVersion(id, start.adding(hours: 2))
        XCTAssertEqual(["a", "b"], try Self.sources(store, id))
        XCTAssertEqual(2, versionFiles(id).count)
        XCTAssertEqual(start.adding(hours: 2), try store.loadVersions(id).versions[0].capturedAt)
    }
    func testAnEmptySheetWithoutHistoryHasNothingToPreserve() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "")
        XCTAssertTrue(try store.captureVersion(id, start, force: true))
        XCTAssertFalse(TestFiles.directoryExists(folder(id)))
        XCTAssertTrue(try store.loadVersions(id).versions.isEmpty)
    }
    func testTimestampsComeFromTheCallerAndStayOrderedWhenTheClockMovesBack() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a"); try store.captureVersion(id, start)
        try Self.edit(store, id, "b")
        XCTAssertFalse(try store.captureVersion(id, start.adding(days: -1)))
        XCTAssertTrue(try store.captureVersion(id, start.adding(days: -1), force: true))
        let versions = try store.loadVersions(id).versions
        XCTAssertEqual(["b", "a"], versions.map(\.sheet.source))
        XCTAssertEqual(start.addingTicks(1), versions[0].capturedAt)
        XCTAssertEqual(64, versions[0].hash.netLength)
    }
    func testCountBoundDropsTheOldestWhenEveryDayHoldsOneVersion() throws {
        let (store, id) = try open(); defer { store.dispose() }
        for day in 0..<(WorkspaceStore.maxVersions + 1) { try Self.edit(store, id, "day \(day)"); try store.captureVersion(id, start.adding(days: day)) }
        let all = try Self.sources(store, id)
        XCTAssertEqual(WorkspaceStore.maxVersions, all.count)
        XCTAssertEqual("day 64", all.first); XCTAssertEqual("day 1", all.last)
    }
    func testCountBoundThinsOlderDaysBeforeDroppingAnyDayEntirely() throws {
        let (store, id) = try open(); defer { store.dispose() }
        // 40 versions on the first day, then 40 on the next: 16 over the bound, all from the older day.
        for i in 0..<40 { try Self.edit(store, id, "first \(i)"); try store.captureVersion(id, start.adding(minutes: 5 * i)) }
        for i in 0..<40 { try Self.edit(store, id, "second \(i)"); try store.captureVersion(id, start.adding(days: 1).adding(minutes: 5 * i)) }
        let all = try Self.sources(store, id)
        XCTAssertEqual(WorkspaceStore.maxVersions, all.count)
        XCTAssertEqual((0..<40).reversed().map { "second \($0)" }, Array(all.prefix(40)))
        XCTAssertEqual((16..<40).reversed().map { "first \($0)" }, Array(all.dropFirst(40)))
    }
    func testByteBoundKeepsTheNewestAndStaysWithinEightMebibytes() throws {
        let (store, id) = try open(); defer { store.dispose() }
        // Non-ASCII source is escaped to six JSON bytes per character, so each copy takes about 1.1 MB.
        for i in 0..<12 { try Self.edit(store, id, "\(i)" + String(repeating: "é", count: 190_000)); try store.captureVersion(id, start.adding(days: i)) }
        let bytes = versionFiles(id).reduce(Int64(0)) { $0 + NetFile.info($1).length }
        XCTAssertTrue((1...WorkspaceStore.maxVersionBytes).contains(bytes), "\(bytes)")
        XCTAssertTrue((2...11).contains(versionFiles(id).count))
        XCTAssertTrue(try store.loadVersions(id).versions[0].sheet.source.hasPrefix("11"))
    }
    func testRestoreCapturesCurrentContentFirstAndCanBeUndoneByRestoringAgain() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "old"); try store.captureVersion(id, start)
        try Self.edit(store, id, "current")
        let versions = try store.loadVersions(id).versions
        XCTAssertEqual(1, versions.count)
        XCTAssertEqual("current", try store.open(id).document.source) // Listing a version changes nothing.
        let restored = try store.restoreVersion(id, versions[0].hash, start.adding(minutes: 1))
        XCTAssertEqual("old", restored.document.source); XCTAssertEqual("old", try store.open(id).document.source)
        XCTAssertEqual(["current", "old"], try Self.sources(store, id))
        let back = try store.restoreVersion(id, try Self.versionOf(store, id, "current").hash, start.adding(minutes: 2))
        XCTAssertEqual("current", back.document.source); XCTAssertEqual("current", try store.open(id).document.source)
        XCTAssertTrue(try Self.sources(store, id).contains("old"))
        assertThrows(.invalidData, try store.restoreVersion(id, String(repeating: "0", count: 64), start.adding(minutes: 3)))
    }
    func testRestoreSurvivesRestartAndKeepsWorkspaceSchemaUntouched() throws {
        let catalog: String
        let (store, id) = try open()
        do {
            defer { store.dispose() }
            catalog = try TestFiles.readText(TestFiles.path(directory, "workspace.json"))
            try Self.edit(store, id, "old"); try store.captureVersion(id, start)
            try Self.edit(store, id, "current")
            _ = try store.restoreVersion(id, try Self.versionOf(store, id, "old").hash, start.adding(minutes: 1))
        }
        XCTAssertEqual(catalog, try TestFiles.readText(TestFiles.path(directory, "workspace.json")))
        let (reopened, _) = try open(); defer { reopened.dispose() }
        XCTAssertEqual("old", try reopened.open(id).document.source)
        XCTAssertEqual(["current", "old"], try Self.sources(reopened, id))
    }
    func testVersionsKeepTheCompleteDocumentIncludingUuidBindings() throws {
        let (store, id) = try open(); defer { store.dispose() }
        let session = try GeneratedUuidSession("id=uuid\nid"); session.enable()
        let engine = SheetEvaluationSession(); var context = EvaluationContext(); context.uuids = try session.context
        try session.supply(try engine.evaluateWithFunctions(session.source, .empty, [], context: context).uuidRequests, context.uuids!)
        let document = try store.open(id).document.with { $0.version = 2; $0.source = session.source; $0.generatedUuids = session.snapshot }
        try store.save(document); try store.captureVersion(id, start)
        try store.save(SheetDocument(1, id, "plain", false))
        let restored = try store.restoreVersion(id, try store.loadVersions(id).versions.last!.hash, start.adding(minutes: 1)).document
        XCTAssertEqual(2, restored.version); XCTAssertFalse(restored.generatedUuids!.bindings.isEmpty)
        XCTAssertEqual(document.generatedUuids!.statements, restored.generatedUuids!.statements)
        XCTAssertEqual(document.generatedUuids!.bindings, restored.generatedUuids!.bindings)
        XCTAssertEqual(restored.generatedUuids!.bindings, try store.open(id).document.generatedUuids!.bindings)
    }
    func testContentThatDiffersOnlyInUuidBindingsIsADistinctVersion() throws {
        let (store, id) = try open(); defer { store.dispose() }
        func bound() -> GeneratedUuidState { GeneratedUuidState(1, [UUID()], []) }
        let document = try store.open(id).document.with { $0.version = 2; $0.source = "uuid" }
        try store.save(document.with { $0.generatedUuids = bound() }); try store.captureVersion(id, start)
        try store.save(document.with { $0.generatedUuids = bound() }); try store.captureVersion(id, start.adding(minutes: 5))
        XCTAssertEqual(2, versionFiles(id).count)
    }
    func testRestoringARemovedDefinitionDoesNotOverrideANewerOne() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.editWithFunctions(store, id, "f(x)=x+1"); try store.captureVersion(id, start)
        let other = try store.create("Other").activeSheetId
        try Self.editWithFunctions(store, other, "f(x)=x+2")
        try Self.editWithFunctions(store, id, "1+1")
        XCTAssertTrue(try store.loadFunctionReceipts(id).isEmpty)
        let fingerprint = try store.loadFunctions().fingerprint
        let restored = try store.restoreVersion(id, try Self.versionOf(store, id, "f(x)=x+1").hash, start.adding(minutes: 1))
        XCTAssertEqual("f(x)=x+1", restored.document.source)
        XCTAssertEqual(fingerprint, try store.loadFunctions().fingerprint)
        XCTAssertFalse(try FunctionUpdate.prepare(restored.document.source, try store.loadFunctions(), try store.loadFunctionReceipts(id)).hasChanges)
        XCTAssertTrue(try FunctionUpdate.prepare(restored.document.source, try store.loadFunctions(), []).hasChanges) // Without the receipt this source would re-apply.
        XCTAssertEqual("12", try Self.run(store, "f(10)"))
    }
    func testRestoringARemovedForgetDoesNotDeleteALaterDefinition() throws {
        let (store, id) = try open(); defer { store.dispose() }
        let other = try store.create("Other").activeSheetId
        try Self.editWithFunctions(store, other, "f(x)=x+1")
        try Self.editWithFunctions(store, id, "forget f"); try store.captureVersion(id, start)
        try Self.editWithFunctions(store, id, "1+1")
        try Self.editWithFunctions(store, other, "f(x)=x+5")
        let restored = try store.restoreVersion(id, try Self.versionOf(store, id, "forget f").hash, start.adding(minutes: 1))
        XCTAssertFalse(try FunctionUpdate.prepare(restored.document.source, try store.loadFunctions(), restored.functionReceipts!).hasChanges)
        XCTAssertEqual("15", try Self.run(store, "f(10)"))
    }
    func testRestoringAroundADefinitionNeitherLosesNorReappliesIt() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "plain"); try store.captureVersion(id, start)
        try Self.editWithFunctions(store, id, "g(x)=x+1")
        _ = try store.restoreVersion(id, try Self.versionOf(store, id, "plain").hash, start.adding(minutes: 1))
        XCTAssertEqual("2", try Self.run(store, "g(1)")) // Removing a directive never removes its function.
        XCTAssertTrue(try store.loadFunctionReceipts(id).isEmpty)
        let other = try store.create("Other").activeSheetId
        try Self.editWithFunctions(store, other, "g(x)=x+9")
        let back = try store.restoreVersion(id, try Self.versionOf(store, id, "g(x)=x+1").hash, start.adding(minutes: 2))
        XCTAssertEqual(1, back.functionReceipts!.count)
        XCTAssertFalse(try FunctionUpdate.prepare(back.document.source, try store.loadFunctions(), try store.loadFunctionReceipts(id)).hasChanges)
        XCTAssertEqual("10", try Self.run(store, "g(1)"))
    }
    func testADirectiveNeverAppliedAtCaptureStaysPendingAfterRestore() throws {
        let (store, id) = try open(); defer { store.dispose() }
        let blocked = "h(x)=missing(x)"
        try Self.editWithFunctions(store, id, blocked); try store.captureVersion(id, start)
        try Self.edit(store, id, "1+1")
        let restored = try store.restoreVersion(id, try Self.versionOf(store, id, blocked).hash, start.adding(minutes: 1))
        XCTAssertTrue(restored.functionReceipts!.isEmpty)
        XCTAssertTrue(try store.loadFunctions().definitions.isEmpty)
    }
    func testUnreadableVersionsAreSkippedAndReportedWithoutTouchingTheSheet() throws {
        let base = directory
        try theory(["{bad", "", "{\"Version\":2}", "null"]) { corruption in
            directory = TestFiles.path(base, UUID().netN)
            let (store, id) = try open(); defer { store.dispose() }
            try Self.edit(store, id, "a"); try store.captureVersion(id, start)
            try Self.edit(store, id, "b"); try store.captureVersion(id, start.adding(hours: 1))
            try Self.edit(store, id, "current")
            let oldest = versionFiles(id).sorted { String.ordinalCompare($0, $1) < 0 }.first!
            let hash = try Self.versionOf(store, id, "a").hash
            try TestFiles.writeText(oldest, corruption)
            let history = try store.loadVersions(id)
            XCTAssertEqual(1, history.skipped); XCTAssertEqual(["b"], history.versions.map(\.sheet.source))
            do { _ = try store.restoreVersion(id, hash, start.adding(hours: 2)); XCTFail("restore must be refused") }
            catch { XCTAssertTrue(error.isIOException || error.isInvalidData || error.isJsonError, "\(error)") } // Failures the host reports in its save state.
            XCTAssertEqual("current", try store.open(id).document.source)
            XCTAssertEqual("b", try store.loadVersions(id).versions[0].sheet.source) // A refused restore captures nothing.
        }
        directory = base
    }
    func testAlteredOrMisfiledContentIsNeverTrusted() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "secret"); try store.captureVersion(id, start)
        let file = versionFiles(id)[0]
        try TestFiles.writeText(file, try TestFiles.readText(file).replacingOccurrences(of: "secret", with: "edited"))
        XCTAssertEqual(1, try store.loadVersions(id).skipped)
        let other = try store.create("Other").activeSheetId
        try Self.edit(store, other, "theirs"); try store.captureVersion(other, start)
        try NetFile.createDirectory(folder(id))
        try NetFile.copy(versionFiles(other)[0], TestFiles.path(folder(id), (versionFiles(other)[0] as NSString).lastPathComponent))
        XCTAssertEqual(2, try store.loadVersions(id).skipped)
    }
    func testInterruptedWritesAndForeignFilesAreIgnored() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a"); try store.captureVersion(id, start)
        let file = versionFiles(id)[0]
        try TestFiles.writeText(file + ".0123.tmp", "{partial"); try TestFiles.writeText(TestFiles.path(folder(id), "notes.json"), "mine")
        let history = try store.loadVersions(id)
        XCTAssertEqual(0, history.skipped); XCTAssertEqual(1, history.versions.count)
    }
    func testDeletionRemovesVersionsOnlyAfterTheBackupCatalogForgetsTheSheet() throws {
        let (store, keep) = try open(); defer { store.dispose() }
        let doomed = try store.create("Doomed").activeSheetId
        try Self.edit(store, doomed, "a"); try store.captureVersion(doomed, start)
        try Self.edit(store, keep, "kept"); try store.captureVersion(keep, start)
        try TestFiles.writeText(versionFiles(doomed)[0] + ".0123.tmp", "{partial")
        let foreign = TestFiles.path(directory, "versions", "not-a-sheet"); try NetFile.createDirectory(foreign); try TestFiles.writeText(TestFiles.path(foreign, "keep.txt"), "x")
        try store.delete(doomed)
        XCTAssertTrue(TestFiles.directoryExists(folder(doomed))) // workspace.json.bak still names it, and its body survives for recovery.
        XCTAssertTrue(TestFiles.exists(body(doomed)))
        try store.rename(keep, "Still here")
        XCTAssertFalse(TestFiles.directoryExists(folder(doomed))); XCTAssertFalse(TestFiles.exists(body(doomed)))
        XCTAssertEqual(1, versionFiles(keep).count)
        XCTAssertTrue(TestFiles.exists(TestFiles.path(foreign, "keep.txt")))
    }
    func testDeletionLeavesFilesItDoesNotOwn() throws {
        let (store, keep) = try open(); defer { store.dispose() }
        let doomed = try store.create("Doomed").activeSheetId
        try Self.edit(store, doomed, "a"); try store.captureVersion(doomed, start)
        let note = TestFiles.path(folder(doomed), "note.txt"); try TestFiles.writeText(note, "mine")
        try store.delete(doomed); try store.rename(keep, "Next")
        XCTAssertTrue(TestFiles.exists(note)); XCTAssertTrue(versionFiles(doomed).isEmpty)
    }
    func testRecoveringTheBackupCatalogStillFindsADeletedSheetsHistory() throws {
        let doomed: UUID
        let (store, keep) = try open()
        do {
            defer { store.dispose() }
            doomed = try store.create("Doomed").activeSheetId
            try Self.edit(store, doomed, "a"); try store.captureVersion(doomed, start)
            try store.delete(doomed)
        }
        try TestFiles.writeText(TestFiles.path(directory, "workspace.json"), "{bad")
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        XCTAssertTrue(try reopened.load().recovered)
        _ = try reopened.open(doomed)
        XCTAssertEqual(["a"], try Self.sources(reopened, doomed))
        XCTAssertEqual(keep, try reopened.load().workspace.sheets[0].id)
    }
    func testUnwritableHistoryFailsVisiblyAndLeavesSavingIntact() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a")
        try NetFile.createDirectory(TestFiles.path(directory, "versions"))
        try TestFiles.writeText(folder(id), "blocks the folder")
        assertThrows(.anyIO, try store.captureVersion(id, start))
        try Self.edit(store, id, "b")
        XCTAssertEqual("b", try store.open(id).document.source)
    }
    /// Windows: the version file held with FileShare.None. Mac: an exclusive flock, which the reader's shared lock cannot join.
    func testFailedCaptureRefusesTheRestoreSoNothingIsLost() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "old"); try store.captureVersion(id, start)
        let hash = try Self.versionOf(store, id, "old").hash
        try Self.edit(store, id, "current")
        do {
            let held = try TestFiles.holdExclusive(versionFiles(id)[0])
            assertThrows(.anyIO, try store.restoreVersion(id, hash, start.adding(minutes: 1)))
            held.close()
        }
        XCTAssertEqual("current", try store.open(id).document.source)
        XCTAssertFalse(TestFiles.exists(TestFiles.path(directory, "function-save.json")))
    }
    /// Windows: the body held with FileShare.Read blocks its replacement. Mac: the holder's shared flock does.
    func testLockedBodyAbandonsTheRestoreAndKeepsTheCurrentSheetAndReceipts() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "old"); try store.captureVersion(id, start)
        try Self.editWithFunctions(store, id, "f(x)=x+1")
        let hash = try Self.versionOf(store, id, "old").hash; let receipts = try store.loadFunctionReceipts(id)
        do {
            let held = try TestFiles.holdShared(body(id))
            assertThrows(.anyIO, try store.restoreVersion(id, hash, start.adding(minutes: 1)))
            held.close()
        }
        XCTAssertEqual("f(x)=x+1", try store.open(id).document.source)
        XCTAssertEqual(receipts, try store.loadFunctionReceipts(id))
        XCTAssertFalse(TestFiles.exists(TestFiles.path(directory, "function-save.json")))
        XCTAssertTrue(try Self.sources(store, id).contains("f(x)=x+1")) // The attempted restore already preserved the current content.
    }
    /// Windows: FileAttributes.ReadOnly on the body. Mac: no write permission (POSIX mode 0444).
    func testReadOnlyBodyAbandonsTheRestore() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "old"); try store.captureVersion(id, start)
        try Self.edit(store, id, "current")
        let hash = try Self.versionOf(store, id, "old").hash
        TestFiles.setReadOnly(body(id), true)
        do {
            defer { TestFiles.setReadOnly(body(id), false) }
            do { _ = try store.restoreVersion(id, hash, start.adding(minutes: 1)); XCTFail("restore must be refused") }
            catch { XCTAssertTrue(error.isIOException || error.isUnauthorized, "\(error)") }
            XCTAssertEqual("current", try store.open(id).document.source)
        }
        try Self.edit(store, id, "still saves")
        XCTAssertEqual("still saves", try store.open(id).document.source)
    }
    func testLoadOpenSaveAndSelectReadNoHistory() throws {
        let other: UUID
        let (store, id) = try open()
        do {
            defer { store.dispose() }
            try Self.edit(store, id, "a"); try store.captureVersion(id, start)
            other = try store.create("Other").activeSheetId
        }
        try TestFiles.writeText(TestFiles.files(folder(id), "*.json")[0], "{bad")
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        _ = try reopened.load(); _ = try reopened.loadFunctions()
        _ = try reopened.open(other); try reopened.select(other); _ = try reopened.open(id); try reopened.select(id)
        XCTAssertEqual("a", try reopened.open(id).document.source)
        try reopened.save(try reopened.open(id).document.with { $0.source = "b" })
        XCTAssertEqual(0, reopened.versionScans)
    }
    func testUnchangedIntervalNeedsNoFolderScan() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.edit(store, id, "a"); try store.captureVersion(id, start)
        let scans = store.versionScans
        for i in 1..<20 { try Self.edit(store, id, "a\(i)"); XCTAssertFalse(try store.captureVersion(id, start.adding(seconds: Double(i)))) }
        XCTAssertEqual(scans, store.versionScans)
    }
    func testExistingFoldersWithoutHistoryKeepWorking() throws {
        let (store, id) = try open(); defer { store.dispose() }
        XCTAssertFalse(TestFiles.directoryExists(TestFiles.path(directory, "versions")))
        XCTAssertEqual(VersionHistory(versions: [], skipped: 0).skipped, try store.loadVersions(id).skipped)
        XCTAssertTrue(try store.loadVersions(id).versions.isEmpty)
        XCTAssertFalse(TestFiles.directoryExists(TestFiles.path(directory, "versions")))
    }
    func testCaptureRequiresAnOpenedSheet() throws {
        let (store, id) = try open()
        store.dispose()
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        assertThrows(.invalidOperation, try reopened.captureVersion(id, start))
        assertThrows(.invalidOperation, try reopened.restoreVersion(id, String(repeating: "0", count: 64), start))
    }
    func testStoredVersionIsPlainJsonWithReceiptsAndUtcTimestamp() throws {
        let (store, id) = try open(); defer { store.dispose() }
        try Self.editWithFunctions(store, id, "f(x)=x"); try store.captureVersion(id, start.toOffset(minutes: 120))
        let json = try JSONNode.parse(Data(try TestFiles.readBytes(versionFiles(id)[0])))
        XCTAssertEqual(1, try json.property("Version").int())
        XCTAssertEqual(0, DateTimeOffset.parseJSON(try json.property("CapturedAt").string())?.offsetMinutes)
        XCTAssertEqual(1, try json.property("Receipts").arrayItems().count)
        XCTAssertEqual("f(x)=x", try json.property("Sheet").property("Source").string())
    }
}
