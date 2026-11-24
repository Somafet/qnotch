import XCTest
@testable import CalculatorEngine

final class PreferencesVersionTests: XCTestCase {
    private var directory = TestFiles.temporary("Calc-tests")
    override func tearDown() { TestFiles.delete(directory) }
    private var preferencesPath: String { TestFiles.path(directory, "preferences.json") }
    private func open() throws -> WorkspaceStore { let store = try WorkspaceStore(directory); _ = try store.load(); return store }
    private func storedVersion() throws -> Int { try JSONNode.parse(Data(try TestFiles.readBytes(preferencesPath))).property("Version").int() }

    func testVersionOneFilesStayReadableAndAreNotRewrittenOnLoad() throws {
        try open().dispose()
        let legacy = "{\"Version\":1,\"WorkdayRegion\":\"DE\",\"AutoCurrencyRates\":true}"
        try TestFiles.writeText(preferencesPath, legacy)
        let store = try open(); defer { store.dispose() }
        let loaded = try store.loadPreferences()
        XCTAssertEqual("DE", loaded.workdayRegion); XCTAssertTrue(loaded.autoCurrencyRates)
        XCTAssertNil(loaded.fontSize); XCTAssertNil(loaded.decimalPlaces); XCTAssertNil(loaded.numberStyle)
        XCTAssertNil(loaded.language); XCTAssertFalse(loaded.alwaysOnTop); XCTAssertNil(loaded.window)
        XCTAssertEqual(legacy, try TestFiles.readText(preferencesPath))
        // Version-1 settings alone keep the file readable by builds that predate version 2.
        try store.setWorkdayRegion("US"); XCTAssertEqual(1, try storedVersion())
    }
    func testVersionTwoSettingsMigrateAndSurviveRestartWithoutLosingVersionOneChoices() throws {
        let placement = WindowPlacementPreference(100, 80, 900, 700, true)
        do {
            let store = try open(); defer { store.dispose() }
            try store.setWorkdayRegion("DE"); try store.setAutoCurrencyRates(true)
            let saved = try store.updatePreferences { $0.with { $0.fontSize = 24; $0.decimalPlaces = 2; $0.numberStyle = "period"; $0.language = "ja"; $0.alwaysOnTop = true; $0.window = placement } }
            XCTAssertEqual(2, saved.version); XCTAssertEqual(2, try storedVersion())
        }
        let reopened = try open(); defer { reopened.dispose() }
        let loaded = try reopened.loadPreferences()
        XCTAssertEqual(24, loaded.fontSize); XCTAssertEqual(2, loaded.decimalPlaces); XCTAssertEqual("period", loaded.numberStyle); XCTAssertEqual("ja", loaded.language)
        XCTAssertTrue(loaded.alwaysOnTop); XCTAssertEqual(placement, loaded.window); XCTAssertEqual("DE", loaded.workdayRegion); XCTAssertTrue(loaded.autoCurrencyRates)
        // Clearing every version-2 setting returns the file to version 1.
        try reopened.updatePreferences { $0.with { $0.fontSize = nil; $0.decimalPlaces = nil; $0.numberStyle = nil; $0.language = nil; $0.alwaysOnTop = false; $0.window = nil } }
        XCTAssertEqual(1, try storedVersion())
        XCTAssertEqual("DE", try reopened.loadPreferences().workdayRegion)
    }
    func testInvalidStoredSettingsRecoverTheLastGoodBackupAndKeepTheRejectedBytes() throws {
        let base = directory
        try theory(["{\"Version\":2,\"FontSize\":9}", "{\"Version\":2,\"FontSize\":41}", "{\"Version\":2,\"DecimalPlaces\":-1}", "{\"Version\":2,\"DecimalPlaces\":21}",
                    "{\"Version\":2,\"NumberStyle\":\"roman\"}", "{\"Version\":2,\"Language\":\"pt\"}",
                    "{\"Version\":2,\"Window\":{\"Left\":0,\"Top\":0,\"Right\":0,\"Bottom\":10,\"Maximized\":false}}",
                    "{\"Version\":2,\"Window\":{\"Left\":-2000000,\"Top\":0,\"Right\":10,\"Bottom\":10,\"Maximized\":false}}",
                    "{\"Version\":1,\"FontSize\":24}"]) { invalid in
            directory = TestFiles.path(base, UUID().netN)
            let store = try open(); defer { store.dispose() }
            try store.updatePreferences { $0.with { $0.fontSize = 18 } }
            try store.updatePreferences { $0.with { $0.fontSize = 22 } }
            try TestFiles.writeText(preferencesPath, invalid)
            XCTAssertEqual(18, try store.loadPreferences().fontSize); XCTAssertTrue(store.preferencesRecovered)
            let rejected = TestFiles.files(directory, "preferences.json.corrupt-*")
            XCTAssertEqual(1, rejected.count)
            XCTAssertEqual(invalid, try TestFiles.readText(rejected[0]))
        }
        directory = base
    }
    func testInvalidChoicesAndFutureVersionsAreNeverWritten() throws {
        let store = try open(); defer { store.dispose() }
        try store.updatePreferences { $0.with { $0.decimalPlaces = 3 } }
        let before = try TestFiles.readText(preferencesPath)
        assertThrows(.invalidData, try store.updatePreferences { $0.with { $0.fontSize = 100 } })
        assertThrows(.invalidData, try store.updatePreferences { $0.with { $0.language = "EN" } })
        assertThrows(.invalidData, try store.updatePreferences { $0.with { $0.window = WindowPlacementPreference(0, 0, 0, 0, false) } })
        XCTAssertEqual(before, try TestFiles.readText(preferencesPath))
        let future = "{\"Version\":3,\"FontSize\":24}"
        try TestFiles.writeText(preferencesPath, future)
        assertThrows(.unsupportedVersion, try store.updatePreferences { $0.with { $0.fontSize = 16 } })
        XCTAssertEqual(future, try TestFiles.readText(preferencesPath))
    }
    func testLargestSettingsStayInsideTheFourKibibyteBound() throws {
        let store = try open(); defer { store.dispose() }
        let largest = try store.updatePreferences { $0.with {
            $0.workdayRegion = "WEEKDAYS"; $0.autoCurrencyRates = true; $0.fontSize = 40; $0.decimalPlaces = 20; $0.numberStyle = "apostrophe"
            $0.language = "zh-Hans"; $0.alwaysOnTop = true; $0.window = WindowPlacementPreference(-1_000_000, -1_000_000, -900_000, -900_000, true)
        } }
        XCTAssertTrue(NetFile.info(preferencesPath).length < 1024)
        XCTAssertEqual(largest, try store.loadPreferences())
    }
    func testInterfaceLanguagesAreTheKeywordAliasLanguages() throws {
        let keywords = try JSONNode.parse(try Data(contentsOf: Fixtures.repositoryRoot.appendingPathComponent("src/QNotch.Calculator.Engine/LanguageKeywords.json")))
        let codes = try keywords.property("languages").arrayItems().map { try $0.property("code").string() }
        XCTAssertEqual(codes, PreferencesDocument.languages)
    }
}
