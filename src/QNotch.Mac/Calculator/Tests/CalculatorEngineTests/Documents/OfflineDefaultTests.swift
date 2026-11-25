import XCTest
@testable import CalculatorEngine

final class OfflineDefaultTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-tests")
    override func tearDown() { TestFiles.delete(directory) }

    func testFreshAndOlderPreferencesLeaveAutomaticRatesOff() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }; _ = try store.load()
        XCTAssertFalse(try store.loadPreferences().autoCurrencyRates)
        XCTAssertFalse(TestFiles.exists(TestFiles.path(directory, "preferences.json")))
        try TestFiles.writeText(TestFiles.path(directory, "preferences.json"), "{\"Version\":1,\"WorkdayRegion\":null}")
        XCTAssertFalse(try store.loadPreferences().autoCurrencyRates)
    }
    func testAWorkspaceCreatesNoRateCache() throws {
        let store = try WorkspaceStore(directory); defer { store.dispose() }; _ = try store.load()
        XCTAssertTrue(TestFiles.files(directory, "currency-rates*").isEmpty)
    }
}
