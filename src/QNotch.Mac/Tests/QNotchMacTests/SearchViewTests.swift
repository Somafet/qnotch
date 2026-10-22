import AppKit
import Testing
@testable import QNotchMac

@MainActor
struct SearchViewTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @Test(arguments: [0, 1, 5, 6], [NSSize(width: 664, height: 308), NSSize(width: 320, height: 180)])
    func boundedResults(count: Int, size: NSSize) throws {
        let view = SearchView { _ in
            (0..<count).map { index in
                SearchHit(title: index.isMultiple(of: 2) ? String(repeating: "Long title \(index) ", count: 30) : "Short title",
                          detail: index.isMultiple(of: 2) ? String(repeating: "Long detail ", count: 40) : "A short detail should fit", run: {})
            }
        }
        view.frame = NSRect(origin: .zero, size: size)
        view.focus(appending: "query")
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
        #expect(view.frame.size == size)
        #expect(view.bounds.contains(scroll.frame))
        #expect(scroll.frame.height == size.height - 46)
        let document = try #require(scroll.documentView)
        #expect(document.frame.width == scroll.contentSize.width)
        let buttons = descendants(document).compactMap { $0 as? HoverButton }
        #expect(buttons.count == count)
        for button in buttons {
            #expect(button.frame.height == 44)
            #expect(button.frame.width == document.frame.width)
            #expect(button.subviews.allSatisfy { button.bounds.insetBy(dx: -2, dy: 0).contains($0.frame) })
            let labels = descendants(button).compactMap { $0 as? NSTextField }
            #expect(labels.allSatisfy { abs($0.frame.width - (button.frame.width - 44)) <= 1 })
        }
    }

    @Test func selectionClampsAndQueryChangesResetActivation() throws {
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
            #expect(view.control(view.field, textView: editor, doCommandBy: selector))
        }
        func selected() -> [HoverButton] {
            descendants(view).compactMap { $0 as? HoverButton }.filter { $0.isAccessibilitySelected() }
        }
        view.focus(appending: "many")
        for _ in 0..<10 { command(#selector(NSResponder.moveDown(_:))) }
        #expect(selected().map { $0.identifier?.rawValue } == ["search-result-5"])
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(activations == ["many-5"])
        for _ in 0..<10 { command(#selector(NSResponder.moveUp(_:))) }
        #expect(selected().map { $0.identifier?.rawValue } == ["search-result-0"])
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(activations == ["many-5", "many-0"])
        view.field.stringValue = "one"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(activations.last == "one-0")
        view.field.stringValue = "absent"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        command(#selector(NSResponder.moveDown(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        view.clear()
        command(#selector(NSResponder.moveUp(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        #expect(selected().isEmpty)
        #expect(activations == ["many-5", "many-0", "one-0"])
        #expect(queries == ["many", "one", "absent"])
        #expect(!view.control(view.field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
    }
}
