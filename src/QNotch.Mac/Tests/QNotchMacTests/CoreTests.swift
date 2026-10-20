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

    func testPointerAgainstTheTopOfTheDisplayIsOverTheNotch() {
        let layout = DisplayLayout(frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
                                   safeTop: 32, cameraGap: CGRect(x: 646, y: 924, width: 179, height: 32))
        for (expanded, wing) in [(false, 0), (false, 150), (true, 0)] as [(Bool, CGFloat)] {
            let surface = layout.surface(expanded: expanded, wing: wing)
            let top = CGPoint(x: layout.cameraHousing!.midX, y: layout.frame.maxY)
            XCTAssertFalse(surface.contains(top), "CGRect.contains leaves out the top row")
            XCTAssertTrue(surface.containsPointer(top), "A pointer flicked up to the camera housing is over the notch")
            XCTAssertTrue(surface.containsPointer(CGPoint(x: surface.minX, y: surface.maxY)))
            XCTAssertTrue(surface.containsPointer(CGPoint(x: surface.midX, y: surface.minY)))
            XCTAssertFalse(surface.containsPointer(CGPoint(x: surface.maxX, y: surface.maxY)))
            XCTAssertFalse(surface.containsPointer(CGPoint(x: surface.minX - 1, y: surface.maxY)))
            XCTAssertFalse(surface.containsPointer(CGPoint(x: surface.midX, y: surface.minY - 1)))
        }
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
        XCTAssertEqual(UpdateChannel.feedURL.scheme, "https")
        XCTAssertFalse(UpdateChannel.feedURL.path.contains("latest"))
    }

    func testBetaUpdatesOptInAndPersist() {
        XCTAssertEqual(UpdateChannel.channels(beta: false), [])
        XCTAssertEqual(UpdateChannel.channels(beta: true), ["beta"])
        XCTAssertFalse(GeneralSettings().betaUpdates)
        var settings = GeneralSettings()
        settings.betaUpdates = true
        let decoded = try? JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded?.betaUpdates, true)
        XCTAssertEqual(try? JSONDecoder().decode(GeneralSettings.self, from: Data("{}".utf8)).betaUpdates, false)
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

final class GeneralSettingsTests: XCTestCase {
    func testDelaysClampAccentsValidateAndNamesFallBack() throws {
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: Data(##"{"hoverDelayMs":9000,"closeDelayMs":5,"accent":"#123456","pinned":true}"##.utf8))
        XCTAssertEqual(decoded.hoverDelayMs, 600)
        XCTAssertEqual(decoded.closeDelayMs, 100)
        XCTAssertNil(decoded.accent)
        XCTAssertTrue(decoded.pinned)
        var settings = GeneralSettings()
        settings.accent = "#4CD98C"
        settings.setCardVisible("note", false)
        let round = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round, settings)
        XCTAssertFalse(round.isCardVisible("note"))
        XCTAssertEqual(GeneralSettings.displayName(chosen: nil, fullUserName: "Ada Lovelace"), "Ada")
        XCTAssertEqual(GeneralSettings.displayName(chosen: "  ", fullUserName: ""), "QNotch")
        XCTAssertEqual(GeneralSettings.displayName(chosen: " Captain ", fullUserName: "Ada Lovelace"), "Captain")
    }
}

final class RegistryOwnershipTests: XCTestCase {
    func testRemovingAModuleKeepsOtherContributions() {
        let registries = ModuleRegistries()
        registries.owner = "timer"
        registries.cards.register(ViewContribution(id: "timer", title: "Timer", order: 26) { NSView() })
        registries.searchSources.register(SearchSource(id: "timer", order: 10) { _ in [] })
        registries.owner = "note"
        registries.cards.register(ViewContribution(id: "note", title: "Note", order: 45) { NSView() })
        registries.owner = nil
        registries.searchSources.register(SearchSource(id: "tabs", order: 80) { _ in [] })
        registries.removeAll(owner: "note")
        XCTAssertEqual(registries.cards.items.map(\.id), ["timer"])
        XCTAssertEqual(registries.searchSources.items.map(\.id), ["timer", "tabs"])
        XCTAssertEqual(registries.cards.ids(owner: "timer"), ["timer"])
    }
}

final class TimerChainingTests: XCTestCase {
    func testNextBlockIsLinedUpAfterFinishing() {
        XCTAssertEqual(Countdown.nextBlock(after: 25), 5)
        XCTAssertEqual(Countdown.nextBlock(after: 50), 5)
        XCTAssertEqual(Countdown.nextBlock(after: 5), 25)
        XCTAssertEqual(Countdown.nextBlock(after: 15), 15)
        var countdown = Countdown(duration: 60)
        countdown.lineUp(duration: 300)
        XCTAssertEqual(countdown.duration, 60, "Only a finished countdown lines up the next block")
        let start = Date(timeIntervalSince1970: 0)
        countdown.toggle(at: start)
        XCTAssertTrue(countdown.refresh(at: start.addingTimeInterval(61)))
        countdown.lineUp(duration: 300)
        XCTAssertTrue(countdown.finished)
        XCTAssertEqual(countdown.duration, 300)
        countdown.toggle(at: start.addingTimeInterval(70))
        XCTAssertFalse(countdown.finished)
        XCTAssertEqual(countdown.secondsLeft(at: start.addingTimeInterval(70)), 300)
    }
}

final class FileTrayListTests: XCTestCase {
    func testAddingDedupesCapsAndExportNamesNeverOverwrite() {
        var list = FileTrayList.adding(["/a", "/b"], to: [])
        XCTAssertEqual(list, ["/a", "/b"])
        list = FileTrayList.adding(["/c", "/a"], to: list)
        XCTAssertEqual(list, ["/c", "/a", "/b"])
        let many = FileTrayList.adding((0..<70).map { "/f\($0)" }, to: list)
        XCTAssertEqual(many.count, 60)
        XCTAssertEqual(many.first, "/f0")
        let taken: Set<String> = ["report.pdf", "report (2).pdf", "notes"]
        XCTAssertEqual(FileTrayList.uniqueName("report.pdf", taken: taken.contains), "report (3).pdf")
        XCTAssertEqual(FileTrayList.uniqueName("notes", taken: taken.contains), "notes (2)")
        XCTAssertEqual(FileTrayList.uniqueName("new.txt", taken: taken.contains), "new.txt")
        XCTAssertEqual(FileTrayList.countText(1, missing: 0), "1 file")
        XCTAssertEqual(FileTrayList.countText(4, missing: 2), "4 files · 2 missing")
    }
}

final class ClipHistoryTests: XCTestCase {
    func testClassificationMatchesWindows() {
        XCTAssertEqual(ClipText.classify("https://github.com/Somafet/qnotch"), .link)
        XCTAssertEqual(ClipText.classify("www.apple.com"), .link)
        XCTAssertEqual(ClipText.classify("see https://x.y now"), .text)
        XCTAssertEqual(ClipText.classify(#"{"a": 1}"#), .code)
        XCTAssertEqual(ClipText.classify("<div><b>x</b></div>"), .code)
        XCTAssertEqual(ClipText.classify("func greet() {\n    print(\"hi\")\n}"), .code)
        XCTAssertEqual(ClipText.classify("if (x == 1) {\n  return y;\n}"), .code)
        XCTAssertEqual(ClipText.classify("Remember to buy milk.\nAnd call mom."), .text)
        XCTAssertEqual(ClipText.entry("https://www.apple.com/mac")?.meta, "Link · www.apple.com")
        XCTAssertEqual(ClipText.entry("let a = 1;\nlet b = 2;\nreturn a + b;")?.meta, "Code · 3 lines")
        XCTAssertNil(ClipText.entry("   \n "))
        XCTAssertNil(ClipText.entry(String(repeating: "x", count: ClipText.maxTextLength + 1)))
        XCTAssertEqual(ClipText.age(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 7200)), "2h ago")
    }

    func testHistoryDedupesKeepsPinsOnTopAndCaps() throws {
        var history = ClipHistory()
        let t0 = Date(timeIntervalSince1970: 0)
        for index in 0..<45 { history.add(try XCTUnwrap(ClipText.entry("item \(index)", at: t0.addingTimeInterval(Double(index))))) }
        XCTAssertEqual(history.entries.count, 40)
        XCTAssertEqual(history.entries.first?.text, "item 44")
        let oldest = try XCTUnwrap(history.entries.last)
        history.togglePin(oldest.id)
        XCTAssertEqual(history.entries.first?.id, oldest.id)
        history.add(try XCTUnwrap(ClipText.entry("item 30", at: t0.addingTimeInterval(100))))
        XCTAssertEqual(history.entries[1].text, "item 30", "A repeat moves to the front of the unpinned entries")
        XCTAssertEqual(history.entries.count, 40)
        history.add(try XCTUnwrap(ClipText.entry("new", at: t0.addingTimeInterval(200))))
        XCTAssertTrue(history.entries.contains { $0.id == oldest.id }, "Pins are never evicted")
        history.clearUnpinned()
        XCTAssertEqual(history.entries.map(\.id), [oldest.id])
        let image = ClipEntry(kind: .image, text: nil, png: Data(count: 5 << 20), key: "a", preview: "", line: "Image", meta: "", created: t0)
        var images = ClipHistory()
        images.add(image)
        images.add(ClipEntry(kind: .image, text: nil, png: Data(count: 5 << 20), key: "b", preview: "", line: "Image", meta: "", created: t0))
        XCTAssertEqual(images.entries.map(\.key), ["b"], "Image bytes stay within 8 MB")
        XCTAssertTrue(images.persistable.isEmpty, "Images are never saved")
        XCTAssertEqual(history.search("ITEM").count, 1)
    }
}

final class NotifyTests: XCTestCase {
    private func post(_ json: String) throws -> NotifyPost {
        guard case .notify(let post) = try NotifyRules.parse(Data(json.utf8), makeID: { "generated" }) else { throw NotifyError("not a post") }
        return post
    }

    func testRequestsAreValidatedLikeWindows() throws {
        let p = try post(##"{"Title":"  Build done \u0007 ","body":"line1\r\nline2","LEVEL":"Success","ttl":"5","app":"CI","actions":[{"label":"Open","url":"https://example.com/x"}]}"##)
        XCTAssertEqual(p.title, "Build done")
        XCTAssertEqual(p.body, "line1\nline2")
        XCTAssertEqual(p.level, .success)
        XCTAssertEqual(p.ttl, 5)
        XCTAssertEqual(p.id, "generated")
        XCTAssertEqual(p.actions.first?.url, "https://example.com/x")
        XCTAssertEqual(try post(#"{"title":"x"}"#).app, "QNotch")
        XCTAssertEqual(try post(#"{"title":"\#(String(repeating: "a", count: 100))"}"#).title.count, 80)
        XCTAssertTrue(try post(#"{"title":"\#(String(repeating: "a", count: 100))"}"#).title.hasSuffix("…"))
        let waiting = try post(#"{"title":"Approve?","wait":true,"timeout":999999,"actions":[{"id":"yes","label":"Yes"},{"label":"No"}]}"#)
        XCTAssertEqual(waiting.timeout, 86_400)
        XCTAssertEqual(waiting.actions.map(\.id), ["yes", "No"])
        XCTAssertTrue(waiting.actions[0].answersOnly)
        func fails(_ json: String, _ message: String) {
            XCTAssertThrowsError(try NotifyRules.parse(Data(json.utf8))) { XCTAssertEqual(($0 as? NotifyError)?.message.hasPrefix(message), true, "\($0)") }
        }
        fails(#"{"body":"no title"}"#, "title is required")
        fails(#"{"title":"x","level":"loud"}"#, "level must be")
        fails(#"{"title":"x","actions":[{"label":"a","url":"javascript:alert(1)"}]}"#, "Action 'a': only")
        fails(#"{"title":"x","actions":[{"label":"a","url":"file:///etc/passwd"}]}"#, "Action 'a': only")
        fails(#"{"title":"x","actions":[{"label":"Yes"}]}"#, "Action 'Yes' needs a url")
        fails(#"{"title":"x","actions":[{"label":"1","url":"https://a"},{"label":"2","url":"https://a"},{"label":"3","url":"https://a"},{"label":"4","url":"https://a"}]}"#, "At most 3")
        fails(#"{"op":"rename"}"#, "Unknown op")
        fails("[1]", "The request is not a JSON object")
        XCTAssertEqual(try NotifyRules.parse(Data(#"{"op":"dismiss","id":"build"}"#.utf8)), .dismiss(id: "build"))
    }

    func testCommandLineMatchesWindowsArguments() throws {
        let data = try NotifyCLI.payload(["Deploy", "finished", "-l", "success", "--url", "https://x.y", "--focus", "--action", "ok=Looks good"], parentPid: 42)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Deploy")
        XCTAssertEqual(object["body"] as? String, "finished")
        XCTAssertEqual(object["wait"] as? Bool, true)
        let actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["label"] as? String }, ["Looks good", "Open", "Show"])
        XCTAssertEqual(actions[2]["focusPid"] as? Int, 42)
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertThrowsError(try NotifyCLI.payload(["--bogus"], parentPid: 1))
        XCTAssertThrowsError(try NotifyCLI.payload(["-b", "no title"], parentPid: 1))
        XCTAssertEqual(String(decoding: try NotifyCLI.payload(["--json", "{\"title\":\n\"x\"}"], parentPid: 1), as: UTF8.self), "{\"title\": \"x\"}\n")
        XCTAssertEqual(NotifyCLI.outcome(NotifyRules.reply(ok: "a", result: "clicked", action: "ok")).code, 0)
        XCTAssertEqual(NotifyCLI.outcome(NotifyRules.reply(ok: "a", result: "clicked", action: "ok")).stdout, "ok")
        XCTAssertEqual(NotifyCLI.outcome(NotifyRules.reply(ok: "a", result: "dismissed")).code, 1)
        XCTAssertEqual(NotifyCLI.outcome(NotifyRules.reply(ok: "a", result: "timeout")).code, 2)
        XCTAssertEqual(NotifyCLI.outcome(NotifyRules.reply(error: "nope")).code, 4)
    }

    func testLoopbackHTTPRules() throws {
        let good = "POST /notify?wait=1 HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nAuthorization: Bearer secret\r\nContent-Length: 20"
        let request = try LocalHTTP.parse(head: good, port: 47821, token: "secret")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/notify")
        XCTAssertEqual(request.query["wait"], "1")
        XCTAssertEqual(request.contentLength, 20)
        func status(_ head: String) -> Int? {
            do { _ = try LocalHTTP.parse(head: head, port: 47821, token: "secret"); return nil }
            catch LocalHTTP.Failure.status(let code, _) { return code } catch { return -1 }
        }
        XCTAssertEqual(status(good + "\r\nOrigin: https://evil.example"), 403)
        XCTAssertEqual(status(good.replacingOccurrences(of: "127.0.0.1:47821", with: "evil.example")), 403)
        XCTAssertEqual(status(good.replacingOccurrences(of: "secret", with: "secreT")), 401)
        XCTAssertEqual(status(good + "\r\nContent-Length: 5"), 400)
        XCTAssertEqual(status(good.replacingOccurrences(of: "20", with: "70000")), 413)
        XCTAssertEqual(status(good + "\r\nTransfer-Encoding: chunked"), 411)
        XCTAssertEqual(status("garbage"), 400)
        XCTAssertTrue(LocalHTTP.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(LocalHTTP.constantTimeEqual("abc", "abcd"))
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"httpPort":80,"toastSeconds":99}"#.utf8))
        XCTAssertEqual(settings.httpPort, 47821)
        XCTAssertEqual(settings.toastSeconds, 60)
    }
}

final class AgentsTests: XCTestCase {
    func testOrderedJSONKeepsOrderCommentsAndNumbers() throws {
        let text = """
        {
          // user comment
          "model": "opus",
          "cleanupPeriodDays": 30.0,
          "env": {"B": "2", "A": "1",},
          "list": [1, true, null, "x\\"y\\u00e9"]
        }
        """
        let value = try OrderedJSON.parse(text)
        XCTAssertEqual(value.objectPairs?.map(\.0), ["model", "cleanupPeriodDays", "env", "list"])
        XCTAssertEqual(value["env"]?.objectPairs?.map(\.0), ["B", "A"])
        XCTAssertTrue(value.text().contains("\"cleanupPeriodDays\": 30.0"))
        XCTAssertEqual(try OrderedJSON.parse(value.text()), value)
        XCTAssertEqual(value["list"]?.arrayValue?.last?.stringValue, "x\"yé")
        XCTAssertThrowsError(try OrderedJSON.parse("{\"a\": }"))
    }

    func testHookFilesConnectAndDisconnectOnlyTheirOwnEntries() throws {
        let file = AgentHookFile(kind: .claude, executable: "/Applications/QNotch.app/Contents/MacOS/QNotch")
        let user = #"{"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#
        XCTAssertEqual(file.status(of: user), .notInstalled)
        let connected = try file.connect(user)
        XCTAssertEqual(file.status(of: connected), .connected)
        let root = try OrderedJSON.parse(connected)
        XCTAssertEqual(root.objectPairs?.first?.0, "theme")
        XCTAssertEqual(root["hooks"]?["Stop"]?.arrayValue?.count, 2)
        XCTAssertEqual(root["hooks"]?["PreToolUse"]?.arrayValue?.first?["matcher"]?.stringValue, "*")
        XCTAssertEqual(try file.connect(connected), connected, "Connecting twice changes nothing")
        let other = AgentHookFile(kind: .claude, executable: "/Users/me/code/qnotch/dist/macos/QNotch.app/Contents/MacOS/QNotch")
        XCTAssertEqual(other.status(of: connected), .otherCopy("/Applications/QNotch.app/Contents/MacOS/QNotch"))
        let disconnected = try file.disconnect(connected)
        XCTAssertEqual(try OrderedJSON.parse(disconnected), try OrderedJSON.parse(user))
        let codex = AgentHookFile(kind: .codex, executable: "/Applications/QNotch.app/Contents/MacOS/QNotch")
        let codexText = try codex.connect(nil)
        XCTAssertEqual(codex.status(of: codexText), .connected)
        XCTAssertTrue(codexText.contains("\"timeout\": 3"))
        XCTAssertEqual(file.status(of: codexText), .notInstalled, "Claude and Codex hooks are told apart")
        if case .error = file.status(of: "[1]") {} else { XCTFail("A non-object file is an error") }
    }

    func testHookCommandIsShellQuoted() throws {
        // The hook runs through /bin/sh, where `$`, backticks and backslashes expand inside double quotes but not single ones.
        let odd = AgentHookFile(kind: .claude, executable: "/Users/me/My$Apps/Don't `Touch`/QNotch")
        XCTAssertEqual(odd.command, #"'/Users/me/My$Apps/Don'\''t `Touch`/QNotch' agent"#)
        XCTAssertTrue(odd.isOurs(odd.command))
        XCTAssertEqual(AgentHookFile.executable(in: odd.command), odd.executable)
        let codex = AgentHookFile(kind: .codex, executable: "/Applications/QNotch.app/Contents/MacOS/QNotch")
        XCTAssertEqual(codex.command, "'/Applications/QNotch.app/Contents/MacOS/QNotch' agent codex")
        XCTAssertTrue(codex.isOurs(codex.command))
        XCTAssertFalse(AgentHookFile(kind: .claude, executable: "/x/QNotch").isOurs(codex.command))
        // Hooks written by earlier builds used JSON-style double quotes; Disconnect still has to find them.
        let legacy = "\"/Applications/QNotch.app/Contents/MacOS/QNotch\" agent"
        XCTAssertTrue(AgentHookFile(kind: .claude, executable: "/x/QNotch").isOurs(legacy))
        XCTAssertFalse(AgentHookFile(kind: .claude, executable: "/x/QNotch").isOurs("say done"))
        XCTAssertFalse(AgentHookFile(kind: .claude, executable: "/x/QNotch").isOurs("/x/qnotch agent"), "An unquoted path is not one we wrote")
    }

    func testHookInputIsTranslatedAndLinksValidated() throws {
        let ask = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/code/api","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?"}]},"transcript_path":"/t.jsonl"}"#
        let event = try XCTUnwrap(AgentEvent.from(hookInput: Data(ask.utf8), codex: false, pid: 7, link: nil, at: 1))
        XCTAssertEqual(event.message, "Which database?")
        XCTAssertEqual(event.transcript, "/t.jsonl")
        let codex = try XCTUnwrap(AgentEvent.from(hookInput: Data(#"{"hook_event_name":"PermissionRequest","session_id":"c","tool_name":"shell"}"#.utf8), codex: true, pid: nil, link: nil, at: 1))
        XCTAssertEqual(codex.event, "Notification")
        XCTAssertEqual(codex.type, "permission_prompt")
        XCTAssertNil(codex.transcript)
        XCTAssertTrue(AgentEvent.isValidLink("claude://code/continue?session=local_abc-123"))
        XCTAssertTrue(AgentEvent.isValidLink("codex://threads/6F9619FF-8B86-D011-B42D-00CF4FC964FF"))
        XCTAssertFalse(AgentEvent.isValidLink("claude://code/continue?session=local_a;rm"))
        XCTAssertFalse(AgentEvent.isValidLink("https://evil.example"))
    }

    func testStatusMachineMatchesWindows() throws {
        var board = AgentBoard()
        func event(_ name: String, _ at: Double, tool: String? = nil, type: String? = nil, message: String? = nil, session: String = "s") -> AgentEvent {
            AgentEvent(agent: "claude", event: name, session: session, cwd: "/code/api", message: message, type: type, tool: tool, pid: 42, at: at)
        }
        XCTAssertNil(board.apply(event("SessionStart", 1)))
        XCTAssertEqual(board.sessions.first?.status, .ready)
        board.apply(event("UserPromptSubmit", 2))
        XCTAssertEqual(board.pillText, "1 working")
        let alert = board.apply(event("Notification", 3, type: "permission_prompt", message: "Claude needs your permission to use Bash"))
        guard case .needsYou(let s)? = alert else { return XCTFail("needs you") }
        XCTAssertEqual(s.waitingTool, "Bash")
        XCTAssertEqual(board.pillText, "api needs you")
        board.apply(event("PostToolUse", 4, tool: "Read"))
        XCTAssertEqual(board.sessions.first?.status, .needsYou, "Another tool's event does not clear the wait")
        board.apply(event("PostToolUse", 5, tool: "Bash"))
        XCTAssertEqual(board.sessions.first?.status, .working)
        XCTAssertNil(board.apply(event("Stop", 3)), "Out-of-order events are ignored")
        guard case .done? = board.apply(event("Stop", 6)) else { return XCTFail("done") }
        board.apply(event("UserPromptSubmit", 7))
        XCTAssertNil(board.apply(event("Notification", 8, type: "idle_prompt")), "An interrupt is not announced")
        XCTAssertEqual(board.sessions.first?.status, .done)
        board.apply(event("SessionEnd", 9))
        XCTAssertTrue(board.sessions.isEmpty)
        board.apply(event("Stop", 10))
        XCTAssertTrue(board.sessions.isEmpty, "A late Stop after SessionEnd does not bring the row back")
        board.apply(event("SessionStart", 11, session: "t"))
        XCTAssertTrue(board.processEnded(42))
        XCTAssertNil(board.pillText)
    }
}

final class AgentUsageTests: XCTestCase {
    func testTranscriptUsageCountsRepliesOnceAndReadsIncrementally() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("s/subagents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appendingPathComponent("s.jsonl")
        let now = ISO8601DateFormatter().string(from: Date())
        func reply(_ id: String, output: Int, model: String = "claude-sonnet-4-5") -> String {
            #"{"type":"assistant","timestamp":"\#(now)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":\#(output)}}}"#
        }
        try Data((reply("m1", output: 10) + "\n" + reply("m1", output: 500) + "\n" + #"{"type":"ai-title","aiTitle":"Fix login"}"# + "\n").utf8).write(to: transcript)
        let usage = TranscriptUsage()
        usage.read(transcript)
        XCTAssertEqual(usage.today.tokens, 1500, "The last line of a reply replaces the earlier ones")
        let expected: Double = (1000.0 * 3 + 500.0 * 15) / 1_000_000
        XCTAssertEqual(usage.today.cost, expected, accuracy: 1e-9)
        XCTAssertEqual(usage.title, "Fix login")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((reply("m2", output: 0, model: "mystery-model") + "\n" + #"{"type":"custom-title","customTitle":"Renamed"}"# + "\n{\"partial").utf8))
        try handle.close()
        try Data((reply("sub", output: 100) + "\n").utf8).write(to: folder.appendingPathComponent("s/subagents/a.jsonl"))
        usage.read(transcript)
        XCTAssertEqual(usage.today.tokens, 1500 + 1000 + 1100)
        XCTAssertTrue(usage.today.unpriced)
        XCTAssertEqual(usage.title, "Renamed")
        XCTAssertEqual(AgentUsage(tokens: 1_940_000, cost: 2.14).text, "1.9M tokens · $2.14")
        XCTAssertEqual(AgentUsage(tokens: 12_000, cost: 0, unpriced: true).text, "12K tokens · price unknown")
        XCTAssertEqual(AgentUsage.tokens(25_000_000), "25M")
        XCTAssertNil(AgentPrices.cost(model: "gpt-5", input: 1, write5m: 0, write1h: 0, read: 0, output: 0, fast: false))
        XCTAssertEqual(AgentPrices.cost(model: "claude-opus-4-1", input: 1_000_000, write5m: 0, write1h: 0, read: 0, output: 0, fast: true), 30)
    }

    func testCodexTitlesAndT3Merge() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let index = "{\"id\":\"a\",\"thread_name\":\"First\"}\n{\"id\":\"a\",\"thread_name\":\"Renamed\"}\n"
        try Data(index.utf8).write(to: file)
        XCTAssertEqual(CodexTitles().read(file), ["a": "Renamed"])
        let env = "6F9619FF-8B86-D011-B42D-00CF4FC964FF", thread = "7F9619FF-8B86-D011-B42D-00CF4FC964FF"
        let running = try XCTUnwrap(T3Session.from(row: [thread, "native-1", "run-1", "claudeAgent", " Pull latest ", "/code/q", "running", "2026-10-16T10:00:00.000Z", ""], environment: env))
        XCTAssertEqual(running.agent, "claude")
        XCTAssertEqual(running.status, .working)
        XCTAssertEqual(running.title, "Pull latest")
        XCTAssertEqual(running.link, "t3code://threads/\(env)/\(thread)")
        XCTAssertNil(T3Session.threadLink(environment: "x", thread: thread))
        var board = AgentBoard()
        board.apply(AgentEvent(agent: "claude", event: "UserPromptSubmit", session: "native-1", cwd: "/code/q", pid: 9, at: 1))
        XCTAssertTrue(board.applyT3([running]).isEmpty)
        XCTAssertEqual(board.sessions.count, 1, "The hook row and the T3 row are one session")
        XCTAssertEqual(board.sessions.first?.title, "Pull latest")
        XCTAssertNil(board.apply(AgentEvent(agent: "claude", event: "Stop", session: "native-1", cwd: "", at: 2)))
        XCTAssertEqual(board.sessions.first?.status, .working, "T3 owns the status")
        var asking = running
        asking.status = .needsYou
        guard case .needsYou? = board.applyT3([asking]).first else { return XCTFail("needs you") }
        var finished = running
        finished.status = .done
        _ = board.applyT3([running])
        guard case .done? = board.applyT3([finished]).first else { return XCTFail("done") }
        board.remove("native-1")
        XCTAssertTrue(board.applyT3([finished]).isEmpty)
        XCTAssertTrue(board.sessions.isEmpty, "A dismissed or finished T3 run is not imported")
        XCTAssertTrue(board.applyT3([]).isEmpty)
    }
}

final class WeatherTests: XCTestCase {
    func testForecastParsesAndFormatsLikeWindows() throws {
        let place = WeatherPlace(id: "1-72837", name: "Oslo", detail: "Norway", lat: 59.91333, lon: 10.73889, elevation: 23, timeZone: "Europe/Oslo", urlPath: "Norway/Oslo/Oslo/Oslo")
        XCTAssertEqual(place.forecastURL?.absoluteString, "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=59.9133&lon=10.7389&altitude=23")
        XCTAssertEqual(place.yrURL?.absoluteString, "https://www.yr.no/en/forecast/daily-table/1-72837/Norway/Oslo/Oslo/Oslo")
        let json = """
        {"properties":{"timeseries":[
         {"time":"2026-10-16T10:00:00Z","data":{"instant":{"details":{"air_temperature":11.6,"apparent_air_temperature":9.4,"wind_speed":4.2}},
          "next_1_hours":{"summary":{"symbol_code":"lightrainshowers_day"},"details":{"precipitation_amount":0.4}},
          "next_6_hours":{"summary":{"symbol_code":"rain"},"details":{"air_temperature_max":13.1,"air_temperature_min":8.0}}}},
         {"time":"2026-10-17T10:00:00Z","data":{"instant":{"details":{"air_temperature":7.0}},
          "next_6_hours":{"summary":{"symbol_code":"clearsky_day"},"details":{"air_temperature_max":9.0,"air_temperature_min":2.4}}}}
        ]}}
        """
        let now = ISO8601DateFormatter().date(from: "2026-10-16T10:30:00Z")!
        let forecast = try WeatherForecast.parse(Data(json.utf8), lat: place.lat, lon: place.lon, fetched: now, expires: now, lastModified: "")
        XCTAssertEqual(forecast.points.count, 2)
        let view = try XCTUnwrap(WeatherFormat.build(forecast, place: place, units: .metric, now: now))
        XCTAssertEqual(view.temp, "12°")
        XCTAssertEqual(view.condition, "Light rain showers")
        XCTAssertEqual(view.detail, "Feels 9° · 4 m/s · 0.4 mm")
        XCTAssertEqual(view.days.map(\.name).first, "Today")
        XCTAssertEqual(view.days.first?.high, "13°")
        XCTAssertEqual(view.days.count, 2)
        XCTAssertEqual(view.days[1].symbol, "clearsky_day")
        XCTAssertEqual(WeatherFormat.build(forecast, place: place, units: .imperial, now: now)?.temp, "53°")
        XCTAssertNil(WeatherFormat.build(forecast, place: place, units: .metric, now: now.addingTimeInterval(3 * 86400)))
        XCTAssertEqual(WeatherFormat.condition("heavysnowshowersandthunder_night"), "Heavy snow showers and thunder")
        XCTAssertEqual(WeatherFormat.condition("rain"), "Rain")
        XCTAssertEqual(WeatherFormat.sfSymbol("partlycloudy_night"), "cloud.moon.fill")
        XCTAssertEqual(WeatherFormat.sfSymbol("heavyrainandthunder"), "cloud.bolt.rain.fill")
        XCTAssertEqual(WeatherFormat.nextRefresh(expires: now.addingTimeInterval(60), now: now), 600)
        XCTAssertEqual(WeatherFormat.nextRefresh(expires: now.addingTimeInterval(9000), now: now), 7200)
        XCTAssertThrowsError(try WeatherForecast.parse(Data(#"{"properties":{"timeseries":[]}}"#.utf8), lat: 0, lon: 0, fetched: now, expires: now, lastModified: ""))
        let search = #"{"_embedded":{"location":[{"id":"2-3054643","name":"Budapest","position":{"lat":47.49801,"lon":19.03991},"elevation":109.6,"timeZone":"Europe/Budapest","urlPath":"Hungary/Budapest/Budapest","region":{"name":"Budapest"},"country":{"name":"Hungary"}}]}}"#
        let places = try WeatherPlace.parseSearch(Data(search.utf8))
        XCTAssertEqual(places.first?.detail, "Hungary")
        XCTAssertEqual(places.first?.elevation, 110)
    }
}

final class GithubTests: XCTestCase {
    func testCalendarParsingStreakAndErrors() throws {
        let response = #"{"data":{"viewer":{"login":"ada","contributionsCollection":{"contributionCalendar":{"totalContributions":7,"weeks":[{"contributionDays":[{"date":"2026-10-14","contributionCount":0,"contributionLevel":"NONE"},{"date":"2026-10-15","contributionCount":3,"contributionLevel":"SECOND_QUARTILE"}]},{"contributionDays":[{"date":"2026-10-16","contributionCount":0,"contributionLevel":"NONE"}]}]}}}}}"#
        let payload = try GithubData.payload(status: 200, body: Data(response.utf8), transportFailed: false)
        let data = try GithubData.parse(payload, fetched: Date())
        XCTAssertEqual(data.login, "ada")
        XCTAssertEqual(data.total, 7)
        XCTAssertEqual(data.days.map(\.level), [0, 2, 0])
        XCTAssertEqual(data.streak, 1, "An empty today does not break the streak")
        XCTAssertTrue(data.sameGraph(data))
        XCTAssertThrowsError(try GithubData.payload(status: 401, body: nil, transportFailed: false)) { XCTAssertEqual(($0 as? GithubError)?.text, "GitHub rejected the token. Check it in Settings.") }
        XCTAssertThrowsError(try GithubData.payload(status: nil, body: nil, transportFailed: true)) { XCTAssertEqual(($0 as? GithubError)?.offline, true) }
        XCTAssertThrowsError(try GithubData.payload(status: 200, body: Data(#"{"errors":[{"message":"Bad credentials"}]}"#.utf8), transportFailed: false)) {
            XCTAssertEqual(($0 as? GithubError)?.text, "Bad credentials")
        }
        let demo = GithubData.demo()
        XCTAssertGreaterThanOrEqual(demo.days.count, 365)
        XCTAssertEqual(demo, GithubData.demo(now: demo.fetched))
    }
}

final class AiUsageTests: XCTestCase {
    func testClaudeAndCodexReadingsLikeWindows() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"qnotch-usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":42.4,"resets_at":"2026-10-16T14:05:00Z"},"seven_day":{"utilization":120,"resets_at":null},"seven_day_opus":null,"cedar_ember":{"eligible":true,"next_grant_id":"g1","grants":[{"id":"g1","resets_left":2,"ends_at":"2026-10-20T12:00:00Z","label":"Bonus"},{"id":"g2","resets_left":5,"paused":true}]}}}}}"#
        XCTAssertNil(ClaudeUsage.answer(line: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"qnotch-init","response":{}}}"#.utf8)))
        XCTAssertNil(ClaudeUsage.answer(line: Data(#"{"type":"system","subtype":"init"}"#.utf8)))
        guard case .usage(let usage)? = ClaudeUsage.answer(line: Data(line.utf8)),
              case let .ok(windows, plan, _, banked) = ClaudeUsage.parse(usage: usage, tier: "default_claude_max_20x", now: now) else { return XCTFail() }
        XCTAssertEqual(windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(windows[0].usedText, "42%")
        XCTAssertEqual(windows[1].usedPercent, 100)
        XCTAssertEqual(windows[0].resetText(now: now), "Resets in 2h 5m")
        XCTAssertEqual(plan, "Max 20x")
        XCTAssertEqual(banked?.count, 2)
        XCTAssertEqual(banked?.text(now: now), "2 banked resets  ·  expires in 4d 0h")
        guard case .failed(let message)? = ClaudeUsage.answer(line: Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"qnotch-usage","error":"Not logged in"}}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(message, "Claude Code could not read usage (Not logged in).")
        XCTAssertEqual(ClaudeUsage.parse(usage: ["rate_limits_available": false], tier: nil), .unavailable("Signed in without a subscription. Usage needs a Claude Pro or Max login."))
        XCTAssertTrue(ClaudeUsage.login(Data(#"{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_5x"}}"#.utf8)) == (true, "default_claude_max_5x"))
        XCTAssertFalse(ClaudeUsage.login(Data("{}".utf8)).signedIn)
        XCTAssertEqual(ClaudeUsage.keychainService(configDir: "/x", isDefault: false, sha256Hex: { _ in "95d6dcc1ffff" }), "Claude Code-credentials-95d6dcc1")
        XCTAssertEqual(ClaudeUsage.keychainService(configDir: "/x", isDefault: true, sha256Hex: { _ in "" }), "Claude Code-credentials")
        XCTAssertEqual(ClaudeUsage.accessToken(Data(#"{"claudeAiOauth":{"accessToken":" t "}}"#.utf8)), "t")
        XCTAssertNil(ClaudeUsage.accessToken(Data("{}".utf8)))
        let bankedBody = #"{"cedar_ember":{"eligible":true,"next_grant_id":"g1","grants":[{"id":"g1","resets_left":1,"ends_at":"2026-10-20T12:00:00Z"}]}}"#
        let extra = ClaudeUsage.banked(body: Data(bankedBody.utf8), now: now)
        XCTAssertEqual(extra?.count, 1)
        guard case .ok(_, _, _, let added) = ClaudeUsage.adding(extra, to: .ok(windows: windows, plan: plan, asOf: now, banked: nil)) else { return XCTFail() }
        XCTAssertEqual(added?.count, 1)
        XCTAssertEqual(ClaudeUsage.adding(extra, to: .unavailable("x")), .unavailable("x"))
        let home = "/Users/me"
        XCTAssertEqual(ClaudeUsage.accountFile(for: ClaudeAccount(path: home + "/.claude", folderName: "Default", isDefault: true), home: home), home + "/.claude.json")
        XCTAssertEqual(ClaudeUsage.accountFile(for: ClaudeAccount(path: home + "/.claude-work", folderName: "work", isDefault: false), home: home), home + "/.claude-work/.claude.json")
        let tail = """
        {"timestamp":"2026-10-16T11:00:00Z","payload":{"rate_limits":{"plan_type":"prolite","primary":{"used_percent":12,"window_minutes":300,"resets_in_seconds":7200},"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1000}}}}
        """
        guard case let .ok(codex, codexPlan, _, _)? = CodexUsage.reading(fromTail: "noise\n" + tail, now: now) else { return XCTFail() }
        XCTAssertEqual(codex.map(\.label), ["5-hour"], "A window that already reset is dropped")
        XCTAssertEqual(codexPlan, "Pro Lite")
        XCTAssertEqual(CodexUsage.label(minutes: 2880), "2-day")
        XCTAssertEqual(CodexUsage.credits(["availableCount": 3, "credits": [["status": "available", "expiresAt": 2000.0, "title": "A"]]])?.count, 3)
        var settings = AiSettings()
        settings.autoPlace(["claude", "chatgpt"])
        settings.slots[0] = nil
        settings.autoPlace(["claude", "cursor"])
        XCTAssertEqual(settings.slots.prefix(3).map { $0 }, ["cursor", "chatgpt", nil], "A removed app is not placed again")
    }

    func testClaudeAccountsAreDiscoveredNamedAndChosen() throws {
        let entries = [".zshrc", ".claude-work", ".claude", ".claude-old", ".claude.json", ".claude-gmail"]
        let found = ClaudeAccount.discover(home: "/Users/a", configDir: nil, entries: entries) { path, _ in path != "/Users/a/.claude-old" }
        XCTAssertEqual(found.map(\.path), ["/Users/a/.claude", "/Users/a/.claude-gmail", "/Users/a/.claude-work"], "Default first, then signed-in folders by name")
        XCTAssertEqual(found.map(\.folderName), ["Default", "gmail", "work"])
        XCTAssertEqual(found.map(\.isDefault), [true, false, false])
        let custom = ClaudeAccount.discover(home: "/Users/a", configDir: "/Users/a/.claude-work/", entries: entries) { _, _ in true }
        XCTAssertEqual(custom.first?.path, "/Users/a/.claude-work", "CLAUDE_CONFIG_DIR comes first and is not listed twice")
        XCTAssertEqual(custom.filter { $0.path == "/Users/a/.claude-work" }.count, 1)
        XCTAssertTrue(custom.contains { $0.path == "/Users/a/.claude" && $0.isDefault })

        var settings = AiSettings()
        XCTAssertEqual(settings.shown(in: found), found[0])
        settings.claudeAccount = found[2].path
        XCTAssertEqual(settings.shown(in: found), found[2])
        settings.claudeAccount = "/gone"
        XCTAssertEqual(settings.shown(in: found), found[0], "A folder that is gone falls back to the first account")
        settings.rename(found[1], to: "  Personal ")
        XCTAssertEqual(settings.name(of: found[1]), "Personal")
        settings.rename(found[1], to: " ")
        XCTAssertEqual(settings.name(of: found[1]), "gmail", "An empty name goes back to the folder's")
        XCTAssertTrue(settings.accountNames.isEmpty)
        settings.rename(found[2], to: "Work")
        let saved = try JSONDecoder().decode(AiSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.accountNames, [found[2].path: "Work"])
        XCTAssertEqual(try JSONDecoder().decode(AiSettings.self, from: Data("{}".utf8)).accountNames, [:])
    }

    func testUsageSummaryNeverShowsANumberWhenUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ok = UsageResult.ok(windows: [UsageWindow(label: "5-hour", usedPercent: 38.4, resetsAt: now.addingTimeInterval(7500)),
                                          UsageWindow(label: "Weekly", usedPercent: 61, resetsAt: nil)], plan: "Max", asOf: now, banked: nil)
        let summary = AiFormat.summary(ok, now: now)
        XCTAssertEqual(summary.headline, "38%")
        XCTAssertEqual(summary.percent, 38.4)
        XCTAssertEqual(summary.sub, "Weekly 61%  ·  resets in 2h 5m")
        let single = AiFormat.summary(.ok(windows: [UsageWindow(label: "Weekly", usedPercent: 5, resetsAt: nil)], plan: nil, asOf: now, banked: nil), now: now)
        XCTAssertEqual(single.sub, "Weekly", "Without a reset time the window's name stands in")
        let down = AiFormat.summary(.unavailable("Not signed in."), now: now)
        XCTAssertEqual(down.headline, "Unavailable")
        XCTAssertNil(down.percent)
        XCTAssertEqual(down.sub, "Not signed in.")
        XCTAssertEqual(AiFormat.summary(nil, now: now).headline, "Checking")
    }
}

final class LayoutOrderTests: XCTestCase {
    func testSavedOrderWinsAndGoneItemsKeepTheirSlot() {
        XCTAssertEqual(LayoutOrder.apply(saved: [], defaults: ["a", "b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(LayoutOrder.apply(saved: ["c", "gone", "a"], defaults: ["a", "b", "c"]), ["c", "a", "b"])
        let moved = LayoutOrder.move("b", to: "c", saved: ["c", "gone", "a"], defaults: ["a", "b", "c"])
        XCTAssertEqual(moved, ["b", "c", "gone", "a"])
        XCTAssertEqual(LayoutOrder.apply(saved: moved, defaults: ["a", "b", "c", "gone"]), ["b", "c", "gone", "a"])
        XCTAssertEqual(LayoutOrder.move("a", to: "a", saved: ["a"], defaults: ["a"]), ["a"])
        XCTAssertEqual(LayoutOrder.reorder(["b", "a"], saved: ["a", "gone", "b"]), ["b", "gone", "a"])
        XCTAssertEqual(LayoutOrder.reorder(["c", "a", "b"], saved: ["a", "b"]), ["c", "a", "b"])
    }
}

final class GameModeTests: XCTestCase {
    func testFullScreenWindowsListsAndOverride() {
        let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
        var settings = GameModeSettings()
        XCTAssertTrue(GameClassifier.isGame(bundleID: "com.valve.game", isSelf: false, windows: [display], display: display, settings: settings, category: "public.app-category.action-games"))
        XCTAssertFalse(GameClassifier.isGame(bundleID: "com.apple.dt.Xcode", isSelf: false, windows: [display], display: display, settings: settings, category: "public.app-category.developer-tools"))
        settings.anyFullScreen = true
        XCTAssertTrue(GameClassifier.isGame(bundleID: "com.apple.dt.Xcode", isSelf: false, windows: [display], display: display, settings: settings))
        XCTAssertFalse(GameClassifier.isGame(bundleID: "com.apple.Safari", isSelf: false, windows: [CGRect(x: 0, y: 37, width: 1470, height: 919)], display: display, settings: settings))
        XCTAssertFalse(GameClassifier.isGame(bundleID: "dev.qnotch.mac", isSelf: true, windows: [display], display: display, settings: settings))
        XCTAssertFalse(GameClassifier.isGame(bundleID: "com.apple.finder", isSelf: false, windows: [display], display: display, settings: settings))
        settings.always = ["com.apple.Safari"]
        XCTAssertTrue(GameClassifier.isGame(bundleID: "com.apple.Safari", isSelf: false, windows: [], display: display, settings: settings))
        settings.never = ["com.apple.Safari", "com.valve.game"]
        XCTAssertFalse(GameClassifier.isGame(bundleID: "com.apple.Safari", isSelf: false, windows: [], display: display, settings: settings))
        XCTAssertFalse(GameClassifier.isGame(bundleID: "com.valve.game", isSelf: false, windows: [display], display: display, settings: settings))
        settings.never = []
        settings.autoDetect = false
        XCTAssertFalse(GameClassifier.isGame(bundleID: "com.valve.game", isSelf: false, windows: [display], display: display, settings: settings))
        XCTAssertTrue(GameClassifier.active(override: .on, detected: false))
        XCTAssertFalse(GameClassifier.active(override: .off, detected: true))
        XCTAssertEqual(GameClassifier.next(.off), .auto)
        let decoded = try? JSONDecoder().decode(GameModeSettings.self, from: Data(#"{"opacity":5}"#.utf8))
        XCTAssertEqual(decoded?.opacity, 30)
    }
}

final class LaunchAgentTests: XCTestCase {
    func testPlistsSchedulesAndLaunchctlOutput() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-16T08:00:00Z")!
        let backup = try XCTUnwrap(LaunchAgentJob.parse(["Label": "me.backup", "ProgramArguments": ["/bin/bash", "/Users/me/bin/backup.sh"],
                                                         "StartCalendarInterval": ["Hour": 9, "Minute": 30]], path: "/x", now: now, calendar: calendar))
        XCTAssertEqual(backup.schedule, "Daily at 09:30")
        XCTAssertEqual(backup.next, ISO8601DateFormatter().date(from: "2026-10-16T09:30:00Z"))
        XCTAssertFalse(backup.fromApp)
        XCTAssertEqual(LaunchAgentJob.parse(["Label": "a", "Program": "/x", "StartInterval": 600], path: "")?.schedule, "Every 10 min")
        XCTAssertEqual(LaunchAgentJob.parse(["Label": "a", "Program": "/x", "StartCalendarInterval": ["Weekday": 1, "Hour": 8]], path: "")?.schedule, "Mondays at 08:00")
        XCTAssertEqual(LaunchAgentJob.parse(["Label": "a", "Program": "/x", "KeepAlive": true], path: "")?.schedule, "Always running")
        XCTAssertEqual(LaunchAgentJob.parse(["Label": "a", "Program": "/x", "RunAtLoad": true], path: "")?.schedule, "At login")
        XCTAssertTrue(try XCTUnwrap(LaunchAgentJob.parse(["Label": "com.google.keystone.agent", "ProgramArguments": ["/Users/me/Library/Application Support/Google/x.app/Contents/MacOS/agent"]], path: "")).fromApp)
        XCTAssertNil(LaunchAgentJob.parse(["Program": "/x"], path: ""))
        let list = LaunchAgentJob.parseList("PID\tStatus\tLabel\n-\t0\tme.backup\n412\t0\thomebrew.mxcl.redis\n-\t78\tme.broken\n")
        XCTAssertEqual(list["homebrew.mxcl.redis"]?.pid, 412)
        XCTAssertEqual(list["me.broken"]?.status, 78)
        XCTAssertNil(list["me.backup"]?.pid ?? nil)
        XCTAssertEqual(LaunchAgentJob.parseDisabled("\tdisabled services = {\n\t\t\"me.backup\" => disabled\n\t\t\"x\" => enabled\n\t}"), ["me.backup"])
    }
}

final class NowPlayingTests: XCTestCase {
    func testNotificationsAndInterpolation() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let spotify = try XCTUnwrap(NowPlaying.from(notification: ["Name": "Hey Jude", "Artist": "The Beatles", "Album": "1", "Player State": "Playing",
                                                                   "Duration": 431_000, "Playback Position": 12.5, "Track ID": "spotify:track:1"], source: .spotify, now: now))
        XCTAssertEqual(spotify.duration, 431)
        XCTAssertEqual(spotify.position(at: now.addingTimeInterval(10)), 22.5)
        XCTAssertEqual(spotify.position(at: now.addingTimeInterval(1000)), 431)
        XCTAssertEqual(spotify.trackID, "spotify:track:1")
        let music = try XCTUnwrap(NowPlaying.from(notification: ["Name": "Song", "Player State": "Paused", "Total Time": 200_000, "PersistentID": 42], source: .music, now: now))
        XCTAssertFalse(music.playing)
        XCTAssertEqual(music.subtitle, "Music")
        XCTAssertNil(music.position(at: now))
        XCTAssertEqual(music.trackID, "42")
        XCTAssertNil(NowPlaying.from(notification: ["Name": "x", "Player State": "Stopped"], source: .music))
        XCTAssertEqual(NowPlaying.time(83), "1:23")
        XCTAssertEqual(NowPlaying.time(3725), "1:02:05")
    }
}

final class ProcessTrackerTests: XCTestCase {
    func testGroupsWhatShellsStartedAndRemembersOrphans() {
        let tracker = ProcessTracker()
        let second: UInt64 = 1_000_000
        func entry(_ pid: Int32, _ parent: Int32, _ exe: String, _ t: UInt64) -> ProcessTracker.Entry { .init(pid: pid, parent: parent, exe: exe, created: t * second) }
        var snapshot: [Int32: ProcessTracker.Entry] = [
            10: entry(10, 1, "claude", 1), 11: entry(11, 10, "node", 2),          // an MCP server: not tracked
            20: entry(20, 10, "zsh", 3), 21: entry(21, 20, "node", 4), 22: entry(22, 21, "esbuild", 5)
        ]
        let sessions = [(id: "s", project: "web", pid: Int32(10))]
        var groups = tracker.walk(snapshot, sessions: sessions, now: 20 * second) { $0 == 21 ? "npm run dev" : "" }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].root, 21)
        XCTAssertEqual(groups[0].label, "npm run dev")
        XCTAssertEqual(groups[0].members.map(\.pid), [21, 22])
        XCTAssertFalse(groups[0].leftRunning)
        // The shell exits and macOS reparents the server to launchd.
        snapshot[20] = nil
        snapshot[21]?.parent = 1
        groups = tracker.walk(snapshot, sessions: sessions, now: 30 * second) { _ in "" }
        XCTAssertEqual(groups.first?.leftRunning, true)
        XCTAssertEqual(groups.first?.session, "")
        // A process too young is not shown yet; a reused pid is not ours.
        snapshot[30] = entry(30, 10, "bash", 29)
        snapshot[31] = entry(31, 30, "python3", 29)
        XCTAssertEqual(tracker.walk(snapshot, sessions: sessions, now: 30 * second) { _ in "" }.count, 1)
        snapshot[21] = entry(21, 1, "node", 40)
        snapshot[22] = nil
        XCTAssertFalse(tracker.walk(snapshot, sessions: sessions, now: 45 * second) { _ in "" }.contains { $0.root == 21 })
        XCTAssertEqual(ProcessTracker.label(["/usr/local/bin/node", "/x/vite.js", "--port", "3000"]), "node vite.js --port 3000")
    }
}

final class SetupCodeTests: XCTestCase {
    private var base: SetupCode.Snapshot {
        SetupCode.Snapshot(general: GeneralSettings(), gameMode: GameModeSettings(), timer: TimerSettings(), weather: WeatherSettings(),
                           notifications: NotificationSettings(), ai: AiSettings(), agents: AgentsSettings())
    }

    func testRoundTripAndWindowsCodes() throws {
        var mine = base
        mine.general.hoverDelayMs = 300
        mine.general.setEnabled("clipboard", false)
        mine.general.setCardVisible("note", false)
        mine.timer.minutes = 45
        mine.weather.units = .imperial
        mine.gameMode.opacity = 55
        mine.gameMode.anyFullScreen = true
        mine.agents.showCost = false
        let code = SetupCode.export(mine)
        XCTAssertTrue(code.hasPrefix(SetupCode.prefix))
        XCTAssertFalse(code.contains("="))
        let plan = try SetupCode.read(code, current: base, modules: ["clipboard", "timer"])
        XCTAssertEqual(plan.result, mine)
        XCTAssertFalse(plan.result.agents.showCost, "The Mac-only cost switch travels in the mac section")
        XCTAssertTrue(try JSONDecoder().decode(AgentsSettings.self, from: Data("{}".utf8)).showCost, "API cost shows by default, as on Windows")
        XCTAssertTrue(plan.turnsOn.isEmpty)
        XCTAssertTrue(plan.titles.contains("Timer"))
        // A code from QNotch for Windows: shared fields apply, Windows-only ones (Theme, Height, hotkeys) are ignored.
        let windows = "qnotch-setup-1:NY9NS8QwEIb_y-txgxQ_QHNb0sMuUhT8uIiHbDsmYadNSUbLsvS_m4ieHnjnmXmZMxxNlCxDn7GL35TahZi7DH3VNAovnkaCRmvTEQrbvqdJTOSYSnhxY9r7O1PyNmR7YBq6OHwxleV3GA7zIdo04EPBFL6FHIpTi6YohZ-WM62rgo9ypFOuk4c_SnSuujCSeLNl2XSo6kJWPKWqvE5Biov9OFMK5QOFZx-X_fQUmP-vKzg70hiH397H2fZBTtDN5a3CjoLzAn3drOsP"
        var current = base
        current.general.setEnabled("weather", false)
        let fromWindows = try SetupCode.read(windows, current: current, modules: ["weather", "clipboard"])
        XCTAssertEqual(fromWindows.result.general.hoverDelayMs, 200)
        XCTAssertEqual(fromWindows.result.general.accent, "#4CD98C")
        XCTAssertEqual(fromWindows.result.general.disabledModules, ["clipboard"])
        XCTAssertEqual(fromWindows.result.general.hiddenCards, ["note"])
        XCTAssertEqual(fromWindows.result.weather.units, .imperial)
        XCTAssertFalse(fromWindows.result.weather.showInPill)
        XCTAssertEqual(fromWindows.result.gameMode.opacity, 50)
        XCTAssertEqual(fromWindows.turnsOn, ["weather"])
        for (bad, message) in [("hello", "This is not a QNotch setup code."), (SetupCode.prefix + "!!!!", "This code is damaged or incomplete. Copy it again.")] {
            XCTAssertThrowsError(try SetupCode.read(bad, current: base, modules: [])) { XCTAssertEqual(($0 as? SetupCode.Failure)?.message, message) }
        }
        let outOfRange = SetupCode.prefix + SetupCode.base64url(SetupCode.deflate(Data(#"{"timer":{"Minutes":999}}"#.utf8)))
        XCTAssertThrowsError(try SetupCode.read(outOfRange, current: base, modules: []))
    }

    func testZeroAndOneAreNumbersNotBooleansAndTruncatedCodesFail() throws {
        // 0 and 1 bridge to Bool, so a naive `is Bool` check used to reject "Off" toasts, 1-day history and a 0 ms hover.
        let edges = Data(#"{"general":{"HoverDwellMs":0},"notifications":{"ToastSeconds":0,"RetentionDays":1,"Sound":true}}"#.utf8)
        let plan = try SetupCode.read(SetupCode.prefix + SetupCode.base64url(SetupCode.deflate(edges)), current: base, modules: [])
        XCTAssertEqual(plan.result.general.hoverDelayMs, 0)
        XCTAssertEqual(plan.result.notifications.toastSeconds, 0)
        XCTAssertEqual(plan.result.notifications.retentionDays, 1)
        XCTAssertTrue(plan.result.notifications.sound)
        // A JSON boolean is still not a number, and a number is still not a boolean.
        for bad in [#"{"notifications":{"ToastSeconds":true}}"#, #"{"notifications":{"Sound":1}}"#] {
            let code = SetupCode.prefix + SetupCode.base64url(SetupCode.deflate(Data(bad.utf8)))
            XCTAssertThrowsError(try SetupCode.read(code, current: base, modules: [])) {
                XCTAssertEqual(($0 as? SetupCode.Failure)?.message, "This code has a value QNotch cannot use (Notifications).")
            }
        }
        // A code that lost its tail when pasted still base64-decodes; the decoder must give up, not wait forever.
        let full = SetupCode.deflate(edges)
        let truncated = SetupCode.prefix + SetupCode.base64url(full.prefix(full.count / 2))
        XCTAssertThrowsError(try SetupCode.read(truncated, current: base, modules: [])) {
            XCTAssertEqual(($0 as? SetupCode.Failure)?.message, "This code is damaged or incomplete. Copy it again.")
        }
    }
}

final class NudgeTests: XCTestCase {
    func testFloatingPillSnapsAndNotchNeverMoves() {
        var pill = DisplayLayout(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), safeTop: 0, cameraGap: nil)
        XCTAssertEqual(pill.snapped(offset: 40, width: 96), 0)
        XCTAssertEqual(pill.snapped(offset: 400, width: 96), 400)
        XCTAssertEqual(pill.snapped(offset: 880, width: 96), 904)
        XCTAssertEqual(pill.snapped(offset: -5000, width: 96), -904)
        pill.offset = 400
        XCTAssertEqual(pill.surface(expanded: false).midX, 1360)
        var notch = DisplayLayout(frame: CGRect(x: 0, y: 0, width: 1470, height: 956), visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 919), safeTop: 37,
                                  cameraGap: CGRect(x: 650, y: 919, width: 170, height: 37))
        let before = notch.surface(expanded: false)
        notch.offset = 300
        XCTAssertEqual(notch.surface(expanded: false), before)
    }
}

final class WingFitTests: XCTestCase {
    func testFullWingSpillsToTheOuterEndOfTheOtherWing() {
        // Right: notifications, agents, weather, memory, battery; left: CPU only.
        let fit = WingFit.fit(leading: [("cpu", 40)], trailing: [("bell", 24), ("agents", 70), ("weather", 40), ("ram", 40), ("battery", 50)],
                              maxWidth: 146, spacing: 6)
        XCTAssertEqual(fit.trailing, ["bell", "agents", "weather"])
        XCTAssertEqual(fit.leading, ["battery", "ram", "cpu"])
    }

    func testDropsOnlyWhenNeitherWingHasRoom() {
        let fit = WingFit.fit(leading: [("a", 100), ("b", 60)], trailing: [("c", 140), ("d", 50)], maxWidth: 146, spacing: 6)
        XCTAssertEqual(fit.leading, ["a"])
        XCTAssertEqual(fit.trailing, ["c"])
    }

    func testHiddenSegmentsTakeNoRoomAndFittingWingsStayPut() {
        let fit = WingFit.fit(leading: [("a", nil), ("b", 50)], trailing: [("c", 50), ("d", nil)], maxWidth: 146, spacing: 6)
        XCTAssertEqual(fit.leading, ["b"])
        XCTAssertEqual(fit.trailing, ["c"])
    }
}

final class OnboardingTests: XCTestCase {
    func testFreshInstallExistingUserAndDiagnosticDecisions() {
        func decide(exists: Bool, readable: Bool = true, done: Bool?, diagnostics: Bool = false) -> Onboarding.AtLaunch {
            Onboarding.atLaunch(settingsExist: exists, readable: readable, done: done, diagnostics: diagnostics)
        }
        XCTAssertEqual(decide(exists: false, done: nil), .show, "A fresh install shows the tour")
        XCTAssertEqual(decide(exists: true, done: nil), .markDone, "Settings from before the tour are marked done silently")
        XCTAssertEqual(decide(exists: true, done: false), .show, "A tour that never ended shows again")
        XCTAssertEqual(decide(exists: true, done: true), .nothing)
        XCTAssertEqual(decide(exists: true, readable: false, done: nil), .nothing, "An unreadable file is never overwritten")
        XCTAssertEqual(decide(exists: false, done: nil, diagnostics: true), .nothing, "--smoke-test and --measure skip the tour")
        XCTAssertEqual(decide(exists: true, done: nil, diagnostics: true), .nothing)
    }

    func testOnboardingDoneIsOptionalAndNeverShared() throws {
        XCTAssertNil(try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"reduceMotion":true}"#.utf8)).onboardingDone)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(GeneralSettings()), as: UTF8.self).contains("onboardingDone"))
        var done = GeneralSettings()
        done.onboardingDone = true
        XCTAssertEqual(try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(done)).onboardingDone, true)
        // A setup code from a Mac that finished the tour leaves this Mac's own value alone.
        func snapshot(_ general: GeneralSettings) -> SetupCode.Snapshot {
            SetupCode.Snapshot(general: general, gameMode: GameModeSettings(), timer: TimerSettings(), weather: WeatherSettings(),
                               notifications: NotificationSettings(), ai: AiSettings(), agents: AgentsSettings())
        }
        var pending = GeneralSettings()
        pending.onboardingDone = false
        let plan = try SetupCode.read(SetupCode.export(snapshot(done)), current: snapshot(pending), modules: [])
        XCTAssertEqual(plan.result.general.onboardingDone, false)
    }

    func testStepsGroupsAndFeatureChoices() {
        XCTAssertEqual(Onboarding.steps(hasConnectRows: true).map(\.rawValue), ["welcome", "open", "features", "connect", "finish"])
        XCTAssertEqual(Onboarding.steps(hasConnectRows: false), [.welcome, .open, .features, .finish])
        let mac = ModuleList.all.map(\.id)
        let groups = Onboarding.groups(available: mac)
        XCTAssertEqual(groups.map(\.title), ["At a glance", "Get things done", "For developers"])
        XCTAssertEqual(groups.flatMap(\.modules).sorted(), mac.sorted(), "Every Mac feature is in exactly one group")
        XCTAssertEqual(groups[1].modules, ["clipboard", "note", "filetray", "colorpicker", "scheduled"], "Search is not a Mac module")
        XCTAssertEqual(Onboarding.groups(available: ["timer"]).map(\.title), ["At a glance"], "Empty groups are left out")
        var settings = GeneralSettings()
        settings.setEnabled("clipboard", false)
        let glance = groups[0]
        XCTAssertTrue(Onboarding.allEnabled(glance, in: settings))
        Onboarding.setGroup(glance, enabled: false, in: &settings)
        XCTAssertEqual(settings.disabledModules, (glance.modules + ["clipboard"]).sorted())
        XCTAssertFalse(Onboarding.allEnabled(glance, in: settings))
        Onboarding.setGroup(glance, enabled: true, in: &settings)
        XCTAssertEqual(settings.disabledModules, ["clipboard"], "Turn all on leaves other groups alone")
        XCTAssertEqual(Set(ModuleList.all.filter { $0.setup != nil }.map(\.id)), ["agents", "github", "weather"])
    }
}

final class GithubDeviceFlowTests: XCTestCase {
    private let deviceCode = "3584d83530557fdd1f46af8289938c8ef79f9dc5"

    func testSignInIsOfferedOnlyWithAClientId() {
        XCTAssertFalse(GithubOAuth.isAvailable(clientId: ""))
        XCTAssertFalse(GithubOAuth.isAvailable(clientId: " \n"))
        XCTAssertTrue(GithubOAuth.isAvailable(clientId: "Ov23liS199CVpbrlXUlC"))
        // The row reads any saved token in the background; never the login Keychain in tests.
        if Keychain.inMemory == nil { Keychain.inMemory = [:] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = ModuleSetupContext(settings: SettingsStore(directory: directory), running: { nil })
        let tokenOnly = GithubSetupView(context: context, clientId: "")
        XCTAssertFalse(tokenOnly.offersSignIn, "Without a client ID there is no Sign in with GitHub")
        XCTAssertTrue(tokenOnly.showsTokenBox, "and the token box shows instead")
        let signIn = GithubSetupView(context: context, clientId: "Iv1.test")
        XCTAssertTrue(signIn.offersSignIn)
        XCTAssertFalse(signIn.showsTokenBox, "The token box waits for Use a token instead")
    }

    func testRequestsAreFormPostsThatAskForJSON() throws {
        let code = GithubDeviceFlow.codeRequest(clientID: "Iv1.abc")
        XCTAssertEqual(code.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(code.httpMethod, "POST")
        XCTAssertEqual(code.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(code.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(decoding: try XCTUnwrap(code.httpBody), as: UTF8.self), "client_id=Iv1.abc&scope=read%3Auser")
        let token = GithubDeviceFlow.tokenRequest(clientID: "Iv1.abc", deviceCode: deviceCode)
        XCTAssertEqual(token.url?.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(token.httpMethod, "POST")
        XCTAssertEqual(String(decoding: try XCTUnwrap(token.httpBody), as: UTF8.self),
                       "client_id=Iv1.abc&device_code=\(deviceCode)&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    }

    func testCodeAnswersAndErrors() throws {
        let body = Data(#"{"device_code":"\#(deviceCode)","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8)
        XCTAssertEqual(try GithubDeviceFlow.parseCode(status: 200, body: body, transportFailed: false),
                       GithubDeviceFlow.Code(deviceCode: deviceCode, userCode: "WDJB-MJHT", verificationURL: URL(string: "https://github.com/login/device")!,
                                             expiresIn: 900, interval: 5))
        let fast = Data(#"{"device_code":"d","user_code":"AB-CD","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8)
        XCTAssertEqual(try GithubDeviceFlow.parseCode(status: 200, body: fast, transportFailed: false).interval, 5, "Never polls faster than 5 seconds")
        func failure(_ status: Int?, _ text: String?, transportFailed: Bool = false) -> GithubError? {
            do {
                _ = try GithubDeviceFlow.parseCode(status: status, body: text.map { Data($0.utf8) }, transportFailed: transportFailed)
                return nil
            } catch { return error as? GithubError }
        }
        XCTAssertEqual(failure(nil, nil, transportFailed: true), .message("No connection to GitHub.", offline: true))
        XCTAssertEqual(failure(200, #"{"error":"device_flow_disabled","error_description":"Device flow must be explicitly enabled for this App"}"#)?.text,
                       "Device flow must be explicitly enabled for this App")
        XCTAssertEqual(failure(400, #"{"error":"unauthorized_client"}"#)?.text, "GitHub refused the sign-in (unauthorized_client).")
        XCTAssertEqual(failure(500, "<html>")?.text, "GitHub returned 500.")
        XCTAssertEqual(failure(200, #"{"device_code":"d","user_code":"AB-CD","verification_uri":"http://example.com","expires_in":900}"#)?.text,
                       "GitHub sent an unexpected response.", "Only an https page is opened")
        XCTAssertEqual(failure(200, #"{"user_code":"AB-CD","verification_uri":"https://github.com/login/device","expires_in":900}"#)?.text,
                       "GitHub sent an unexpected response.")
    }

    func testPollAnswersAndBackoff() {
        func poll(_ json: String, status: Int = 200) -> GithubDeviceFlow.Poll {
            GithubDeviceFlow.parsePoll(status: status, body: Data(json.utf8), transportFailed: false)
        }
        XCTAssertEqual(poll(#"{"error":"authorization_pending","error_description":"The authorization request is still pending."}"#), .pending)
        XCTAssertEqual(poll(#"{"error":"slow_down","error_description":"Too many requests.","interval":10}"#), .slowDown(interval: 10))
        XCTAssertEqual(poll(#"{"error":"slow_down"}"#), .slowDown(interval: nil))
        XCTAssertEqual(poll(#"{"error":"expired_token"}"#), .expired)
        XCTAssertEqual(poll(#"{"error":"access_denied"}"#), .denied)
        XCTAssertEqual(poll(#"{"access_token":"gho_16C7e42F292c6912E7710c838347Ae178B4a","token_type":"bearer","scope":"read:user"}"#),
                       .token("gho_16C7e42F292c6912E7710c838347Ae178B4a"))
        XCTAssertEqual(poll(#"{"error":"incorrect_device_code","error_description":"The device_code provided is not valid."}"#),
                       .failed("The device_code provided is not valid."))
        XCTAssertEqual(poll(#"{"error":"unsupported_grant_type"}"#), .failed("GitHub refused the sign-in (unsupported_grant_type)."))
        XCTAssertEqual(poll("<html>", status: 502), .failed("GitHub returned 502."))
        XCTAssertEqual(poll(#"{"ok":true}"#), .failed("GitHub sent an unexpected response."))
        XCTAssertEqual(GithubDeviceFlow.parsePoll(status: nil, body: nil, transportFailed: true), .failed("No connection to GitHub."))
        XCTAssertEqual(GithubDeviceFlow.nextInterval(after: .slowDown(interval: nil), current: 5), 10, "slow_down adds 5 seconds")
        XCTAssertEqual(GithubDeviceFlow.nextInterval(after: .slowDown(interval: 20), current: 5), 20, "or uses GitHub's longer interval")
        XCTAssertEqual(GithubDeviceFlow.nextInterval(after: .slowDown(interval: 6), current: 5), 10)
        XCTAssertEqual(GithubDeviceFlow.nextInterval(after: .pending, current: 5), 5)
        XCTAssertEqual(GithubDeviceFlow.expiredMessage, "The code expired.")
        XCTAssertEqual(GithubDeviceFlow.deniedMessage, "Sign-in was cancelled on GitHub.")
    }
}
