import Foundation
import XCTest
import QNotchMacCore
@testable import QNotchMac

final class SearchEnablementTests: XCTestCase {
    func testSearchDefaultsOnForExistingSettings() throws {
        for json in ["{}", #"{"timerEnabled":false}"#, #"{"disabledModules":["note"]}"#] {
            let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
            XCTAssertTrue(settings.isEnabled("search"), json)
        }
    }

    func testSearchChoicePersistsAndGroupTogglePreservesOtherFeatures() throws {
        var settings = GeneralSettings()
        settings.setEnabled("timer", false)
        settings.setEnabled("search", false)
        settings = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(!settings.isEnabled("search"))
        let group = try XCTUnwrap(Onboarding.groups(available: ModuleList.all.map(\.id)).first { $0.modules.contains("search") })
        Onboarding.setGroup(group, enabled: true, in: &settings)
        XCTAssertTrue(settings.isEnabled("search"))
        XCTAssertTrue(!settings.isEnabled("timer"))
        Onboarding.setGroup(group, enabled: false, in: &settings)
        XCTAssertTrue(!settings.isEnabled("search"))
        XCTAssertTrue(settings.isEnabled("stats"))
        XCTAssertTrue(ModuleList.all.filter { $0.id == "search" }.count == 1)
    }
}
