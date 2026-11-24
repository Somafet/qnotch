import AppKit
import XCTest
import CalculatorEngine
@testable import QNotchMac

/// The Calculator on its real store (a temporary folder): saving, reopening, generated values with undo, version history,
/// imports, exports and folder sync, and the files Windows reads.
@MainActor
final class CalculatorDocumentsTests: XCTestCase {
    private var root: URL!
    private var board: NSPasteboard!
    private var opened: [CalculatorWorkspace] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("calc-app-" + UUID().uuidString, isDirectory: true)
        board = NSPasteboard(name: NSPasteboard.Name("dev.qnotch.tests.calculator.\(UUID().uuidString)"))
        CalculatorClipboard.board = board
        CalculatorText.language = "en"
    }
    override func tearDown() {
        opened.forEach { $0.shutdown() }
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func open(_ name: String = "calculator") throws -> CalculatorWorkspace {
        let documents = try StoredCalculatorDocuments(directory: root.appendingPathComponent(name, isDirectory: true))
        let workspace = CalculatorWorkspace(documents: documents, tabs: CalculatorTabList(), synchronous: true)
        opened.append(workspace)
        return workspace
    }

    private func close(_ workspace: CalculatorWorkspace) {
        workspace.shutdown()
        opened.removeAll { $0 === workspace }
    }

    func testSheetsPreferencesAndClosesSurviveAQuit() throws {
        var workspace = try open()
        XCTAssertEqual(workspace.source, CalculatorDocumentStore.starterSource, "a first workspace starts like Windows")
        workspace.edit("rent = 1450\nrent / 2")
        XCTAssertTrue(workspace.newSheet())
        workspace.edit("1 / 3")
        workspace.updatePreferences { $0.decimalPlaces = 2; $0.numberStyle = "plain" }
        let second = workspace.activeID
        XCTAssertTrue(workspace.newSheet())
        let third = workspace.activeID
        XCTAssertTrue(workspace.close(third))
        close(workspace) // A waiting close becomes a delete when QNotch quits.

        workspace = try open()
        XCTAssertEqual(workspace.documents.sheets.map(\.name), ["Sheet", "Sheet 1"])
        XCTAssertEqual(workspace.activeID, second)
        XCTAssertEqual(workspace.source, "1 / 3")
        XCTAssertEqual(workspace.preferences.decimalPlaces, 2)
        XCTAssertEqual(workspace.lines.first?.answer, "0.33")
    }

    func testTheFolderOfAnotherOpenCalculatorIsRefused() throws {
        let workspace = try open()
        XCTAssertThrowsError(try StoredCalculatorDocuments(directory: root.appendingPathComponent("calculator")))
        close(workspace)
        XCTAssertNoThrow(try StoredCalculatorDocuments(directory: root.appendingPathComponent("calculator")).close())
    }

    func testFlushWritesPendingTextWhenThePanelCloses() throws {
        let workspace = try open()
        workspace.edit("pending = 7")
        XCTAssertTrue(workspace.dirty)
        workspace.flush()
        XCTAssertFalse(workspace.dirty)
        let path = root.appendingPathComponent("calculator/sheets/" + workspace.activeID.uuidString.lowercased().replacingOccurrences(of: "-", with: "") + ".json")
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("pending = 7"))
    }

    func testAUuidKeepsItsValueAcrossEditsUndoAndAQuit() throws {
        var workspace = try open()
        workspace.edit("uuid")
        let value = try XCTUnwrap(workspace.lines.first?.answer)
        XCTAssertEqual(value.count, 36)
        XCTAssertTrue(workspace.dirty, "the first uuid turns generated values on and is saved")

        // Deleting the line and undoing it brings the same value back (the identity travels with the undo step).
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        XCTAssertTrue(workspace.willEdit(NSRange(location: 0, length: 4)))
        workspace.edit("", change: (NSRange(location: 0, length: 4), 0), undo: undo)
        undo.endUndoGrouping()
        undo.undo()
        workspace.edit("uuid", undo: nil)
        XCTAssertEqual(workspace.lines.first?.answer, value)

        // A line typed above moves the identity with its statement.
        workspace.edit("note\nuuid", change: (NSRange(location: 0, length: 0), 5))
        XCTAssertEqual(workspace.lines.last?.answer, value)
        close(workspace)

        workspace = try open()
        XCTAssertEqual(workspace.lines.last?.answer, value)
    }

    func testRollingKeepsTheRollUntilRolledAgain() throws {
        let workspace = try open()
        var rolled: [CalculatorDiceRoll] = []
        let token = workspace.observe { if case .rolled(let roll) = $0 { rolled.append(roll) } }
        workspace.edit("2d6")
        XCTAssertNotNil(workspace.lines.first?.pending, "an unrolled line waits for Return")
        workspace.roll(line: 0, again: false)
        XCTAssertNil(workspace.lines.first?.pending)
        XCTAssertEqual(rolled.count, 1)
        XCTAssertEqual(rolled.first?.dice.count, 2)
        let first = workspace.lines.first?.answer
        workspace.roll(line: 0, again: false)
        XCTAssertEqual(rolled.count, 1, "Return on a rolled line keeps its roll")
        XCTAssertEqual(workspace.lines.first?.answer, first)
        withExtendedLifetime(token) {}
    }

    func testSavedFunctionsReachOtherSheets() throws {
        let workspace = try open()
        workspace.edit("double(x) = x * 2\ndouble(4)")
        XCTAssertTrue(workspace.save())
        XCTAssertEqual(workspace.documents.functions?.names, ["double"])
        XCTAssertTrue(workspace.newSheet())
        workspace.edit("double(21)")
        XCTAssertEqual(workspace.lines.first?.answer, "42")
    }

    func testAVersionIsKeptAndRestored() throws {
        let workspace = try open()
        let documents = try XCTUnwrap(workspace.documents as? StoredCalculatorDocuments)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        documents.now = { clock }
        workspace.edit("first = 1")
        XCTAssertTrue(workspace.save())
        clock += 600
        workspace.edit("second = 2")
        XCTAssertTrue(workspace.save())
        let history = try XCTUnwrap(workspace.loadHistory())
        XCTAssertEqual(history.versions.map(\.source).first, "first = 1")
        var replaced = 0
        let token = workspace.observe { if $0 == .replaced { replaced += 1 } }
        XCTAssertTrue(workspace.restoreVersion(history.versions[0], of: workspace.activeID))
        XCTAssertEqual(replaced, 1)
        XCTAssertEqual(workspace.source, "first = 1")
        XCTAssertEqual(try documents.open(workspace.activeID).source, "first = 1")
        XCTAssertEqual(try XCTUnwrap(workspace.loadHistory()).versions.first?.source, "second = 2", "the replaced text is kept too")
        withExtendedLifetime(token) {}
    }

    func testImportedFilesBecomeSheets() throws {
        let workspace = try open()
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let text = files.appendingPathComponent("Groceries.txt")
        try "milk = 2\nbread = 3\nmilk + bread".write(to: text, atomically: true, encoding: .utf8)
        let bad = files.appendingPathComponent("Empty.slvr")
        try "{".write(to: bad, atomically: true, encoding: .utf8)
        var outcome: (Int, String)?
        workspace.importFiles([text, bad]) { outcome = ($0, $1) }
        XCTAssertEqual(outcome?.0, 1)
        XCTAssertTrue(outcome?.1.contains("Empty.slvr: not imported.") == true)
        XCTAssertEqual(workspace.activeName, "Groceries")
        XCTAssertEqual(workspace.lines.last?.answer, "5")
        XCTAssertEqual(workspace.status, CalculatorText.imported(1))
    }

    func testExportsAndTheShareLinkReadTheSheet() throws {
        let workspace = try open()
        workspace.edit("hotel = 120\nfuel = 30\nsum")
        let export = try workspace.currentExport()
        XCTAssertEqual(export.totalText, "150")
        let png = try CalculatorExportRenderer.png(export, width: 480, theme: .sheet(fontSize: 15), transparent: false)
        XCTAssertGreaterThan(png.data.count, 1000)
        XCTAssertEqual(png.omitted, 0)
        let pdf = try CalculatorExportRenderer.pdf(export)
        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
        workspace.copyShareLink(dark: true)
        XCTAssertEqual(workspace.status, CalculatorText.localLinkCopied)
        let link = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(try CalculatorShareLink.decode(link).lines.map(\.result), ["120", "30", "150"])
    }

    func testTwoMacsShareSheetsThroughASyncFolder() throws {
        let folder = root.appendingPathComponent("Synced", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = try open("one"), second = try open("two")
        first.edit("from the first = 1")
        XCTAssertTrue(first.setSyncFolder(folder))
        XCTAssertTrue(second.setSyncFolder(folder))
        XCTAssertEqual(first.syncFolder?.lastPathComponent, "Synced")
        // The sessions apply on the main queue: run it until the first sheet reaches the second workspace.
        let deadline = Date().addingTimeInterval(30)
        while second.documents.sheets.count < 2, Date() < deadline {
            first.requestSync()
            second.requestSync()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertGreaterThanOrEqual(second.documents.sheets.count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(CalculatorSyncSession.fileExtension) }
        XCTAssertGreaterThanOrEqual(files.count, 2)
        XCTAssertTrue(second.setSyncFolder(nil))
        XCTAssertNil(second.syncFolder)
    }

    func testDemoRunsUseAThrowawayFolder() throws {
        let data = root.appendingPathComponent("calculator", isDirectory: true)
        let documents = try CalculatorStorage.open(directory: data, demo: true)
        let demo = try XCTUnwrap((documents as? StoredCalculatorDocuments)?.directory)
        XCTAssertNotEqual(demo, data)
        XCTAssertEqual(documents.sheets.map(\.name), ["Trip", "Rent split", "Budget"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path), "the user's folder is never touched")
        documents.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: demo.path))
    }

    /// Writes a workspace and sync folder through the app's own paths for the C# check
    /// (`dotnet run --project src/QNotch.Mac/Calculator/Tools/DocumentsOracle -- verify <dir>/data <dir>/sync`).
    /// Runs only with CALC_WRITE_APP_DOCUMENTS=<dir>.
    func testWritesASampleWorkspaceForTheWindowsCheck() throws {
        guard let target = ProcessInfo.processInfo.environment["CALC_WRITE_APP_DOCUMENTS"] else { throw XCTSkip("CALC_WRITE_APP_DOCUMENTS not set") }
        let out = URL(fileURLWithPath: target, isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        let sync = out.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let documents = try StoredCalculatorDocuments(directory: out.appendingPathComponent("data", isDirectory: true))
        var clock = Date()
        documents.now = { clock }
        let workspace = CalculatorWorkspace(documents: documents, tabs: CalculatorTabList(), synchronous: true)
        workspace.edit("# Trip 日本 😀\nnights = 3\nhotel = 129 * nights\nhotel + 40")
        workspace.save()
        clock += 600
        workspace.edit("# Trip 日本 😀\nnights = 4\nhotel = 129 * nights\nhotel + 40")
        workspace.save()
        XCTAssertNil(workspace.rename(workspace.activeID, to: "Trip <&> \"quoted\""))
        XCTAssertTrue(workspace.newSheet())
        workspace.edit("area(w, h) = w * h\narea(3, 4)\nid = uuid\n2d6 + 1")
        workspace.roll(line: 3, again: false)
        workspace.save()
        XCTAssertTrue(workspace.newSheet())
        workspace.edit("gone")
        let gone = workspace.activeID
        XCTAssertTrue(workspace.close(gone))
        workspace.commitClosedSheets(everything: true)
        workspace.updatePreferences { $0.decimalPlaces = 2; $0.numberStyle = "comma"; $0.language = "de"; $0.defaultCurrency = "EUR" }
        XCTAssertTrue(workspace.setSyncFolder(sync))
        // Passes until one finds nothing left to publish.
        let deadline = Date().addingTimeInterval(40)
        var quiet = 0
        var lastPasses = -1
        while Date() < deadline, quiet < 2 {
            workspace.requestSync()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let passes = workspace.syncSession?.passes ?? 0
            if passes != lastPasses { lastPasses = passes; quiet += 1 }
        }
        workspace.shutdown()
        XCTAssertGreaterThan(lastPasses, 0)
    }
}
