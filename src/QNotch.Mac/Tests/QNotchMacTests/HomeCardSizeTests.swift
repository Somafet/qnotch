import AppKit
import XCTest
import QNotchMacCore
@testable import QNotchMac

final class HomeCardSizeTests: XCTestCase {
    func testOldAndInvalidSavedSizesUseSupportedDefaults() throws {
        let old = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"cardOrder":["media","timer"]}"#.utf8))
        XCTAssertTrue(old.cardSizes.isEmpty)
        XCTAssertEqual(HomeCardSize.resolve(saved: old.cardSizes["media"], defaultSpan: 2), .medium)
        for saved in [-1, 0, 3, 99] {
            XCTAssertEqual(HomeCardSize.resolve(saved: saved, defaultSpan: 2), .medium)
            XCTAssertEqual(HomeCardSize.resolve(saved: saved, defaultSpan: 1), .small)
        }
        XCTAssertEqual(HomeCardSize.resolve(saved: 2, defaultSpan: 1), .small)
        XCTAssertEqual(HomeCardSize.resolve(saved: 1, defaultSpan: 2), .small)
    }

    func testSizesSurviveRestartHidingDisablingAndOrdering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var general = GeneralSettings()
        general.cardSizes = ["media": 1, "weather": 2, "future-card": 1]
        general.setCardVisible("media", false)
        general.setEnabled("weather", false)
        general.cardOrder = ["weather", "media", "timer"]
        XCTAssertTrue(SettingsStore(directory: directory).save("general", general))
        var restored = SettingsStore(directory: directory).load("general", default: GeneralSettings())
        XCTAssertEqual(restored, general)
        restored.setCardVisible("media", true)
        restored.setEnabled("weather", true)
        restored.cardOrder.reverse()
        XCTAssertEqual(restored.cardSizes, general.cardSizes)
    }

    private final class Content: NSView, HomeCardSizing {
        var sizes: [HomeCardSize] = []
        func setHomeCardSize(_ size: HomeCardSize) { sizes.append(size) }
    }

    @MainActor
    func testSmallTimerShowsTheCompleteLongestReadout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let module = TimerModule(), registry = ModuleRegistries()
        module.initialize(ModuleContext(settings: SettingsStore(directory: directory), registries: registry, shell: nil))
        defer { module.stop() }
        module.choose(minutes: 180)
        let contribution = try XCTUnwrap(registry.cards.items.first)
        let card = CardView(title: contribution.title, content: contribution.makeView())
        card.frame = NSRect(x: 0, y: 0, width: 214, height: HomeView.rowHeight)
        card.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let readout = try XCTUnwrap(descendants(card).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "timer-remaining"
        })
        XCTAssertEqual(readout.stringValue, "180:00")
        XCTAssertLessThanOrEqual(readout.attributedStringValue.size().width, readout.bounds.width + 1)
    }

    @MainActor
    func testCompactEmptyStatesFitWithoutAccountsOrPlayers() async throws {
        let weather = WeatherModule(), github = GithubModule(), media = MediaModule()
        let weatherView = WeatherCardView(module: weather)
        let githubView = GithubCardView(module: github)
        let mediaView = MediaView(module: media, large: false)
        weatherView.reload(); githubView.reload(); mediaView.reload()
        let views: [NSView & HomeCardSizing] = [weatherView, githubView, mediaView]
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for view in views {
            view.setHomeCardSize(.small)
            let card = CardView(title: "Widget", content: view)
            card.frame = NSRect(x: 0, y: 0, width: 226, height: HomeView.rowHeight)
            card.layoutSubtreeIfNeeded()
            for child in descendants(card) where !child.isHiddenOrHasHiddenAncestor {
                XCTAssertTrue(card.bounds.insetBy(dx: -1, dy: -1).contains(child.convert(child.bounds, to: card)),
                              "\(type(of: view)): \(type(of: child)) escapes the Small card")
            }
        }
    }

    @MainActor
    func testLiveResizeControlsHitTestingAndDenseRepacking() async throws {
        let previousMotion = Motion.userReduced
        Motion.userReduced = true
        defer { Motion.userReduced = previousMotion }
        let content = Content()
        let wide = ViewContribution(id: "wide", title: "Wide widget", order: 0, span: 2) { content }
        let narrow = ViewContribution(id: "narrow", title: "Small widget", order: 1) { NSView() }
        let home = HomeView(cards: [(wide, content), (narrow, NSView())])
        home.frame = NSRect(x: 0, y: 0, width: 700, height: 376)
        home.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(home.documentView)
        let wideHost = try XCTUnwrap(document.subviews.first { $0.identifier?.rawValue == "card-wide" })
        let narrowHost = try XCTUnwrap(document.subviews.first { $0.identifier?.rawValue == "card-narrow" })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let handles = descendants(home).compactMap { $0 as? HomeResizeHandle }
        let handle = try XCTUnwrap(handles.first { $0.direction == 1 })
        XCTAssertEqual(handles.count, 2, "Single-size cards have no resize anchors")
        XCTAssertTrue(handles.allSatisfy(\.isHidden))
        let originalWidth = wideHost.frame.width
        var saved: [String: Int] = [:]
        home.resized = { saved[$0] = $1.rawValue }
        home.editing = true
        home.layoutSubtreeIfNeeded()
        XCTAssertFalse(handle.isHidden)
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document.superview)
        XCTAssertTrue(document.hitTest(point) === handle)
        let bodyPoint = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: document.superview)
        XCTAssertTrue(document.hitTest(bodyPoint) === document, "Card content stays inert in edit mode")
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 0), modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, 500))
        handle.mouseDragged(with: event(.leftMouseDragged, 200))
        XCTAssertTrue(saved.isEmpty, "Preview does not save or reorder")
        handle.mouseUp(with: event(.leftMouseUp, 200))
        home.layoutSubtreeIfNeeded()
        XCTAssertEqual(saved, ["wide": 1])
        XCTAssertEqual(content.sizes, [.medium, .small])
        XCTAssertEqual(wideHost.frame.width, narrowHost.frame.width)
        XCTAssertEqual(narrowHost.frame.minX, wideHost.frame.maxX + HomeView.gap)
        XCTAssertFalse(wideHost.frame.intersects(narrowHost.frame))
        let leading = try XCTUnwrap(handles.first { $0.direction == -1 })
        leading.mouseDown(with: event(.leftMouseDown, 200))
        leading.mouseDragged(with: event(.leftMouseDragged, -100))
        leading.mouseUp(with: event(.leftMouseUp, -100))
        home.layoutSubtreeIfNeeded()
        XCTAssertEqual(wideHost.frame.width, originalWidth)
        XCTAssertEqual(saved, ["wide": 2])
        XCTAssertEqual(content.sizes, [.medium, .small, .medium])
        XCTAssertTrue(content.isDescendant(of: wideHost))
        handle.mouseDown(with: event(.leftMouseDown, 200))
        handle.mouseUp(with: event(.leftMouseUp, 200))
        XCTAssertEqual(content.sizes, [.medium, .small, .medium], "A tap does not resize")
        handle.mouseDown(with: event(.leftMouseDown, 200))
        handle.mouseUp(with: event(.leftMouseUp, 20_000))
        XCTAssertEqual(wideHost.frame.width, originalWidth, "Unsupported widths clamp to Medium")
        XCTAssertTrue(handle.accessibilityPerformDecrement())
        XCTAssertEqual(saved, ["wide": 1])
        XCTAssertTrue(handle.accessibilityPerformIncrement())
        XCTAssertEqual(saved, ["wide": 2])
        home.editing = false
        XCTAssertTrue(handles.allSatisfy(\.isHidden))
        home.applySizes(["wide": 1, "narrow": 2])
        home.layoutSubtreeIfNeeded()
        XCTAssertEqual(wideHost.frame.width, narrowHost.frame.width)
        XCTAssertEqual(saved, ["wide": 2], "Restoring sizes does not write them again")
    }
}
