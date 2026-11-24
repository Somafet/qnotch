import XCTest
@testable import CalculatorEngine

final class PreferencesTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-tests")
    override func tearDown() { TestFiles.delete(directory) }

    func testRegionSurvivesRestartWithoutChangingSourceAndOldWorkspacesNeedNoRewrite() throws {
        let id: UUID
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            id = try store.load().workspace.activeSheetId
            XCTAssertNil(try store.loadPreferences().workdayRegion)
            XCTAssertFalse(TestFiles.exists(TestFiles.path(directory, "preferences.json")))
            _ = try store.open(id); try store.save(SheetDocument(1, id, "f(n)=n working days\n2027-12-23+f(1)", false))
            try store.setWorkdayRegion("US")
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        _ = try reopened.load(); let region = try reopened.loadPreferences().workdayRegion; XCTAssertEqual("US", region)
        let sheet = try reopened.open(id); let session = SheetEvaluationSession()
        XCTAssertEqual("2027-12-27", try session.evaluateWithFunctions(sheet.document.source, try reopened.loadFunctions(), sheet.functionReceipts ?? [], context: EvaluationContext(workdayRegion: region)).results.last!.display)
        XCTAssertEqual("2027-12-24", try session.evaluateWithFunctions(sheet.document.source, try reopened.loadFunctions(), sheet.functionReceipts ?? [], context: EvaluationContext(workdayRegion: "DE")).results.last!.display)
        XCTAssertTrue(sheet.document.source.contains("f(1)"))
        XCTAssertNil(try reopened.setWorkdayRegion(nil).workdayRegion)
    }
    func testDefaultCurrencySurvivesRestartAndRejectsUnknownCodes() throws {
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            _ = try store.load(); XCTAssertNil(try store.loadPreferences().defaultCurrency)
            let saved = try store.updatePreferences { $0.with { $0.defaultCurrency = "HUF" } }
            XCTAssertEqual(2, saved.version)
            assertThrows(.invalidData, try store.updatePreferences { $0.with { $0.defaultCurrency = "ZZZ" } })
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }
        _ = try reopened.load(); XCTAssertEqual("HUF", try reopened.loadPreferences().defaultCurrency)
        XCTAssertNil(try reopened.updatePreferences { $0.with { $0.defaultCurrency = nil } }.defaultCurrency)
    }
    func testCorruptPreferencesRecoverTheLastGoodBackupAndPreserveRejectedBytes() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        _ = try store.load(); try store.setWorkdayRegion("DE"); try store.setWorkdayRegion("US")
        let path = TestFiles.path(directory, "preferences.json"); try TestFiles.writeText(path, "{bad")
        XCTAssertEqual("DE", try store.loadPreferences().workdayRegion); XCTAssertTrue(store.preferencesRecovered)
        let rejected = TestFiles.files(directory, "preferences.json.corrupt-*")
        XCTAssertEqual(1, rejected.count)
        XCTAssertEqual("{bad", try TestFiles.readText(rejected[0]))
    }
    func testUnsupportedVersionsAndInvalidChoicesCannotBeSilentlyOverwritten() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        _ = try store.load(); try store.setWorkdayRegion("DE")
        assertThrows(.invalidData, try store.setWorkdayRegion("ZZ"))
        let path = TestFiles.path(directory, "preferences.json"); let future = "{\"Version\":999,\"WorkdayRegion\":\"US\"}"
        try TestFiles.writeText(path, future)
        assertThrows(.unsupportedVersion, try store.loadPreferences())
        assertThrows(.unsupportedVersion, try store.setWorkdayRegion("US"))
        XCTAssertEqual(future, try TestFiles.readText(path))
    }
    /// Windows: the file held with FileShare.Read blocks its replacement. Mac: the holder's shared flock does.
    func testFailedPreferenceReplacementRetainsThePreviousCalendar() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }
        _ = try store.load(); try store.setWorkdayRegion("DE")
        let path = TestFiles.path(directory, "preferences.json")
        do {
            let locked = try TestFiles.holdShared(path)
            assertThrows(.io, try store.setWorkdayRegion("US"))
            locked.close()
        }
        XCTAssertEqual("DE", try store.loadPreferences().workdayRegion)
        XCTAssertTrue(TestFiles.files(directory, "preferences.json.*.tmp").isEmpty)
    }
    func testAutomaticCurrencyDownloadsDefaultOffAndCalendarChangesPreserveTheExplicitChoice() throws {
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            _ = try store.load(); XCTAssertFalse(try store.loadPreferences().autoCurrencyRates)
            try store.setAutoCurrencyRates(true); XCTAssertTrue(try store.setWorkdayRegion("DE").autoCurrencyRates)
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        XCTAssertTrue(try reopened.loadPreferences().autoCurrencyRates); XCTAssertEqual("DE", try reopened.loadPreferences().workdayRegion)
        XCTAssertEqual("DE", try reopened.setAutoCurrencyRates(false).workdayRegion)
    }
    func testRecoveringAnOlderBackupCannotReenableRevokedNetworkConsent() throws {
        do {
            let store = try WorkspaceStore(directory); defer { store.dispose() }
            _ = try store.load(); try store.setAutoCurrencyRates(true); try store.setAutoCurrencyRates(false)
            try TestFiles.writeText(TestFiles.path(directory, "preferences.json"), "{bad")
            XCTAssertFalse(try store.loadPreferences().autoCurrencyRates); XCTAssertTrue(store.preferencesRecovered)
        }
        let reopened = try WorkspaceStore(directory); defer { reopened.dispose() }; _ = try reopened.load()
        XCTAssertFalse(try reopened.loadPreferences().autoCurrencyRates)
    }
}
