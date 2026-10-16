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
        XCTAssertTrue(ModuleList.make(disabled: ModuleList.all.map(\.id)).isEmpty)
        XCTAssertFalse(ModuleList.make(disabled: []).isEmpty)
    }

    func testRealTimerRegistersAllFiveExtensionConcepts() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registries = ModuleRegistries()
        let modules = ModuleList.make(disabled: ModuleList.all.map(\.id).filter { $0 != "timer" })
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

    func testLegacyTimerSwitchAndMissingKeysDecode() throws {
        let legacy = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"reduceMotion":true,"timerEnabled":false}"#.utf8))
        XCTAssertTrue(legacy.reduceMotion)
        XCTAssertEqual(legacy.disabledModules, ["timer"])
        XCTAssertFalse(legacy.isEnabled("timer"))
        let empty = try JSONDecoder().decode(GeneralSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, GeneralSettings())
        let timer = try JSONDecoder().decode(TimerSettings.self, from: Data(#"{"minutes":10}"#.utf8))
        XCTAssertEqual(timer.minutes, 10)
        XCTAssertTrue(timer.playSound)
        var general = GeneralSettings()
        general.setEnabled("volume", false); general.setEnabled("clipboard", false); general.setEnabled("volume", false)
        XCTAssertEqual(general.disabledModules, ["clipboard", "volume"])
        general.setEnabled("volume", true)
        XCTAssertEqual(general.disabledModules, ["clipboard"])
        let encoded = String(decoding: try JSONEncoder().encode(general), as: UTF8.self)
        XCTAssertFalse(encoded.contains("timerEnabled"))
    }

    func testKeyComboRoundTripsAndRequiresAGlobalModifier() throws {
        let toggle = try XCTUnwrap(KeyCombo("ctrl+opt+n"))
        XCTAssertEqual(toggle.keyCode, 0x2D)
        XCTAssertEqual(toggle.modifiers, KeyCombo.control | KeyCombo.option)
        XCTAssertEqual(toggle.display, "⌃⌥N")
        XCTAssertEqual(KeyCombo(toggle.text), toggle)
        XCTAssertEqual(KeyCombo("Shift + Cmd + Space")?.display, "⇧⌘Space")
        XCTAssertEqual(KeyCombo("alt+1")?.text, "opt+1")
        XCTAssertTrue(toggle.isAllowedGlobally)
        XCTAssertFalse(try XCTUnwrap(KeyCombo("shift+a")).isAllowedGlobally)
        for invalid in ["", "ctrl+opt", "ctrl+n+m", "ctrl+unknown"] { XCTAssertNil(KeyCombo(invalid), invalid) }
        XCTAssertNil(KeyCombo(keyCode: 0xFF, modifiers: 0))
    }

    func testCardGridPacksDenselyInReadingOrder() {
        let slots = CardGrid.place(spans: [2, 2, 1, 1, 3, 5])
        XCTAssertEqual(slots, [
            .init(row: 0, column: 0, span: 2), .init(row: 1, column: 0, span: 2),
            .init(row: 0, column: 2, span: 1), .init(row: 1, column: 2, span: 1),
            .init(row: 2, column: 0, span: 3), .init(row: 3, column: 0, span: 3)
        ])
        XCTAssertEqual(CardGrid.rows(slots), 4)
        XCTAssertEqual(CardGrid.rows([]), 0)
    }
}

final class VolumeLevelTests: XCTestCase {
    func testStepsClampAndRaisingUnmutes() {
        let muted = VolumeLevel(scalar: 0.5, muted: true)
        XCTAssertEqual(muted.text, "Muted")
        XCTAssertEqual(muted.symbol, "speaker.slash.fill")
        XCTAssertEqual(muted.stepped(by: 1), VolumeLevel(scalar: 0.52, muted: false))
        XCTAssertEqual(VolumeLevel(scalar: 0.99, muted: false).stepped(by: 3).percent, 100)
        XCTAssertEqual(VolumeLevel(scalar: 0.01, muted: false).stepped(by: -1).percent, 0)
        XCTAssertTrue(VolumeLevel(scalar: 0, muted: false).isSilent)
        XCTAssertEqual(VolumeLevel(scalar: 0.333, muted: false).text, "33%")
        XCTAssertEqual(VolumeLevel(scalar: 0.8, muted: false).symbol, "speaker.wave.3.fill")
        XCTAssertEqual(VolumeLevel(scalar: 2, muted: false).scalar, 1)
        XCTAssertTrue(muted.setting(percent: 0).muted)
    }
}

final class NoteTextTests: XCTestCase {
    func testWordsAndLineMatches() {
        XCTAssertEqual(NoteText.words(in: ""), 0)
        XCTAssertEqual(NoteText.words(in: "Buy milk,\nthen call Ádám — at 5pm."), 7)
        let text = "Groceries\n  buy MILK and eggs\n\nCafé meeting\n" + String(repeating: "x", count: 50) + " milk " + String(repeating: "y", count: 50)
        let hits = NoteText.matches(of: "milk", in: text)
        XCTAssertEqual(hits.first, "buy MILK and eggs")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits[1].hasPrefix("…") && hits[1].hasSuffix("…") && hits[1].contains("milk"))
        XCTAssertEqual(NoteText.matches(of: "cafe", in: text), ["Café meeting"])
        XCTAssertEqual(NoteText.matches(of: "", in: text), [])
        XCTAssertEqual(NoteText.matches(of: "e", in: text, limit: 2).count, 2)
    }
}

final class HexColorTests: XCTestCase {
    func testFormattingNormalizingAndRecents() throws {
        XCTAssertEqual(HexColor.string(red: 1, green: 0.5, blue: 0), "#FF8000")
        XCTAssertEqual(HexColor.string(red: -1, green: 2, blue: 0.2), "#00FF33")
        XCTAssertEqual(HexColor.normalize(" #abc"), "#AABBCC")
        XCTAssertEqual(HexColor.normalize("5b9dff"), "#5B9DFF")
        for bad in ["", "#12345", "#GG0000", "#1234567"] { XCTAssertNil(HexColor.normalize(bad), bad) }
        let c = try XCTUnwrap(HexColor.components("#FF8000"))
        XCTAssertEqual(c.green, 128.0 / 255, accuracy: 0.0001)
        var recent: [String] = []
        for color in ["#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#777777"] { recent = HexColor.remember(color, in: recent) }
        XCTAssertEqual(recent.count, 6)
        XCTAssertEqual(recent.first, "#777777")
        recent = HexColor.remember("#444444", in: recent)
        XCTAssertEqual(recent.prefix(2), ["#444444", "#777777"])
        XCTAssertEqual(Set(recent).count, recent.count)
        let decoded = try JSONDecoder().decode(ColorPickerSettings.self, from: Data(##"{"recent":["#abc","nope"]}"##.utf8))
        XCTAssertEqual(decoded.recent, ["#AABBCC"])
    }
}

final class CaptureStateTests: XCTestCase {
    func testSummaryNamesMicrophoneAppsOnly() {
        XCTAssertEqual(CaptureState().summary, "")
        XCTAssertFalse(CaptureState().active)
        XCTAssertEqual(CaptureState(microphone: true).summary, "Microphone in use.")
        XCTAssertEqual(CaptureState(microphone: true, microphoneApps: ["Zoom", "Safari", "Zoom"], camera: true).summary,
                       "Microphone: Safari, Zoom. Camera in use.")
        XCTAssertEqual(CaptureState(camera: true).summary, "Camera in use.")
    }
}

final class SystemStatsTests: XCTestCase {
    func testCpuRatesAndFormatting() {
        XCTAssertNil(SystemStats.cpuPercent(from: nil, to: .init(busy: 10, total: 100)))
        XCTAssertEqual(SystemStats.cpuPercent(from: .init(busy: 10, total: 100), to: .init(busy: 35, total: 200)), 25)
        XCTAssertNil(SystemStats.cpuPercent(from: .init(busy: 10, total: 100), to: .init(busy: 10, total: 100)))
        XCTAssertEqual(SystemStats.rate(from: 1000, to: 3000, seconds: 2), 1000)
        XCTAssertEqual(SystemStats.rate(from: UInt64(UInt32.max) - 99, to: 100, seconds: 1), 200)
        XCTAssertNil(SystemStats.rate(from: 0, to: 10, seconds: 0.01))
        XCTAssertEqual(SystemStats.rateText(819_600), "820 KB/s")
        XCTAssertEqual(SystemStats.rateText(1_250_000), "1.2 MB/s")
        XCTAssertEqual(SystemStats.rateText(nil), "--")
        XCTAssertEqual(SystemStats.shortRate(4_000), "4K")
        XCTAssertEqual(SystemStats.memoryText(used: 6_550_000_000, total: 8_589_934_592), "6.1/8 GB")
        XCTAssertEqual(SystemStats.percentText(12.6), "13%")
        XCTAssertTrue(SystemStats.countsInterface("en0", loopback: false))
        for name in ["lo0", "utun3", "awdl0", "llw0", "bridge0", "anpi1"] { XCTAssertFalse(SystemStats.countsInterface(name, loopback: false), name) }
        XCTAssertFalse(SystemStats.countsInterface("en5", loopback: true))
        XCTAssertEqual(SystemStats.batterySymbol(percent: 50, charging: false), "battery.50")
        XCTAssertEqual(SystemStats.batterySymbol(percent: 5, charging: true), "battery.100.bolt")
    }

    func testStatsSettingsDefaultsAvoidMenuBarDuplicates() throws {
        let decoded = try JSONDecoder().decode(StatsSettings.self, from: Data(#"{"wingGPU":true}"#.utf8))
        XCTAssertTrue(decoded.wingCPU && decoded.wingMemory && decoded.wingGPU)
        XCTAssertFalse(decoded.wingBattery || decoded.wingClock || decoded.wingNetwork)
        var none = StatsSettings()
        none.wingCPU = false; none.wingMemory = false
        XCTAssertFalse(none.anyWing)
        none.wingClock = true
        XCTAssertTrue(none.anyWing)
        XCTAssertFalse(none.sampledWing)
    }
}
