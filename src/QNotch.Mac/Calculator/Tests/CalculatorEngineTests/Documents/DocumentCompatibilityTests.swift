import XCTest
@testable import CalculatorEngine

/// Mac and Windows share data and sync folders, so the Mac must read every file the C# engine writes and write the same bytes for the
/// same state. The references in tests/fixtures/calculator/documents were written by the C# engine (Tools/DocumentsOracle):
/// json/ holds System.Text.Json's bytes for fixed values; workspace/, sync/ and legacy/ are folders the C# stores wrote.
/// Not a port of a C# test class.
final class DocumentCompatibilityTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-compat-tests")
    override func tearDown() { TestFiles.delete(directory) }
    private static let fixtures = Fixtures.url("documents").path
    private static func manifest() throws -> JSONNode { try JSONNode.parse(try Fixtures.data("documents/manifest.json")) }

    // The same values Tools/DocumentsOracle serializes.
    private static let awkward = "price = 120 \"q\" \\ / <b>&amp;</b> 'a'+`b` \u{1}\u{1f}\u{7f} é € 日本 😀\ttab\r\nnext"
    private static func g(_ text: String) -> UUID { UUID.netParseD(text)! }
    private static let sheetId = g("0f8c2d6e-1a3b-4c5d-8e9f-a0b1c2d3e4f5"), other = g("ffeeddcc-bbaa-4998-8776-655443322110")
    private static let statement1 = g("11111111-2222-4333-8444-555555555555"), statement2 = g("aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee")
    private static let value1 = g("12345678-9abc-4def-8123-456789abcdef"), revision = g("01020304-0506-4708-890a-0b0c0d0e0f10")
    private static let ancestor = g("f1e2d3c4-b5a6-4978-8a9b-acbdcedfe0f1")
    private static let uuids = GeneratedUuidState(1, [statement1, statement2], [UuidBinding(statement: statement1, site: "uuid/0", value: value1),
                                                                               UuidBinding(statement: statement2, site: "f/1/uuid/0", value: value1)])
    private static let dice = GeneratedUuidState(2, [statement1, statement2], [UuidBinding(statement: statement1, site: "uuid/0", value: value1)],
                                                 dice: [DiceBinding(statement: statement2, formula: "2d6+3", faces: [4, 6])])
    private static let receipts = [FunctionReceipt(key: String(repeating: "A", count: 64), count: 1),
                                   FunctionReceipt(key: "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", count: 2)]
    private static let captured = DateTimeOffset(2026, 10, 31, 12, 0, 0)
    private static func padded(_ text: String) -> String { text + String(repeating: "0", count: 64 - text.count) }

    private static func cases() -> [(name: String, json: String, roundTrip: ([UInt8]) throws -> String, equal: ([UInt8]) throws -> Bool)] {
        func entry<T: JSONDocument & Equatable>(_ name: String, _ value: T) -> (String, String, ([UInt8]) throws -> String, ([UInt8]) throws -> Bool) {
            (name, value.json, { try T.decode(try NetJSON.parseObject($0)!).json }, { try T.decode(try NetJSON.parseObject($0)!) == value })
        }
        var preferences2 = PreferencesDocument(2, "WEEKDAYS")
        preferences2.autoCurrencyRates = true; preferences2.fontSize = 40; preferences2.decimalPlaces = 20; preferences2.numberStyle = "apostrophe"
        preferences2.language = "zh-Hans"; preferences2.alwaysOnTop = true; preferences2.window = WindowPlacementPreference(-1_000_000, -20, 900, 700, true)
        preferences2.defaultCurrency = "HUF"
        var region = PreferencesDocument(1, "DE"); region.autoCurrencyRates = true
        var sparse = PreferencesDocument(2, nil); sparse.fontSize = 12
        return [
            entry("sheet-v1", SheetDocument(1, sheetId, awkward, false)),
            entry("sheet-v1-dark-empty", SheetDocument(1, other, "", true)),
            entry("sheet-v2-uuids", SheetDocument(2, sheetId, "uuid\nf(1)", false, generatedUuids: uuids)),
            entry("sheet-v2-dice", SheetDocument(2, sheetId, "uuid\n2d6+3", true, generatedUuids: dice)),
            entry("workspace", WorkspaceDocument(1, other, true, [SheetEntry(sheetId, "Sheet"), SheetEntry(other, "Reise 日本 😀 <&>")])),
            entry("functions", FunctionCatalog(3, [FunctionDefinition(name: "f", parameters: ["x"], body: "x+1"), FunctionDefinition(name: "area", parameters: ["w", "h"], body: "w*h"),
                                                    FunctionDefinition(name: "constant", parameters: [], body: "7 €")])),
            entry("functions-empty", FunctionCatalog(1, [])),
            entry("receipts", FunctionReceiptDocument(1, sheetId, receipts)),
            entry("receipts-empty", FunctionReceiptDocument(1, other, [])),
            entry("function-save", FunctionSaveTransaction(1, SheetDocument(2, sheetId, "saved()=uuid", false, generatedUuids: GeneratedUuidState(1, [statement1], [])),
                                                           FunctionCatalog(2, [FunctionDefinition(name: "saved", parameters: [], body: "uuid")]),
                                                           FunctionReceiptDocument(1, sheetId, [receipts[0]]))),
            entry("preferences-v1", PreferencesDocument(1, nil)),
            entry("preferences-v1-region", region),
            entry("preferences-v2", preferences2),
            entry("preferences-v2-sparse", sparse),
            entry("version", SheetVersion(1, sheetId, captured, String(repeating: "B", count: 64), SheetDocument(1, sheetId, "a + b", false), receipts)),
            entry("version-fraction", SheetVersion(1, sheetId, captured.addingTicks(1_234_500), padded("C0FFEE"), SheetDocument(2, sheetId, "uuid", false, generatedUuids: uuids), [])),
            entry("version-max", SheetVersion(1, sheetId, .maxValue, String(repeating: "D", count: 64), SheetDocument(1, sheetId, "", false), [])),
            entry("sync-state", SyncStateDocument(1, "/Users/someone/Library/CloudStorage/Drop box/Sync \"QNotch\" 日本", [
                SyncBase(sheetId, revision, String(repeating: "E", count: 64), "Sheet", 639_000_000_000_000_001, 1234),
                SyncBase(other, ancestor, String(repeating: "F", count: 64), "Reise 😀", 0, 0)])),
            entry("sync-state-off", SyncStateDocument(1, nil, [])),
            entry("calcsheet", SyncSheetFile(1, sheetId, revision, [ancestor, statement1], "MacBook “Pro” 😀", captured.addingTicks(1).toOffset(minutes: 120), false,
                                             "Reise 日本", awkward, SyncFolderFiles.contentHash("Reise 日本", awkward, nil))),
            entry("calcsheet-uuids", SyncSheetFile(1, sheetId, revision, [], "Computer", captured.toOffset(minutes: -330), false, "Sheet", "uuid\n2d6+3",
                                                   SyncFolderFiles.contentHash("Sheet", "uuid\n2d6+3", dice), generatedUuids: dice)),
            entry("calcsheet-tombstone", SyncSheetFile(1, other, ancestor, [revision], "C", captured.adding(days: -200), true, "", "", SyncFolderFiles.contentHash("", "", nil))),
        ].map { (name: $0.0, json: $0.1, roundTrip: $0.2, equal: $0.3) }
    }

    func testSwiftWritesTheBytesSystemTextJsonWrites() throws {
        let cases = Self.cases()
        XCTAssertEqual(cases.count, try NetFile.entries(Self.fixtures + "/json").filter { $0.hasSuffix(".json") }.count, "every fixture has a Swift case")
        for item in cases {
            let bytes = try TestFiles.readBytes(Self.fixtures + "/json/" + item.name + ".json")
            XCTAssertEqual(bytes.utf8Text, item.json, item.name)
            XCTAssertEqual(bytes.utf8Text, try item.roundTrip(bytes), item.name + " round trip")
            XCTAssertTrue(try item.equal(bytes), item.name + " decodes to the same value")
            CaseCounter.record(file: #filePath)
        }
    }

    func testContentHashesMatchTheCSharpEngine() throws {
        for item in try Self.manifest().property("hashes").arrayItems() {
            let state: GeneratedUuidState?
            switch item["case"]?.stringValue {
            case "uuids": state = Self.uuids
            case "dice": state = Self.dice
            case "statement": state = GeneratedUuidState(1, [Self.statement1], [])
            default: state = nil
            }
            XCTAssertEqual(try item.property("hash").string(), SyncFolderFiles.contentHash(try item.property("name").string(), try item.property("source").string(), state))
            CaseCounter.record(file: #filePath)
        }
    }

    /// Every JSON file in a folder, by path relative to it.
    private func jsonFiles(_ root: String) throws -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        func walk(_ folder: String, _ prefix: String) throws {
            for name in try NetFile.entries(folder) where name != "session.lock" {
                let path = (folder as NSString).appendingPathComponent(name)
                if NetFile.directoryExists(path) { try walk(path, prefix + name + "/") } else { result[prefix + name] = try TestFiles.readBytes(path) }
            }
        }
        try walk(root, "")
        return result
    }
    private func copyFixture(_ name: String) throws -> String {
        let target = TestFiles.path(directory, name)
        func copy(_ from: String, _ to: String) throws {
            try NetFile.createDirectory(to)
            for entry in try NetFile.entries(from) {
                let source = (from as NSString).appendingPathComponent(entry), destination = (to as NSString).appendingPathComponent(entry)
                if NetFile.directoryExists(source) { try copy(source, destination) } else { try NetFile.copy(source, destination) }
            }
        }
        try copy(Self.fixtures + "/" + name, target)
        return target
    }

    func testTheMacReadsAWindowsWorkspaceAndWouldWriteTheSameBytes() throws {
        let data = try copyFixture("workspace")
        let before = try jsonFiles(data)
        let manifest = try Self.manifest().property("workspace")
        let store = try WorkspaceStore(data); defer { store.dispose() }
        let loaded = try store.load()
        XCTAssertFalse(loaded.recovered); XCTAssertFalse(loaded.migrated)
        XCTAssertEqual(try manifest.property("active").string(), loaded.workspace.activeSheetId.netN)
        XCTAssertEqual(try manifest.property("dark").bool(), loaded.workspace.dark)
        let sheets = try manifest.property("sheets").arrayItems()
        XCTAssertEqual(try sheets.map { try $0.property("id").string() }, loaded.workspace.sheets.map(\.id.netN))
        XCTAssertEqual(try sheets.map { try $0.property("name").string() }, loaded.workspace.sheets.map(\.name))
        XCTAssertEqual(before["workspace.json"]?.utf8Text, loaded.workspace.json)
        for (sheet, entry) in zip(sheets, loaded.workspace.sheets) {
            let opened = try store.open(entry.id)
            XCTAssertFalse(opened.recovered)
            XCTAssertEqual(try sheet.property("source").string(), opened.document.source)
            XCTAssertEqual(try sheet.property("version").int(), opened.document.version)
            XCTAssertEqual(try sheet.property("receipts").int(), opened.functionReceipts?.count)
            XCTAssertEqual(before["sheets/" + entry.id.netN + ".json"]?.utf8Text, opened.document.json)
            if let receipts = before["sheets/" + entry.id.netN + ".receipts"] {
                XCTAssertEqual(receipts.utf8Text, FunctionReceiptDocument(1, entry.id, opened.functionReceipts ?? []).json)
            }
            let history = try store.loadVersions(entry.id)
            XCTAssertEqual(0, history.skipped)
            let expected = try sheet.property("versions").arrayItems()
            XCTAssertEqual(try expected.map { try $0.property("hash").string() }, history.versions.map(\.hash))
            XCTAssertEqual(try expected.map { try $0.property("ticks").int64() }, history.versions.map(\.capturedAt.utcTicks))
            XCTAssertEqual(try expected.map { try $0.property("source").string() }, history.versions.map(\.sheet.source))
            XCTAssertEqual(try expected.map { try $0.property("receipts").int() }, history.versions.map(\.receipts.count))
            for version in history.versions {
                // The file name carries the D19 ticks and the content hash the Mac computes for the same document.
                let name = "versions/" + entry.id.netN + "/" + pad(version.capturedAt.utcTicks, 19) + "-" + WorkspaceStore.contentHash(version.sheet) + ".json"
                XCTAssertEqual(before[name]?.utf8Text, version.json, name)
            }
        }
        let functions = try store.loadFunctions()
        XCTAssertEqual(try manifest.property("functions").arrayItems().map { try $0.property("name").string() + "=" + $0.property("body").string() },
                       functions.definitions.map { $0.name + "=" + $0.body })
        XCTAssertEqual(before["functions.json"]?.utf8Text, FunctionCatalog(try manifest.property("functionsVersion").int(), functions.definitions).json)
        let preferences = try store.loadPreferences()
        XCTAssertEqual(before["preferences.json"]?.utf8Text, preferences.json)
        XCTAssertEqual("DE", preferences.workdayRegion); XCTAssertEqual(18, preferences.fontSize); XCTAssertEqual(WindowPlacementPreference(10, 20, 810, 620, false), preferences.window)
        let state = try FolderSync.loadState(data)
        XCTAssertEqual(before["sync.json"]?.utf8Text, state.json)
        XCTAssertEqual(try Self.manifest().property("syncFolder").string(), state.folder)
        // Reading a Windows folder rewrites nothing.
        XCTAssertEqual(before, try jsonFiles(data))
    }

    func testTheMacReadsAWindowsSyncFolderAndSettlesWithoutWriting() throws {
        let data = try copyFixture("workspace"), folder = try copyFixture("sync")
        let files = try Self.manifest().property("workspace").property("sync").arrayItems()
        let snapshot = SyncFolderFiles.scan(folder, DateTimeOffset(2026, 11, 1, 12, 0, 0))
        XCTAssertTrue(snapshot.available); XCTAssertEqual(0, snapshot.skipped); XCTAssertTrue(snapshot.duplicates.isEmpty)
        XCTAssertEqual(Set(try files.map { try $0.property("sheet").string() }), Set(snapshot.canonical.keys.map(\.netN)))
        for expected in files {
            let entry = try XCTUnwrap(snapshot.canonical[UUID.netParseN(try expected.property("sheet").string())!])
            XCTAssertEqual(.ready, entry.state)
            let file = try XCTUnwrap(entry.file)
            XCTAssertEqual(try expected.property("revision").string(), file.revision.netN)
            XCTAssertEqual(try expected.property("deleted").bool(), file.deleted)
            XCTAssertEqual(try expected.property("name").string(), file.name)
            XCTAssertEqual(try expected.property("source").string(), file.source)
            XCTAssertEqual(try expected.property("hash").string(), file.hash)
            XCTAssertEqual(try TestFiles.readBytes(entry.path).utf8Text, file.json)
        }
        // Point this computer's sync state at the copied folder, keeping the bases Windows recorded.
        let state = try FolderSync.loadState(data)
        try AtomicJson.write(FolderSync.statePath(data), SyncStateDocument(1, folder, state.bases))
        let before = try jsonFiles(folder)
        let store = try WorkspaceStore(data); defer { store.dispose() }; _ = try store.load()
        let sync = FolderSync(store, "Mac", clock: { DateTimeOffset(2026, 11, 1, 12, 0, 0) })
        let report = try sync.synchronize(sync.scan(folder))
        XCTAssertEqual(.synchronized, report.status, report.problem ?? "")
        XCTAssertEqual([0, 0, 0, 0, 0, 0], [report.published, report.imported, report.updated, report.conflicts, report.deleted, report.failed])
        XCTAssertEqual(before, try jsonFiles(folder))
    }

    func testTheMacMigratesAWindowsLegacySheet() throws {
        let data = try copyFixture("legacy")
        let manifest = try Self.manifest().property("legacy")
        let bytes = try TestFiles.readBytes(TestFiles.path(data, "sheet.json"))
        let legacy = try SheetStore(data)
        let document = try legacy.load().document
        XCTAssertEqual(bytes.utf8Text, document.json)
        legacy.dispose()
        let store = try WorkspaceStore(data); defer { store.dispose() }
        let loaded = try store.load()
        XCTAssertTrue(loaded.migrated); XCTAssertEqual(try manifest.property("id").string(), loaded.workspace.activeSheetId.netN)
        XCTAssertEqual(try manifest.property("dark").bool(), loaded.workspace.dark)
        XCTAssertEqual(try manifest.property("source").string(), try store.open(loaded.workspace.activeSheetId).document.source)
        XCTAssertEqual(bytes, try TestFiles.readBytes(TestFiles.path(data, "sheet.json")))
        // The migrated body is the same document, so its bytes are the legacy file's.
        XCTAssertEqual(bytes, try TestFiles.readBytes(TestFiles.path(data, "sheets", loaded.workspace.activeSheetId.netN + ".json")))
    }

    /// The Mac half of the reverse check: a workspace and sync folder written by the Swift stores with the operations the oracle used.
    /// With CALC_WRITE_MAC_DOCUMENTS set to a folder, they are copied there for `DocumentsOracle verify` to read with the C# stores.
    func testTheMacWritesAWorkspaceTheCSharpReaderOpens() throws {
        let data = TestFiles.path(directory, "data"), folder = TestFiles.path(directory, "sync")
        try NetFile.createDirectory(folder)
        do {
            let store = try WorkspaceStore(data); defer { store.dispose() }
            let first = try store.load().workspace.activeSheetId
            let second = try store.create("Reise 日本 😀 <&>", "fuel = 40\nfuel * 3 \"q\" 'a'").activeSheetId
            let third = try store.create("Scratch", "1+1").activeSheetId
            let opened = try store.open(first).document.with { $0.source = "f(x)=x+1\nf(2)\n" + Self.awkward }
            try store.saveWithFunctions(opened, try FunctionUpdate.prepare(opened.source, try store.loadFunctions(), try store.loadFunctionReceipts(first)))
            try store.save(try store.open(second).document.with {
                $0.version = 2; $0.source = "uuid\nid = uuid"
                $0.generatedUuids = GeneratedUuidState(1, [Self.statement1, Self.statement2], [UuidBinding(statement: Self.statement1, site: "uuid/0", value: Self.value1)])
            })
            try store.captureVersion(first, Self.captured)
            let edited = try store.open(first).document.with { $0.source = "f(2) * 10" }
            try store.saveWithFunctions(edited, try FunctionUpdate.prepare(edited.source, try store.loadFunctions(), try store.loadFunctionReceipts(first)))
            try store.captureVersion(first, Self.captured.adding(hours: 1).addingTicks(42))
            try store.updatePreferences { $0.with {
                $0.workdayRegion = "DE"; $0.autoCurrencyRates = true; $0.fontSize = 18; $0.decimalPlaces = 2; $0.numberStyle = "comma"; $0.language = "de"
                $0.alwaysOnTop = true; $0.window = WindowPlacementPreference(10, 20, 810, 620, false); $0.defaultCurrency = "EUR"
            } }
            try store.setDark(true); try store.select(second)
            try FolderSync.setFolder(data, folder)
            var clock = DateTimeOffset(2026, 11, 1, 9, 30, 15, offsetMinutes: 60).addingTicks(7_654_321)
            let sync = FolderSync(store, "Mac 😀", clock: { clock })
            XCTAssertEqual(3, try sync.synchronize(sync.scan(folder)).published)
            try store.delete(third)
            clock = clock.adding(minutes: 1)
            let report = try sync.synchronize(sync.scan(folder))
            XCTAssertEqual(0, report.failed, report.problem ?? "")
            XCTAssertTrue(try SyncSheetFile.decode(try NetJSON.parseObject(try TestFiles.readBytes(SyncFolderFiles.canonicalPath(folder, third)))!).deleted)
        }
        guard let target = ProcessInfo.processInfo.environment["CALC_WRITE_MAC_DOCUMENTS"], !target.isEmpty else { return }
        TestFiles.delete(target)
        try NetFile.createDirectory(target)
        for name in ["data", "sync"] { XCTAssertEqual(0, rename(TestFiles.path(directory, name), TestFiles.path(target, name))) }
        try NetFile.delete(TestFiles.path(target, "data", "session.lock"))
    }

    /// System.Text.Json behaviours the reader reproduces (each checked against the C# engine with a scratch oracle).
    func testTheReaderRejectsWhatSystemTextJsonRejects() throws {
        let id = "\"Id\":\"0f8c2d6e-1a3b-4c5d-8e9f-a0b1c2d3e4f5\""
        func read(_ text: String) throws -> SheetDocument? { try NetJSON.parseObject(Array(text.utf8)).map(SheetDocument.decode) }
        for rejected in ["[]", "1", "{\"Version\":1,}", "{\"Version\":1/*x*/}", "{\"Version\":1.0,\(id)}", "{\"Version\":1e0,\(id)}", "{\"Version\":\"1\",\(id)}",
                         "{\"Version\":null,\(id)}", "{\"Version\":1,\(id),\"Dark\":null}", "{\"Version\":2147483648,\(id)}", "{\"Version\":01}",
                         "{\"Version\":1,\"Id\":\"0f8c2d6e1a3b4c5d8e9fa0b1c2d3e4f5\"}", "{\"Version\":1,\"Id\":\"{0f8c2d6e-1a3b-4c5d-8e9f-a0b1c2d3e4f5}\"}",
                         "{\"Version\":1,\(id),\"Source\":\"a\\uD800b\"}", "{\"Version\":1,\"Source\":\"\\x\"}", ""] {
            assertThrows(.json, try read(rejected), rejected)
        }
        assertThrows(.json, try NetJSON.parseObject([0xEF, 0xBB, 0xBF] + Array("{\"Version\":1}".utf8)), "byte-order mark")
        assertThrows(.json, try NetJSON.parseObject(Array("{\"Version\":1,\"Source\":\"".utf8) + [0xC3, 0x28] + Array("\"}".utf8)), "invalid UTF-8")
        XCTAssertNil(try read("null"))
        XCTAssertEqual(0, try read("{\"version\":1,\(id)}")?.version) // Names are case-sensitive.
        XCTAssertEqual(2, try read("{\"Version\":1,\"Version\":2}")?.version) // The last duplicate wins.
        XCTAssertEqual(UUID.netParseD("0f8c2d6e-1a3b-4c5d-8e9f-a0b1c2d3e4f5"), try read("{\"Version\":1,\"Id\":\"0F8C2D6E-1A3B-4C5D-8E9F-A0B1C2D3E4F5\"}")?.id)
        XCTAssertEqual(true, try read("{\"Version\":1,\(id)}")?.nulls.contains("Source")) // Missing reference: null, rejected by validation.
        XCTAssertEqual(DateTimeOffset.parseJSON("2026-10-31T12:00:00.123456789+00:00")?.utcTicks, 639_290_448_001_234_567)
        XCTAssertEqual(DateTimeOffset.parseJSON("2026-10-31T12:00:00Z")?.utcTicks, 639_290_448_000_000_000)
        XCTAssertEqual(DateTimeOffset.parseJSON("2026-10-31T12:00:00+02")?.offsetMinutes, 120)
        XCTAssertNil(DateTimeOffset.parseJSON("2026-10-31T12:00:00+0200"))
        XCTAssertNil(DateTimeOffset.parseJSON("2026-10-31 12:00:00Z"))
        XCTAssertNil(DateTimeOffset.parseJSON("2026-02-29T00:00:00Z"))
        XCTAssertEqual("0001-01-01T00:00:00+00:00", DateTimeOffset.minValue.jsonText)
    }
}
