import XCTest
@testable import CalculatorEngine

final class ImportTests: XCTestCase {
    private static func fixture(_ name: String) -> String { Fixtures.url("import/" + name).path }
    private static func results(_ source: String) throws -> [String] { try SheetEvaluator.evaluate(source).map(\.display) }

    func testSoulverJsonIdentifierReferencesBecomeCalcLineReferences() throws {
        let sheet = try SheetImport.readFile(ImportTests.fixture("trip.slvr"))
        XCTAssertEqual(.soulver, sheet.format)
        XCTAssertEqual("trip", sheet.name)
        // Hand-written oracle: line ids 2 and 3 are referenced by line 4, line 4 by line 5; line numbering is unchanged.
        XCTAssertEqual("# Trip\nhotel = 3 * 90\ntrain = 45\nL2 + L3\nL4 / 2\n[00000000-0000-4000-8000-000000000000] + 1", sheet.source)
        let results = try ImportTests.results(sheet.source)
        XCTAssertEqual("315", results[3]); XCTAssertEqual("157.5", results[4]) // 3*90 + 45 = 315; 315/2
        let fileNotes = sheet.notices.filter { $0.line == 0 }
        XCTAssertEqual(1, fileNotes.count)
        XCTAssertTrue(fileNotes.first?.message.contains("answer, appearance, font, theme, version") == true, fileNotes.first?.message ?? "")
        XCTAssertTrue(sheet.notices.contains { $0.line == 6 && $0.message.contains("matches no line") })
        XCTAssertFalse(sheet.notices.contains { (1...5).contains($0.line) })
    }

    func testSoulverPlainTextLineWordsTranslateOutsideComments() throws {
        let sheet = try SheetImport.readFile(ImportTests.fixture("plain-refs.slvr"))
        let lines = sheet.source.netSplit("\n")
        XCTAssertEqual("L3 * 2", lines[3])
        XCTAssertEqual("// line9 stays in comments", lines[4])
        XCTAssertEqual("line9 + 1", lines[5])
        XCTAssertEqual("240", try ImportTests.results(sheet.source)[3]) // 40 * 3 * 2
        XCTAssertTrue(sheet.notices.contains { $0.line == 6 && $0.message.contains("does not name another line") })
    }

    func testNumiAndTextAreKeptVerbatimWithUnsupportedLinesReported() throws {
        let numi = try SheetImport.parse("budget.numi", Array("# Monthly budget\r\nrent = 1200\r\nfood = 350\r\nrent + food\r\nprev / 2\r\ntotal\r\n$40 + 5\r\nGroceries\r\n".utf8))
        XCTAssertEqual(.numi, numi.format)
        XCTAssertEqual("# Monthly budget\nrent = 1200\nfood = 350\nrent + food\nprev / 2\ntotal\n$40 + 5\nGroceries\n", numi.source)
        let results = try ImportTests.results(numi.source)
        XCTAssertEqual("1550", results[3]); XCTAssertEqual("775", results[4])
        XCTAssertTrue(numi.notices.contains { $0.line == 6 && $0.message.hasPrefix("No result") })
        XCTAssertTrue(numi.notices.contains { $0.line == 7 && $0.message.contains("cannot evaluate") }); XCTAssertEqual(2, numi.notices.count, "\(numi.notices)")
        let text = try SheetImport.readFile(ImportTests.fixture("notes.txt"))
        XCTAssertEqual(.text, text.format)
        XCTAssertTrue(text.source.hasPrefix("a = 2\nb = 5\na * b"))
        XCTAssertTrue(text.notices.isEmpty, "\(text.notices)")
        XCTAssertEqual("10", try ImportTests.results(text.source)[2])
        XCTAssertEqual("budget", try SheetImport.readFile(ImportTests.fixture("budget.numi")).name)
    }

    func testUtf16AndBomInputsDecode() throws {
        let utf16 = [UInt8]([0xFF, 0xFE]) + "x = 4 €\nx".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual("x = 4 €\nx", try SheetImport.parse("a.txt", utf16).source)
        let bom = [UInt8]([0xEF, 0xBB, 0xBF]) + Array("1 + 1".utf8)
        XCTAssertEqual("1 + 1", try SheetImport.parse("a.numi", bom).source)
    }

    func testCorruptFixtureIsRejectedAndUnchanged() throws {
        try theory([("corrupt.slvr", "Corrupt Soulver file")]) { (name: String, message: String) in
            let path = ImportTests.fixture(name); let before = try TestFiles.readBytes(path)
            let error = assertThrows(.importRejected, try SheetImport.readFile(path))
                XCTAssertTrue(error?.netMessage.contains(message) == true, error?.netMessage ?? ""); XCTAssertEqual(before, try TestFiles.readBytes(path))
        }
    }

    func testHostileOrOversizedInputsAreRejected() throws {
        func message(_ expression: @autoclosure () throws -> ImportedSheet) -> String { assertThrows(.importRejected, try expression())?.netMessage ?? "" }
        XCTAssertTrue(message(try SheetImport.parse("a.txt", [0x31, 0x00, 0x32])).contains("Binary"))
        XCTAssertTrue(message(try SheetImport.parse("a.numi", [0x31, 0xC3, 0x28])).contains("UTF-8"))
        XCTAssertTrue(message(try SheetImport.parse("a.txt", Array("1\n\u{1b}[2J".utf8))).contains("U+001B"))
        XCTAssertTrue(message(try SheetImport.parse("a.txt", [UInt8](repeating: 0, count: SheetImport.maxTextBytes + 1))).contains("bytes"))
        XCTAssertTrue(message(try SheetImport.parse("a.txt", Array(String(repeating: "1", count: SheetStore.maxCharacters + 1).utf8))).contains("characters"))
        XCTAssertTrue(message(try SheetImport.parse("a.txt", Array(String(repeating: "\n", count: SheetEvaluator.maxLines).utf8))).contains("lines"))
        XCTAssertTrue(message(try SheetImport.parse("a.exe", [0x31])).contains("Unsupported file type"))
        XCTAssertTrue(message(try SheetImport.parse("a.slvr", Array("{\"version\": 3, \"rows\": [1, 2]}".utf8))).contains("Unrecognized"))
        let deep = String(repeating: "[", count: SheetImport.maxJsonDepth + 2) + String(repeating: "]", count: SheetImport.maxJsonDepth + 2)
        XCTAssertTrue(message(try SheetImport.parse("a.slvr", Array(deep.utf8))).contains("Corrupt"))
    }

    func testLargeFileOnDiskIsRejectedBeforeReading() throws {
        let directory = TestFiles.temporary("calc-import-"); try NetFile.createDirectory(directory)
        defer { TestFiles.delete(directory) }
        let path = TestFiles.path(directory, "big.numi")
        try TestFiles.writeBytes(path, []); XCTAssertEqual(0, truncate(path, off_t(SheetImport.maxTextBytes + 1)))
        XCTAssertTrue(assertThrows(.importRejected, try SheetImport.readFile(path))?.netMessage.contains("exceeds") == true)
        XCTAssertEqual(Int64(SheetImport.maxTextBytes + 1), NetFile.info(path).length)
        XCTAssertTrue(assertThrows(.importRejected, try SheetImport.readFile(TestFiles.path(directory, "missing.slvr")))?.netMessage.contains("not found") == true)
    }

    func testSoulverBodyAndEmbeddedLineBreaksKeepNumbering() throws {
        let body = try SheetImport.parse("b.slvr", Array("{\"text\": \"a = 1\\nb = 2\\nline1 + line2\", \"style\": 1}".utf8))
        XCTAssertEqual("a = 1\nb = 2\nL1 + L2", body.source)
        XCTAssertEqual("3", try ImportTests.results(body.source)[2])
        XCTAssertTrue(body.notices.contains { $0.line == 0 && $0.message.contains("style") })
        let broken = try SheetImport.parse("c.slvr", Array("{\"lines\": [{\"text\": \"1 +\\n2\"}, {\"text\": \"line1 * 3\"}]}".utf8))
        XCTAssertEqual("1 + 2\nL1 * 3", broken.source)
        XCTAssertEqual("9", try ImportTests.results(broken.source)[1])
        XCTAssertTrue(broken.notices.contains { $0.line == 1 && $0.message.contains("joined") })
    }

    func testShortAndDuplicateIdentifiersAreNotGuessed() throws {
        let shortIds = try SheetImport.parse("s.slvr", Array("{\"lines\": [{\"id\": 1, \"text\": \"5\"}, {\"id\": 2, \"text\": \"[1] + 1\"}]}".utf8))
        XCTAssertEqual("5\n[1] + 1", shortIds.source)
        let duplicate = try SheetImport.parse("d.slvr", Array("{\"lines\": [{\"id\": \"abcdefgh\", \"text\": \"5\"}, {\"id\": \"abcdefgh\", \"text\": \"6\"}, {\"id\": \"ijklmnop\", \"text\": \"[abcdefgh] + 1\"}]}".utf8))
        XCTAssertEqual("5\n6\n[abcdefgh] + 1", duplicate.source)
        XCTAssertTrue(duplicate.notices.contains { $0.line == 3 && $0.message.contains("ambiguous") })
    }

    func testNamesAreValidAndUnique() throws {
        XCTAssertEqual("Imported", SheetImport.sheetName("   .txt"))
        XCTAssertEqual("a b", SheetImport.sheetName("a\tb.numi"))
        XCTAssertEqual(WorkspaceStore.maxNameLength, SheetImport.sheetName(String(repeating: "x", count: 200) + ".txt").netLength)
        XCTAssertEqual("Budget 3", SheetImport.uniqueName("Budget", ["budget", "Budget 2"]))
        let longName = String(repeating: "y", count: WorkspaceStore.maxNameLength)
        XCTAssertEqual(WorkspaceStore.maxNameLength, SheetImport.uniqueName(longName, [longName]).netLength)
    }

    func testImportedSourceCreatesAPersistedSheet() throws {
        let directory = TestFiles.temporary("calc-import-"); try NetFile.createDirectory(directory)
        defer { TestFiles.delete(directory) }
        let sheet = try SheetImport.readFile(ImportTests.fixture("trip.slvr"))
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            var workspace = try store.load().workspace
            workspace = try store.create(SheetImport.uniqueName(sheet.name, workspace.sheets.map(\.name)), sheet.source)
            XCTAssertEqual(sheet.source, try store.open(workspace.activeSheetId).document.source)
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        let loaded = try reopened.load().workspace
        XCTAssertTrue(loaded.sheets.contains { $0.name == "trip" })
        XCTAssertEqual(sheet.source, try reopened.open(loaded.sheets.first { $0.name == "trip" }!.id).document.source)
    }
}
