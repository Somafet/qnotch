import XCTest
@testable import CalculatorEngine

final class FunctionPersistenceTests: XCTestCase {
    private var directory = TestFiles.temporary("Calc-tests")
    override func tearDown() { TestFiles.delete(directory) }
    @discardableResult
    private static func save(_ store: WorkspaceStore, _ id: UUID, _ source: String) throws -> SheetDocument {
        let opened = try store.open(id).document.with { $0.source = source }
        let update = try FunctionUpdate.prepare(source, try store.loadFunctions(), try store.loadFunctionReceipts(id))
        try store.saveWithFunctions(opened, update); return opened
    }
    private static func instant(_ value: DateTimeOffset) -> Instant { Instant(unixTicks: value.utcTicks - Ticks.unixEpoch) }

    func testDefinitionsSurviveRestartAndOldSheetsDoNotOverrideNewDefinitions() throws {
        let first: UUID, second: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            first = try store.load().workspace.activeSheetId
            try Self.save(store, first, "f(x)=x+1")
            second = try store.create("Other").activeSheetId
            try Self.save(store, second, "f(x)=x+2")
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        let sheet = try reopened.open(first)
        let evaluated = try SheetEvaluationSession().evaluateWithFunctions(sheet.document.source + "\nf(10)", try reopened.loadFunctions(), sheet.functionReceipts!)
        XCTAssertEqual("12", evaluated.results[1].display)
        try Self.save(reopened, second, "forget f")
        XCTAssertTrue(try reopened.loadFunctions().definitions.isEmpty)
        XCTAssertTrue(TestFiles.files(directory, "function-save.json").isEmpty)
    }
    func testCalendarFunctionsReopenFromSourceWithTheNewHostDate() throws {
        let id: UUID
        let source = "nextMonth(d)=d+1month\ncurrent()=today\nnextMonth(2024-01-31)\ncurrent()"
        do { let store = try WorkspaceStore(directory); defer { store.dispose() }; id = try store.load().workspace.activeSheetId; try Self.save(store, id, source) }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let sheet = try reopened.open(id)
        XCTAssertEqual(source, sheet.document.source)
        let session = SheetEvaluationSession()
        let result = try session.evaluateWithFunctions(sheet.document.source, try reopened.loadFunctions(), sheet.functionReceipts!, context: EvaluationContext(today: DateOnly.parseISO("2026-10-30")))
        XCTAssertFalse(result.functions.hasChanges); XCTAssertEqual("2024-02-29", result.results[2].display); XCTAssertEqual("2026-10-30", result.results[3].display)
        XCTAssertEqual("2026-11-01", try session.evaluateWithFunctions("current()", try reopened.loadFunctions(), [], context: EvaluationContext(today: DateOnly.parseISO("2026-11-01"))).results[0].display)
    }
    func testClockIntervalFunctionsReopenWithoutAClockOrEvaluatedSnapshot() throws {
        let id: UUID; let source = "work(a,b)=from a to b\nshift(t)=t+90min\nwork(22:00,06:00)-30min\nshift(23:30)"
        do { let store = try WorkspaceStore(directory); defer { store.dispose() }; id = try store.load().workspace.activeSheetId; try Self.save(store, id, source) }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let sheet = try reopened.open(id)
        XCTAssertEqual(source, sheet.document.source)
        let result = try SheetEvaluationSession().evaluateWithFunctions(source, try reopened.loadFunctions(), sheet.functionReceipts!)
        XCTAssertFalse(result.functions.hasChanges); XCTAssertFalse(result.usesCurrentDate)
        XCTAssertEqual("7 h 30 min", result.results[2].display); XCTAssertEqual("(01:00 + 1 day)", result.results[3].display)
    }
    func testZonedAndCurrentTimeFunctionsReopenFromSourceWithFreshContext() throws {
        let id: UUID; let source = "zone(d,t)=d at t Europe/Budapest\nclock()=now in unix\nzone(2026-10-30,15:00)\nclock()"
        do { let store = try WorkspaceStore(directory); defer { store.dispose() }; id = try store.load().workspace.activeSheetId; try Self.save(store, id, source) }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let sheet = try reopened.open(id)
        XCTAssertEqual(source, sheet.document.source)
        let instant = DateTimeOffset(2026, 10, 30, 12, 0, 1)
        let result = try SheetEvaluationSession().evaluateWithFunctions(sheet.document.source, try reopened.loadFunctions(), sheet.functionReceipts!, context: EvaluationContext(now: Self.instant(instant)))
        XCTAssertFalse(result.functions.hasChanges); XCTAssertTrue(result.usesCurrentInstant); XCTAssertFalse(result.usesCurrentDate)
        XCTAssertEqual("2026-10-30T15:00:00+01:00", result.results[2].display); XCTAssertEqual("1793361601", result.results[3].display)
        XCTAssertFalse(try TestFiles.readText(TestFiles.path(directory, "functions.json")).contains("1793361601"))
    }
    func testCountdownFunctionsReopenWithFreshClockAndLocalRules() throws {
        let id: UUID; let source = "remaining(d)=until d\nremaining(2026-11-01)"
        do { let store = try WorkspaceStore(directory); defer { store.dispose() }; id = try store.load().workspace.activeSheetId; try Self.save(store, id, source) }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load(); let sheet = try reopened.open(id)
        let context = EvaluationContext(today: DateOnly.parseISO("2026-10-31"), now: Self.instant(DateTimeOffset(2026, 10, 31, 12, 0, 0)),
                                        localZone: try LocalZoneSnapshot(FixedZone.utc, version: "test UTC"))
        let result = try SheetEvaluationSession().evaluateWithFunctions(sheet.document.source, try reopened.loadFunctions(), sheet.functionReceipts!, context: context)
        XCTAssertFalse(result.functions.hasChanges); XCTAssertTrue(result.requiresSecondRefresh); XCTAssertTrue(result.usesLocalTimeZone)
        XCTAssertEqual("12 h", result.results[1].display); XCTAssertEqual(source, sheet.document.source)
        XCTAssertFalse(try TestFiles.readText(TestFiles.path(directory, "functions.json")).contains("12 h"))
    }
    /// Windows holds the file open with FileShare.Read so its replacement fails; the Mac holder takes a shared flock.
    func testInterruptedSaveReplaysCompleteTransactionBeforeOtherWrites() throws {
        let base = directory
        try theory(["body", "library", "receipts"]) { stage in
            directory = TestFiles.path(base, stage)
            let id: UUID
            do {
                let store = try WorkspaceStore(directory); defer { store.dispose() }
                id = try store.load().workspace.activeSheetId; try Self.save(store, id, "f(x)=x+1")
                let document = try store.open(id).document.with { $0.source = "f(x)=x+2" }
                let update = try FunctionUpdate.prepare(document.source, try store.loadFunctions(), try store.loadFunctionReceipts(id))
                let file: String
                switch stage {
                case "body": file = TestFiles.path(directory, "sheets", id.netN + ".json")
                case "library": file = TestFiles.path(directory, "functions.json")
                default: file = TestFiles.path(directory, "sheets", id.netN + ".receipts")
                }
                let locked = try TestFiles.holdShared(file); defer { locked.close() }
                assertThrows(.anyIO, try store.saveWithFunctions(document, update))
                XCTAssertTrue(TestFiles.exists(TestFiles.path(directory, "function-save.json")))
                assertThrows(.anyIO, try store.rename(id, "must not bypass pending transaction"))
            }
            let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
            let sheet = try reopened.open(id)
            XCTAssertEqual("f(x)=x+2", sheet.document.source)
            XCTAssertEqual("12", try SheetEvaluationSession().evaluateWithFunctions("f(10)", try reopened.loadFunctions(), []).results[0].display)
            XCTAssertEqual(1, sheet.functionReceipts!.count)
            XCTAssertFalse(TestFiles.exists(TestFiles.path(directory, "function-save.json")))
        }
        directory = base
    }
    func testFailedAndStalePlansCannotReplaceFunctions() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }; let id = try store.load().workspace.activeSheetId
        try Self.save(store, id, "f(x)=x+1")
        let document = try store.open(id).document.with { $0.source = "f(x)=x+2" }
        let stale = try FunctionUpdate.prepare(document.source, try store.loadFunctions(), try store.loadFunctionReceipts(id))
        try Self.save(store, id, "f(x)=x+3")
        assertThrows(.invalidData, try store.saveWithFunctions(document, stale))
        let bad = try Self.save(store, id, "f(x)=unknown(x)")
        XCTAssertEqual("f(x)=unknown(x)", bad.source)
        XCTAssertEqual("13", try SheetEvaluationSession().evaluateWithFunctions("f(10)", try store.loadFunctions(), []).results[0].display)
    }
    func testFunctionLibraryCorruptionRecoversBackupAndPreservesRejectedFile() throws {
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            let id = try store.load().workspace.activeSheetId
            try Self.save(store, id, "f(x)=x+1"); try Self.save(store, id, "f(x)=x+2")
        }
        try TestFiles.writeText(TestFiles.path(directory, "functions.json"), "{bad")
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        XCTAssertEqual("11", try SheetEvaluationSession().evaluateWithFunctions("f(10)", try reopened.loadFunctions(), []).results[0].display)
        XCTAssertEqual(1, TestFiles.files(directory, "functions.json.corrupt-*").count)
    }
    func testForeignOrFutureJournalIsRefusedBeforeMutatingSource() throws {
        do { let store = try WorkspaceStore(directory); _ = try store.load(); store.dispose() }
        let transaction = FunctionSaveTransaction(1, SheetDocument(1, UUID(), "overwrite", false), FunctionCatalog(1, []), FunctionReceiptDocument(1, UUID(), []))
        let journal = TestFiles.path(directory, "function-save.json")
        try TestFiles.writeText(journal, transaction.json)
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        assertThrows(.invalidData, try reopened.load())
        XCTAssertTrue(TestFiles.exists(journal))
        XCTAssertEqual(1, TestFiles.files(TestFiles.path(directory, "sheets"), "*.json").count)
        var future = transaction; future.version = 2
        try TestFiles.writeText(journal, future.json)
        assertThrows(.unsupportedVersion, try reopened.load())
    }
}
