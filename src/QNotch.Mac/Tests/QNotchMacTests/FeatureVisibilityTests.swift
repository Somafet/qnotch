import Foundation
import XCTest
import QNotchMacCore

final class FeatureVisibilityTests: XCTestCase {
    func testExistingSettingsKeepContributionsVisible() throws {
        for json in ["{}", #"{"disabledModules":["media"],"hiddenCards":["system"]}"#] {
            let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
            XCTAssertTrue(settings.isTabVisible("media"))
            XCTAssertTrue(settings.isNotchVisible("stats"))
            XCTAssertTrue(settings.isTabVisible("terminal"), "Future contributions default to visible")
        }
    }

    func testChoicesPersistIndependentlyOfEnablementAndOrdering() throws {
        var settings = GeneralSettings()
        settings.cardOrder = ["system", "media", "timer"]
        settings.tabOrder = ["timer", "media", "files"]
        settings.setCardVisible("media", false)
        settings.setTabVisible("media", false)
        settings.setNotchVisible("media", false)
        settings.setEnabled("media", false)
        settings = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        settings.setEnabled("media", true)
        XCTAssertTrue(settings.isEnabled("media"))
        XCTAssertFalse(settings.isCardVisible("media"))
        XCTAssertFalse(settings.isTabVisible("media"))
        XCTAssertFalse(settings.isNotchVisible("media"))
        settings.setCardVisible("media", true)
        settings.setTabVisible("media", true)
        settings.setNotchVisible("media", true)
        XCTAssertEqual(settings.cardOrder, ["system", "media", "timer"])
        XCTAssertEqual(settings.tabOrder, ["timer", "media", "files"])
        XCTAssertTrue(settings.hiddenCards.isEmpty && settings.hiddenTabs.isEmpty && settings.hiddenNotchModules.isEmpty)
    }

    func testHidingBeforeFirstDragRetainsDefaultSlotAcrossReorder() {
        let defaults = ["media", "timer", "files", "ai"]
        let saved = LayoutOrder.remember(saved: [], defaults: defaults)
        let reordered = LayoutOrder.reorder(["ai", "timer", "files"], saved: saved)
        XCTAssertEqual(LayoutOrder.apply(saved: reordered, defaults: defaults), ["media", "ai", "timer", "files"])
        XCTAssertEqual(LayoutOrder.remember(saved: ["gone", "files"], defaults: defaults), ["gone", "files", "media", "timer", "ai"])
        XCTAssertEqual(LayoutOrder.reorder(["files", "timer"], saved: ["gone", "timer", "media", "files"]), ["gone", "files", "media", "timer"])
    }
}
