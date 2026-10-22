import AppKit
import XCTest
@testable import QNotchMac

@MainActor
final class SearchViewTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testBoundedResults() async throws {
        for count in [0, 1, 5, 6] {
            for size in [NSSize(width: 664, height: 308), NSSize(width: 320, height: 180)] {
                try XCTContext.runActivity(named: "count=\(count), size=\(size)") { _ in
                    try checkBoundedResults(count: count, size: size)
                }
            }
        }
    }

    private func checkBoundedResults(count: Int, size: NSSize) throws {
        let view = SearchView { _ in
            (0..<count).map { index in
                SearchHit(title: index.isMultiple(of: 2) ? String(repeating: "Long title \(index) ", count: 30) : "Short title",
                          detail: index.isMultiple(of: 2) ? String(repeating: "Long detail ", count: 40) : "A short detail should fit", run: {})
            }
        }
        view.frame = NSRect(origin: .zero, size: size)
        view.focus(appending: "query")
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(view.frame.size == size)
        XCTAssertTrue(view.bounds.contains(scroll.frame))
        XCTAssertTrue(scroll.frame.height == size.height - 46)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(document.frame.width == scroll.contentSize.width)
        let buttons = descendants(document).compactMap { $0 as? HoverButton }
        XCTAssertTrue(buttons.count == count)
        for button in buttons {
            XCTAssertTrue(button.frame.height == 44)
            XCTAssertTrue(button.frame.width == document.frame.width)
            XCTAssertTrue(button.subviews.allSatisfy { button.bounds.insetBy(dx: -2, dy: 0).contains($0.frame) })
            let labels = descendants(button).compactMap { $0 as? NSTextField }
            XCTAssertTrue(labels.allSatisfy { abs($0.frame.width - (button.frame.width - 44)) <= 1 })
        }
    }

    func testSelectionClampsAndQueryChangesResetActivation() async throws {
        var activations: [String] = []
        var queries: [String] = []
        let view = SearchView { query in
            queries.append(query)
            let count = query == "many" ? 6 : query == "one" ? 1 : 0
            return (0..<count).map { index in
                SearchHit(title: "\(query)-\(index)", detail: "", run: { activations.append("\(query)-\(index)") })
            }
        }
        view.frame = NSRect(x: 0, y: 0, width: 664, height: 308)
        let editor = NSTextView()
        func command(_ selector: Selector) {
            XCTAssertTrue(view.control(view.field, textView: editor, doCommandBy: selector))
        }
        func selected() -> [HoverButton] {
            descendants(view).compactMap { $0 as? HoverButton }.filter { $0.isAccessibilitySelected() }
        }
        view.focus(appending: "many")
        for _ in 0..<10 { command(#selector(NSResponder.moveDown(_:))) }
        XCTAssertTrue(selected().map { $0.identifier?.rawValue } == ["search-result-5"])
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(activations == ["many-5"])
        for _ in 0..<10 { command(#selector(NSResponder.moveUp(_:))) }
        XCTAssertTrue(selected().map { $0.identifier?.rawValue } == ["search-result-0"])
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(activations == ["many-5", "many-0"])
        view.field.stringValue = "one"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(activations.last == "one-0")
        view.field.stringValue = "absent"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        view.clear()
        command(#selector(NSResponder.moveUp(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(selected().isEmpty)
        XCTAssertTrue(activations == ["many-5", "many-0", "one-0"])
        XCTAssertTrue(queries == ["many", "one", "absent"])
        XCTAssertTrue(!view.control(view.field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }
}
