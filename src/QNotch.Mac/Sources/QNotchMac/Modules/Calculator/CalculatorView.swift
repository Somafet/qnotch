import AppKit
import CalculatorEngine

/// Increase Contrast: stronger hairlines and no soft shadows. The Calculator's surfaces are already solid, so
/// Reduce Transparency changes nothing here.
enum CalculatorContrast {
    static var increased: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var stroke: NSColor { increased ? Palette.textTertiary : Palette.stroke }
    static var strongStroke: NSColor { increased ? Palette.textSecondary : Palette.strokeStrong }
    static func shadow(_ layer: CALayer?, opacity: Float, radius: CGFloat, y: CGFloat) {
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = increased ? 0 : opacity
        layer?.shadowRadius = radius
        layer?.shadowOffset = CGSize(width: 0, height: y)
    }
}

/// The tab's cheap host. The editor, the engine and the sheets load the first time the tab shows.
final class CalculatorHostView: NSView, PanelKeyboardContent {
    private weak var module: CalculatorModule?
    private(set) var page: CalculatorTabView?
    private var loading = false
    private var focusWhenReady = false

    init(module: CalculatorModule) {
        self.module = module
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("calculator")
        // A snapshot renders this tab at once, so demo data must be there before it draws.
        if Runtime.diagnostics { load() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        guard page == nil, !loading, let module else { return }
        loading = true
        module.withWorkspace { [weak self] workspace in
            guard let self else { return }
            self.loading = false
            guard let workspace else {
                let failed = placeholder(symbol: "plus.forwardslash.minus", title: "Calculator unavailable", detail: "Your sheets were not changed.")
                embed(failed, in: self, inset: 0, fill: true)
                return
            }
            let page = CalculatorTabView(workspace: workspace, shell: module.shell)
            self.page = page
            page.translatesAutoresizingMaskIntoConstraints = true
            page.autoresizingMask = [.width, .height]
            page.frame = self.bounds
            self.addSubview(page)
            if self.focusWhenReady { self.focusWhenReady = false; page.focusKeyboard() }
        }
    }

    func focusKeyboard() {
        if let page { page.focusKeyboard() } else { focusWhenReady = true; load() }
    }
}

/// The Calculator tab (Windows CalculatorSurface): the sheet tabs with the page's status and menu above a card
/// that holds the editor and the live results beside each line, the closed-sheet notice, and in-panel cards
/// (hover details, explanation, rename, all sheets) anchored to what opened them.
final class CalculatorTabView: NSView, SheetEditorHost, ResultPillHost, SheetTabStripDelegate, PanelKeyboardContent {
    static let headerHeight: CGFloat = 30
    static let baseGutter: CGFloat = 220

    let workspace: CalculatorWorkspace
    private weak var shell: ModuleShell?
    let strip = SheetTabStrip()
    let status = line("", size: 11, color: Palette.textSecondary)
    let more = HoverButton(symbol: "ellipsis", style: .icon, symbolSize: 13, label: CalculatorText.sheets) {}
    /// What the sheet converts money with; shown only while it does (Windows CurrencyRatesAction).
    let ratesButton = HoverButton("", style: .plain, label: CalculatorText.currencyRates) {}
    let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: 14)
    let scroll = SheetScrollView()
    let results = ResultsColumn()
    let notice = NoticeBar()
    private let overlay = OverlayLayer()
    private var editors: [UUID: SheetTextView] = [:]
    private var editorOrder: [UUID] = []
    private var scrollPositions: [UUID: NSPoint] = [:]
    private(set) var editor: SheetTextView!
    private(set) var pills: [Int: ResultPill] = [:]
    private var observation: AnyObject?
    private var hoverTask: DispatchWorkItem?
    private(set) var hoverCard: ResultCardView?
    private weak var hoverPill: ResultPill?
    private var lastCardHidden = Date.distantPast
    private var gutter = baseGutter
    private var noticeShown: CalculatorWorkspace.Notice?
    private var contrastObserver: NSObjectProtocol?

    init(workspace: CalculatorWorkspace, shell: ModuleShell?) {
        self.workspace = workspace
        self.shell = shell
        super.init(frame: NSRect(x: 0, y: 0, width: 676, height: 300))
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("calculator-page")
        strip.delegate = self
        more.handler = { [weak self] in self?.showSheetMenu() }
        more.identifier = NSUserInterfaceItemIdentifier("calculator-more")
        more.refusesFirstResponder = true
        status.identifier = NSUserInterfaceItemIdentifier("calculator-status")
        status.alignment = .right
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ratesButton.identifier = NSUserInterfaceItemIdentifier("calculator-rates")
        ratesButton.font = .systemFont(ofSize: 11, weight: .medium)
        ratesButton.padding = NSSize(width: 8, height: 3)
        ratesButton.refusesFirstResponder = true
        ratesButton.handler = { [weak self] in self?.showRatesMenu() }
        ratesButton.isHidden = true
        for view in [strip, status, ratesButton, more, card, notice, overlay] as [NSView] { addSubview(view) }
        card.addSubview(scroll)
        card.addSubview(results)
        results.scroll = scroll
        results.host = self
        notice.undo.handler = { [weak self] in self?.workspace.undoClose() }
        notice.isHidden = true
        overlay.isHidden = true
        overlay.dismiss = { [weak self] in self?.closeOverlay(returnFocus: true) }
        scroll.scrolled = { [weak self] in self?.scrolled() }
        observation = workspace.observe { [weak self] change in self?.apply(change) }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                             object: nil, queue: .main) { [weak self] _ in self?.applyContrast() }
        applyContrast()
        showEditor()
        strip.show(workspace.tabs.visible, active: workspace.activeID)
        refreshStatus()
        refreshRates()
        refreshNotice(animated: false)
        layoutResults()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    deinit {
        if let contrastObserver { NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver) }
    }

    private func applyContrast() {
        card.stroke = CalculatorContrast.stroke
        notice.stroke = CalculatorContrast.strongStroke
        CalculatorContrast.shadow(notice.layer, opacity: 0.35, radius: 8, y: -3)
        strip.applyContrast()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let header = Self.headerHeight
        more.frame = NSRect(x: width - 30, y: (header - 28) / 2, width: 30, height: 28)
        var right = more.frame.minX
        if !ratesButton.isHidden {
            let size = ratesButton.intrinsicContentSize
            let ratesWidth = min(190, size.width)
            ratesButton.frame = NSRect(x: right - 4 - ratesWidth, y: ((header - size.height) / 2).rounded(), width: ratesWidth, height: size.height)
            right = ratesButton.frame.minX
        }
        let statusWidth = min(170, ceil(status.intrinsicContentSize.width))
        status.isHidden = status.stringValue.isEmpty
        let statusX = right - 6 - (status.isHidden ? 0 : statusWidth)
        status.frame = NSRect(x: statusX, y: (header - 14) / 2, width: status.isHidden ? 0 : statusWidth, height: 14)
        strip.frame = NSRect(x: 0, y: 0, width: max(120, statusX - 8), height: header)
        card.frame = NSRect(x: 0, y: header + 6, width: width, height: max(0, bounds.height - header - 6))
        layoutCard()
        overlay.frame = bounds
        layoutNotice()
    }

    private func layoutCard() {
        // The editor spans the gutter, so its scroller lands on the card edge, not between source and results.
        scroll.frame = NSRect(x: 14, y: 1, width: max(0, card.bounds.width - 18), height: max(0, card.bounds.height - 2))
        editor?.reserved = gutter + 24
        let columnWidth = gutter
        results.frame = NSRect(x: scroll.frame.maxX - 10 - columnWidth, y: scroll.frame.minY, width: columnWidth, height: scroll.frame.height)
        layoutResults()
    }

    private func layoutNotice() {
        guard !notice.isHidden else { return }
        let size = notice.fittedSize(maxWidth: min(460, card.bounds.width - 40))
        notice.frame = NSRect(x: card.frame.minX + (card.bounds.width - size.width) / 2, y: card.frame.maxY - 10 - size.height, width: size.width, height: size.height)
    }

    // MARK: Editors

    /// The sheet in front's editor. Recent editors are kept (four, as Windows) so their undo stacks survive.
    private func showEditor() {
        let id = workspace.activeID
        if let current = editor, current.sheetID != id { scrollPositions[current.sheetID] = scroll.contentView.bounds.origin }
        var next = editors[id]
        if next == nil || next?.string != workspace.source {
            next = SheetTextView(sheetID: id, text: workspace.source, fontSize: CGFloat(workspace.displayed.resolvedFontSize))
            editors[id] = next
        }
        guard let next else { return }
        next.host = self
        editorOrder.removeAll { $0 == id }
        editorOrder.append(id)
        while editorOrder.count > 4 { editors[editorOrder.removeFirst()] = nil }
        let hadFocus = window?.firstResponder is SheetTextView || window?.firstResponder is ResultPill
        editor = next
        next.reserved = gutter + 24
        next.frame = NSRect(origin: .zero, size: NSSize(width: scroll.contentSize.width, height: max(next.frame.height, scroll.contentSize.height)))
        scroll.documentView = next
        if let position = scrollPositions[id] { scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView) }
        clearPills()
        if hadFocus { window?.makeFirstResponder(next) }
    }

    func focusKeyboard() {
        if let field = overlay.focus { window?.makeFirstResponder(field); return }
        window?.makeFirstResponder(editor)
    }

    // MARK: Workspace changes

    private func apply(_ change: CalculatorWorkspace.Change) {
        switch change {
        case .sheet:
            closeOverlay(returnFocus: false)
            hideCard(animated: false)
            showEditor()
            layoutResults()
        case .tabs(let tabChange):
            let stripChange: SheetTabStrip.Change
            switch tabChange {
            case .closed(let id, let keeping): stripChange = .closed(id, keepingPlace: keeping)
            case .restored(let id): stripChange = .restored(id)
            case .created(let id): stripChange = .created(id)
            case .refreshed, .renamed: stripChange = .none
            }
            strip.show(workspace.tabs.visible, active: workspace.activeID, change: stripChange)
            for id in editors.keys where !workspace.documents.sheets.contains(where: { $0.id == id }) {
                editors[id] = nil
                editorOrder.removeAll { $0 == id }
            }
        case .results:
            updateGutter()
            layoutResults()
        case .notice:
            refreshNotice(animated: true)
        case .status:
            refreshStatus()
        case .rates:
            refreshRates()
        case .visibility:
            // An open card holds the panel open; it belongs to the page on screen.
            if !workspace.visible { closeOverlay(returnFocus: false); hideCard(animated: false) }
        case .preferences:
            let size = CGFloat(workspace.displayed.resolvedFontSize)
            for editor in editors.values { editor.fontSize = size }
            clearPills()
            layoutResults()
        }
    }

    private func refreshStatus() {
        status.stringValue = workspace.status
        status.toolTip = workspace.status.isEmpty ? nil : workspace.status
        needsLayout = true
    }

    /// The rates button follows the sheet in front; an open rates menu follows a download.
    private func refreshRates() {
        let currencies = workspace.currencies
        let shown = currencies.uses
        if shown {
            let status = currencies.status
            ratesButton.text = status
            ratesButton.toolTip = currencies.tip
            ratesButton.setAccessibilityLabel(CalculatorText.currencyRatesName(status))
        }
        if ratesButton.isHidden == shown { ratesButton.isHidden = !shown }
        if let menu = overlay.content as? RatesMenuCard {
            if shown { menu.show(currencies.menuEntries(automatic: workspace.preferences.autoCurrencyRates)) } else { closeOverlay(returnFocus: true) }
        }
        needsLayout = true
    }

    /// The rates menu, anchored under its button (Windows ShowCurrencyRates).
    func showRatesMenu() {
        let currencies = workspace.currencies
        let menu = RatesMenuCard(entries: currencies.menuEntries(automatic: workspace.preferences.autoCurrencyRates))
        menu.run = { [weak self] id in
            guard let self else { return }
            self.closeOverlay(returnFocus: true)
            if !currencies.perform(id, workspace: self.workspace), id == CalculatorCurrencies.sourceID { currencies.openSource() }
        }
        menu.escape = { [weak self] in self?.closeOverlay(returnFocus: true) }
        present(menu, width: RatesMenuCard.width, anchor: ratesButton.isHidden ? more : ratesButton, focus: menu)
    }

    private func refreshNotice(animated: Bool) {
        let next = workspace.notice
        guard next != noticeShown else { return }
        let wasShown = noticeShown != nil
        noticeShown = next
        if let next {
            notice.set(text: next.text, undo: next.undo, tip: next.tip)
            notice.isHidden = false
            notice.layer?.removeAllAnimations()
            layoutNotice()
            // It rises from the card's bottom edge and goes back the same way.
            if animated, !wasShown { Motion.enter(notice, duration: 0.22, up: -8) }
            else if animated { Motion.crossfade(notice) }
        } else if animated, !notice.isHidden {
            Motion.leave(notice, duration: 0.16, up: -8) { [weak self] in
                guard let self, self.noticeShown == nil else { return }
                self.notice.isHidden = true
                self.notice.layer?.removeAllAnimations()
            }
        } else {
            notice.isHidden = true
        }
    }

    // MARK: Results beside each line

    /// Timestamps and network addresses are part of their value: the column widens for them, bounded so the
    /// sheet keeps room to edit.
    private func updateGutter() {
        let wide: Set<String> = ["LocalTimestamp", "ZonedMoment", "Network"]
        var width = Self.baseGutter
        let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(workspace.displayed.resolvedFontSize), weight: .semibold)
        for line in workspace.lines where line.kind.map(wide.contains) == true {
            width = max(width, ceil((CalculatorResultText.shown(line) as NSString).size(withAttributes: [.font: font]).width) + 48)
        }
        width = min(width, max(Self.baseGutter, card.bounds.width - 240))
        guard abs(width - gutter) > 0.5 else { return }
        gutter = width
        layoutCard()
    }

    private func clearPills() {
        let focused = pills.values.contains { window?.firstResponder === $0 }
        for pill in pills.values { pill.removeFromSuperview() }
        pills.removeAll()
        hideCard(animated: false)
        if focused { window?.makeFirstResponder(editor) }
    }

    private func scrolled() {
        hideCard(animated: false)
        layoutResults()
    }

    /// Places a pill beside the first row of every visible line with a result. Only lines in view get one.
    func layoutResults() {
        guard let editor, let layoutManager = editor.layoutManager, results.bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: editor.textContainer!)
        let visible = scroll.contentView.bounds
        guard let range = editor.lines(in: visible) else { return clearPills() }
        let current: [Substring] = workspace.evaluatedSource == workspace.source ? [] : workspace.source.split(separator: "\n", omittingEmptySubsequences: false)
        var keep = Set<Int>()
        let fontSize = CGFloat(workspace.displayed.resolvedFontSize)
        let text = editor.string as NSString
        let starts = editor.lineStarts
        for index in range {
            guard let result = workspace.result(forLine: index, of: current), CalculatorResultText.isShown(result),
                  let row = editor.rowRect(ofLine: index) else { continue }
            let top = row.minY - visible.minY
            guard top + row.height > 0, top < results.bounds.height else { continue }
            keep.insert(index)
            var pill = pills[index]
            if pill?.result != result {
                let focused = pill.map { window?.firstResponder === $0 } ?? false
                pill?.removeFromSuperview()
                let made = ResultPill(result: result, fontSize: fontSize)
                made.host = self
                results.addSubview(made)
                pills[index] = made
                pill = made
                if focused { window?.makeFirstResponder(made) }
            }
            guard let pill else { continue }
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : text.length
            if starts[index] <= end, end <= text.length {
                pill.expression = text.substring(with: NSRange(location: starts[index], length: end - starts[index])).trimmingCharacters(in: .whitespaces)
            }
            let width = min(results.bounds.width, pill.naturalWidth)
            pill.frame = NSRect(x: results.bounds.width - width, y: top, width: width, height: row.height)
            pill.needsDisplay = true
        }
        for (index, pill) in pills where !keep.contains(index) {
            if window?.firstResponder === pill { window?.makeFirstResponder(editor) }
            if hoverPill === pill { hideCard(animated: false) }
            pill.removeFromSuperview()
            pills[index] = nil
        }
        updateKeyLoop()
    }

    /// Tab order: the sheet, then its results top to bottom.
    private func updateKeyLoop() {
        let ordered = pills.sorted { $0.key < $1.key }.map(\.value)
        var previous: NSView = editor
        for pill in ordered { previous.nextKeyView = pill; previous = pill }
        previous.nextKeyView = nil
    }

    // MARK: SheetEditorHost

    func editorEscape() -> Bool {
        if !overlay.isHidden { closeOverlay(returnFocus: true); return true }
        return false
    }
    func editorCycleSheet(_ direction: Int) { workspace.cycle(direction) }
    func editorRename() { renameSheet(workspace.activeID) }
    /// ⌥⇥: the result of the caret's line, or the next one below it.
    func editorFocusResult() {
        let line = editor.line(at: editor.selectedRange().location)
        guard let target = pills.sorted(by: { $0.key < $1.key }).first(where: { $0.key >= line })?.value ?? pills.values.first else { NSSound.beep(); return }
        window?.makeFirstResponder(target)
    }
    func editorTextChanged(_ editor: SheetTextView) {
        guard editor === self.editor else { return }
        hideCard(animated: false)
        workspace.edit(editor.string, composing: editor.hasMarkedText())
        layoutResults()
    }

    // MARK: ResultPillHost

    func pillCopy(_ pill: ResultPill) {
        guard pill.copies else { return }
        if workspace.copy(pill.result) { pill.confirmCopy() }
        // A mouse copy returns typing to the sheet; a keyboard user stays on the result.
        if let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(event.type) { window?.makeFirstResponder(editor) }
    }

    func pillExplain(_ pill: ResultPill) {
        let text = CalculatorResultText.explanation(pill.result)
        guard !text.isEmpty else { NSSound.beep(); return }
        hideCard(animated: false)
        let card = ExplanationCard(text: text)
        card.close.handler = { [weak self] in self?.closeOverlay(returnFocus: true) }
        card.escape = { [weak self] in self?.closeOverlay(returnFocus: true) }
        present(card, width: 400, anchor: pill, focus: card.text)
    }

    func pillHover(_ pill: ResultPill, inside: Bool) {
        hoverTask?.cancel()
        if inside {
            // Quick to come back once a card was just showing.
            let delay = Date().timeIntervalSince(lastCardHidden) < 0.5 || hoverCard != nil ? 0.15 : 0.4
            let task = DispatchWorkItem { [weak self, weak pill] in
                guard let self, let pill, pill.superview != nil else { return }
                self.showCard(for: pill)
            }
            hoverTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        } else if hoverPill === pill, window?.firstResponder !== pill {
            hideCard(animated: true)
        }
    }

    func pillFocus(_ pill: ResultPill, focused: Bool) {
        if focused { showCard(for: pill) } else if hoverPill === pill { hideCard(animated: true) }
    }

    func pillMenu(_ pill: ResultPill, event: NSEvent) {
        hideCard(animated: false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(CalculatorText.copy, key: "c") { [weak self, weak pill] in if let pill { self?.pillCopy(pill) } })
        let explain = item(CalculatorText.explainMenu) { [weak self, weak pill] in if let pill { self?.pillExplain(pill) } }
        explain.isEnabled = CalculatorResultText.explains(pill.result)
        menu.addItem(explain)
        popUp(menu, at: convert(event.locationInWindow, from: nil))
    }

    func pillEscape() { window?.makeFirstResponder(editor) }

    func pillTyped(_ event: NSEvent) {
        window?.makeFirstResponder(editor)
        editor.keyDown(with: event)
    }

    // MARK: The hover card

    private func showCard(for pill: ResultPill) {
        guard overlay.isHidden, let model = CalculatorResultText.card(pill.result) else { return hideCard(animated: false) }
        if hoverPill === pill, hoverCard != nil { return }
        hideCard(animated: false)
        let view = ResultCardView(card: model)
        let size = view.fittedSize()
        let anchor = pill.convert(pill.bounds, to: self)
        var origin = NSPoint(x: min(bounds.width - size.width, anchor.maxX - size.width), y: anchor.maxY + 2)
        if origin.y + size.height > bounds.height - 4 { origin.y = anchor.minY - 2 - size.height }
        origin.x = max(0, origin.x)
        view.frame = NSRect(origin: origin, size: size)
        addSubview(view, positioned: .below, relativeTo: overlay)
        hoverCard = view
        hoverPill = pill
        // A short settle-in: a fade and a 4-point drop.
        Motion.enter(view, duration: 0.14, up: 4)
    }

    private func hideCard(animated: Bool) {
        hoverTask?.cancel()
        guard let view = hoverCard else { return }
        hoverCard = nil
        hoverPill = nil
        lastCardHidden = Date()
        if animated { Motion.leave(view, duration: 0.1) { view.removeFromSuperview() } } else { view.removeFromSuperview() }
    }

    // MARK: Overlays

    private var overlayHold: AnyObject?

    /// One in-panel card at a time, anchored below (or above) the control that opened it. Esc or a click
    /// outside closes it and typing returns to the sheet. The panel stays open meanwhile.
    private func present(_ content: NSView, width: CGFloat, anchor: NSView?, focus: NSView?) {
        closeOverlay(returnFocus: false)
        hideCard(animated: false)
        content.translatesAutoresizingMaskIntoConstraints = false
        overlay.show(content)
        content.widthAnchor.constraint(equalToConstant: width).isActive = true
        let size = NSSize(width: width, height: ceil(content.fittingSize.height))
        var origin: NSPoint
        if let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor {
            let frame = anchor.convert(anchor.bounds, to: self)
            origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY + 4)
            if origin.y + size.height > bounds.height - 4 { origin.y = max(4, frame.minY - 4 - size.height) }
        } else {
            origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        }
        origin.x = min(max(0, origin.x), bounds.width - size.width)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: origin.x),
            content.topAnchor.constraint(equalTo: overlay.topAnchor, constant: origin.y)
        ])
        overlay.layoutSubtreeIfNeeded()
        overlay.focus = focus
        overlayHold = shell?.holdOpen()
        Motion.enter(content, duration: 0.18, up: 4, scale: 0.98, anchor: .top)
        if let focus { window?.makeFirstResponder(focus) }
    }

    @discardableResult
    func closeOverlay(returnFocus: Bool) -> Bool {
        guard let content = overlay.content else { return false }
        overlay.clear()
        overlayHold = nil
        Motion.leave(content, duration: 0.12, up: 4) { [weak overlay] in
            if let overlay { overlay.removed(content) } else { content.removeFromSuperview() }
        }
        if returnFocus { window?.makeFirstResponder(editor) }
        return true
    }

    var overlayContent: NSView? { overlay.content }

    // MARK: Menus

    private func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        let target = ClosureTarget(action)
        item.target = target
        item.representedObject = target
        return item
    }

    /// Menus keep the panel open while they track.
    private func popUp(_ menu: NSMenu, at point: NSPoint) {
        let hold = shell?.holdOpen()
        menu.popUp(positioning: nil, at: point, in: self)
        withExtendedLifetime(hold) {}
        if overlay.isHidden, window?.firstResponder === window || window?.firstResponder == nil { window?.makeFirstResponder(editor) }
    }

    private func showSheetMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let new = item(CalculatorText.newSheet, key: "t") { [weak self] in self?.newSheet() }
        new.isEnabled = workspace.tabs.canCreate
        menu.addItem(new)
        menu.addItem(.separator())
        menu.addItem(item(CalculatorText.renameMenu) { [weak self] in guard let self else { return }; self.renameSheet(self.workspace.activeID) })
        let close = item(CalculatorText.closeSheet, key: "w") { [weak self] in guard let self else { return }; self.workspace.close(self.workspace.activeID) }
        close.isEnabled = workspace.tabs.canClose(workspace.activeID) != .unknown
        menu.addItem(close)
        menu.addItem(.separator())
        menu.addItem(item(CalculatorText.settings) { [weak self] in self?.shell?.openSettings(section: CalculatorModule.id) })
        popUp(menu, at: NSPoint(x: more.frame.maxX - menu.size.width, y: more.frame.maxY + 4))
    }

    private func newSheet() {
        if workspace.newSheet() { window?.makeFirstResponder(editor) }
    }

    // MARK: SheetTabStripDelegate

    func stripSelect(_ id: UUID) {
        closeOverlay(returnFocus: false)
        if workspace.switchTo(id) || id == workspace.activeID { window?.makeFirstResponder(editor) }
    }
    func stripClose(_ id: UUID) {
        closeOverlay(returnFocus: false)
        workspace.close(id)
    }
    func stripRename(_ id: UUID) { renameSheet(id) }
    func stripNew() { newSheet() }
    func stripMenu(_ id: UUID, tab: NSView, event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(CalculatorText.renameMenu) { [weak self] in self?.renameSheet(id) })
        menu.addItem(.separator())
        let close = item(CalculatorText.closeSheet, key: id == workspace.activeID ? "w" : "") { [weak self] in self?.workspace.close(id) }
        close.isEnabled = workspace.tabs.canClose(id) != .unknown
        menu.addItem(close)
        popUp(menu, at: convert(event.locationInWindow, from: nil))
    }

    /// Every sheet in a filterable list: type to narrow, arrows to move, Return to open.
    func stripAll(_ anchor: NSView) {
        let list = AllSheetsCard(tabs: workspace.tabs.visible, current: workspace.activeID)
        list.open = { [weak self] id in
            guard let self else { return }
            self.closeOverlay(returnFocus: false)
            self.stripSelect(id)
        }
        list.escape = { [weak self] in self?.closeOverlay(returnFocus: true) }
        present(list, width: 280, anchor: anchor, focus: list.filter)
    }

    /// Renames this sheet, not whichever is in front by the time the name is confirmed.
    func renameSheet(_ id: UUID) {
        guard workspace.canRename(id), let entry = workspace.documents.sheets.first(where: { $0.id == id }) else { return }
        let card = RenameCard(name: entry.name)
        card.commit = { [weak self, weak card] name in
            guard let self, let card else { return }
            if let problem = self.workspace.rename(id, to: name) { card.show(problem: problem) } else { self.closeOverlay(returnFocus: true) }
        }
        card.cancel = { [weak self] in self?.closeOverlay(returnFocus: true) }
        present(card, width: 300, anchor: strip.view(for: id) ?? strip, focus: card.field)
        card.field.currentEditor()?.selectAll(nil)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the page on screen: a page still fading out after a tab switch takes no shortcuts.
        guard window != nil, workspace.visible, !isHiddenOrHasHiddenAncestor else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, key == "t" { closeOverlay(returnFocus: false); newSheet(); return true }
        if modifiers == .command, key == "w" {
            if closeOverlay(returnFocus: true) { return true }
            workspace.close(workspace.activeID)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Diagnostics

    var pillsByLine: [Int: ResultPill] { pills }
    func showCardForDiagnostics(_ pill: ResultPill) { showCard(for: pill) }
}

/// The editor's scroll view: overlay scroller and a soft fade where the sheet continues, in place of a rule.
final class SheetScrollView: NSScrollView {
    var scrolled: (() -> Void)?
    private let mask = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() {
        updateFade()
        scrolled?()
    }

    override func tile() {
        super.tile()
        updateFade()
    }

    /// Fades the top while scrolled down and the bottom while more follows. No fade, no mask.
    private func updateFade() {
        guard let layer else { return }
        let visible = contentView.bounds
        let height = documentView?.frame.height ?? 0
        let top = visible.minY > 1, bottom = visible.maxY < height - 1
        guard top || bottom, bounds.height > 40 else { layer.mask = nil; return }
        let edge = 14 / bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        // Layer space: y grows upward, so the first stop is the bottom edge.
        mask.colors = [bottom ? clear : solid, solid, solid, top ? clear : solid]
        mask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = mask
        CATransaction.commit()
    }
}

/// The column the results stand in, beside the editor. Scrolling over it scrolls the sheet.
final class ResultsColumn: NSView {
    weak var scroll: NSScrollView?
    weak var host: CalculatorTabView?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("calculator-results")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Results")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func scrollWheel(with event: NSEvent) { scroll?.scrollWheel(with: event) }
    /// Empty space in the column belongs to the editor (a click there places the caret).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A closed tab's way back, and short notes such as the sheet limit, in the card above its last lines.
final class NoticeBar: FillView {
    let text = line("", size: 12, color: Palette.textPrimary)
    let undo = HoverButton(CalculatorText.undo, style: .row, label: CalculatorText.undo) {}

    init() {
        super.init(fill: Palette.rgb(0x222228), stroke: Palette.strokeStrong, radius: 9)
        identifier = NSUserInterfaceItemIdentifier("calculator-notice")
        text.identifier = NSUserInterfaceItemIdentifier("calculator-notice-text")
        undo.identifier = NSUserInterfaceItemIdentifier("calculator-undo-close")
        undo.tint = Palette.accent
        undo.padding = NSSize(width: 8, height: 3)
        undo.refusesFirstResponder = true
        addSubview(text)
        addSubview(undo)
        CalculatorContrast.shadow(layer, opacity: 0.35, radius: 8, y: -3)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(text value: String, undo shows: Bool, tip: String?) {
        text.stringValue = value
        text.toolTip = tip
        undo.isHidden = !shows
        setAccessibilityLabel(value)
        NSAccessibility.post(element: text, notification: .announcementRequested, userInfo: [.announcement: value, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        needsLayout = true
    }

    func fittedSize(maxWidth: CGFloat) -> NSSize {
        let undoWidth = undo.isHidden ? 0 : undo.intrinsicContentSize.width + 8
        let textWidth = min(ceil(text.intrinsicContentSize.width), maxWidth - 24 - undoWidth)
        return NSSize(width: 12 + textWidth + (undo.isHidden ? 12 : 8 + undoWidth - 2), height: 30)
    }

    override func layout() {
        super.layout()
        let height = text.intrinsicContentSize.height
        let undoSize = undo.isHidden ? .zero : undo.intrinsicContentSize
        undo.frame = NSRect(x: bounds.width - 4 - undoSize.width, y: (bounds.height - undoSize.height) / 2, width: undoSize.width, height: undoSize.height)
        let right = undo.isHidden ? bounds.width - 12 : undo.frame.minX - 6
        text.frame = NSRect(x: 12, y: (bounds.height - height) / 2, width: max(0, right - 12), height: height)
    }
}

/// Holds the open in-panel card above a transparent layer that closes it on any click outside.
private final class OverlayLayer: NSView {
    var dismiss: (() -> Void)?
    private(set) var content: NSView?
    weak var focus: NSView?
    override var isFlipped: Bool { true }

    func show(_ view: NSView) {
        content = view
        addSubview(view)
        isHidden = false
    }

    /// The card stays a moment to fade out; the layer stops catching clicks at once.
    func clear() {
        content = nil
        focus = nil
        isHidden = subviews.isEmpty
    }

    /// A closed card finished fading out.
    func removed(_ view: NSView) {
        view.removeFromSuperview()
        if content == nil, subviews.isEmpty { isHidden = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let content else { return nil }
        let local = convert(point, from: superview)
        if content.frame.contains(local) { return super.hitTest(point) }
        return self
    }
    // Any button outside closes, the middle one too: it never reaches a tab under the card.
    override func mouseDown(with event: NSEvent) { dismiss?() }
    override func rightMouseDown(with event: NSEvent) { dismiss?() }
    override func otherMouseDown(with event: NSEvent) { dismiss?() }
}
