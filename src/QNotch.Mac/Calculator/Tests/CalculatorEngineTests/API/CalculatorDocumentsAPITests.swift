import XCTest
import CalculatorEngine

/// The documents surface the Mac app uses (no @testable import here on purpose).
final class CalculatorDocumentsAPITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("calc-api-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func evaluate(_ sheet: CalculatorSheet, _ source: String, functions: CalculatorFunctions? = nil, generated: CalculatorGeneratedValues? = nil) throws -> CalculatorEvaluation {
        let format = CalculatorFormat(locale: Locale(identifier: "en_US"))
        var context = generated?.context(for: source, functions: functions).context
        var evaluation = try sheet.evaluate(source, format: format, functions: functions, uuids: context)
        if evaluation.needsGeneratedValues, let generated {
            try generated.supply(evaluation)
            context = generated.context(for: source, functions: functions).context
            evaluation = try sheet.evaluate(source, format: format, functions: functions, uuids: context)
        }
        return evaluation
    }

    func testWorkspacePersistsSheetsAndPreferencesAcrossOpens() throws {
        var (store, opened) = try CalculatorDocumentStore.open(directory: folder)
        XCTAssertEqual(opened.sheet?.source, CalculatorDocumentStore.starterSource)
        XCTAssertFalse(opened.recovered)
        let second = try store.create(name: "Rent", source: "rent = 1450")
        _ = try store.openSheet(second)
        _ = try store.save(second, source: "rent = 1500\nrent / 3", generated: nil)
        try store.updatePreferences { $0.decimalPlaces = 2; $0.language = "de" }
        store.close()

        (store, opened) = try CalculatorDocumentStore.open(directory: folder)
        defer { store.close() }
        XCTAssertEqual(store.sheets.map(\.name), ["Sheet", "Rent"])
        XCTAssertEqual(store.activeSheetID, second)
        XCTAssertEqual(opened.sheet?.source, "rent = 1500\nrent / 3")
        XCTAssertEqual(try store.preferences().decimalPlaces, 2)
        XCTAssertEqual(try store.preferences().language, "de")
        XCTAssertThrowsError(try CalculatorDocumentStore.open(directory: folder)) { error in
            XCTAssertEqual((error as? CalculatorDocumentError)?.kind, .io) // The folder is in use.
        }
    }

    func testDeletingKeepsTheLastSheet() throws {
        let (store, _) = try CalculatorDocumentStore.open(directory: folder)
        defer { store.close() }
        let first = store.activeSheetID
        let second = try store.create(name: "Two")
        try store.delete([second])
        XCTAssertEqual(store.sheets.map(\.id), [first])
        XCTAssertThrowsError(try store.delete([first]))
        XCTAssertFalse(CalculatorDocumentStore.isValidName("  "))
        XCTAssertTrue(CalculatorDocumentStore.isValidName("Trip 日本"))
    }

    func testDefinitionsAreAdoptedWithReceipts() throws {
        let (store, _) = try CalculatorDocumentStore.open(directory: folder)
        defer { store.close() }
        let id = store.activeSheetID
        let saved = try store.save(id, source: "double(x) = x * 2\ndouble(21)", generated: nil)
        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.functions.names, ["double"])
        // Another sheet sees the saved function, and Search can use the library alone.
        let other = try store.create(name: "Other")
        let functions = try store.functions(for: other)
        XCTAssertEqual(try evaluate(CalculatorSheet(), "double(4)", functions: functions).lines[0].answer, "8")
        XCTAssertEqual(CalculatorQuick().answer("double(5)+1", functions: functions.libraryOnly)?.answer, "11")
        // Saving the same text again changes nothing.
        XCTAssertFalse(try store.save(id, source: "double(x) = x * 2\ndouble(21)", generated: nil, receipts: nil).changed)
    }

    func testGeneratedUuidsAndRollsSurviveASave() throws {
        var (store, _) = try CalculatorDocumentStore.open(directory: folder)
        let id = store.activeSheetID
        let source = "uuid\n2d6"
        let generated = CalculatorGeneratedValues(source: source)
        XCTAssertTrue(generated.context(for: source, functions: nil).enabled)
        let first = try evaluate(CalculatorSheet(), source, generated: generated)
        let value = first.lines[0].answer
        XCTAssertEqual(value.count, 36)
        XCTAssertNotNil(first.lines[1].pending)
        let roll = try XCTUnwrap(try generated.roll(line: 1, again: false))
        XCTAssertEqual(roll.dice.count, 2)
        XCTAssertNil(try generated.roll(line: 1, again: false)) // Already rolled.
        XCTAssertEqual(generated.linesWithValues, IndexSet([0, 1]))
        _ = try store.save(id, source: source, generated: generated)
        store.close()

        (store, _) = try CalculatorDocumentStore.open(directory: folder)
        defer { store.close() }
        let reopened = try CalculatorGeneratedValues(try store.openSheet(id))
        let again = try evaluate(CalculatorSheet(), source, generated: reopened)
        XCTAssertEqual(again.lines[0].answer, value)
        XCTAssertEqual(reopened.rolled(line: 1)?.faces, roll.faces)
        XCTAssertNil(again.lines[1].pending)

        // A line inserted above moves the identity with its statement, and the edit can be undone.
        let edit = try XCTUnwrap(reopened.apply("note\n" + source, range: NSRange(location: 0, length: 0), replacementLength: 5))
        XCTAssertEqual(try evaluate(CalculatorSheet(), "note\n" + source, generated: reopened).lines[1].answer, value)
        try edit.undo()
        reopened.replaySource(source)
        XCTAssertEqual(try evaluate(CalculatorSheet(), source, generated: reopened).lines[0].answer, value)
    }

    func testVersionsAreCapturedAndRestored() throws {
        let (store, _) = try CalculatorDocumentStore.open(directory: folder)
        defer { store.close() }
        let id = store.activeSheetID
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.save(id, source: "first = 1", generated: nil)
        XCTAssertTrue(try store.captureVersion(id, now: start))
        _ = try store.save(id, source: "second = 2", generated: nil)
        XCTAssertFalse(try store.captureVersion(id, now: start.addingTimeInterval(60))) // The interval defers it.
        XCTAssertTrue(try store.captureVersion(id, now: start.addingTimeInterval(60), force: true))
        let history = try store.versions(of: id)
        XCTAssertEqual(history.versions.map(\.source), ["second = 2", "first = 1"])
        let restored = try store.restoreVersion(id, hash: history.versions[1].hash, now: start.addingTimeInterval(120))
        XCTAssertEqual(restored.source, "first = 1")
        XCTAssertEqual(try store.openSheet(id).source, "first = 1")
    }

    func testTabsKeepClosedSheetsUntilTheirWindowEnds() {
        let tabs = CalculatorSheetTabs()
        let a = UUID(), b = UUID()
        tabs.update([.init(id: a, name: "A"), .init(id: b, name: "B")], active: a)
        let now = Date()
        XCTAssertEqual(tabs.close(a, now: now)?.wasActive, true)
        XCTAssertEqual(tabs.activeID, b)
        XCTAssertEqual(tabs.canClose(b), .lastSheet)
        XCTAssertTrue(tabs.takeExpired(now: now.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(tabs.undo(now: now)?.id, a)
        XCTAssertEqual(tabs.activeID, a)
        tabs.close(b, now: now)
        XCTAssertEqual(tabs.takeExpired(now: now.addingTimeInterval(CalculatorSheetTabs.undoWindow)).map(\.id), [b])
        XCTAssertEqual(tabs.uniqueName { "Sheet \($0)" }, "Sheet 1")
    }

    func testExportsAndShareLinksReadWhatTheSheetShows() throws {
        let (store, _) = try CalculatorDocumentStore.open(directory: folder)
        defer { store.close() }
        let source = "# Trip\nhotel = 120\nfuel = 30\nsum"
        let evaluation = try evaluate(CalculatorSheet(), source)
        let export = try CalculatorExport(title: "Trip", source: source, evaluation: evaluation)
        XCTAssertTrue(export.hasResults)
        XCTAssertEqual(export.totalText, "150")
        XCTAssertEqual(try export.resultsText(), "\r\n120\r\n30\r\n150")
        XCTAssertTrue(String(decoding: try export.text(.plainText), as: UTF8.self).contains("hotel = 120"))
        XCTAssertTrue(try export.tableHTML().contains("<table"))
        let layout = try export.layout(width: 480, pageHeight: .infinity, margin: 20, lineHeight: 20) { text, _ in Double(text.count) * 7 }
        XCTAssertEqual(layout.pages.count, 1)
        XCTAssertTrue(layout.pages[0].runs.contains { $0.text == "150" && $0.style == .total })
        XCTAssertEqual(CalculatorExportFormat.csv.suggestedName("a/b"), "a b.csv")

        let link = try CalculatorShareLink.create(store: store, title: "Trip", source: source, evaluation: evaluation, dark: true)
        XCTAssertTrue(CalculatorShareLink.isLocal(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ShareViewer/index.html").path))
        let decoded = try CalculatorShareLink.decode(link)
        XCTAssertEqual(decoded.title, "Trip")
        XCTAssertEqual(decoded.lines.map(\.result), [nil, "120", "30", "150"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.writeHelp().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.writeNotices().path))
    }

    func testImportReadsTextFilesIntoSheets() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Groceries.txt")
        try "milk = 2\nbread = 3\nmilk + bread\r\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(CalculatorImport.isSupported(file))
        XCTAssertFalse(CalculatorImport.isSupported(folder.appendingPathComponent("x.pdf")))
        let sheet = try CalculatorImport.read(file)
        XCTAssertEqual(sheet.name, "Groceries")
        XCTAssertEqual(sheet.source, "milk = 2\nbread = 3\nmilk + bread\n")
        XCTAssertEqual(CalculatorImport.uniqueName("Groceries", existing: ["groceries"]), "Groceries 2")
    }

    func testInterfaceTextHasEveryLanguage() {
        XCTAssertEqual(CalculatorInterfaceText.languages.first?.code, "en")
        XCTAssertEqual(CalculatorInterfaceText.languages.count, 9)
        XCTAssertEqual(CalculatorInterfaceText.string("settings", language: "de"), "Einstellungen")
        XCTAssertEqual(CalculatorInterfaceText.resolve(nil, preferred: ["de-AT", "en"]), "de")
        XCTAssertEqual(CalculatorInterfaceText.resolve(nil, preferred: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(CalculatorInterfaceText.resolve("ko", preferred: ["de"]), "ko")
        XCTAssertEqual(CalculatorInterfaceText.resolve(nil, preferred: ["pt-BR"]), "en")
    }
}
