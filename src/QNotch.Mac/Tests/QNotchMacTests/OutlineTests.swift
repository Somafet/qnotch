import XCTest
import AppKit
@testable import QNotchMac

final class OutlineTests: XCTestCase {
    // Mirrors scripts/check-snapshots.mjs.
    private static let quoted = #""(?:[^"\\\n]|\\[\\"nt])*""#
    private static let number = #"\d+(?:\.\d{1,2})?"#
    private static let textLine = try! NSRegularExpression(pattern: "^\(quoted)$")
    private static let controlLine = try! NSRegularExpression(pattern:
        "^\\[(?:Button|Toggle|Tab|Field|SecureField|Slider|Progress|PopUp|Item|Link)\\](?: \(quoted))?(?: #[a-z0-9][a-z0-9._-]*)?" +
        "(?: (?:\(number) of \(number)|value=\(quoted)))?(?: checked)?(?: selected)?(?: focused)?(?: disabled)?$")

    private func assertParses(_ outline: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(outline.hasSuffix("\n"), file: file, line: line)
        var depth = 0
        for (index, text) in outline.split(separator: "\n", omittingEmptySubsequences: false).dropLast().enumerated() {
            let indent = text.prefix { $0 == " " }.count
            let body = String(text.dropFirst(indent))
            let range = NSRange(body.startIndex..., in: body)
            XCTAssertEqual(indent % 2, 0, "line \(index + 1): odd indentation", file: file, line: line)
            XCTAssertLessThanOrEqual(indent / 2, depth + 1, "line \(index + 1): indented too far", file: file, line: line)
            XCTAssertTrue(Self.textLine.firstMatch(in: body, range: range) != nil || Self.controlLine.firstMatch(in: body, range: range) != nil,
                          "line \(index + 1) does not parse: \(body)", file: file, line: line)
            depth = indent / 2
        }
    }

    private func place(_ view: NSView, in parent: NSView, y: CGFloat, width: CGFloat = 160, height: CGFloat = 22) {
        view.frame = NSRect(x: 10, y: y, width: width, height: height)
        parent.addSubview(view)
    }

    func testControlsTextAndStates() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        var y: CGFloat = 560
        func add(_ view: NSView) { place(view, in: root, y: y); y -= 30 }

        add(NSTextField(labelWithString: "Focus"))
        let start = NSButton(title: "Start", target: nil, action: nil)
        start.identifier = NSUserInterfaceItemIdentifier("timer-start")
        add(start)
        let sounds = NSButton(checkboxWithTitle: "Sounds", target: nil, action: nil)
        sounds.state = .on
        add(sounds)
        let toggle = ActionSwitch("Note", value: true) { _ in }
        toggle.identifier = NSUserInterfaceItemIdentifier("feature-note")
        add(toggle)
        let off = ActionSwitch("Weather", value: false) { _ in }
        off.isEnabled = false
        add(off)
        let field = NSTextField(string: "wea")
        field.setAccessibilityLabel("Search")
        field.identifier = NSUserInterfaceItemIdentifier("search-field")
        add(field)
        let secret = NSSecureTextField(string: "hunter2")
        secret.setAccessibilityLabel("Token")
        add(secret)
        let slider = NSSlider(value: 40, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.setAccessibilityLabel("Volume")
        add(slider)
        let level = LevelSlider(label: "Level")
        level.value = 12.345
        add(level)
        let popUp = ActionPopUp("Mode", items: ["Automatic", "On"], selected: 1) { _ in }
        add(popUp)
        let hidden = NSButton(title: "Hidden", target: nil, action: nil)
        hidden.isHidden = true
        add(hidden)
        add(NSTextField(labelWithString: ""))
        let auto = NSButton(title: "Start", target: nil, action: nil)
        auto.identifier = NSUserInterfaceItemIdentifier("_NS:42")
        add(auto)

        let outline = Outline.text(for: root)
        XCTAssertEqual(outline, """
        "Focus"
        [Button] "Start" #timer-start
        [Toggle] "Sounds" checked
        [Toggle] "Note" #feature-note checked
        [Toggle] "Weather" disabled
        [Field] "Search" #search-field value="wea"
        [SecureField] "Token"
        [Slider] "Volume" 40 of 100
        [Slider] "Level" 12.35 of 100
        [PopUp] "Mode" value="On"
        [Button] "Start"

        """)
        XCTAssertFalse(outline.contains("hunter2"))
        assertParses(outline)
    }

    func testNestingTabsAndOwnTitles() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Pure containers add no line; their children keep the parent's depth.
        let outer = NSView(), inner = NSStackView()
        place(outer, in: root, y: 100, width: 380, height: 190)
        place(inner, in: outer, y: 10, width: 360, height: 170)
        let bar = TabBar(items: [("home", "house", "Home"), ("timer", "timer", "Timer")], selected: 1) { _ in }
        place(bar, in: inner, y: 120, width: 200, height: 34)
        // A row whose own title is repeated inside it: only the detail stays, one level deeper.
        let hit = HoverButton("", style: .row, label: "Weather") {}
        place(hit, in: inner, y: 60, width: 300, height: 44)
        place(NSTextField(labelWithString: "Weather"), in: hit, y: 22)
        place(NSTextField(labelWithString: "Budapest\t12°"), in: hit, y: 2)
        let icon = HoverButton(symbol: "gearshape", style: .icon, label: "Settings") {}
        icon.identifier = NSUserInterfaceItemIdentifier("open-settings")
        place(icon, in: inner, y: 20, width: 32, height: 30)
        bar.layoutSubtreeIfNeeded()

        let outline = Outline.text(for: root)
        XCTAssertEqual(outline, """
        [Tab] "Home" #tab-home
        [Tab] "Timer" #tab-timer selected
        [Item] "Weather"
          "Budapest\\t12°"
        [Button] "Settings" #open-settings

        """)
        assertParses(outline)
    }

    func testEscapingAndScrolledOutContent() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scroll.hasVerticalScroller = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 280, height: 1000))
        scroll.documentView = document
        root.addSubview(scroll)
        place(NSTextField(labelWithString: #"Say "hi" \ then"# + "\nleave"), in: document, y: 10, height: 40)
        place(NSTextField(labelWithString: "Far below"), in: document, y: 900)
        let note = NSTextView(frame: NSRect(x: 0, y: 120, width: 200, height: 60))
        note.string = "line one\r\nline two"
        note.setAccessibilityLabel("Note")
        root.addSubview(note)

        let outline = Outline.text(for: root)
        XCTAssertEqual(outline, """
        "Say \\"hi\\" \\\\ then\\nleave"
        [Field] "Note" value="line one\\nline two"

        """)
        XCTAssertFalse(outline.contains("Scroller"))
        assertParses(outline)
    }

    func testCustomAccessibilityRolesLinksAndIllustrations() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let usage = NSView()
        usage.setAccessibilityElement(true)
        usage.setAccessibilityRole(.levelIndicator)
        usage.setAccessibilityValue("40 percent used")
        place(usage, in: root, y: 160, height: 5)
        let link = NSButton(title: "", target: nil, action: nil)
        link.attributedTitle = NSAttributedString(string: "yr.no", attributes: [.link: URL(string: "https://yr.no")!])
        place(link, in: root, y: 120)
        let art = NSView()
        art.setAccessibilityElement(true)
        art.setAccessibilityRole(.image)
        place(art, in: root, y: 20, width: 200, height: 80)
        place(NSTextField(labelWithString: "9:41"), in: art, y: 10)

        let outline = Outline.text(for: root)
        XCTAssertEqual(outline, """
        [Progress] 40 of 100
        [Link] "yr.no"

        """)
        assertParses(outline)
    }

    func testNumbersAndQuoting() {
        XCTAssertEqual(Outline.number(40), "40")
        XCTAssertEqual(Outline.number(0.5), "0.5")
        XCTAssertEqual(Outline.number(1.005), "1") // rounds to two decimals
        XCTAssertEqual(Outline.number(-3), "0")
        XCTAssertEqual(Outline.quote("a\tb\n\"c\"\\"), #""a\tb\n\"c\"\\""#)
    }

    func testDiagnosticOptions() {
        let options = DiagnosticOptions(arguments: ["QNotch", "--smoke-test", "/tmp/smoke", "--only", "tab-*, settings-general,,", "--appearance", "dark"], environment: [:])
        XCTAssertNil(options.problem)
        XCTAssertEqual(options.only, ["tab-*", "settings-general"])
        XCTAssertEqual(options.appearance, .dark)
        XCTAssertTrue(options.includes("tab-timer"))
        XCTAssertTrue(options.includes("tab-home-edit.png"))
        XCTAssertTrue(options.includes("settings-general"))
        XCTAssertFalse(options.includes("settings-general-2"))
        XCTAssertFalse(options.includes("pill"))
        XCTAssertTrue(DiagnosticOptions(arguments: [], environment: [:]).includes("anything"))

        XCTAssertTrue(DiagnosticOptions.matches("onboarding-open-tried", pattern: "onboarding-*-tried"))
        XCTAssertTrue(DiagnosticOptions.matches("pill", pattern: "*"))
        XCTAssertTrue(DiagnosticOptions.matches("card-note", pattern: "*note"))
        XCTAssertTrue(DiagnosticOptions.matches("aXbXc", pattern: "a*b*c"))
        XCTAssertFalse(DiagnosticOptions.matches("a", pattern: "a*a"))
        XCTAssertFalse(DiagnosticOptions.matches("tab-home", pattern: "tab"))

        XCTAssertEqual(DiagnosticOptions(arguments: [], environment: ["QNOTCH_MAC_DATA_DIR": "/tmp/env"]).dataDirectory, "/tmp/env")
        XCTAssertEqual(DiagnosticOptions(arguments: ["--data-dir", "/tmp/arg"], environment: ["QNOTCH_MAC_DATA_DIR": "/tmp/env"]).dataDirectory, "/tmp/arg")
        XCTAssertNotNil(DiagnosticOptions(arguments: ["--appearance", "sepia"], environment: [:]).problem)
        XCTAssertNotNil(DiagnosticOptions(arguments: ["--only"], environment: [:]).problem)
        XCTAssertEqual(DiagnosticOptions(arguments: ["--appearance", "light"], environment: [:]).nsAppearance?.name, .aqua)
    }
}
