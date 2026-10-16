import XCTest
import CoreGraphics
@testable import QNotchMacCore
@testable import QNotchMac

final class CoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testDeadlineSurvivesMissingRefreshesAndSleep() {
        var timer = Countdown(duration: 90)
        timer.toggle(at: now)
        XCTAssertEqual(timer.text(at: now.addingTimeInterval(45)), "0:45")
        XCTAssertTrue(timer.refresh(at: now.addingTimeInterval(120)))
        XCTAssertTrue(timer.finished)
        XCTAssertFalse(timer.isRunning)
        XCTAssertFalse(timer.refresh(at: now.addingTimeInterval(121)))
    }

    func testPauseResumeAndReset() {
        var timer = Countdown(duration: 60)
        timer.toggle(at: now)
        timer.toggle(at: now.addingTimeInterval(10))
        XCTAssertEqual(timer.secondsLeft(at: now.addingTimeInterval(100)), 50)
        XCTAssertNil(timer.nextWake(at: now, visible: true))
        timer.toggle(at: now.addingTimeInterval(200))
        XCTAssertEqual(timer.secondsLeft(at: now.addingTimeInterval(210)), 40)
        timer.reset(duration: 300)
        XCTAssertEqual(timer.text(at: now), "5:00")
        XCTAssertFalse(timer.isRunning)
    }

    func testVisibilityControlsWakeSchedule() {
        var timer = Countdown(duration: 300)
        XCTAssertNil(timer.nextWake(at: now, visible: false))
        timer.toggle(at: now)
        XCTAssertEqual(timer.nextWake(at: now, visible: false), 60, "Collapsed shows whole minutes")
        XCTAssertEqual(timer.nextWake(at: now.addingTimeInterval(30), visible: false), 30)
        XCTAssertEqual(timer.nextWake(at: now.addingTimeInterval(250), visible: false), 1, "Final minute shows seconds")
        XCTAssertEqual(timer.nextWake(at: now, visible: true), 1)
        XCTAssertEqual(timer.nextWake(at: now.addingTimeInterval(299.5), visible: true), 0.5)
    }

    func testShortTextUsesMinutesUntilTheFinalMinute() {
        var timer = Countdown(duration: 25 * 60)
        XCTAssertEqual(timer.shortText(at: now), "25:00", "A stopped timer shows the full time")
        timer.toggle(at: now)
        XCTAssertEqual(timer.shortText(at: now), "25m")
        XCTAssertEqual(timer.shortText(at: now.addingTimeInterval(60)), "24m")
        XCTAssertEqual(timer.shortText(at: now.addingTimeInterval(24 * 60 + 1)), "0:59")
        XCTAssertEqual(timer.progress(at: now.addingTimeInterval(12.5 * 60)), 0.5, accuracy: 0.0001)
    }

    func testFormattingRoundsUpAndNeverShowsNegativeTime() {
        var timer = Countdown(duration: 60)
        timer.toggle(at: now)
        XCTAssertEqual(timer.text(at: now.addingTimeInterval(0.1)), "1:00")
        XCTAssertEqual(timer.text(at: now.addingTimeInterval(59.9)), "0:01")
        XCTAssertEqual(timer.text(at: now.addingTimeInterval(61)), "0:00")
    }

    func testHoverCannotDowngradeExplicitKeyboardFocus() {
        var state = ShellState()
        XCTAssertFalse(state.acceptsKeyboard)
        state.open(keyboard: false)
        XCTAssertTrue(state.expanded)
        XCTAssertFalse(state.acceptsKeyboard)
        state.pointerLeft()
        XCTAssertFalse(state.expanded)
        state.open(keyboard: true)
        state.open(keyboard: false)
        state.pointerLeft()
        XCTAssertTrue(state.acceptsKeyboard)
        state.close()
        XCTAssertFalse(state.acceptsKeyboard)
    }

    func testNotchedDisplayUsesRealHousingCenterAndSafeTop() {
        let layout = DisplayLayout(frame: CGRect(x: 100, y: 200, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 100, y: 224, width: 1512, height: 921),
                                   safeTop: 37, cameraGap: CGRect(x: 760, y: 1145, width: 192, height: 37))
        let idle = layout.surface(expanded: false)
        XCTAssertEqual(idle.width, 192 + 2 * DisplayLayout.flare, "An idle surface hugs the camera housing")
        XCTAssertEqual(idle.height, 37)
        for (expanded, wing) in [(false, 48), (true, 0), (true, 48)] as [(Bool, CGFloat)] {
            let surface = layout.surface(expanded: expanded, wing: wing)
            XCTAssertEqual(surface.maxY, layout.frame.maxY, "The surface must join the physical bezel, not sit below the notch")
            XCTAssertEqual(surface.midX, 856)
            XCTAssertTrue(layout.frame.contains(surface))
            let wings = layout.wings(expanded: expanded, wing: wing)!
            XCTAssertGreaterThanOrEqual(wings.left.width, wing)
            XCTAssertEqual(wings.left.maxX, layout.cameraHousing!.minX)
            XCTAssertEqual(wings.right.minX, layout.cameraHousing!.maxX)
            XCTAssertFalse(wings.left.intersects(layout.cameraHousing!))
            XCTAssertFalse(wings.right.intersects(layout.cameraHousing!))
            XCTAssertEqual(wings.left.maxY, layout.frame.maxY)
            XCTAssertTrue(surface.contains(wings.left))
            XCTAssertTrue(surface.contains(wings.right))
        }
        XCTAssertEqual(layout.panelBody.maxY, layout.cameraHousing!.minY)
        XCTAssertEqual(layout.surface(expanded: true).width, DisplayLayout.panelSize.width)
        XCTAssertEqual(layout.surface(expanded: true).height, DisplayLayout.panelSize.height + 37)
    }

    func testUnknownCameraGeometryFallsBackWithoutCoveringControls() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for gap in [nil, CGRect(x: -100, y: 945, width: 200, height: 37)] as [CGRect?] {
            let layout = DisplayLayout(frame: frame, visibleFrame: frame, safeTop: 37, cameraGap: gap)
            XCTAssertFalse(layout.integratesCameraHousing)
            XCTAssertNil(layout.wings(expanded: false))
            XCTAssertEqual(layout.surface(expanded: false).maxY, 945)
            XCTAssertEqual(layout.panelBody.maxY, 945)
        }
    }

    func testNonNotchedExternalDisplayWithNegativeOriginAvoidsMenuBar() {
        let layout = DisplayLayout(frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                   visibleFrame: CGRect(x: -1920, y: -100, width: 1920, height: 1055), safeTop: 0, cameraGap: nil)
        XCTAssertEqual(layout.surface(expanded: false).midX, -960)
        XCTAssertEqual(layout.surface(expanded: false, wing: 120).width, 148, "A floating pill fits its content")
        XCTAssertEqual(layout.surface(expanded: false).width, 96)
        XCTAssertEqual(layout.surface(expanded: true).maxY, 949)
        XCTAssertTrue(layout.visibleFrame.contains(layout.surface(expanded: true)))
    }

    func testSmallDisplayClampsBothSurfaceSizes() {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let layout = DisplayLayout(frame: frame, visibleFrame: frame, safeTop: 0, cameraGap: nil)
        XCTAssertTrue(frame.contains(layout.surface(expanded: true)))
        XCTAssertEqual(layout.surface(expanded: true).width, 304)
    }

    func testSettingsRoundTripIsIsolatedAndCorruptFileIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        var settings = GeneralSettings()
        settings.displayID = 42
        settings.reduceMotion = true
        XCTAssertTrue(store.save("general", settings))
        XCTAssertEqual(store.load("general", default: GeneralSettings()), settings)
        let corrupt = Data("broken JSON".utf8)
        let url = directory.appendingPathComponent("general.json")
        try corrupt.write(to: url)
        XCTAssertEqual(store.load("general", default: GeneralSettings()), GeneralSettings())
        XCTAssertNotNil(store.problem)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnavailableSettingsAreReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        XCTAssertFalse(store.save("general", GeneralSettings()))
        XCTAssertNotNil(store.problem)
    }

    func testMacChannelRejectsWindowsTagsAndGlobalLatestEndpoint() {
        XCTAssertTrue(UpdateChannel.accepts(tag: "macos-v0.1.0"))
        XCTAssertTrue(UpdateChannel.accepts(tag: "macos-v0.1.0-beta.1"))
        XCTAssertTrue(UpdateChannel.accepts(tag: "macos-v0.1.0-alpha.0"))
        for tag in ["v1.0.0", "macos-v01.0.0", "macos-v1.0.0;echo bad", "macos-v1.0.0\n"] {
            XCTAssertFalse(UpdateChannel.accepts(tag: tag), tag)
        }
        XCTAssertFalse(UpdateChannel.releasesURL.path.hasSuffix("latest"))
    }

    func testDisabledModuleIsNeverConstructed() {
        XCTAssertTrue(ModuleList.make(timerEnabled: false).isEmpty)
    }

    func testRealTimerRegistersAllFiveExtensionConcepts() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registries = ModuleRegistries()
        let modules = ModuleList.make(timerEnabled: true)
        modules.forEach { $0.initialize(ModuleContext(settings: SettingsStore(directory: directory), registries: registries, shell: nil)) }
        defer { modules.forEach { $0.stop() } }
        XCTAssertEqual(registries.cards.items.map(\.id), ["timer"])
        XCTAssertEqual(registries.tabs.items.map(\.id), ["timer"])
        XCTAssertEqual(registries.segments.items.map(\.id), ["timer.pill", "timer.ring"])
        XCTAssertEqual(registries.segments.items.map(\.slot), [.trailing, .leading])
        XCTAssertEqual(registries.searchSources.items.first?.find("COUNTDOWN").count, 1)
        XCTAssertEqual(registries.searchSources.items.first?.find("unknown").count, 0)
        XCTAssertEqual(registries.settingsSections.items.map(\.id), ["timer"])
    }
}
