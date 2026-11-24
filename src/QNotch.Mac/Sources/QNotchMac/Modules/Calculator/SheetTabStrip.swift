import AppKit

/// What the strip reports.
protocol SheetTabStripDelegate: AnyObject {
    func stripSelect(_ id: UUID)
    func stripClose(_ id: UUID)
    func stripRename(_ id: UUID)
    func stripMenu(_ id: UUID, tab: NSView, event: NSEvent)
    func stripNew()
    func stripAll(_ anchor: NSView)
}

/// One row of sheet tabs that never wraps (Windows SheetTabStrip), drawn like the panel's own icon tab strip:
/// a soft track with a sliding indicator behind the sheet in front. Tabs share the width between 92 and 150
/// points; past that the row scrolls with the wheel, chevrons on the sides that have more, and an all-sheets
/// button. Only the tabs in view exist. A closed tab collapses in place while its neighbours spring over, and
/// Undo brings it back from the same spot; every move starts from where things are on screen.
final class SheetTabStrip: NSView {
    static let minTabWidth: CGFloat = 92, maxTabWidth: CGFloat = 150, gap: CGFloat = 2, inset: CGFloat = 2
    static let chevronWidth: CGFloat = 22, allWidth: CGFloat = 28, addWidth: CGFloat = 30, height: CGFloat = 30

    weak var delegate: SheetTabStripDelegate?
    private let track = FillView(fill: Palette.control, radius: 10)
    private let row = ClipRow()
    private let indicator = FillView(fill: Palette.controlHover, stroke: Palette.stroke, radius: 8)
    private var views: [UUID: SheetTabView] = [:]
    private var spare: [SheetTabView] = []
    /// Closed tabs collapsing in place, by sheet.
    private var ghosts: [UUID: SheetTabView] = [:]
    private(set) var tabs: [CalculatorTab] = []
    private(set) var active: UUID?
    private var offset: CGFloat = 0
    private var tabWidth: CGFloat = maxTabWidth
    private var viewWidth: CGFloat = 0
    private let left = HoverButton(symbol: "chevron.left", style: .icon, symbolSize: 10, label: CalculatorText.scrollTabsLeft) {}
    private let right = HoverButton(symbol: "chevron.right", style: .icon, symbolSize: 10, label: CalculatorText.scrollTabsRight) {}
    private let leftShade = FillView(fill: Palette.rgb(0x1C1C1F), radius: 8)
    private let rightShade = FillView(fill: Palette.rgb(0x1C1C1F), radius: 8)
    let all = HoverButton(symbol: "chevron.down", style: .icon, symbolSize: 11, label: CalculatorText.allSheets) {}
    let add = HoverButton(symbol: "plus", style: .icon, symbolSize: 13, label: CalculatorText.newSheetTip) {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(track)
        track.addSubview(row)
        row.addSubview(indicator)
        for shade in [leftShade, rightShade] { track.addSubview(shade) }
        leftShade.addSubview(left)
        rightShade.addSubview(right)
        addSubview(all)
        addSubview(add)
        left.handler = { [weak self] in self?.page(-1) }
        right.handler = { [weak self] in self?.page(1) }
        all.handler = { [weak self] in guard let self else { return }; self.delegate?.stripAll(self.all) }
        add.handler = { [weak self] in self?.delegate?.stripNew() }
        left.identifier = NSUserInterfaceItemIdentifier("calculator-tabs-left")
        right.identifier = NSUserInterfaceItemIdentifier("calculator-tabs-right")
        all.identifier = NSUserInterfaceItemIdentifier("calculator-tabs-all")
        add.identifier = NSUserInterfaceItemIdentifier("calculator-new")
        for button in [left, right, all, add] { button.refusesFirstResponder = true }
        all.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(CalculatorText.sheets)
        identifier = NSUserInterfaceItemIdentifier("calculator-tabs")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func applyContrast() {
        indicator.stroke = CalculatorContrast.strongStroke
        track.stroke = CalculatorContrast.increased ? CalculatorContrast.stroke : nil
    }

    // MARK: Content

    enum Change { case none, closed(UUID, keepingPlace: Bool), restored(UUID), created(UUID) }

    /// Shows these tabs. A close keeps the row where it is when the tab was not in front, so the next tab
    /// slides under the pointer for another middle-click; otherwise the tab in front comes fully into view.
    func show(_ tabs: [CalculatorTab], active: UUID, change: Change = .none) {
        // Where everything is now (model frames; running springs are additive and carry on).
        var before: [UUID: CGFloat] = [:]
        for (id, view) in views { before[id] = view.frame.minX }
        let indicatorBefore = indicator.isHidden ? nil : indicator.frame.minX
        let moved = active != self.active
        let keepingPlace: Bool
        if case .closed(_, true) = change { keepingPlace = true } else { keepingPlace = false }
        let activeWasInView = isInView(self.active)
        if case .closed(let id, _) = change, let view = views.removeValue(forKey: id) { collapse(view, id: id) }
        self.tabs = tabs
        self.active = active
        relayout()
        if keepingPlace { if activeWasInView { reveal(active) } } else if moved || !isInView(active) { reveal(active) }
        if case .restored(let id) = change { reveal(id) }
        place()
        // Neighbours spring from where they were.
        for (id, view) in views {
            if let old = before[id], abs(old - view.frame.minX) > 0.5 { Motion.settle(view, from: CGPoint(x: old - view.frame.minX, y: 0)) }
        }
        if let indicatorBefore, !indicator.isHidden, abs(indicatorBefore - indicator.frame.minX) > 0.5 {
            Motion.settle(indicator, from: CGPoint(x: indicatorBefore - indicator.frame.minX, y: 0))
        }
        switch change {
        case .restored(let id), .created(let id): expand(id)
        default: break
        }
    }

    /// The closed tab collapses where it stood, from where it is on screen.
    private func collapse(_ view: SheetTabView, id: UUID) {
        freeze(view)
        view.unbindForGhost()
        ghosts[id] = view
        Motion.leave(view, duration: 0.18, scale: 0.6) { [weak self, weak view] in
            guard let self, let view, self.ghosts[id] === view else { return }
            self.ghosts[id] = nil
            view.layer?.removeAllAnimations()
            view.removeFromSuperview()
        }
    }

    /// A restored or new tab grows back from its own spot; a tab still collapsing turns around mid-flight.
    private func expand(_ id: UUID) {
        guard let view = views[id] else { return }
        if let ghost = ghosts.removeValue(forKey: id) {
            ghost.layer?.removeAllAnimations()
            ghost.removeFromSuperview()
            // The tab comes back from the ghost's size and opacity on screen.
            let shown = ghost.layer?.presentation()
            view.layer?.opacity = 1
            if let layer = view.layer, Motion.fades {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = shown?.opacity ?? 0
                fade.duration = Motion.moves ? 0.2 : Motion.crossfadeDuration
                fade.timingFunction = Motion.easeOut
                layer.add(fade, forKey: "restore.opacity")
            }
            Motion.settle(view, from: CGPoint(x: ghost.frame.minX - view.frame.minX, y: 0))
            return
        }
        Motion.enter(view, duration: 0.24, scale: 0.6)
    }

    /// Moves a view's model to where it shows now and drops its animations, so a new one starts from there.
    private func freeze(_ view: NSView) {
        guard let layer = view.layer else { return }
        let dx = layer.presentation()?.transform.m41 ?? 0
        layer.removeAllAnimations()
        view.frame.origin.x += dx
    }

    func setActive(_ id: UUID) { show(tabs, active: id) }

    private func isInView(_ id: UUID?) -> Bool {
        guard let id, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let left = CGFloat(index) * step
        return left >= offset - 0.5 && left + tabWidth <= offset + viewWidth + 0.5
    }

    // MARK: Scrolling

    private var step: CGFloat { tabWidth + Self.gap }
    private var contentWidth: CGFloat { tabs.isEmpty ? 0 : CGFloat(tabs.count) * step - Self.gap }

    /// Scrolls just enough to show a tab whole, clear of the chevrons.
    func reveal(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), viewWidth > 0 else { return }
        if contentWidth <= viewWidth { offset = 0; return }
        let left = CGFloat(index) * step, right = left + tabWidth
        let leftInset = left > 0 ? Self.chevronWidth : 0
        let rightInset = right < contentWidth ? Self.chevronWidth : 0
        if left - leftInset < offset { offset = left - leftInset }
        else if right + rightInset > offset + viewWidth { offset = right + rightInset - viewWidth }
        offset = min(max(0, offset), max(0, contentWidth - viewWidth))
    }

    private func page(_ direction: CGFloat) {
        setOffset(offset + direction * max(step, viewWidth - 2 * Self.chevronWidth - step))
    }

    private func setOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), max(0, contentWidth - viewWidth))
        guard abs(clamped - offset) > 0.01 else { return }
        offset = clamped
        place()
    }

    override func scrollWheel(with event: NSEvent) {
        guard contentWidth > viewWidth else { return super.scrollWheel(with: event) }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        setOffset(offset - delta * (event.hasPreciseScrollingDeltas ? 1 : 12))
    }

    // MARK: Layout: only the tabs in view

    override func layout() {
        super.layout()
        relayout()
        if let active, !isInView(active) { reveal(active) }
        place()
    }

    private func relayout() {
        let available = bounds.width - Self.addWidth - Self.inset * 2
        guard available > 0 else { return }
        let count = CGFloat(max(1, tabs.count))
        let fitting = (available + Self.gap) / count - Self.gap
        let overflow = fitting < Self.minTabWidth
        all.isHidden = !overflow
        tabWidth = overflow ? Self.minTabWidth : min(Self.maxTabWidth, floor(fitting))
        viewWidth = overflow ? max(Self.minTabWidth, available - Self.allWidth) : contentWidth
        offset = min(max(0, offset), max(0, contentWidth - viewWidth))
        let height = Self.height
        track.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: viewWidth + Self.inset * 2, height: height)
        row.frame = NSRect(x: Self.inset, y: Self.inset, width: viewWidth, height: height - Self.inset * 2)
        var x = track.frame.maxX + 2
        if overflow { all.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: Self.allWidth, height: 28); x += Self.allWidth }
        add.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: Self.addWidth, height: 28)
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let height = row.bounds.height
        var keep = Set<UUID>()
        if !tabs.isEmpty, viewWidth > 0 {
            let first = max(0, Int(floor(offset / step)))
            let last = min(tabs.count - 1, Int(floor((offset + viewWidth) / step)))
            if first <= last {
                for index in first...last {
                    let tab = tabs[index]
                    keep.insert(tab.id)
                    let view = views[tab.id] ?? take()
                    views[tab.id] = view
                    view.bind(tab, index: index, active: tab.id == active)
                    view.frame = NSRect(x: (CGFloat(index) * step - offset).rounded(), y: 0, width: tabWidth, height: height)
                }
            }
        }
        for (id, view) in views where !keep.contains(id) {
            views[id] = nil
            view.layer?.removeAllAnimations()
            view.unbind()
            spare.append(view)
        }
        if let active, let view = views[active] {
            indicator.isHidden = false
            indicator.frame = view.frame
        } else {
            indicator.isHidden = true
        }
        let more = contentWidth > viewWidth + 0.5
        leftShade.isHidden = !(more && offset > 0.5)
        rightShade.isHidden = !(more && offset < contentWidth - viewWidth - 0.5)
        leftShade.frame = NSRect(x: Self.inset, y: Self.inset, width: Self.chevronWidth, height: height)
        rightShade.frame = NSRect(x: track.bounds.width - Self.inset - Self.chevronWidth, y: Self.inset, width: Self.chevronWidth, height: height)
        left.frame = leftShade.bounds
        right.frame = rightShade.bounds
    }

    private func take() -> SheetTabView {
        if let view = spare.popLast() { view.isHidden = false; return view }
        let view = SheetTabView(strip: self)
        row.addSubview(view)
        return view
    }

    /// The tab view showing a sheet (diagnostics and anchors).
    func view(for id: UUID) -> SheetTabView? { views[id] }

    // MARK: What a tab reports

    fileprivate func tabSelected(_ tab: CalculatorTab) { delegate?.stripSelect(tab.id) }
    fileprivate func tabClosed(_ tab: CalculatorTab) { delegate?.stripClose(tab.id) }
    fileprivate func tabRenamed(_ tab: CalculatorTab) { delegate?.stripRename(tab.id) }
    fileprivate func tabMenu(_ tab: CalculatorTab, view: NSView, event: NSEvent) { delegate?.stripMenu(tab.id, tab: view, event: event) }
}

/// Clips the tabs to the track.
private final class ClipRow: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
}

/// One visible tab. A press selects it at once; a middle-click closes it browser style (on release over the
/// same tab, never selecting it first). The close mark shows on the tab in front and the hovered one.
final class SheetTabView: NSView, OutlineRoleProviding, MiddleClickTarget {
    private weak var strip: SheetTabStrip?
    private let label = line("", size: 12, color: Palette.textSecondary)
    let close = HoverButton(symbol: "xmark", style: .icon, symbolSize: 8, label: CalculatorText.closeSheet) {}
    private(set) var tab: CalculatorTab?
    private(set) var isActive = false
    private var hovering = false
    private var middlePressed: UUID?
    private var tracking: NSTrackingArea?

    init(strip: SheetTabStrip) {
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        label.setAccessibilityElement(false)
        addSubview(label)
        addSubview(close)
        close.refusesFirstResponder = true
        close.handler = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.strip?.tabClosed(tab)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    var outlineRole: Outline.Role? { .tab }
    override func isAccessibilitySelected() -> Bool { isActive }
    override func accessibilityValue() -> Any? { NSNumber(value: isActive ? 1 : 0) }
    override func accessibilityPerformPress() -> Bool {
        guard let tab else { return false }
        strip?.tabSelected(tab)
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func bind(_ tab: CalculatorTab, index: Int, active: Bool) {
        if self.tab != tab {
            middlePressed = nil
            self.tab = tab
            label.stringValue = tab.name
            toolTip = tab.name
            setAccessibilityLabel(tab.name)
        }
        identifier = NSUserInterfaceItemIdentifier("calculator-tab-\(index)")
        close.identifier = NSUserInterfaceItemIdentifier("calculator-tab-\(index)-close")
        isActive = active
        paint()
    }

    func unbind() {
        tab = nil
        middlePressed = nil
        identifier = nil
        close.identifier = nil
        isHidden = true
    }

    /// A ghost keeps its look but answers nothing.
    func unbindForGhost() {
        tab = nil
        identifier = nil
        close.identifier = nil
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { tab == nil ? nil : super.hitTest(point) }

    private func paint() {
        close.isHidden = !(isActive || hovering)
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        label.textColor = isActive || hovering ? Palette.textPrimary : Palette.textSecondary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 18
        close.frame = NSRect(x: bounds.width - closeSize - 4, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        // Centered in the room the close mark leaves, so names never shift when it appears.
        let height = label.intrinsicContentSize.height
        label.alignment = .center
        label.frame = NSRect(x: 8, y: (bounds.height - height) / 2, width: max(0, bounds.width - 8 - 22), height: height)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }

    override func mouseDown(with event: NSEvent) {
        guard let tab else { return }
        if event.clickCount == 2 { strip?.tabRenamed(tab); return }
        strip?.tabSelected(tab)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let tab else { return }
        strip?.tabMenu(tab, view: self, event: event)
    }

    /// The press only arms the close: the sheet in front keeps its caret.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let tab else { return super.otherMouseDown(with: event) }
        middlePressed = tab.id
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let pressed = middlePressed
        middlePressed = nil
        let point = convert(event.locationInWindow, from: nil)
        middleUp(inside: bounds.contains(point), pressed: pressed)
    }

    private func middleUp(inside: Bool, pressed: UUID?) {
        if inside, let pressed, let tab, tab.id == pressed { strip?.tabClosed(tab) }
    }

    /// The debug channel's and smoke check's middle click: the same press and release.
    func middleClick(releasedInside: Bool) {
        guard let tab else { return }
        middleUp(inside: releasedInside, pressed: tab.id)
    }
}
