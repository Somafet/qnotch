import AppKit
import QNotchMacCore

/// A quick note on a Home card (Windows NoteModule). `note.txt` is loaded off the main thread,
/// saved 500 ms after the last keystroke with an atomic write, and flushed when QNotch quits.
/// Nothing runs while idle.
final class NoteModule: NotchModule {
    enum Status { case saved, editing, failed }

    private var context: ModuleContext!
    private let io = DispatchQueue(label: "qnotch.note", qos: .utility)
    private var url: URL!
    private(set) var text = ""
    private(set) var status = Status.saved
    private(set) var modified: Date?
    private var edited = false
    private var pending: DispatchWorkItem?
    private var revision = 0
    private weak var card: NoteCardView?

    func initialize(_ context: ModuleContext) {
        self.context = context
        url = context.settings.directory.appendingPathComponent("note.txt")
        context.registries.cards.register(ViewContribution(id: "note", title: "Note", order: 45, symbol: "note.text") { [unowned self] in
            let card = NoteCardView(module: self)
            self.card = card
            return card
        })
        context.registries.searchSources.register(SearchSource(id: "note", order: 30) { [weak self] query in
            guard let self else { return [] }
            return NoteText.matches(of: query, in: self.text).map { snippet in
                SearchHit(title: snippet, detail: "Note · opens Home", symbol: "note.text") { [weak self] in
                    self?.context.shell?.selectTab("home")
                    self?.card?.focus()
                }
            }
        })
        let url = url!
        io.async { [weak self] in
            let loaded = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            DispatchQueue.main.async {
                // Typing before the load finished wins.
                guard let self, !self.edited else { return }
                self.text = String(loaded.prefix(NoteText.maxLength))
                self.modified = date
                self.card?.reload()
            }
        }
    }

    func setVisibility(panel: Bool, activeTab: String) {
        if !panel { flush() }
    }
    func systemDidWake() {}
    func stop() { flush(wait: true) }

    func edit(_ value: String) {
        edited = true
        text = String(value.prefix(NoteText.maxLength))
        status = .editing
        pending?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.save() }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
        card?.refreshFooter()
    }

    private func flush(wait: Bool = false) {
        guard let pending, !pending.isCancelled else { return }
        pending.cancel()
        save(wait: wait)
    }

    private func save(wait: Bool = false) {
        Analytics.record("notes", "save")
        pending = nil
        revision += 1
        let snapshot = text, revision = revision, url = url!, directory = context.settings.directory
        let write = { [weak self] in
            var ok = true
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(snapshot.utf8).write(to: url, options: .atomic)
            } catch { ok = false }
            let finish = {
                guard let self, self.revision == revision else { return }
                self.status = ok ? .saved : .failed
                if ok { self.modified = Date() }
                self.card?.refreshFooter()
            }
            if wait { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
        if wait { io.sync(execute: write) } else { io.async(execute: write) }
    }
}

// MARK: - Home card

private final class NoteCardView: NSView, NSTextViewDelegate {
    private weak var module: NoteModule?
    private let scroll = NSScrollView()
    private let editor = NoteTextView()
    private let footer = line("", size: 11, color: Palette.textTertiary)
    private let state = NSImageView()

    init(module: NoteModule) {
        self.module = module
        super.init(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = Palette.textPrimary
        editor.insertionPointColor = Palette.accent
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.autoresizingMask = .width
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.setAccessibilityLabel("Note")
        editor.placeholder = "Jot something down"
        scroll.documentView = editor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        state.setAccessibilityElement(false)
        let bottom = row([footer, spacer(), state], spacing: 6)
        let stack = column([scroll, bottom], spacing: 6)
        embed(stack, in: self, inset: 0, fill: true)
        for view in [scroll, bottom] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module, editor.string != module.text else { return refreshFooter() }
        editor.string = module.text
        refreshFooter()
    }

    func focus() {
        guard window?.isKeyWindow == true else { return }
        window?.makeFirstResponder(editor)
    }

    func textDidChange(_ notification: Notification) {
        if editor.string.count > NoteText.maxLength { editor.string = String(editor.string.prefix(NoteText.maxLength)) }
        module?.edit(editor.string)
    }

    func refreshFooter() {
        guard let module else { return }
        let words = NoteText.words(in: module.text)
        let date = module.modified.map { Self.date.string(from: $0) + " · " } ?? ""
        footer.stringValue = date + (words == 1 ? "1 word" : "\(words) words")
        let (name, color, label): (String, NSColor, String) = switch module.status {
        case .saved: ("checkmark.circle.fill", .systemGreen, "Saved")
        case .editing: ("pencil", Palette.textTertiary, "Editing")
        case .failed: ("exclamationmark.triangle.fill", .systemRed, "Not saved")
        }
        state.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        state.contentTintColor = color
        state.toolTip = label
        footer.setAccessibilityLabel(footer.stringValue + ". " + label)
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()
}

/// Escape closes the panel (instead of completion), and an empty note shows a placeholder.
private final class NoteTextView: NSTextView {
    var placeholder = ""
    override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: [
            .font: font ?? .systemFont(ofSize: 13), .foregroundColor: Palette.textTertiary
        ])
    }
    override func didChangeText() {
        super.didChangeText()
        if string.count <= 1 { needsDisplay = true }
    }
}
