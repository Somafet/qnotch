import XCTest
@testable import CalculatorEngine

final class FolderSyncSessionTests: XCTestCase {
    private let root = TestFiles.temporary("Calc-sync-session")
    private var data: String { TestFiles.path(root, "data") }
    private var shared: String { TestFiles.path(root, "shared") }
    private let storeGate = NSLock()
    private var store: WorkspaceStore!
    private let reportsGate = NSLock()
    private var reports: [SyncReport] = []
    private let completedSignal = DispatchSemaphore(value: 0)

    override func setUpWithError() throws {
        try NetFile.createDirectory(shared)
        store = try WorkspaceStore(data); _ = try store.load()
    }
    override func tearDown() {
        store.dispose()
        TestFiles.delete(root)
    }
    private func session(_ canApply: (() -> Bool)? = nil) -> FolderSyncSession {
        let gate = storeGate
        return FolderSyncSession(store, data, "A", post: { action in gate.lock(); action(); gate.unlock() }, canApply: canApply ?? { true },
                                 completed: { [weak self] report in
                                     guard let self else { return }
                                     self.reportsGate.lock(); self.reports.append(report); self.reportsGate.unlock(); self.completedSignal.signal()
                                 })
    }
    private func nextReport(file: StaticString = #filePath, line: UInt = #line) -> SyncReport? {
        guard completedSignal.wait(timeout: .now() + 20) == .success else { XCTFail("No sync pass completed", file: file, line: line); return nil }
        reportsGate.lock(); defer { reportsGate.unlock() }
        return reports.last
    }
    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    func testOffCreatesNoWatcherTimerOrPass() throws {
        let session = session(); defer { session.dispose() }
        try session.start(); session.request()
        XCTAssertNil(session.folder)
        XCTAssertFalse(session.watching); XCTAssertFalse(session.timerExists)
        pause(FolderSyncSession.debounce * 2)
        XCTAssertEqual(0, session.passes)
        XCTAssertTrue(try NetFile.entries(shared).isEmpty)
    }

    func testEnablingWatchesAndReactsToFolderChangesThenClearingStopsEverything() throws {
        let session = session(); defer { session.dispose() }
        try session.setFolder(shared)
        XCTAssertTrue(session.watching)
        let first = try XCTUnwrap(nextReport())
        XCTAssertEqual(.synchronized, first.status); XCTAssertEqual(1, first.published)

        // Another computer publishes a sheet; the watcher alone must bring it in.
        let other = TestFiles.path(root, "other")
        do {
            let otherStore = try WorkspaceStore(other); defer { otherStore.dispose() }
            _ = try otherStore.load(); try FolderSync.setFolder(other, shared)
            try otherStore.create("Remote", "7*6")
            let engine = FolderSync(otherStore, "B")
            _ = try engine.synchronize(engine.scan(shared))
        }
        var report: SyncReport
        repeat { report = try XCTUnwrap(nextReport()) } while report.imported == 0
        storeGate.lock(); let names = try store.load().workspace.sheets.map(\.name); storeGate.unlock()
        XCTAssertTrue(names.contains("Remote"))

        try session.setFolder(nil)
        XCTAssertFalse(session.watching); XCTAssertFalse(session.timerExists); XCTAssertNil(session.folder)
        let passes = session.passes
        try TestFiles.writeText(TestFiles.path(shared, UUID().netN + ".calcsheet"), "{}")
        pause(FolderSyncSession.debounce * 3)
        XCTAssertEqual(passes, session.passes)
    }

    func testBurstsOfRequestsAreCoalesced() throws {
        let session = session(); defer { session.dispose() }
        try session.setFolder(shared)
        _ = nextReport()
        pause(FolderSyncSession.debounce * 3)
        while completedSignal.wait(timeout: .now()) == .success {}
        let before = session.passes
        for _ in 0..<40 { session.request(); pause(0.01) }
        _ = nextReport()
        pause(FolderSyncSession.debounce * 3)
        XCTAssertTrue((1...2).contains(session.passes - before), "\(session.passes - before) passes")
    }

    func testDeferredPassIsRetriedNotDropped() throws {
        let allowGate = NSLock(); var allow = false
        let session = session { allowGate.lock(); defer { allowGate.unlock() }; return allow }; defer { session.dispose() }
        try session.setFolder(shared)
        pause(FolderSyncSession.debounce * 2)
        XCTAssertEqual(0, session.passes)
        allowGate.lock(); allow = true; allowGate.unlock()
        let report = try XCTUnwrap(nextReport()) // One-shot retry after retryDelay.
        XCTAssertEqual(1, report.published)
    }

    func testDisposeStopsWatcher() throws {
        let session = session()
        try session.setFolder(shared)
        XCTAssertTrue(session.watching)
        session.dispose()
        XCTAssertFalse(session.watching); XCTAssertFalse(session.timerExists)
        session.request()
        XCTAssertFalse(session.timerExists)
    }
}
