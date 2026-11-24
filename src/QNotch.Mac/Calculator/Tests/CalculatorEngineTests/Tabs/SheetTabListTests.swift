import XCTest
@testable import CalculatorEngine

/// Calculator tab checks: what closing, undoing and expiring do to the tab list, and that a closed sheet stays in the real store
/// until its window ends. No window, no network.
final class SheetTabListTests: XCTestCase {
    private static let t0 = DateTimeOffset(2026, 1, 1, 12, 0, 0)

    /// `new Guid(n, 0, 0, new byte[8])`: the first field is n, so its "D" form is 0000000n-0000-0000-0000-000000000000.
    private static func id(_ oneBased: Int) -> UUID {
        let a = UInt32(oneBased)
        return UUID(uuid: (UInt8(a >> 24), UInt8(a >> 16 & 255), UInt8(a >> 8 & 255), UInt8(a & 255), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
    /// `Guid.ToByteArray()[0]`: the low byte of the first field.
    private static func firstByte(_ id: UUID) -> UInt8 { id.uuid.3 }
    private static func sheets(_ count: Int) -> [SheetTab] { (1...count).map { SheetTab(id($0), "Sheet \($0)") } }
    private static func list(_ count: Int, _ active: Int = 0) -> SheetTabList {
        let sheets = sheets(count)
        let list = SheetTabList()
        list.update(sheets, sheets[active].id)
        return list
    }
    private static func names(_ list: SheetTabList) -> String { list.visible.map { $0.name.replacingOccurrences(of: "Sheet ", with: "") }.joined(separator: ",") }
    private let id = SheetTabListTests.id, list = SheetTabListTests.list, names = SheetTabListTests.names, t0 = SheetTabListTests.t0

    /// closing an inactive tab leaves the active sheet
    func testClosingAnInactiveTabLeavesTheActiveSheet() {
        let list = list(4, 1)
        let closed = list.close(id(4), t0)
        XCTAssertTrue(closed?.wasActive == false && closed?.position == 3)
        XCTAssertTrue(list.activeId == id(2))
        XCTAssertTrue(names(list) == "1,2,3")
    }

    /// closing the active tab activates its right neighbor, or the left one at the end
    func testClosingTheActiveTabActivatesItsRightNeighborOrTheLeftOneAtTheEnd() {
        let list = list(4, 1)
        list.close(id(2), t0)
        XCTAssertTrue(list.activeId == id(3))
        let last = self.list(3, 2)
        last.close(id(3), t0)
        XCTAssertTrue(last.activeId == id(2))
    }

    /// neighbors go outward, right first
    func testNeighborsGoOutwardRightFirst() {
        XCTAssertTrue(list(5, 0).neighborsOf(id(3)).map { String(SheetTabListTests.firstByte($0)) }.joined(separator: ",") == "4,2,5,1")
    }

    /// a chosen neighbor wins over the nearest one
    func testAChosenNeighborWinsOverTheNearestOne() {
        let list = list(4, 1)
        list.close(id(2), t0, next: id(1))
        XCTAssertTrue(list.activeId == id(1))
    }

    /// the last visible sheet cannot be closed
    func testTheLastVisibleSheetCannotBeClosed() {
        let list = list(2, 0)
        XCTAssertTrue(list.close(id(2), t0) != nil)
        XCTAssertTrue(list.canClose(id(1)) == .lastSheet)
        XCTAssertTrue(list.close(id(1), t0) == nil)
        XCTAssertTrue(names(list) == "1" && list.activeId == id(1))
    }

    /// the last sheet closes once a replacement is in front, and undo brings it back in front
    func testTheLastSheetClosesOnceAReplacementIsInFrontAndUndoBringsItBackInFront() {
        // The surface creates an empty sheet first, then closes the old one as a tab that was in front.
        let list = list(1, 0)
        list.update(SheetTabListTests.sheets(2), id(2))
        let closed = list.close(id(1), t0, wasActive: true)
        XCTAssertTrue(closed?.wasActive == true && closed?.position == 0)
        XCTAssertTrue(names(list) == "2" && list.activeId == id(2))
        XCTAssertTrue(list.undo(t0)?.id == id(1))
        XCTAssertTrue(list.activeId == id(1) && names(list) == "1,2")
    }

    /// closing all but one quickly stops at one
    func testClosingAllButOneQuicklyStopsAtOne() {
        let list = list(6, 2)
        for tab in list.visible { list.close(tab.id, t0) }
        XCTAssertTrue(list.visible.count == 1 && list.closed.count == 5)
        XCTAssertTrue(list.activeId == list.visible[0].id)
    }

    /// an unknown or already closed sheet is refused
    func testAnUnknownOrAlreadyClosedSheetIsRefused() {
        let list = list(3, 0)
        XCTAssertTrue(list.canClose(id(9)) == .unknown)
        list.close(id(3), t0)
        XCTAssertTrue(list.canClose(id(3)) == .unknown)
        XCTAssertTrue(list.close(id(3), t0) == nil)
        XCTAssertTrue(!list.setActive(id(3)))
    }

    /// undo restores the most recent close, at its old place
    func testUndoRestoresTheMostRecentCloseAtItsOldPlace() {
        let list = list(5, 0)
        list.close(id(2), t0)
        list.close(id(4), t0)
        XCTAssertTrue(names(list) == "1,3,5")
        XCTAssertTrue(list.undo(t0)?.id == id(4))
        XCTAssertTrue(names(list) == "1,3,4,5")
        XCTAssertTrue(list.undo(t0)?.id == id(2))
        XCTAssertTrue(names(list) == "1,2,3,4,5")
        XCTAssertTrue(list.undo(t0) == nil)
    }

    /// undo brings an active sheet back in front, an inactive one stays behind
    func testUndoBringsAnActiveSheetBackInFrontAnInactiveOneStaysBehind() {
        let active = list(3, 1)
        active.close(id(2), t0)
        active.setActive(id(1))   // the user moved on
        active.undo(t0)
        XCTAssertTrue(active.activeId == id(2))
        let inactive = list(3, 1)
        inactive.close(id(3), t0)
        inactive.undo(t0)
        XCTAssertTrue(inactive.activeId == id(2))
    }

    /// every close and undo moves the one deadline on
    func testEveryCloseAndUndoMovesTheOneDeadlineOn() {
        let list = list(4, 0)
        list.close(id(2), t0)
        XCTAssertTrue(list.dueAt == t0.addingTicks(SheetTabList.undoWindow))
        let later = t0.adding(seconds: 5)
        list.close(id(3), later)
        XCTAssertTrue(list.dueAt == later.addingTicks(SheetTabList.undoWindow))
        XCTAssertTrue(list.takeExpired(t0.addingTicks(SheetTabList.undoWindow)).isEmpty) // the first close did not expire on its own
        let undone = later.adding(seconds: 1)
        list.undo(undone)
        XCTAssertTrue(list.dueAt == undone.addingTicks(SheetTabList.undoWindow))
        list.undo(undone)
        XCTAssertTrue(list.dueAt == nil)
    }

    /// expiry hands over every waiting close, oldest first, once
    func testExpiryHandsOverEveryWaitingCloseOldestFirstOnce() {
        let list = list(4, 0)
        list.close(id(2), t0)
        list.close(id(3), t0)
        XCTAssertTrue(list.takeExpired(t0.adding(seconds: 7.9)).isEmpty)
        let due = list.takeExpired(t0.addingTicks(SheetTabList.undoWindow))
        XCTAssertTrue(due.map(\.id) == [id(2), id(3)])
        XCTAssertTrue(list.dueAt == nil && list.closed.isEmpty && list.totalCount == 2)
        XCTAssertTrue(list.takeExpired(t0.adding(hours: 1)).isEmpty)
        XCTAssertTrue(list.undo(t0) == nil)
    }

    /// shutdown takes everything regardless of the deadline
    func testShutdownTakesEverythingRegardlessOfTheDeadline() {
        let list = list(3, 0)
        list.close(id(3), t0)
        XCTAssertTrue(list.takeAll().map(\.id) == [id(3)])
        XCTAssertTrue(list.dueAt == nil)
    }

    /// waiting closes count toward the limit and keep their names
    func testWaitingClosesCountTowardTheLimitAndKeepTheirNames() {
        let list = list(SheetTabList.maxSheets, 0)
        list.close(id(2), t0)
        XCTAssertTrue(!list.canCreate && list.totalCount == SheetTabList.maxSheets)
        XCTAssertTrue(list.uniqueName { "Sheet \($0)" } == "Sheet 257")
        _ = list.takeExpired(t0.adding(minutes: 1))
        XCTAssertTrue(list.canCreate)
        XCTAssertTrue(list.uniqueName { "Sheet \($0)" } == "Sheet 2")
    }

    /// a catalog refresh keeps waiting closes hidden and in place
    func testACatalogRefreshKeepsWaitingClosesHiddenAndInPlace() {
        let sheets = SheetTabListTests.sheets(4)
        let list = SheetTabList()
        list.update(sheets, sheets[0].id)
        list.close(id(3), t0)
        list.update(sheets + [SheetTab(id(5), "Sheet 5")], id(1))
        XCTAssertTrue(names(list) == "1,2,4,5" && list.closed.count == 1)
        list.undo(t0)
        XCTAssertTrue(names(list) == "1,2,3,4,5")
    }

    /// a sheet removed elsewhere stops waiting
    func testASheetRemovedElsewhereStopsWaiting() {
        let sheets = SheetTabListTests.sheets(3)
        let list = SheetTabList()
        list.update(sheets, sheets[0].id)
        list.close(id(3), t0)
        list.update(sheets.prefix(2), id(1))
        XCTAssertTrue(list.closed.isEmpty && list.dueAt == nil)
        XCTAssertTrue(list.undo(t0) == nil)
    }

    /// a catalog that names a waiting sheet as active falls back to a visible one
    func testACatalogThatNamesAWaitingSheetAsActiveFallsBackToAVisibleOne() {
        let sheets = SheetTabListTests.sheets(3)
        let list = SheetTabList()
        list.update(sheets, sheets[0].id)
        list.close(id(2), t0)
        list.update(sheets, id(2))
        XCTAssertTrue(list.activeId == id(1))
    }

    /// sync leaving only a waiting sheet makes it the visible last sheet
    func testSyncLeavingOnlyAWaitingSheetMakesItTheVisibleLastSheet() {
        let sheets = SheetTabListTests.sheets(2)
        let list = SheetTabList()
        list.update(sheets, id(2))
        list.close(id(1), t0)
        list.update(sheets.prefix(1), id(2)) // another computer deleted the active sheet
        XCTAssertTrue(names(list) == "1" && list.activeId == id(1))
        XCTAssertTrue(list.closed.isEmpty && list.dueAt == nil)
        XCTAssertTrue(list.takeAll().isEmpty)
    }

    /// a group delete is one change and always leaves a sheet
    func testAGroupDeleteIsOneChangeAndAlwaysLeavesASheet() throws {
        let directory = TestFiles.temporary("qnotch-calculator-tests")
        defer { TestFiles.delete(directory) }
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        let first = try store.load().workspace.activeSheetId
        let second = try store.create("Two").activeSheetId
        let third = try store.create("Three").activeSheetId
        let left = try store.deleteMany([second, third])
        XCTAssertTrue(left.sheets.count == 1 && left.sheets[0].id == first && left.activeSheetId == first)
        var refused = false
        do { try store.deleteMany([first]) } catch let e where e.isInvalidData { refused = true }
        XCTAssertTrue(try refused && store.open(first).document.id == first)
    }

    /// a crash during the window loses nothing: the store still holds the closed sheet
    func testACrashDuringTheWindowLosesNothingTheStoreStillHoldsTheClosedSheet() throws {
        let directory = TestFiles.temporary("qnotch-calculator-tests")
        defer { TestFiles.delete(directory) }
        let kept: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            var workspace = try store.load().workspace
            let first = workspace.activeSheetId
            workspace = try store.create("Keep me", "1 + 1")
            kept = workspace.activeSheetId
            let list = SheetTabList()
            list.update(workspace.sheets.map { SheetTab($0.id, $0.name) }, kept)
            XCTAssertTrue(list.close(kept, t0, next: first) != nil)
            try store.select(first)
            // No delete yet: the process ends here.
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        let workspace = try reopened.load().workspace
        XCTAssertTrue(workspace.sheets.contains { $0.id == kept && $0.name == "Keep me" })
        XCTAssertTrue(try reopened.open(kept).document.source == "1 + 1")
        XCTAssertTrue(workspace.activeSheetId != kept)
    }
}
