import XCTest
@testable import CalculatorEngine

/// Each Computer has its own data folder and store; they meet only through one shared sync folder,
/// as two computers do through iCloud Drive/OneDrive/Dropbox. Provider behaviour (overwrites, duplicates, placeholders, truncation)
/// is simulated on disk.
final class FolderSyncTests: XCTestCase {
    private let root = TestFiles.temporary("Calc-sync-tests")
    private var shared: String { TestFiles.path(root, "shared") }
    private var computers: [Computer] = []
    override func setUpWithError() throws { try NetFile.createDirectory(shared) }
    override func tearDown() {
        for c in computers { c.store.dispose() }
        TestFiles.delete(root)
    }

    struct Sheet: Equatable { let name: String, source: String }
    final class Clock { var now = DateTimeOffset(2026, 11, 1, 12, 0, 0) }
    final class Computer {
        let data: String
        let store: WorkspaceStore
        let sync: FolderSync
        let clock = Clock()
        var now: DateTimeOffset { get { clock.now } set { clock.now = newValue } }
        init(_ data: String, _ device: String) throws {
            self.data = data; store = try WorkspaceStore(data); _ = try store.load()
            let clock = self.clock
            sync = FolderSync(store, device, clock: { clock.now })
        }
        var workspace: WorkspaceDocument { get throws { try store.load().workspace } }
        func run(_ folder: String) throws -> SyncReport { try sync.synchronize(sync.scan(folder)) }
        func source(_ id: UUID) throws -> String { try store.open(id).document.source }
        func edit(_ id: UUID, _ source: String) throws { let doc = try store.open(id).document; try store.save(doc.with { $0.source = source }) }
        func add(_ name: String, _ source: String) throws -> UUID { try store.create(name, source).activeSheetId }
        func sheets() throws -> [UUID: Sheet] {
            var result: [UUID: Sheet] = [:]
            for s in try workspace.sheets { result[s.id] = Sheet(name: s.name, source: try source(s.id)) }
            return result
        }
    }
    private func machine(_ device: String, connect: Bool = true) throws -> Computer {
        let computer = try Computer(TestFiles.path(root, device), device)
        computers.append(computer)
        if connect { try FolderSync.setFolder(computer.data, shared) }
        return computer
    }
    private func canonical(_ id: UUID) -> String { SyncFolderFiles.canonicalPath(shared, id) }
    private func readFile(_ id: UUID) throws -> SyncSheetFile { try SyncSheetFile.decode(try NetJSON.parseObject(try TestFiles.readBytes(canonical(id)))!) }
    private static func sharedOf(_ c: Computer) throws -> String { try FolderSync.configuredFolder(c.data)! }
    private func quiesce(_ all: [Computer], file: StaticString = #filePath, line: UInt = #line) throws {
        for _ in 0..<6 {
            var writes = 0
            for c in all {
                let r = try c.run(try FolderSyncTests.sharedOf(c))
                writes += r.published + r.imported + r.updated + r.conflicts + r.deleted
                XCTAssertEqual(0, r.failed, r.problem ?? "", file: file, line: line)
            }
            if writes == 0 { return }
        }
        XCTFail("Sync did not converge", file: file, line: line)
    }
    private func sources(_ c: Computer) throws -> [String] { try c.sheets().values.map(\.source) }

    func testOffByDefaultReadsAndWritesNothing() throws {
        let a = try machine("A", connect: false)
        XCTAssertNil(try FolderSync.configuredFolder(a.data))
        XCTAssertFalse(TestFiles.exists(FolderSync.statePath(a.data)))
        try FolderSync.setFolder(a.data, nil) // Clearing an unset folder creates no state file.
        XCTAssertFalse(TestFiles.exists(FolderSync.statePath(a.data)))
        let report = try a.run(shared)
        XCTAssertEqual(.off, report.status)
        XCTAssertTrue(try NetFile.entries(shared).isEmpty)
    }

    func testFolderSelectionIsValidated() throws {
        let a = try machine("A", connect: false)
        assertThrows(.invalidData, try FolderSync.setFolder(a.data, "relative\\folder"))
        assertThrows(.invalidData, try FolderSync.setFolder(a.data, a.data))
        assertThrows(.invalidData, try FolderSync.setFolder(a.data, TestFiles.path(a.data, "sheets")))
        assertThrows(.invalidData, try FolderSync.setFolder(a.data, root))
        assertThrows(.directoryNotFound, try FolderSync.setFolder(a.data, TestFiles.path(root, "missing")))
        try FolderSync.setFolder(a.data, shared + "/")
        XCTAssertEqual(shared, try FolderSync.configuredFolder(a.data))
    }

    func testFirstConnectMergesBothComputersByStableIdentity() throws {
        let a = try machine("A"), b = try machine("B")
        let travel = try a.add("Travel", "fuel = 40\nfuel * 3")
        try quiesce([a, b])
        XCTAssertEqual(try a.sheets(), try b.sheets())
        XCTAssertEqual(3, try a.sheets().count) // Two starter sheets plus Travel.
        XCTAssertEqual("fuel = 40\nfuel * 3", try b.source(travel))
        XCTAssertEqual("Travel", try b.workspace.sheets.first { $0.id == travel }!.name)
        XCTAssertTrue(TestFiles.exists(canonical(travel)))
    }

    func testEditsPropagateWithNewRevisionsAndIdlePassesWriteNothing() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        let first = try readFile(id)
        let stamp = NetFile.info(canonical(id)).lastWriteTicks
        for _ in 0..<3 { let idle = try a.run(shared); XCTAssertEqual(0, idle.published); XCTAssertEqual(.synchronized, idle.status) }
        XCTAssertEqual(stamp, NetFile.info(canonical(id)).lastWriteTicks)

        try a.edit(id, "2 + 2")
        XCTAssertEqual(1, try a.run(shared).published)
        let second = try readFile(id)
        XCTAssertNotEqual(first.revision, second.revision)
        XCTAssertEqual(first.revision, second.ancestors[0])
        XCTAssertEqual("A", second.device)
        let update = try b.run(shared)
        XCTAssertEqual(1, update.updated); XCTAssertTrue(update.changedSheets.contains(id))
        XCTAssertEqual("2 + 2", try b.source(id))
        XCTAssertEqual(second.revision, try readFile(id).revision) // Fast-forward does not rewrite the file.

        try b.store.rename(id, "Budget")
        _ = try b.run(shared); _ = try a.run(shared)
        XCTAssertEqual("Budget", try a.workspace.sheets.first { $0.id == id }!.name)
    }

    func testSameLengthEditWithinOneFileTimeTickIsStillPublished() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        let body = TestFiles.path(a.data, "sheets", id.netN + ".json")
        try a.edit(id, "aaaa"); _ = try a.run(shared)
        let stamp = NetFile.info(body).lastWriteTicks
        try a.edit(id, "bbbb")
        try NetFile.setLastWriteTicks(body, stamp) // Coarse system time: both saves share one tick.
        XCTAssertEqual(1, try a.run(shared).published)
        XCTAssertEqual("bbbb", try readFile(id).source)
    }

    func testFastForwardKeepsReplacedContentInVersionHistory() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        try a.edit(id, "replacement"); _ = try a.run(shared)
        _ = try b.run(shared)
        let history = try b.store.loadVersions(id).versions.map(\.sheet.source)
        XCTAssertTrue(history.contains(WorkspaceStore.starterSource))
    }

    func testConcurrentEditsKeepBothAsConflictCopyOnEveryComputer() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        try a.edit(id, "edited on A"); try b.edit(id, "edited on B")
        _ = try a.run(shared)
        let conflict = try b.run(shared)
        XCTAssertEqual(1, conflict.conflicts)
        XCTAssertEqual("edited on B", try b.source(id)) // The computer that finds the conflict keeps its own text in place.
        try quiesce([a, b])
        XCTAssertEqual(try a.sheets(), try b.sheets())
        let all = try sources(a)
        XCTAssertTrue(all.contains("edited on A")); XCTAssertTrue(all.contains("edited on B"))
        XCTAssertTrue(try a.sheets().values.contains { $0.name == "Sheet (conflict, A)" && $0.source == "edited on A" })
    }

    func testProviderOverwriteOfAnUnseenRevisionIsDetectedByAncestry() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        let original = try TestFiles.readBytes(canonical(id))
        try b.edit(id, "from B"); _ = try b.run(shared)
        let fromB = try TestFiles.readBytes(canonical(id))
        try TestFiles.writeBytes(canonical(id), original) // A has not yet received B's upload.
        try a.edit(id, "from A"); _ = try a.run(shared)
        try TestFiles.writeBytes(canonical(id), fromB) // Provider: last writer wins, A's upload is silently replaced.
        let report = try a.run(shared)
        XCTAssertEqual(1, report.conflicts)
        try quiesce([a, b])
        XCTAssertEqual(try a.sheets(), try b.sheets())
        let all = try sources(a)
        XCTAssertTrue(all.contains("from A")); XCTAssertTrue(all.contains("from B"))
    }

    func testProviderDuplicateFilesBecomeConflictCopies() throws {
        try theory(["%@ (1).calcsheet", "%@-DESKTOP-7Q2.calcsheet", "%@ (Someone's conflicted copy 2026-11-01).calcsheet"]) { pattern in
            for c in computers { c.store.dispose() }; computers = []
            TestFiles.delete(root); try NetFile.createDirectory(shared)
            let a = try machine("A"), b = try machine("B")
            let id = try a.workspace.activeSheetId
            try quiesce([a, b])
            let stale = try TestFiles.readBytes(canonical(id))
            try b.edit(id, "kept by provider as duplicate"); _ = try b.run(shared)
            let duplicate = TestFiles.path(shared, String(format: pattern, id.netN))
            try NetFile.move(canonical(id), duplicate, overwrite: false); try TestFiles.writeBytes(canonical(id), stale)
            let report = try a.run(shared)
            XCTAssertEqual(1, report.conflicts)
            XCTAssertFalse(TestFiles.exists(duplicate))
            XCTAssertTrue(try a.sheets().values.contains { $0.source == "kept by provider as duplicate" })
            try quiesce([a, b])
            XCTAssertEqual(try a.sheets(), try b.sheets())
        }
    }

    func testIdenticalDuplicateIsRemovedWithoutACopy() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        let duplicate = TestFiles.path(shared, id.netN + " (1).calcsheet")
        try NetFile.copy(canonical(id), duplicate)
        let report = try a.run(shared)
        XCTAssertEqual(0, report.conflicts)
        XCTAssertFalse(TestFiles.exists(duplicate))
        XCTAssertEqual(1, try a.workspace.sheets.count)
    }

    func testFileDeletedOutsideCalcIsRestoredAndNeverDeletesLocalWork() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        let revision = try readFile(id).revision
        try NetFile.delete(canonical(id))
        let report = try a.run(shared)
        XCTAssertEqual(1, report.restored)
        XCTAssertEqual(revision, try readFile(id).revision) // Unchanged content keeps its revision, so other computers see no change.
        XCTAssertEqual(WorkspaceStore.starterSource, try a.source(id))

        try NetFile.delete(canonical(id)); try a.edit(id, "edited after external delete")
        _ = try a.run(shared)
        XCTAssertEqual([revision], try readFile(id).ancestors)
    }

    func testUnavailableFolderChangesNothing() throws {
        let a = try machine("A")
        _ = try a.add("Second", "1")
        _ = try a.run(shared)
        try NetFile.deleteTree(shared)
        let before = try a.sheets()
        let report = try a.run(shared)
        XCTAssertEqual(.folderUnavailable, report.status)
        XCTAssertEqual(before, try a.sheets())
        XCTAssertFalse(TestFiles.directoryExists(shared))
    }

    func testEmptiedFolderIsRepopulatedNotPropagatedAsDeletes() throws {
        let a = try machine("A"), b = try machine("B")
        try quiesce([a, b])
        let before = try a.sheets()
        for file in try NetFile.files(shared) { try NetFile.delete(file) }
        _ = try a.run(shared); _ = try b.run(shared)
        XCTAssertEqual(before, try a.sheets()); XCTAssertEqual(before, try b.sheets())
        XCTAssertEqual(before.count, TestFiles.files(shared, "*.calcsheet").count)
    }

    func testDeletionInCalcPropagatesAsTombstone() throws {
        let a = try machine("A"), b = try machine("B")
        let extra = try a.add("Scratch", "1+1")
        try quiesce([a, b])
        try a.store.delete(extra)
        _ = try a.run(shared)
        XCTAssertTrue(try readFile(extra).deleted)
        let report = try b.run(shared)
        XCTAssertEqual(1, report.deleted)
        XCTAssertFalse(try b.workspace.sheets.contains { $0.id == extra })
        try quiesce([a, b])
        XCTAssertEqual(try a.sheets(), try b.sheets())
    }

    func testEditWinsOverDeleteInBothOrders() throws {
        let a = try machine("A"), b = try machine("B")
        let first = try a.add("First", "1"), second = try a.add("Second", "2")
        try quiesce([a, b])
        // A deletes and publishes first; B had edited it.
        try a.store.delete(first); _ = try a.run(shared)
        try b.edit(first, "B kept editing")
        _ = try b.run(shared)
        XCTAssertEqual("B kept editing", try b.source(first))
        // B edits and publishes first; A deletes without having seen it.
        try b.edit(second, "B edited second"); _ = try b.run(shared)
        try a.store.delete(second); _ = try a.run(shared)
        try quiesce([a, b])
        XCTAssertEqual(try a.sheets(), try b.sheets())
        XCTAssertEqual("B kept editing", try a.source(first))
        XCTAssertEqual("B edited second", try a.source(second))
    }

    func testRemoteDeleteOfTheLastLocalSheetKeepsIt() throws {
        let a = try machine("A"), b = try machine("B", connect: false)
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        // B imports A's only sheet and deletes its own starter, so it has one sheet that A then deletes.
        try FolderSync.setFolder(b.data, shared); _ = try b.run(shared)
        try b.store.delete(try b.workspace.sheets.first { $0.id != id }!.id); _ = try b.run(shared)
        XCTAssertEqual(1, try b.workspace.sheets.count)
        // Another computer deletes it in Calc: a tombstone that descends from B's base.
        let current = try readFile(id)
        let tombstone = SyncSheetFile(SyncFolderFiles.format, id, UUID(), [current.revision], "C", b.now, true, "", "", SyncFolderFiles.contentHash("", "", nil))
        try TestFiles.writeText(canonical(id), tombstone.json)
        let report = try b.run(shared)
        XCTAssertEqual(0, report.deleted); XCTAssertEqual(1, report.published)
        XCTAssertTrue(try b.workspace.sheets.contains { $0.id == id })
        XCTAssertFalse(try readFile(id).deleted)
    }

    /// Windows marks a cloud placeholder with FileAttributes.Offline; on the Mac only the kernel can make a file dataless
    /// (SF_DATALESS), so the test stands in for the provider through `SyncFolderFiles.attributes`.
    func testPlaceholderIsNeitherReadNorOverwritten() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        try b.edit(id, "newer, still in the cloud"); _ = try b.run(shared)
        let bytes = try TestFiles.readBytes(canonical(id))
        try a.edit(id, "local edit")
        let real = SyncFolderFiles.attributes, placeholder = canonical(id)
        SyncFolderFiles.attributes = { path, info in path == placeholder ? .offline : real(path, info) }
        defer { SyncFolderFiles.attributes = real }
        let waiting = try a.run(shared)
        XCTAssertEqual(.waiting, waiting.status)
        XCTAssertEqual(1, waiting.waiting)
        XCTAssertEqual("Waiting for download", waiting.problem)
        XCTAssertEqual(bytes, try TestFiles.readBytes(canonical(id)))
        XCTAssertEqual("local edit", try a.source(id))
        SyncFolderFiles.attributes = real // Download finished.
        XCTAssertEqual(1, try a.run(shared).conflicts)
        try quiesce([a, b])
        let all = try sources(a)
        XCTAssertTrue(all.contains("local edit")); XCTAssertTrue(all.contains("newer, still in the cloud"))
    }

    func testPlaceholderAttributesAreRecognized() throws {
        try theory([(FileAttributes(rawValue: 0x400000), true), // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
                    (FileAttributes(rawValue: 0x40000), true),   // FILE_ATTRIBUTE_RECALL_ON_OPEN
                    (FileAttributes.offline, true),
                    ([FileAttributes.archive, .readOnly], false),
                    ([FileAttributes(rawValue: 0x80000), .archive], false)]) { (attributes: FileAttributes, placeholder: Bool) in // Pinned, fully present
            XCTAssertEqual(placeholder, SyncFolderFiles.isPlaceholder(attributes))
        }
    }

    func testPartialDownloadWaitsThenIsSetAsideWithoutLoss() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        let bytes = try TestFiles.readBytes(canonical(id))
        let truncated = Array(bytes[..<(bytes.count / 2)])
        try TestFiles.writeBytes(canonical(id), truncated)
        try a.edit(id, "local while partial")
        let first = try a.run(shared)
        XCTAssertEqual(1, first.waiting)
        XCTAssertEqual(FolderSync.incompleteGrace, first.recheckAfter)
        XCTAssertEqual(truncated, try TestFiles.readBytes(canonical(id)))
        a.now = a.now.adding(minutes: 5)
        XCTAssertEqual(5 * Ticks.perMinute, try a.run(shared).recheckAfter)
        XCTAssertEqual(truncated, try TestFiles.readBytes(canonical(id)))
        a.now = a.now.adding(minutes: 6)
        let aside = try a.run(shared)
        XCTAssertEqual(1, aside.damaged); XCTAssertEqual(1, aside.published)
        let damaged = TestFiles.files(shared, "*" + SyncFolderFiles.damagedExtension)
        XCTAssertEqual(1, damaged.count)
        XCTAssertEqual(truncated, try TestFiles.readBytes(damaged[0]))
        XCTAssertEqual("local while partial", try readFile(id).source)
    }

    func testGrowingDownloadRestartsTheGracePeriod() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        let bytes = try TestFiles.readBytes(canonical(id))
        try TestFiles.writeBytes(canonical(id), Array(bytes[..<10]))
        _ = try a.run(shared)
        a.now = a.now.adding(minutes: 9)
        try TestFiles.writeBytes(canonical(id), Array(bytes[..<20])) // Still arriving.
        a.now = a.now.adding(minutes: 9)
        XCTAssertEqual(0, try a.run(shared).damaged)
        try TestFiles.writeBytes(canonical(id), bytes) // Complete.
        let done = try a.run(shared)
        XCTAssertEqual(.synchronized, done.status)
        XCTAssertTrue(TestFiles.files(shared, "*" + SyncFolderFiles.damagedExtension).isEmpty)
    }

    func testValidJsonWithMismatchedHashIsTreatedAsIncomplete() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        let tampered = try readFile(id).with { $0.source = "half written" }
        try TestFiles.writeText(canonical(id), tampered.json)
        let report = try a.run(shared)
        XCTAssertEqual(1, report.waiting)
        XCTAssertEqual(WorkspaceStore.starterSource, try a.source(id))
    }

    func testFutureFormatIsNeverOverwrittenOrSetAside() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        let future = try TestFiles.readText(canonical(id)).replacingOccurrences(of: "\"Format\":1", with: "\"Format\":2")
        try TestFiles.writeText(canonical(id), future)
        try a.edit(id, "local")
        a.now = a.now.adding(days: 1)
        let report = try a.run(shared)
        XCTAssertEqual(1, report.waiting); XCTAssertEqual(0, report.damaged)
        XCTAssertEqual(future, try TestFiles.readText(canonical(id)))
    }

    /// Windows: the file is held open with FileShare.None. Mac: an exclusive flock, which the scan sees as Locked.
    func testLockedFileDefersWithRetry() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        _ = try a.run(shared)
        try a.edit(id, "while locked")
        do {
            let held = try TestFiles.holdExclusive(canonical(id))
            let report = try a.run(shared)
            XCTAssertTrue(report.retrySoon); XCTAssertEqual(0, report.published)
            held.close()
        }
        XCTAssertEqual(1, try a.run(shared).published)
        XCTAssertEqual("while locked", try readFile(id).source)
    }

    func testChangeBetweenScanAndApplyIsNotOverwritten() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        try a.edit(id, "A pending")
        let snapshot = a.sync.scan(shared) // Taken on a background thread...
        try b.edit(id, "B landed meanwhile"); _ = try b.run(shared)
        let landed = try readFile(id).revision
        let report = try a.sync.synchronize(snapshot) // ...applied after B's write arrived.
        XCTAssertTrue(report.retrySoon); XCTAssertEqual(0, report.published)
        XCTAssertEqual(landed, try readFile(id).revision)
        try quiesce([a, b])
        let all = try sources(a)
        XCTAssertTrue(all.contains("A pending")); XCTAssertTrue(all.contains("B landed meanwhile"))
    }

    func testWritesAreAtomicAndStaleTemporariesAreCleaned() throws {
        let a = try machine("A")
        let foreign = TestFiles.path(shared, ".0123.4567" + SyncFolderFiles.temporaryExtension)
        let fresh = TestFiles.path(shared, ".89ab.cdef" + SyncFolderFiles.temporaryExtension)
        try TestFiles.writeText(foreign, "{"); try TestFiles.writeText(fresh, "{")
        try NetFile.setLastWriteTicks(foreign, a.now.utcTicks - 2 * Ticks.perHour)
        try NetFile.setLastWriteTicks(fresh, a.now.utcTicks)
        _ = try a.run(shared)
        XCTAssertFalse(TestFiles.exists(foreign)); XCTAssertTrue(TestFiles.exists(fresh))
        XCTAssertEqual(1, TestFiles.files(shared, "*.calcsheet").count)
    }

    func testAncestryStaysBounded() throws {
        let a = try machine("A")
        let id = try a.workspace.activeSheetId
        for i in 0..<(SyncFolderFiles.maxAncestors + 8) { try a.edit(id, "v\(i)"); _ = try a.run(shared) }
        XCTAssertEqual(SyncFolderFiles.maxAncestors, try readFile(id).ancestors.count)
    }

    func testFolderScanIsBounded() throws {
        let a = try machine("A")
        for i in 0..<(SyncFolderFiles.maxFiles + 5) { try TestFiles.writeText(TestFiles.path(shared, "junk\(i).calcsheet"), "x") }
        let snapshot = a.sync.scan(shared)
        XCTAssertEqual(SyncFolderFiles.maxFiles + 5, snapshot.skipped)
        XCTAssertTrue(snapshot.canonical.isEmpty)
    }

    func testCorruptStateRecoversFromBackupWithoutLosingWork() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        try quiesce([a, b])
        try a.edit(id, "one"); _ = try a.run(shared)
        try a.edit(id, "two"); _ = try a.run(shared)
        try TestFiles.writeText(FolderSync.statePath(a.data), "{ broken")
        try a.edit(id, "three")
        try quiesce([a, b])
        XCTAssertEqual(try a.sheets(), try b.sheets())
        XCTAssertTrue(try a.sheets().values.contains { $0.source == "three" })
    }

    func testClearingStopsSyncAndLeavesFolderFilesAlone() throws {
        let a = try machine("A")
        _ = try a.run(shared)
        let files = try NetFile.files(shared).sorted().map(TestFiles.readBytes)
        try FolderSync.setFolder(a.data, nil)
        XCTAssertNil(try FolderSync.configuredFolder(a.data))
        try a.edit(try a.workspace.activeSheetId, "after clearing")
        XCTAssertEqual(.off, try a.run(shared).status)
        XCTAssertEqual(files, try NetFile.files(shared).sorted().map(TestFiles.readBytes))
    }

    func testGeneratedUuidsTravelWithTheSheet() throws {
        let a = try machine("A"), b = try machine("B")
        let id = try a.workspace.activeSheetId
        let statement = UUID(), value = UUID()
        let doc = try a.store.open(id).document
        try a.store.save(doc.with { $0.version = 2; $0.source = "uuid"; $0.generatedUuids = GeneratedUuidState(1, [statement], [UuidBinding(statement: statement, site: "0", value: value)]) })
        try quiesce([a, b])
        let received = try b.store.open(id).document
        XCTAssertEqual(value, received.generatedUuids!.bindings.first!.value)
        XCTAssertEqual(1, received.generatedUuids!.bindings.count)
    }

    /// Random edits, deletes, adds and syncs on three computers, with scans applied late to model background delays.
    /// Oracle: every text that no user replaced or deleted still exists on every computer after quiescence, and all computers agree.
    func testRandomInterleavingsLoseNothingAndConverge() throws {
        try theory([1, 2, 3, 4, 5, 6]) { (seed: Int32) in
            for c in computers { c.store.dispose() }; computers = []
            TestFiles.delete(root); try NetFile.createDirectory(shared)
            var random = NetRandom(seed)
            let all = [try machine("A"), try machine("B"), try machine("C")]
            var superseded = Set<String>()
            var produced = Set(try all.flatMap { try $0.sheets().values.map(\.source) })
            var delayed: [ObjectIdentifier: SyncFolderSnapshot] = [:]
            var counter = 0
            for _ in 0..<120 {
                let c = all[random.next(all.count)]
                let sheets = try c.workspace.sheets
                switch random.next(10) {
                case 0, 1, 2:
                    let id = sheets[random.next(sheets.count)].id
                    superseded.insert(try c.source(id))
                    counter += 1
                    let text = "text \(counter) by \(c.data.last!)"; produced.insert(text); try c.edit(id, text)
                case 3 where sheets.count < 8:
                    counter += 1
                    let text = "new \(counter)"; produced.insert(text); _ = try c.add("S\(counter)", text)
                case 4 where sheets.count > 1:
                    let id = sheets[random.next(sheets.count)].id; superseded.insert(try c.source(id)); try c.store.delete(id)
                case 5:
                    delayed[ObjectIdentifier(c)] = c.sync.scan(shared)
                case 6 where delayed[ObjectIdentifier(c)] != nil:
                    let old = delayed.removeValue(forKey: ObjectIdentifier(c))!
                    XCTAssertEqual(0, try c.sync.synchronize(old).failed)
                default:
                    XCTAssertEqual(0, try c.run(shared).failed)
                }
            }
            try quiesce(all)
            let reference = try all[0].sheets()
            for c in all { XCTAssertEqual(reference, try c.sheets()) }
            let finalSources = Set(reference.values.map(\.source))
            for text in produced.subtracting(superseded) { XCTAssertTrue(finalSources.contains(text), "seed \(seed): lost \(text)") }
        }
    }
}
