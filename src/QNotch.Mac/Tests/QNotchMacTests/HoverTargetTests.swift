import AppKit
import Foundation
import XCTest
import QNotchMacCore
@testable import QNotchMac

final class HoverTargetTests: XCTestCase {
    func testExistingSettingsKeepGenericHover() throws {
        for json in ["{}", #"{"hoverOpensSegment":false}"#, #"{"hoverOpensSegment":"invalid"}"#] {
            let value = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
            XCTAssertTrue(!value.hoverOpensSegment, json)
        }
    }

    func testPreferencePersists() throws {
        var settings = GeneralSettings()
        settings.hoverOpensSegment = true
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.hoverOpensSegment)
    }

    @MainActor
    func testRoutesFinalLiveSegmentAndLatchesUntilClose() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let shell = fixture.shell
        try shell.withDiagnosticLayout(SnapshotViews.virtualDisplay) {
            let first = try fixture.point("fixture.cpu")
            let final = try fixture.point("fixture.memory")
            shell.selectTab("fixture")
            shell.completeHover(at: first)
            XCTAssertTrue(shell.activeTab == "fixture", "Default-off hover preserves navigation")
            shell.close(restoreFocus: false)
            shell.pointerLeft()
            shell.updateGeneral { $0.hoverOpensSegment = true }
            XCTAssertTrue(shell.segmentID(at: first) == "fixture.cpu")
            shell.completeHover(at: final)
            XCTAssertTrue(shell.activeTab == "home")
            XCTAssertTrue(fixture.card.detail == "memory")
            XCTAssertTrue(!shell.state.acceptsKeyboard && !shell.panel.canBecomeKey)
            shell.completeHover(at: first)
            XCTAssertTrue(fixture.card.detail == "memory", "Crossing while expanded must not switch")
            shell.close(restoreFocus: false)
            XCTAssertTrue(fixture.card.detail == nil)
            shell.pointerLeft()
            shell.completeHover(at: first)
            XCTAssertTrue(fixture.card.detail == "cpu")
        }
    }

    @MainActor
    func testHiddenCardDetailPreservesLayoutAndIsRemovedWithOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let shell = fixture.shell
        shell.updateGeneral { $0.setCardVisible("fixture", false); $0.cardOrder = ["gone", "fixture"] }
        let settings = shell.general
        shell.activateSegment("fixture.memory")
        XCTAssertTrue(shell.currentBody?.identifier?.rawValue == "segment-detail-fixture")
        XCTAssertTrue(shell.general == settings)
        XCTAssertTrue(fixture.transientCard?.detail == "memory")
        shell.selectTab("home")
        XCTAssertTrue(shell.currentBody?.identifier?.rawValue != "segment-detail-fixture")
        shell.activateSegment("fixture.memory")
        let removed = NSHashTable<NSView>.weakObjects()
        if let body = shell.currentBody { removed.add(body) }
        shell.registries.removeAll(owner: "fixture-owner")
        // The normal module-disable path discards the panel and invalidates removed content.
        shell.updateGeneral { $0.disabledModules.append("unavailable-fixture") }
        XCTAssertTrue(shell.activeTab == "home")
        XCTAssertTrue(shell.currentBody?.identifier?.rawValue != "segment-detail-fixture")
        XCTAssertTrue(removed.allObjects.allSatisfy { $0.superview == nil }, "Removed destination must be detached, including during native animation teardown")
        shell.activateSegment("fixture.memory")
        XCTAssertTrue(shell.activeTab == "home")
    }

    @MainActor
    func testTabHiddenMissingStaticPeekAndHousingFallbacks() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let shell = fixture.shell
        shell.activateSegment("fixture.tab")
        XCTAssertTrue(shell.activeTab == "fixture")
        shell.updateGeneral { $0.setTabVisible("fixture", false) }
        shell.activateSegment("fixture.tab")
        XCTAssertTrue(shell.activeTab == "home")
        shell.activateSegment("fixture.missing")
        XCTAssertTrue(shell.activeTab == "home")
        shell.close(restoreFocus: false)
        shell.pointerLeft()
        shell.updateGeneral { $0.hoverOpensSegment = true }
        try shell.withDiagnosticLayout(SnapshotViews.virtualDisplay) {
            shell.selectTab("fixture")
            let staticPoint = try fixture.point("fixture.static")
            shell.completeHover(at: staticPoint)
            XCTAssertTrue(shell.activeTab == "fixture", "A static indicator keeps normal navigation")
            shell.close(restoreFocus: false)
            shell.pointerLeft()
            let housing = try XCTUnwrap(shell.layout).surface(expanded: false, wing: shell.wing)
            shell.completeHover(at: NSPoint(x: housing.midX, y: housing.midY))
            XCTAssertTrue(shell.activeTab == "fixture")
            shell.close(restoreFocus: false)
            shell.pointerLeft()
            let point = try fixture.point("fixture.cpu")
            let peek = shell.peek(symbol: "bell", tint: .white, leading: "Alert", trailing: "Ready", seconds: nil)
            XCTAssertTrue(shell.segmentID(at: point) == nil)
            peek?.end()
            shell.gameMode.override = .on
            shell.activateSegment("fixture.cpu")
            shell.completeHover(at: point)
            XCTAssertTrue(!shell.state.expanded)
            shell.gameMode.override = .off
        }
    }

    @MainActor
    func testRevealsCardPastFirstRowsWithoutReordering() async throws {
        let previousMotion = Motion.userReduced
        Motion.userReduced = true
        defer { Motion.userReduced = previousMotion }
        let home = HomeView(cards: (0..<15).map { index in
            (ViewContribution(id: "card\(index)", title: "Card \(index)", order: index, span: index == 14 ? 2 : 1, makeView: { NSView() }), NSView())
        })
        home.frame = NSRect(x: 0, y: 0, width: 700, height: 250)
        home.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(home.documentView)
        let order = document.subviews.map(\.identifier)
        let target = try XCTUnwrap(document.subviews.first { $0.identifier?.rawValue == "card-card14" })
        XCTAssertTrue(!document.visibleRect.contains(target.frame))
        home.revealCard("card14")
        XCTAssertTrue(document.visibleRect.contains(target.frame))
        XCTAssertTrue(document.subviews.map(\.identifier) == order)
        home.editing = true
        defer { home.editing = false }
        home.layoutSubtreeIfNeeded()
        let handle = try XCTUnwrap(target.subviews.compactMap { $0 as? HomeResizeHandle }.first)
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document.superview)
        XCTAssertTrue(document.hitTest(point) === handle, "Revealed cards retain usable resize edges")
    }

    @MainActor
    func testSlotAccessibilityAndKeyboardShareTheActionAfterSpill() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let shell = fixture.shell
        try shell.withDiagnosticLayout(SnapshotViews.virtualDisplay) {
            let slot = try XCTUnwrap(fixture.slots.first { $0.segmentID == "fixture.memory" })
            let point = try fixture.point("fixture.memory")
            XCTAssertTrue(slot.superview?.identifier?.rawValue == "notch-left-wing", "Fixture must spill RAM to the other wing")
            XCTAssertTrue(shell.segmentID(at: point) == "fixture.memory")
            XCTAssertTrue(slot.toolTip == "Open memory details")
            XCTAssertTrue(slot.accessibilityLabel() == "Open memory details")
            XCTAssertTrue(slot.accessibilityPerformPress())
            XCTAssertTrue(fixture.card.detail == "memory")
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: shell.panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            shell.selectTab("fixture")
            slot.keyDown(with: key)
            XCTAssertTrue(shell.activeTab == "home" && fixture.card.detail == "memory")
            slot.isHidden = true
            XCTAssertTrue(!slot.accessibilityPerformPress())
        }
    }
}

private final class DetailFixture: NSView, SegmentDetailContent {
    var detail: String?
    func emphasize(_ detail: String?) -> Bool { self.detail = detail; return true }
}

@MainActor
private final class Fixture {
    let directory: URL
    let shell: ShellController
    let card = DetailFixture()
    weak var transientCard: DetailFixture?
    var slots: [SegmentSlotView] {
        func walk(_ view: NSView) -> [SegmentSlotView] { (view as? SegmentSlotView).map { [$0] } ?? view.subviews.flatMap(walk) }
        shell.surface.layoutSubtreeIfNeeded()
        return walk(shell.surface)
    }
    init() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/hover-tests/" + UUID().uuidString)
        let store = SettingsStore(directory: directory)
        var settings = GeneralSettings()
        settings.disabledModules = ModuleList.all.map(\.id)
        settings.reduceMotion = true
        XCTAssertTrue(store.save("general", settings))
        shell = ShellController(store: store, renderOnly: true)
        shell.registries.owner = "fixture-owner"
        shell.registries.cards.register(ViewContribution(id: "fixture", title: "Details", order: 0) { [unowned self] in
            if self.shell.general.isCardVisible("fixture") { return self.card }
            let card = DetailFixture()
            self.transientCard = card
            return card
        })
        shell.registries.tabs.register(ViewContribution(id: "fixture", title: "Fixture", order: 0) { NSView() })
        let destinations: [(String, SegmentSlot, SegmentDestination?, CGFloat)] = [
            ("cpu", .leading, .card("fixture", emphasis: "cpu", allowsHiddenDetail: true), 35),
            ("tab", .trailing, .tab("fixture"), 72),
            ("memory", .trailing, .card("fixture", emphasis: "memory", allowsHiddenDetail: true), 70),
            ("missing", .leading, .tab("absent"), 12),
            ("static", .leading, nil, 10)
        ]
        for (index, entry) in destinations.enumerated() {
            shell.registries.segments.register(SegmentContribution(id: "fixture." + entry.0, order: index, slot: entry.1,
                destination: entry.2, destinationLabel: "Open " + entry.0 + " details") {
                let view = NSView()
                size(view, width: entry.3, height: 17)
                return view
            })
        }
        shell.registries.owner = nil
        // Rebuild the shell's normal contribution slots without constructing any real module.
        shell.updateGeneral { $0.profileName = "Hover test" }
    }
    func point(_ id: String) throws -> NSPoint {
        let slot = try XCTUnwrap(slots.first { $0.segmentID == id })
        XCTAssertTrue(!slot.isHiddenOrHasHiddenAncestor)
        let rect = shell.panel.convertToScreen(slot.convert(slot.bounds, to: nil))
        return NSPoint(x: rect.midX, y: rect.midY)
    }
    func stop() {
        shell.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
