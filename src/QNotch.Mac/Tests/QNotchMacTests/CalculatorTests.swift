import AppKit
import XCTest
import CalculatorEngine
@testable import QNotchMac

/// The tab list's close and undo rules, a port of tests/QNotch.CalculatorTests/Tabs/SheetTabListTests.cs.
final class CalculatorTabListTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_767_268_800)

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000", n))! }
    private func sheets(_ count: Int) -> [CalculatorTab] { (1...count).map { CalculatorTab(id: id($0), name: "Sheet \($0)") } }
    private func list(_ count: Int, active: Int = 0) -> CalculatorTabList {
        let tabs = sheets(count)
        let list = CalculatorTabList()
        list.update(tabs, active: tabs[active].id)
        return list
    }
    private func names(_ list: CalculatorTabList) -> String { list.visible.map { $0.name.replacingOccurrences(of: "Sheet ", with: "") }.joined(separator: ",") }

    func testClosingAnInactiveTabLeavesTheActiveSheet() {
        let list = list(4, active: 1)
        let closed = list.close(id(4), now: t0)
        XCTAssertEqual(closed?.wasActive, false)
        XCTAssertEqual(closed?.position, 3)
        XCTAssertEqual(list.activeID, id(2))
        XCTAssertEqual(names(list), "1,2,3")
    }

    func testClosingTheActiveTabActivatesItsRightNeighborOrTheLeftOneAtTheEnd() {
        let list = list(4, active: 1)
        list.close(id(2), now: t0)
        XCTAssertEqual(list.activeID, id(3))
        let last = self.list(3, active: 2)
        last.close(id(3), now: t0)
        XCTAssertEqual(last.activeID, id(2))
    }

    func testNeighborsGoOutwardRightFirst() {
        XCTAssertEqual(list(5).neighbors(of: id(3)), [id(4), id(2), id(5), id(1)])
    }

    func testAChosenNeighborWinsOverTheNearestOne() {
        let list = list(4, active: 1)
        list.close(id(2), now: t0, next: id(1), wasActive: false)
        XCTAssertEqual(list.activeID, id(1))
    }

    func testTheLastVisibleSheetCannotBeClosed() {
        let list = list(2)
        XCTAssertNotNil(list.close(id(2), now: t0))
        XCTAssertEqual(list.canClose(id(1)), .lastSheet)
        XCTAssertNil(list.close(id(1), now: t0))
        XCTAssertEqual(names(list), "1")
        XCTAssertEqual(list.activeID, id(1))
    }

    func testTheLastSheetClosesOnceAReplacementIsInFrontAndUndoBringsItBackInFront() {
        let list = list(1)
        list.update(sheets(2), active: id(2))
        let closed = list.close(id(1), now: t0, next: nil, wasActive: true)
        XCTAssertEqual(closed?.wasActive, true)
        XCTAssertEqual(closed?.position, 0)
        XCTAssertEqual(names(list), "2")
        XCTAssertEqual(list.activeID, id(2))
        XCTAssertEqual(list.undo(now: t0)?.id, id(1))
        XCTAssertEqual(list.activeID, id(1))
        XCTAssertEqual(names(list), "1,2")
    }

    func testClosingAllButOneQuicklyStopsAtOne() {
        let list = list(6, active: 2)
        for tab in list.visible { list.close(tab.id, now: t0) }
        XCTAssertEqual(list.visible.count, 1)
        XCTAssertEqual(list.closed.count, 5)
        XCTAssertEqual(list.activeID, list.visible[0].id)
    }

    func testAnUnknownOrAlreadyClosedSheetIsRefused() {
        let list = list(3)
        XCTAssertEqual(list.canClose(id(9)), .unknown)
        list.close(id(3), now: t0)
        XCTAssertEqual(list.canClose(id(3)), .unknown)
        XCTAssertNil(list.close(id(3), now: t0))
        XCTAssertFalse(list.setActive(id(3)))
    }

    func testUndoRestoresTheMostRecentCloseAtItsOldPlace() {
        let list = list(5)
        list.close(id(2), now: t0)
        list.close(id(4), now: t0)
        XCTAssertEqual(names(list), "1,3,5")
        XCTAssertEqual(list.undo(now: t0)?.id, id(4))
        XCTAssertEqual(names(list), "1,3,4,5")
        XCTAssertEqual(list.undo(now: t0)?.id, id(2))
        XCTAssertEqual(names(list), "1,2,3,4,5")
        XCTAssertNil(list.undo(now: t0))
    }

    func testUndoBringsAnActiveSheetBackInFrontAnInactiveOneStaysBehind() {
        let active = list(3, active: 1)
        active.close(id(2), now: t0)
        active.setActive(id(1))
        active.undo(now: t0)
        XCTAssertEqual(active.activeID, id(2))
        let inactive = list(3, active: 1)
        inactive.close(id(3), now: t0)
        inactive.undo(now: t0)
        XCTAssertEqual(inactive.activeID, id(2))
    }

    func testEveryCloseAndUndoMovesTheOneDeadlineOn() {
        let list = list(4)
        let window = CalculatorTabList.undoWindow
        list.close(id(2), now: t0)
        XCTAssertEqual(list.dueAt, t0 + window)
        let later = t0 + 5
        list.close(id(3), now: later)
        XCTAssertEqual(list.dueAt, later + window)
        XCTAssertTrue(list.takeExpired(now: t0 + window).isEmpty, "the first close did not expire on its own")
        let undone = later + 1
        list.undo(now: undone)
        XCTAssertEqual(list.dueAt, undone + window)
        list.undo(now: undone)
        XCTAssertNil(list.dueAt)
    }

    func testExpiryHandsOverEveryWaitingCloseOldestFirstOnce() {
        let list = list(4)
        list.close(id(2), now: t0)
        list.close(id(3), now: t0)
        XCTAssertTrue(list.takeExpired(now: t0 + 7.9).isEmpty)
        XCTAssertEqual(list.takeExpired(now: t0 + CalculatorTabList.undoWindow).map(\.id), [id(2), id(3)])
        XCTAssertNil(list.dueAt)
        XCTAssertTrue(list.closed.isEmpty)
        XCTAssertEqual(list.totalCount, 2)
        XCTAssertTrue(list.takeExpired(now: t0 + 3600).isEmpty)
        XCTAssertNil(list.undo(now: t0))
    }

    func testShutdownTakesEverythingRegardlessOfTheDeadline() {
        let list = list(3)
        list.close(id(3), now: t0)
        XCTAssertEqual(list.takeAll().map(\.id), [id(3)])
        XCTAssertNil(list.dueAt)
    }

    func testWaitingClosesCountTowardTheLimitAndKeepTheirNames() {
        let list = list(CalculatorTabList.maxSheets)
        list.close(id(2), now: t0)
        XCTAssertFalse(list.canCreate)
        XCTAssertEqual(list.totalCount, CalculatorTabList.maxSheets)
        XCTAssertEqual(list.uniqueName { "Sheet \($0)" }, "Sheet 257")
        _ = list.takeExpired(now: t0 + 60)
        XCTAssertTrue(list.canCreate)
        XCTAssertEqual(list.uniqueName { "Sheet \($0)" }, "Sheet 2")
    }

    func testACatalogRefreshKeepsWaitingClosesHiddenAndInPlace() {
        let tabs = sheets(4)
        let list = CalculatorTabList()
        list.update(tabs, active: tabs[0].id)
        list.close(id(3), now: t0)
        list.update(tabs + [CalculatorTab(id: id(5), name: "Sheet 5")], active: id(1))
        XCTAssertEqual(names(list), "1,2,4,5")
        XCTAssertEqual(list.closed.count, 1)
        list.undo(now: t0)
        XCTAssertEqual(names(list), "1,2,3,4,5")
    }

    func testASheetRemovedElsewhereStopsWaiting() {
        let tabs = sheets(3)
        let list = CalculatorTabList()
        list.update(tabs, active: tabs[0].id)
        list.close(id(3), now: t0)
        list.update(Array(tabs.prefix(2)), active: id(1))
        XCTAssertTrue(list.closed.isEmpty)
        XCTAssertNil(list.dueAt)
        XCTAssertNil(list.undo(now: t0))
    }

    func testACatalogThatNamesAWaitingSheetAsActiveFallsBackToAVisibleOne() {
        let tabs = sheets(3)
        let list = CalculatorTabList()
        list.update(tabs, active: tabs[0].id)
        list.close(id(2), now: t0)
        list.update(tabs, active: id(2))
        XCTAssertEqual(list.activeID, id(1))
    }

    func testSyncLeavingOnlyAWaitingSheetMakesItTheVisibleLastSheet() {
        let tabs = sheets(2)
        let list = CalculatorTabList()
        list.update(tabs, active: id(2))
        list.close(id(1), now: t0)
        list.update(Array(tabs.prefix(1)), active: id(2))
        XCTAssertEqual(names(list), "1")
        XCTAssertEqual(list.activeID, id(1))
        XCTAssertTrue(list.closed.isEmpty)
        XCTAssertNil(list.dueAt)
        XCTAssertTrue(list.takeAll().isEmpty)
    }

    func testAGroupDeleteIsOneChangeAndAlwaysLeavesASheet() throws {
        let store = InMemoryCalculatorDocuments()
        let first = store.activeSheetID
        let second = try store.create(name: "Two", source: "")
        let third = try store.create(name: "Three", source: "")
        try store.delete([second, third])
        XCTAssertEqual(store.sheets.map(\.id), [first])
        XCTAssertEqual(store.activeSheetID, first)
        XCTAssertThrowsError(try store.delete([first]))
        XCTAssertNoThrow(try store.source(of: first))
    }

    func testSheetNamesAreTrimmedAndRefuseControlCharacters() {
        XCTAssertEqual(try InMemoryCalculatorDocuments.validName("  Rent  "), "Rent")
        XCTAssertThrowsError(try InMemoryCalculatorDocuments.validName("   "))
        XCTAssertThrowsError(try InMemoryCalculatorDocuments.validName("a\u{7}b"))
        XCTAssertThrowsError(try InMemoryCalculatorDocuments.validName(String(repeating: "x", count: 81)))
    }
}

/// The open Calculator without views: evaluation, sheets, closing with Undo, preferences and the date refresh.
@MainActor
final class CalculatorWorkspaceTests: XCTestCase {
    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: NSPasteboard.Name("dev.qnotch.tests.calculator.\(UUID().uuidString)"))
        CalculatorClipboard.board = board
    }
    override func tearDown() {
        board.releaseGlobally()
        super.tearDown()
    }

    private func workspace(_ sheets: [(String, String)] = [("Sheet", "a = 2\na * 21")], active: Int = 0) -> CalculatorWorkspace {
        let documents = InMemoryCalculatorDocuments(sheets: sheets.map { (name: $0.0, source: $0.1) }, active: active)
        try? documents.updatePreferences { $0.numberStyle = "plain" }
        return CalculatorWorkspace(documents: documents, tabs: CalculatorTabList(), synchronous: true)
    }

    func testTypingUpdatesTheResultsBesideEachLine() {
        let workspace = workspace()
        XCTAssertEqual(workspace.lines.map(\.answer), ["2", "42"])
        XCTAssertEqual(workspace.lines[1].dependencies, [0])
        let delivered = workspace.deliveries
        workspace.edit("a = 2\na * 21\na + 1")
        XCTAssertEqual(workspace.deliveries, delivered + 1)
        XCTAssertEqual(workspace.lines.map(\.answer), ["2", "42", "3"])
        XCTAssertTrue(workspace.dirty)
    }

    func testCompositionDefersEvaluationUntilTheInputMethodCommits() {
        let workspace = workspace()
        let delivered = workspace.deliveries
        workspace.edit("a = 2\na * 2", composing: true)
        XCTAssertEqual(workspace.deliveries, delivered)
        XCTAssertFalse(workspace.close(workspace.activeID), "a sheet being composed is never closed")
        workspace.edit("a = 2\na * 2", composing: false)
        XCTAssertEqual(workspace.lines.last?.answer, "4")
    }

    func testResultsKeepTheirLinesAcrossAnEditStillBeingEvaluated() {
        let old: [Substring] = ["1+1", "x = 2", "x * 3", "4+4"]
        // A line inserted after the first: the lines around it keep their results; the new one has none yet.
        let current: [Substring] = ["1+1", "new", "x = 2", "x * 3", "4+4"]
        XCTAssertEqual((0..<5).map { CalculatorWorkspace.evaluatedLine(for: $0, old: old, current: current) }, [0, nil, 1, 2, 3])
        // A line deleted.
        let deleted: [Substring] = ["1+1", "x * 3", "4+4"]
        XCTAssertEqual((0..<3).map { CalculatorWorkspace.evaluatedLine(for: $0, old: old, current: deleted) }, [0, 2, 3])
        // An edited line shows nothing until its answer arrives.
        let edited: [Substring] = ["1+1", "x = 5", "x * 3", "4+4"]
        XCTAssertEqual((0..<4).map { CalculatorWorkspace.evaluatedLine(for: $0, old: old, current: edited) }, [0, nil, 2, 3])
    }

    func testCopyPutsTheCopyTextOnTheClipboard() {
        let workspace = workspace()
        XCTAssertTrue(workspace.copy(workspace.lines[1]))
        XCTAssertEqual(board.string(forType: .string), "42")
    }

    func testNewSheetsTakeTheFirstFreeNumberAndComeInFront() {
        let workspace = workspace()
        XCTAssertTrue(workspace.newSheet())
        XCTAssertEqual(workspace.activeName, "Sheet 1")
        XCTAssertTrue(workspace.source.isEmpty)
        XCTAssertTrue(workspace.newSheet())
        XCTAssertEqual(workspace.tabs.visible.map(\.name), ["Sheet", "Sheet 1", "Sheet 2"])
    }

    func testClosingTheSheetInFrontSavesItMovesRightAndUndoBringsItBack() {
        let workspace = workspace([("A", "1+1"), ("B", "2+2"), ("C", "3+3")], active: 1)
        let b = workspace.activeID
        workspace.edit("2+3")
        XCTAssertTrue(workspace.close(b))
        XCTAssertEqual(workspace.activeName, "C")
        XCTAssertEqual(workspace.notice, CalculatorWorkspace.Notice(text: "Closed B.", undo: true, tip: "B"))
        XCTAssertTrue(workspace.documents.sheets.contains { $0.id == b }, "a closed sheet stays until its undo window ends")
        XCTAssertTrue(workspace.undoClose())
        XCTAssertEqual(workspace.activeID, b)
        XCTAssertEqual(workspace.source, "2+3", "the unsaved edit was saved before closing")
        XCTAssertNil(workspace.notice)
    }

    func testClosingAnotherTabKeepsTheSheetInFrontAndCountsTheOthers() {
        let workspace = workspace([("A", ""), ("B", ""), ("C", "")], active: 0)
        let ids = workspace.tabs.visible.map(\.id)
        workspace.close(ids[1])
        workspace.close(ids[2])
        XCTAssertEqual(workspace.activeID, ids[0])
        XCTAssertEqual(workspace.notice?.text, "Closed C and 1 more.")
        workspace.undoClose()
        XCTAssertEqual(workspace.activeID, ids[0], "an inactive tab comes back behind")
        XCTAssertEqual(workspace.notice?.text, "Closed B.")
    }

    func testClosingTheLastSheetReplacesItAndUndoDropsTheUnusedReplacement() {
        let workspace = workspace([("Only", "1+1")])
        let only = workspace.activeID
        XCTAssertTrue(workspace.close(only))
        XCTAssertNotEqual(workspace.activeID, only)
        XCTAssertEqual(workspace.activeName, "Sheet 1")
        XCTAssertEqual(workspace.tabs.visible.count, 1)
        let fresh = workspace.activeID
        XCTAssertTrue(workspace.undoClose())
        XCTAssertEqual(workspace.activeID, only)
        XCTAssertFalse(workspace.documents.sheets.contains { $0.id == fresh })
        XCTAssertEqual(workspace.tabs.visible.map(\.name), ["Only"])
    }

    func testAReplacementSomeoneTypedIntoStaysAfterUndo() {
        let workspace = workspace([("Only", "1+1")])
        let only = workspace.activeID
        workspace.close(only)
        workspace.edit("5*5")
        workspace.undoClose()
        XCTAssertEqual(workspace.activeID, only)
        XCTAssertEqual(workspace.tabs.visible.map(\.name), ["Only", "Sheet 1"])
    }

    func testExpiredClosesBecomeDeletes() {
        let workspace = workspace([("A", ""), ("B", "")])
        let b = workspace.tabs.visible[1].id
        let start = Date()
        workspace.now = { start }
        workspace.close(b)
        workspace.now = { start + CalculatorTabList.undoWindow + 0.1 }
        workspace.commitClosedSheets(everything: false)
        XCTAssertFalse(workspace.documents.sheets.contains { $0.id == b })
        XCTAssertNil(workspace.notice)
        XCTAssertFalse(workspace.undoClose())
    }

    func testShutdownDeletesWaitingClosesAndSaves() {
        let workspace = workspace([("A", ""), ("B", "")])
        let a = workspace.activeID, b = workspace.tabs.visible[1].id
        workspace.edit("7*6")
        workspace.close(b)
        workspace.shutdown()
        XCTAssertEqual(workspace.documents.sheets.map(\.id), [a])
        XCTAssertEqual(try workspace.documents.source(of: a), "7*6")
    }

    func testTheSheetLimitIsANoticeNotAFailure() {
        let sheets = (0..<CalculatorTabList.maxSheets).map { ("S\($0)", "") }
        let workspace = workspace(sheets)
        XCTAssertFalse(workspace.newSheet())
        XCTAssertEqual(workspace.notice?.text, CalculatorText.sheetLimit(CalculatorTabList.maxSheets))
        XCTAssertEqual(workspace.notice?.undo, false)
    }

    func testRenameChecksTheName() {
        let workspace = workspace()
        let id = workspace.activeID
        XCTAssertEqual(workspace.rename(id, to: "\u{1}"), CalculatorText.invalidSheetName)
        XCTAssertNil(workspace.rename(id, to: "  Budget "))
        XCTAssertEqual(workspace.tabs.visible.first?.name, "Budget")
    }

    func testCycleMovesThroughTheTabsBothWays() {
        let workspace = workspace([("A", ""), ("B", ""), ("C", "")])
        workspace.cycle(1)
        XCTAssertEqual(workspace.activeName, "B")
        workspace.cycle(-1)
        workspace.cycle(-1)
        XCTAssertEqual(workspace.activeName, "C")
    }

    func testPreferencesRecalculateWithTheNewFormat() {
        let workspace = workspace([("Sheet", "1/3")])
        XCTAssertEqual(workspace.lines.first?.answer, "≈ 0.3333")
        let delivered = workspace.deliveries
        workspace.updatePreferences { $0.decimalPlaces = 2 }
        XCTAssertEqual(workspace.format.decimalPlaces, 2)
        XCTAssertEqual(workspace.deliveries, delivered + 1)
        XCTAssertEqual(workspace.lines.first?.answer, "0.33")
    }

    func testDateRefreshRunsOnlyWhileVisible() {
        let workspace = workspace([("Sheet", "today")])
        XCTAssertEqual(workspace.evaluation?.usesCurrentDate, true)
        XCTAssertFalse(workspace.hasDateSchedule, "nothing is scheduled while hidden")
        workspace.setVisible(true)
        XCTAssertTrue(workspace.hasDateSchedule)
        workspace.setVisible(false)
        XCTAssertFalse(workspace.hasDateSchedule)
        let plain = self.workspace()
        plain.setVisible(true)
        XCTAssertFalse(plain.hasDateSchedule, "a sheet without dates needs no timer")
    }

    func testRefreshDeadlines() {
        let zone = TimeZone(identifier: "Europe/Bucharest")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let evening = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 23, minute: 59, second: 30))!
        XCTAssertEqual(CalculatorWorkspace.midnightDelay(evening, zone: zone), 30, accuracy: 0.001)
        XCTAssertEqual(CalculatorWorkspace.secondDelay(Date(timeIntervalSince1970: 100.25)), 0.75, accuracy: 0.0001)
    }
}

/// Hover cards, explanations and accessible names from real engine results.
final class CalculatorResultTextTests: XCTestCase {
    private func lines(_ source: String) throws -> [CalculatorLineResult] {
        try CalculatorSheet().evaluate(source, format: CalculatorFormat(styleId: "plain")).lines
    }

    func testAPlainResultHasNoCardAndADependentOneNamesItsSources() throws {
        let results = try lines("a = 2\na * 21")
        XCTAssertNil(CalculatorResultText.card(results[0]))
        XCTAssertEqual(CalculatorResultText.summary(results[1]).sources, "Uses L1")
        XCTAssertEqual(CalculatorResultText.accessibilityName(results[1]), "Line 2: 42. Copy result")
        XCTAssertTrue(CalculatorResultText.copies(results[1]))
    }

    func testARoundedResultKeepsItsExactValueOneHoverAway() throws {
        let result = try XCTUnwrap(lines("250 km in miles").first)
        XCTAssertTrue(result.answer.hasPrefix("≈"))
        guard case let .explain(headline, note, _, kind)? = CalculatorResultText.card(result) else { return XCTFail("no card") }
        XCTAssertEqual(headline, result.exact)
        XCTAssertEqual(note, "", "the engine's guarantees (Exact definitions…) are not the value's origin")
        XCTAssertEqual(kind, "Number")
        let explanation = CalculatorResultText.explanation(result)
        XCTAssertTrue(explanation.contains("convert unit(250 km) = "), explanation)
        XCTAssertTrue(CalculatorResultText.explains(result))
    }

    func testAnErrorIsAProblemCardAndCannotBeCopied() throws {
        let result = try XCTUnwrap(lines("1/0").first)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(CalculatorResultText.card(result), .problem(result.error!))
        XCTAssertFalse(CalculatorResultText.copies(result))
        XCTAssertEqual(CalculatorResultText.accessibilityName(result), "Line 1: \(CalculatorResultText.shown(result))")
    }

    func testKindNamesReadAsWords() {
        XCTAssertEqual(CalculatorResultText.kindName("LocalTimestamp"), "Local timestamp")
        XCTAssertEqual(CalculatorResultText.kindName("Money"), "Money")
        XCTAssertNil(CalculatorResultText.kindName(nil))
    }

    func testCardTextJoinsTheKindAndSources() {
        let card = CalculatorResultText.Card.explain(headline: "1/3", note: "", sources: "Uses L1", kind: "Number")
        XCTAssertEqual(card.text, "1/3\nNumber · Uses L1")
    }
}

/// Search answers: only real calculations, off the main thread, remembered per query.
@MainActor
final class CalculatorSearchTests: XCTestCase {
    func testOrdinaryWordsNeverStartTheEngine() {
        let search = CalculatorSearch()
        XCTAssertTrue(search.find("weather").isEmpty)
        XCTAssertFalse(search.isCalculating)
        XCTAssertTrue(search.find("2026 plans").isEmpty)
        XCTAssertFalse(search.isCalculating)
    }

    func testAnAnswerArrivesAfterTheKeystrokeAndCopiesOnRun() {
        let search = CalculatorSearch()
        let arrived = expectation(description: "answer")
        search.answered = { arrived.fulfill() }
        var copied: CalculatorSearch.Answer?
        search.run = { copied = $0 }
        XCTAssertTrue(search.find("12*3+1").isEmpty, "the keystroke never waits for the engine")
        XCTAssertTrue(search.isCalculating)
        wait(for: [arrived], timeout: 10)
        let hits = search.find("12*3+1")
        XCTAssertEqual(hits.map(\.title), ["37"])
        XCTAssertEqual(hits.first?.detail, "12*3+1")
        hits.first?.run()
        XCTAssertEqual(copied?.copy, "37")
    }

    func testAStaleQueryIsCancelledByTheNextOne() {
        let search = CalculatorSearch()
        let arrived = expectation(description: "answer")
        arrived.assertForOverFulfill = false
        search.answered = { arrived.fulfill() }
        _ = search.find("1+1")
        _ = search.find("1+2")
        wait(for: [arrived], timeout: 10)
        XCTAssertEqual(search.find("1+2").map(\.title), ["3"])
    }
}

/// The page itself: pills beside lines, copying, the editor's geometry and the strip.
@MainActor
final class CalculatorViewTests: XCTestCase {
    private func page(_ source: String = "a = 2\na * 21\n\n# Heading\nb = a + 1") -> CalculatorTabView {
        CalculatorClipboard.board = NSPasteboard(name: NSPasteboard.Name("dev.qnotch.tests.calculator.\(UUID().uuidString)"))
        let documents = InMemoryCalculatorDocuments(sheets: [("One", source), ("Two", "")])
        try? documents.updatePreferences { $0.numberStyle = "plain" }
        let workspace = CalculatorWorkspace(documents: documents, tabs: CalculatorTabList(), synchronous: true)
        let page = CalculatorTabView(workspace: workspace, shell: nil)
        page.frame = NSRect(x: 0, y: 0, width: 676, height: 300)
        page.layoutSubtreeIfNeeded()
        page.layout()
        page.layoutResults()
        return page
    }

    func testEveryLineWithAResultGetsANamedPillOnItsRow() throws {
        let page = page()
        XCTAssertEqual(Set(page.pillsByLine.keys), [0, 1, 4])
        let pill = try XCTUnwrap(page.pillsByLine[1])
        XCTAssertEqual(pill.text, "42")
        XCTAssertEqual(pill.accessibilityLabel(), "Line 2: 42. Copy result")
        XCTAssertEqual(pill.identifier?.rawValue, "calculator-result-2")
        XCTAssertEqual(pill.accessibilityValue() as? String, "a * 21", "VoiceOver reads the line's expression with its result")
        XCTAssertEqual(pill.accessibilityCustomActions()?.map(\.name), [CalculatorText.explainMenu])
        let rows = [0, 1, 4].compactMap { page.pillsByLine[$0]?.frame.minY }
        XCTAssertEqual(rows, rows.sorted(), "results follow their lines down the column")
        XCTAssertGreaterThan(rows[2] - rows[1], rows[1] - rows[0], "the blank line and the heading push the last result down")
    }

    func testPressingAPillCopiesAndConfirms() throws {
        let page = page()
        let pill = try XCTUnwrap(page.pillsByLine[1])
        XCTAssertTrue(pill.accessibilityPerformPress())
        XCTAssertEqual(CalculatorClipboard.board.string(forType: .string), "42")
        XCTAssertTrue(pill.showsCopied)
    }

    func testHidingThePageClosesItsCardAndReleasesThePanel() {
        let page = page()
        page.workspace.setVisible(true)
        page.stripAll(page.more)
        XCTAssertNotNil(page.overlayContent)
        page.workspace.setVisible(false)
        XCTAssertNil(page.overlayContent, "an open card would otherwise hold the panel open on other tabs")
    }

    func testTheEditorTracksLines() {
        let editor = SheetTextView(sheetID: UUID(), text: "1\n22\n\n333", fontSize: 15)
        XCTAssertEqual(editor.lineStarts, [0, 2, 5, 6])
        XCTAssertEqual(editor.line(at: 0), 0)
        XCTAssertEqual(editor.line(at: 3), 1)
        XCTAssertEqual(editor.line(at: 6), 3)
        XCTAssertTrue(SheetTextView.isColourLiteral("#3cc8d9"))
        XCTAssertFalse(SheetTextView.isColourLiteral("#budget"))
        XCTAssertFalse(editor.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
    }

    func testTheStripShowsTheSheetsAndClosingUpdatesIt() {
        let page = page()
        XCTAssertEqual(page.strip.tabs.map(\.name), ["One", "Two"])
        let two = page.workspace.tabs.visible[1].id
        page.workspace.close(two)
        XCTAssertEqual(page.strip.tabs.map(\.name), ["One"])
        XCTAssertFalse(page.notice.isHidden)
        page.workspace.undoClose()
        XCTAssertEqual(page.strip.tabs.map(\.name), ["One", "Two"])
    }

    func testSwitchingSheetsSwapsTheEditorAndKeepsUndoPerSheet() {
        let page = page()
        let first = page.editor
        page.workspace.switchTo(page.workspace.tabs.visible[1].id)
        XCTAssertFalse(page.editor === first)
        XCTAssertTrue(page.pillsByLine.isEmpty)
        page.workspace.switchTo(page.workspace.tabs.visible[0].id)
        XCTAssertTrue(page.editor === first, "a recent sheet keeps its editor and undo stack")
    }

    func testSettingsPageOffersTheSupportedPreferences() {
        let documents = InMemoryCalculatorDocuments()
        let workspace = CalculatorWorkspace(documents: documents, tabs: CalculatorTabList(), synchronous: true)
        let page = CalculatorSettingsView.page(workspace)
        let text = Outline.text(for: page)
        for id in ["calculator-settings-workday", "calculator-settings-text-size", "calculator-settings-decimal-places",
                   "calculator-settings-number-format", "calculator-settings-default-currency", "calculator-settings-download-latest",
                   "calculator-settings-download-monthly", "calculator-settings-auto-rates", "calculator-settings-rate-source"] {
            XCTAssertTrue(text.contains("#" + id), id)
        }
        XCTAssertTrue(Outline.unnamedControls(in: text).isEmpty, text)
    }
}

/// The rates button, its menu and the automatic download (Windows CalculatorSurface.Currencies). Every run is offline.
final class CalculatorRatesTests: XCTestCase {
    private func day(_ year: Int, _ month: Int, _ day: Int) -> CalculatorDay { CalculatorDay(year: year, month: month, day: day)! }
    private func status(downloading: Bool = false, warning: String? = nil, requests: [CalculatorDay?]? = nil, latest: CalculatorRateText.Snapshot?,
                        historical: [CalculatorDay: CalculatorRateText.Snapshot] = [:]) -> String {
        CalculatorRateText.status(downloading: downloading, warning: warning, uses: requests != nil, requests: requests ?? [], latest: latest,
                                  historical: historical, today: day(2026, 11, 24))
    }
    private func workspace(_ source: String) -> CalculatorWorkspace {
        let documents = InMemoryCalculatorDocuments(sheets: [(name: "Sheet", source: source)])
        try? documents.updatePreferences { $0.numberStyle = "plain" }
        return CalculatorWorkspace(documents: documents, tabs: CalculatorTabList(), synchronous: true)
    }

    func testTheStatusNamesTheSourceAndHowOldTheRatesAre() {
        let daily = CalculatorRateText.Snapshot(isMonthly: false, asOf: day(2026, 11, 21))
        XCTAssertEqual(status(latest: daily), "ECB · 21 Nov")
        XCTAssertEqual(status(latest: CalculatorRateText.Snapshot(isMonthly: false, asOf: day(2026, 11, 20))), "ECB · stale 20 Nov")
        XCTAssertEqual(status(latest: CalculatorRateText.Snapshot(isMonthly: true, asOf: day(2026, 11, 1))), "EU monthly · Nov 2026")
        XCTAssertEqual(status(latest: CalculatorRateText.Snapshot(isMonthly: true, asOf: day(2026, 10, 1))), "EU monthly · stale Oct 2026")
        XCTAssertEqual(status(latest: nil), "Rates unavailable")
        XCTAssertEqual(status(latest: nil, historical: [day(2026, 1, 5): daily]), "ECB · history cached")
        XCTAssertEqual(status(downloading: true, latest: daily), "Downloading rates…")
        XCTAssertEqual(status(warning: "Downloaded rates in memory; cache save failed", latest: daily), "ECB · not saved")
    }

    func testTheStatusFollowsTheDatesTheSheetAsksFor() {
        let latest = CalculatorRateText.Snapshot(isMonthly: false, asOf: day(2026, 11, 21))
        let history = [day(2025, 1, 6): CalculatorRateText.Snapshot(isMonthly: false, asOf: day(2025, 1, 6)),
                       day(2025, 1, 5): CalculatorRateText.Snapshot(isMonthly: false, asOf: day(2025, 1, 3))]
        XCTAssertEqual(status(requests: [nil], latest: latest, historical: history), "ECB · 21 Nov")
        XCTAssertEqual(status(requests: [day(2025, 1, 6)], latest: latest, historical: history), "ECB · 2025-01-06")
        XCTAssertEqual(status(requests: [day(2025, 1, 6), day(2025, 1, 5)], latest: latest, historical: history), "ECB · multiple dates")
        XCTAssertEqual(status(requests: [nil, day(2025, 1, 6)], latest: latest, historical: history), "ECB · mixed dates")
        XCTAssertEqual(status(requests: [day(2024, 2, 2)], latest: latest, historical: history), "History unavailable")
        XCTAssertEqual(status(requests: [nil], latest: nil), "Rates unavailable")
    }

    func testASheetThatConvertsMoneyShowsTheRatesButtonAndMenu() throws {
        let page = CalculatorTabView(workspace: workspace("100 EUR in USD\n50 EUR in USD on 2025-01-06"), shell: nil)
        page.frame = NSRect(x: 0, y: 0, width: 676, height: 300)
        page.layoutSubtreeIfNeeded()
        let currencies = page.workspace.currencies
        XCTAssertTrue(currencies.uses)
        XCTAssertFalse(page.ratesButton.isHidden)
        XCTAssertEqual(page.ratesButton.text, "Rates unavailable")
        XCTAssertEqual(page.ratesButton.accessibilityLabel(), "Currency reference rates: Rates unavailable")
        page.showRatesMenu()
        let menu = try XCTUnwrap(page.overlayContent as? RatesMenuCard)
        XCTAssertEqual(menu.entries.map(\.id), ["calculator-rates-status", "calculator-rates-latest", "calculator-rates-monthly", "calculator-rates-history",
                                                "calculator-rates-auto", "calculator-rates-source"])
        XCTAssertEqual(menu.entries[3].title, "Download historical dates (1)")
        XCTAssertEqual(menu.entries[3].tip, "Network: api.frankfurter.dev receives these dates and base EUR only: 2025-01-06")
        XCTAssertEqual(menu.entries[4].kind, .check(false))
        let plain = CalculatorTabView(workspace: workspace("2 + 2"), shell: nil)
        XCTAssertTrue(plain.ratesButton.isHidden, "a sheet without money conversions has no rates button")
    }

    func testTheAutomaticDownloadWaitsForPermissionAVisibleSheetAndIdleTyping() {
        let workspace = workspace("100 EUR in USD")
        workspace.setVisible(true)
        XCTAssertFalse(workspace.currencies.hasSchedule, "nothing downloads unless allowed")
        let delivered = workspace.deliveries
        workspace.updatePreferences { $0.autoCurrencyRates = true }
        XCTAssertEqual(workspace.deliveries, delivered, "allowing downloads changes no answer")
        XCTAssertTrue(workspace.currencies.hasSchedule)
        workspace.edit("100 EUR in USD ", composing: true)
        XCTAssertFalse(workspace.currencies.hasSchedule, "composing stops it")
        workspace.edit("100 EUR in USD")
        XCTAssertTrue(workspace.currencies.hasSchedule)
        workspace.setVisible(false)
        XCTAssertFalse(workspace.currencies.hasSchedule, "hidden: no timer")
        workspace.setVisible(true)
        workspace.edit("2 + 2")
        XCTAssertFalse(workspace.currencies.hasSchedule, "a sheet that needs no latest rates downloads nothing")
        workspace.shutdown()
    }

    func testADisplayChoiceIsPreviewedWithoutSavingIt() {
        let workspace = workspace("1/3")
        XCTAssertEqual(workspace.lines.first?.answer, "≈ 0.3333")
        workspace.preview { $0.decimalPlaces = 2 }
        XCTAssertEqual(workspace.lines.first?.answer, "0.33")
        XCTAssertNil(workspace.preferences.decimalPlaces)
        workspace.preview { $0.fontSize = 20 }
        XCTAssertEqual(workspace.displayed.resolvedFontSize, 20)
        XCTAssertEqual(workspace.lines.first?.answer, "≈ 0.3333", "a preview replaces the one before")
        workspace.preview(nil)
        XCTAssertEqual(workspace.displayed.resolvedFontSize, CalculatorPreferences.defaultFontSize)
        workspace.preview { $0.decimalPlaces = 1 }
        let delivered = workspace.deliveries
        workspace.updatePreferences { $0.decimalPlaces = 1 }
        XCTAssertEqual(workspace.deliveries, delivered, "committing what the preview shows evaluates nothing again")
        XCTAssertEqual(workspace.lines.first?.answer, "0.3")
        XCTAssertNil(workspace.displayPreview)
    }
}
