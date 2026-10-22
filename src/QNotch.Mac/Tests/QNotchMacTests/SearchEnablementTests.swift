import Foundation
import Testing
import QNotchMacCore
@testable import QNotchMac

struct SearchEnablementTests {
    @Test(arguments: ["{}", #"{"timerEnabled":false}"#, #"{"disabledModules":["note"]}"#])
    func searchDefaultsOnForExistingSettings(json: String) throws {
        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
        #expect(settings.isEnabled("search"))
    }

    @Test func searchChoicePersistsAndGroupTogglePreservesOtherFeatures() throws {
        var settings = GeneralSettings()
        settings.setEnabled("timer", false)
        settings.setEnabled("search", false)
        settings = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        #expect(!settings.isEnabled("search"))
        let group = try #require(Onboarding.groups(available: ModuleList.all.map(\.id)).first { $0.modules.contains("search") })
        Onboarding.setGroup(group, enabled: true, in: &settings)
        #expect(settings.isEnabled("search"))
        #expect(!settings.isEnabled("timer"))
        Onboarding.setGroup(group, enabled: false, in: &settings)
        #expect(!settings.isEnabled("search"))
        #expect(settings.isEnabled("stats"))
        #expect(ModuleList.all.filter { $0.id == "search" }.count == 1)
    }
}
