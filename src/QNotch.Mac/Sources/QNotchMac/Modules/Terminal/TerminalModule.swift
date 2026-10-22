import AppKit

/// Module owns the shell; closing/switching panels only hides its view. Diagnostics always
/// use deterministic bytes and a fake input sink, never start a shell or execute a command.
final class TerminalModule: NotchModule {
    private(set) var session: TerminalSession?
    private(set) var screen = TerminalScreen()
    private(set) var status = "Opens your login shell in your home folder"
    private(set) var demoInput = Data()
    private weak var view: TerminalTabView?
    private var visible = false

    func initialize(_ context: ModuleContext) {
        context.registries.tabs.register(ViewContribution(id: "terminal", title: "Terminal", order: 95, symbol: "terminal") { [unowned self] in
            let view = TerminalTabView(module: self)
            self.view = view
            return view
        })
        if Runtime.diagnostics {
            status = "Demo session · no commands run"
            screen.feed(Data("\u{1B}[36mguest@mac\u{1B}[0m ~ % printf 'Hello from QNotch\\n'\r\nHello from QNotch\r\n\u{1B}[36mguest@mac\u{1B}[0m ~ % ".utf8))
        }
    }

    func setVisibility(panel: Bool, activeTab: String) {
        visible = panel && activeTab == "terminal"
        if visible {
            startIfNeeded()
            view?.refresh()
        }
    }
    func systemDidWake() {}
    func stop() { visible = false; session?.stop(); session = nil }

    private func startIfNeeded() {
        guard session == nil, !Runtime.diagnostics else { return }
        let session = TerminalSession()
        self.session = session
        screen.reply = { [weak session] in session?.send($0) }
        session.output = { [weak self] bytes in
            guard let self else { return }
            self.screen.feed(bytes)
            if self.visible { self.view?.refresh() }
        }
        session.ended = { [weak self] _ in
            self?.status = "Session ended · turn Terminal off and on to start again"
            self?.view?.refresh()
        }
        do {
            try session.start(columns: screen.columns, rows: screen.rows)
            status = "Login shell · session stays alive when the panel closes"
        } catch {
            status = "Shell unavailable · turn Terminal off and on to retry"
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns != screen.columns || rows != screen.rows else { return }
        screen.resize(columns: columns, rows: rows)
        session?.resize(columns: screen.columns, rows: screen.rows)
    }
    func send(_ bytes: Data) {
        if Runtime.diagnostics { demoInput.append(bytes.prefix(max(0, 64 * 1024 - demoInput.count))) }
        else { session?.send(bytes) }
    }
}

final class TerminalTabView: NSView, PanelKeyboardContent {
    private let module: TerminalModule
    private let scroll = NSScrollView()
    let terminal: TerminalCanvas
    private let footer = line("", size: 10, color: Palette.textTertiary)
    private var heading: NSStackView!

    init(module: TerminalModule) {
        self.module = module
        terminal = TerminalCanvas(module: module)
        super.init(frame: .zero)
        let help = line("Quick commands · ⌘V paste · ⌘C copy selection · ⌘F search · ⌃⌥N close", size: 10, color: Palette.textTertiary)
        heading = row([help, spacer()], spacing: 8)
        scroll.documentView = terminal
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        scroll.layer?.cornerRadius = 8
        for view in [heading!, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 32)
        heading.frame = NSRect(x: 16, y: bounds.height - 42, width: width, height: 26)
        footer.frame = NSRect(x: 16, y: 16, width: width, height: 14)
        scroll.frame = NSRect(x: 16, y: 40, width: width, height: max(0, bounds.height - 92))
        scroll.tile()
        let size = scroll.contentSize
        guard size.width > 20, size.height > 20 else { return }
        module.resize(columns: Int((size.width - 12) / TerminalCanvas.cellWidth), rows: Int((size.height - 8) / TerminalCanvas.cellHeight))
        refresh()
    }
    func focusKeyboard() { window?.makeFirstResponder(terminal) }
    func refresh() {
        footer.stringValue = module.status
        terminal.refresh(width: scroll.contentSize.width)
    }
}

/// A cell canvas with AppKit text input/IME and plain-text selection. No web view, scripting,
/// URL opening, OSC clipboard access or persistent transcript. Rendering happens only on output.
final class TerminalCanvas: NSView, NSTextInputClient {
    static let cellWidth: CGFloat = 7.85, cellHeight: CGFloat = 16
    private let module: TerminalModule
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var marked = NSAttributedString(string: "")
    private var anchor: Int?
    private var selection: Range<Int>?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(module: TerminalModule) {
        self.module = module
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("terminal-input")
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal input and output")
        setAccessibilityHelp("Type commands. Control C interrupts. Control Option N closes the panel. Command C copies selected output.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(width: CGFloat) {
        let visible = visibleRect
        let atBottom = visible.maxY >= bounds.maxY - Self.cellHeight * 2
        setFrameSize(NSSize(width: max(1, width), height: CGFloat(module.screen.lines.count) * Self.cellHeight + 8))
        // History eviction invalidates old selections; keep offsets bounded.
        if let range = selection, range.upperBound > module.screen.lines.count * module.screen.columns { selection = nil }
        if atBottom { scrollToEndOfDocument(nil) }
        setAccessibilityValue(module.screen.plainText)
        needsDisplay = true
    }
    override func scrollToEndOfDocument(_ sender: Any?) { scroll(NSPoint(x: 0, y: max(0, bounds.height - (enclosingScrollView?.contentSize.height ?? 0)))) }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = offset(convert(event.locationInWindow, from: nil)); selection = nil; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let end = offset(convert(event.locationInWindow, from: nil))
        selection = min(anchor, end)..<max(anchor, end); needsDisplay = true
        autoscroll(with: event)
    }
    private func offset(_ point: NSPoint) -> Int {
        let screen = module.screen
        let y = min(screen.lines.count - 1, max(0, Int((point.y - 4) / Self.cellHeight)))
        let x = min(screen.columns, max(0, Int((point.x - 6) / Self.cellWidth)))
        return y * screen.columns + x
    }

    override func draw(_ dirtyRect: NSRect) {
        let screen = module.screen, lines = screen.lines
        let first = max(0, Int(dirtyRect.minY / Self.cellHeight) - 1)
        let last = min(lines.count, Int(dirtyRect.maxY / Self.cellHeight) + 1)
        guard first < last else { return }
        for row in first..<last {
            for (column, cell) in lines[row].enumerated() {
                let rect = NSRect(x: 6 + CGFloat(column) * Self.cellWidth, y: 4 + CGFloat(row) * Self.cellHeight, width: Self.cellWidth, height: Self.cellHeight)
                let selected = selection?.contains(row * screen.columns + column) == true
                let fg = color(cell.style.inverse ? cell.style.background : cell.style.foreground, foreground: true)
                let bg = color(cell.style.inverse ? cell.style.foreground : cell.style.background, foreground: false)
                (selected ? NSColor.selectedTextBackgroundColor : bg).setFill(); rect.fill()
                if !cell.continuation {
                    (cell.text as NSString).draw(at: rect.origin, withAttributes: [.font: cell.style.bold ? NSFont.monospacedSystemFont(ofSize: 13, weight: .bold) : font,
                                                                               .foregroundColor: fg])
                }
            }
        }
        if screen.cursorVisible {
            let historyRows = lines.count - screen.rows
            let rect = NSRect(x: 6 + CGFloat(screen.x) * Self.cellWidth, y: 4 + CGFloat(historyRows + screen.y) * Self.cellHeight, width: Self.cellWidth, height: Self.cellHeight)
            NSColor.systemCyan.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            if !marked.string.isEmpty { (marked.string as NSString).draw(at: rect.origin, withAttributes: [.font: font, .foregroundColor: NSColor.white, .backgroundColor: NSColor.darkGray]) }
        }
    }
    private func color(_ index: Int, foreground: Bool) -> NSColor {
        if index < 0 { return foreground ? NSColor(white: 0.9, alpha: 1) : .clear }
        let colors: [NSColor] = [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan, .lightGray,
                                 .darkGray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPink, .systemCyan, .white]
        if index < 16 { return colors[index] }
        if index >= 232 { return NSColor(white: CGFloat(8 + (index - 232) * 10) / 255, alpha: 1) }
        let c = index - 16
        func channel(_ n: Int) -> CGFloat { n == 0 ? 0 : CGFloat(55 + n * 40) / 255 }
        return NSColor(red: channel(c / 36), green: channel(c / 6 % 6), blue: channel(c % 6), alpha: 1)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if let bytes = Self.key(event, applicationCursor: module.screen.applicationCursor) { module.send(bytes) }
        else { interpretKeyEvents([event]) }
    }
    static func key(_ event: NSEvent, applicationCursor: Bool) -> Data? {
        let prefix = applicationCursor ? "\u{1B}O" : "\u{1B}["
        let keys: [UInt16: String] = [36: "\r", 76: "\r", 48: "\t", 51: "\u{7F}", 53: "\u{1B}",
            123: prefix + "D", 124: prefix + "C", 125: prefix + "B", 126: prefix + "A",
            115: "\u{1B}[H", 119: "\u{1B}[F", 117: "\u{1B}[3~", 116: "\u{1B}[5~", 121: "\u{1B}[6~"]
        if let key = keys[event.keyCode] { return Data(key.utf8) }
        if event.modifierFlags.contains(.control), let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            if (64...95).contains(scalar.value) || (97...122).contains(scalar.value) { return Data([UInt8(scalar.value & 31)]) }
            if scalar == " " { return Data([0]) }
        }
        if event.modifierFlags.contains(.option), let text = event.charactersIgnoringModifiers { return Data(("\u{1B}" + text).utf8) }
        return nil
    }
    @objc func copy(_ sender: Any?) {
        guard let selection else { return }
        let screen = module.screen
        let text = screen.lines.enumerated().compactMap { row, cells -> String? in
            let start = max(0, selection.lowerBound - row * screen.columns), end = min(cells.count, selection.upperBound - row * screen.columns)
            return start < end ? TerminalScreen.text(Array(cells[start..<end])) : nil
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 64 * 1024 - 12 else { return }
        // Strip embedded control sequences from pasted text. Newlines still submit commands.
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" || $0 == "\r" || $0 == "\t" }))
        let normalized = clean.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        let bytes = module.screen.bracketedPaste ? "\u{1B}[200~" + normalized + "\u{1B}[201~" : normalized
        module.send(Data(bytes.utf8))
    }
    override func selectAll(_ sender: Any?) { selection = 0..<(module.screen.lines.count * module.screen.columns); needsDisplay = true }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSAttributedString(string: ""); module.send(Data(text.utf8)); needsDisplay = true
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = NSAttributedString(string: (string as? NSAttributedString)?.string ?? (string as? String ?? "")); needsDisplay = true
    }
    func unmarkText() { marked = NSAttributedString(string: ""); needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let screen = module.screen
        let rect = NSRect(x: 6 + CGFloat(screen.x) * Self.cellWidth, y: 4 + CGFloat(screen.lines.count - screen.rows + screen.y) * Self.cellHeight, width: Self.cellWidth, height: Self.cellHeight)
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
    override func doCommand(by selector: Selector) {} // Mapped terminal keys never reach AppKit editing commands.
}
