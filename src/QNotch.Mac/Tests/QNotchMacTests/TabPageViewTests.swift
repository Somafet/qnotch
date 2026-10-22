import AppKit
import XCTest
@testable import QNotchMac

// AppKit UI regressions use the project's XCTest baseline (Xcode 15 / Swift 5.9).
final class TabPageViewTests: XCTestCase {
    private final class Body: NSView, TabHeaderProviding, PanelKeyboardContent {
        let tabHeaderActions: NSView
        let action: HoverButton
        let scroll = NSScrollView()
        let document = FlippedView()
        var presses = 0
        var focused = false

        init() {
            action = HoverButton("Clear all", style: .plain, action: {})
            tabHeaderActions = row([action], spacing: 4)
            super.init(frame: .zero)
            action.handler = { [weak self] in self?.presses += 1 }
            scroll.documentView = document
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            embed(scroll, in: self, inset: 0, fill: true)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func focusKeyboard() { focused = true }
    }

    @MainActor
    func testLandmarkAndActionsStayFixedAcrossLongTitlesStatesAndScrolling() async throws {
        for width: CGFloat in [320, 664] {
            for title in ["Media", "Scheduled tasks", String(repeating: "長いタイトル — Long localized title ", count: 12)] {
                let body = Body()
                let page = TabPageView(id: "test", title: title, content: body)
                page.frame = NSRect(x: 0, y: 0, width: width, height: 308)
                page.layoutSubtreeIfNeeded()
                let titleFrame = page.heading.frame
                for height: CGFloat in [0, 44, 2000] {
                    body.document.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    for hidden in [false, true] {
                        body.action.isHidden = hidden
                        body.scroll.isHidden = height == 0
                        body.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - 100)))
                        page.layoutSubtreeIfNeeded()
                        XCTAssertEqual(page.heading.frame.origin, titleFrame.origin)
                        XCTAssertEqual(page.heading.font, NSFont.systemFont(ofSize: 14, weight: .semibold))
                        XCTAssertEqual(page.header.frame.height, 28)
                        XCTAssertEqual(page.bounds.maxY - page.header.frame.maxY, 0)
                        XCTAssertEqual(page.header.frame.minY - body.frame.maxY, 12)
                        XCTAssertEqual(body.frame.minX, 0)
                        XCTAssertEqual(body.frame.width, width)
                        let alignedTitle = page.heading.alignmentRect(forFrame: page.heading.frame)
                        XCTAssertEqual(alignedTitle.minX, 0)
                        XCTAssertTrue(alignedTitle.maxX <= body.tabHeaderActions.frame.minX - 11)
                        if !hidden {
                            XCTAssertTrue(page.header.bounds.contains(body.tabHeaderActions.frame))
                            XCTAssertEqual(body.action.frame.height, 28)
                            XCTAssertEqual(body.action.convert(body.action.bounds, to: page.header).maxX, width)
                            body.action.performClick(nil)
                        }
                        XCTAssertTrue(page.isAccessibilityElement())
                        XCTAssertEqual(page.accessibilityRole(), .group)
                        XCTAssertEqual(page.accessibilityLabel(), title)
                        XCTAssertTrue(page.accessibilityTitleUIElement() as? NSTextField === page.heading)
                        XCTAssertEqual(page.heading.accessibilityLabel(), title)
                        XCTAssertEqual(Outline.unnamedControls(in: Outline.text(for: page)), [])
                    }
                }
                XCTAssertEqual(body.presses, 3)
                page.focusKeyboard()
                XCTAssertTrue(body.focused, "The wrapper must forward Terminal's focus contract")
            }
        }
    }

    @MainActor
    func testBodyWithoutActionsAndExceptionSurfaces() async {
        let body = NSView()
        let page = TabPageView(id: "timer", title: "Timer", content: body)
        page.frame = NSRect(x: 0, y: 0, width: 664, height: 308)
        page.layoutSubtreeIfNeeded()
        XCTAssertNil(page.actions)
        XCTAssertEqual(page.heading.alignmentRect(forFrame: page.heading.frame).width, 664)
        XCTAssertEqual(body.frame.height, 268)
        let search = SearchView { _ in [] }
        XCTAssertEqual(search.field.accessibilityLabel(), "Search QNotch")
        XCTAssertFalse(search.subviews.contains { $0 is TabPageView })
    }
}
