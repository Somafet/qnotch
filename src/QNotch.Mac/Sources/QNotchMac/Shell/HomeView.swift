import AppKit
import QNotchMacCore

/// Home: the registered cards in a three-column grid that scrolls when it overflows. In edit mode
/// (Windows EditMode) cards jiggle and can be dragged to a new place; their content is not
/// clickable. The jiggle loops only while editing and is skipped when motion is reduced.
final class HomeView: NSScrollView {
    static let columns = 3, rowHeight: CGFloat = 148, gap: CGFloat = 10
    private let document = GridDocument()

    /// Called with the new order of the shown cards after a drag.
    var reordered: (([String]) -> Void)? {
        get { document.reordered }
        set { document.reordered = newValue }
    }

    init(cards: [(contribution: ViewContribution, view: NSView)], sizes: [String: Int] = [:]) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        documentView = document
        document.cards = cards.map { item in
            let contribution = item.contribution
            let selected = HomeCardSize.resolve(saved: sizes[contribution.id], defaultSpan: contribution.span)
            (item.view as? HomeCardSizing)?.setHomeCardSize(selected)
            let card = CardView(title: contribution.title, content: item.view)
            if contribution.supportedCardSizes.count > 1 {
                let handles = [-1, 1].map { direction in
                    let handle = HomeResizeHandle(title: contribution.title, direction: direction)
                    handle.identifier = NSUserInterfaceItemIdentifier("home-resize-" + contribution.id + (direction < 0 ? "-leading" : "-trailing"))
                    handle.currentSize = selected
                    handle.began = { [weak document] in document?.beginResize(contribution.id) }
                    handle.moved = { [weak document] delta in document?.resizeBy(delta) }
                    handle.ended = { [weak document] in document?.finishResize() }
                    handle.adjusted = { [weak document] delta in document?.adjustSize(contribution.id, by: delta) }
                    handle.translatesAutoresizingMaskIntoConstraints = false
                    card.addSubview(handle)
                    NSLayoutConstraint.activate([
                        handle.widthAnchor.constraint(equalToConstant: 16), handle.heightAnchor.constraint(equalToConstant: 36),
                        handle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                        direction < 0 ? handle.leadingAnchor.constraint(equalTo: card.leadingAnchor)
                            : handle.trailingAnchor.constraint(equalTo: card.trailingAnchor)
                    ])
                    return handle
                }
                document.handles[contribution.id] = handles
            }
            card.identifier = NSUserInterfaceItemIdentifier("card-" + item.contribution.id)
            document.addSubview(card)
            return (contribution.id, card, selected.rawValue, contribution.span, item.view)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var resized: ((String, HomeCardSize) -> Void)? {
        get { document.resized }
        set { document.resized = newValue }
    }

    func applySizes(_ sizes: [String: Int]) {
        for card in document.cards {
            document.resizeCard(card.id, to: HomeCardSize.resolve(saved: sizes[card.id], defaultSpan: card.defaultSpan), notify: false)
        }
    }

    var editing: Bool {
        get { document.editing }
        set { document.editing = newValue }
    }

    override func layout() {
        super.layout()
        document.width = contentSize.width
        document.layoutCards(animated: false)
    }
}

private final class GridDocument: NSView {
    var cards: [(id: String, view: NSView, span: Int, defaultSpan: Int, content: NSView)] = []
    var handles: [String: [HomeResizeHandle]] = [:]
    private var resizing: (id: String, startSpan: Int)?
    var resized: ((String, HomeCardSize) -> Void)?
    var width: CGFloat = 0
    var reordered: (([String]) -> Void)?
    var editing = false { didSet { if oldValue != editing { applyEditing() } } }
    private var dragging: (index: Int, offset: NSPoint, before: [String])?
    private var tracker = VelocityTracker()
    /// The card that just made way for the dragged one. It cannot trade back until the dragged
    /// card's center leaves it, so cards of different widths never flip back and forth.
    private var displaced: String?
    override var isFlipped: Bool { true }

    private func frames() -> [NSRect] {
        let slots = CardGrid.place(spans: cards.map(\.span), columns: HomeView.columns)
        let columns = CGFloat(HomeView.columns), gap = HomeView.gap
        let unit = floor((width - gap * (columns - 1)) / columns)
        return slots.map { slot in
            let span = CGFloat(slot.span)
            return NSRect(x: CGFloat(slot.column) * (unit + gap), y: CGFloat(slot.row) * (HomeView.rowHeight + gap),
                          width: unit * span + gap * (span - 1), height: HomeView.rowHeight)
        }
    }

    func layoutCards(animated: Bool) {
        let frames = frames()
        for (index, (card, frame)) in zip(cards, frames).enumerated() where dragging?.index != index {
            if animated, Motion.enabled {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = Motion.easeOut
                    card.view.animator().frame = frame
                }
            } else { card.view.frame = frame }
        }
        let rows = frames.map(\.maxY).max() ?? 0
        if frame.size != NSSize(width: width, height: rows) { setFrameSize(NSSize(width: width, height: rows)) }
    }

    func resizeCard(_ id: String, to size: HomeCardSize, notify: Bool = true) {
        guard dragging == nil, let index = cards.firstIndex(where: { $0.id == id }),
              HomeCardSize.supported(defaultSpan: cards[index].defaultSpan).contains(size),
              cards[index].span != size.rawValue else { return }
        cards[index].view.layer?.removeAnimation(forKey: "jiggle")
        cards[index].span = size.rawValue
        (cards[index].content as? HomeCardSizing)?.setHomeCardSize(size)
        for handle in handles[id] ?? [] { handle.currentSize = size }
        layoutCards(animated: false)
        applyEditing()
        if notify { resized?(id, size) }
    }

    func beginResize(_ id: String) {
        guard editing, dragging == nil, let card = cards.first(where: { $0.id == id }) else { return }
        resizing = (id, card.span)
        applyEditing()
    }

    /// Snap the dragged edge to a supported column width. Persist once, when released.
    func resizeBy(_ delta: CGFloat) {
        guard let resizing, let card = cards.first(where: { $0.id == resizing.id }) else { return }
        let step = max(1, floor((width - HomeView.gap * 2) / 3) + HomeView.gap)
        let sizes = HomeCardSize.supported(defaultSpan: card.defaultSpan)
        let requested = CGFloat(resizing.startSpan) + delta / step
        let closest = sizes.min { abs(CGFloat($0.rawValue) - requested) < abs(CGFloat($1.rawValue) - requested) }!
        resizeCard(card.id, to: closest, notify: false)
    }

    func finishResize() {
        guard let previous = resizing else { return }
        resizing = nil
        applyEditing()
        if let card = cards.first(where: { $0.id == previous.id }), card.span != previous.startSpan,
           let size = HomeCardSize(rawValue: card.span) { resized?(card.id, size) }
    }

    func adjustSize(_ id: String, by delta: Int) {
        guard editing, let card = cards.first(where: { $0.id == id }),
              let size = HomeCardSize(rawValue: card.span + delta) else { return }
        resizeCard(id, to: size)
    }

    // MARK: Edit mode

    private func applyEditing() {
        if !editing, resizing != nil { finishResize() }
        for handle in handles.values.flatMap({ $0 }) { handle.isHidden = !editing }
        if !editing, window?.firstResponder is HomeResizeHandle { window?.makeFirstResponder(nil) }
        for (index, card) in cards.enumerated() {
            guard let layer = card.view.layer else { continue }
            layer.removeAnimation(forKey: "jiggle")
            (card.view as? FillView)?.stroke = editing ? Palette.strokeStrong : Palette.stroke
            guard editing, Motion.enabled, resizing?.id != card.id else { continue }
            // About ±0.7° around the card's center, each card a little out of phase.
            let bounds = card.view.bounds
            func tilt(_ degrees: CGFloat) -> CATransform3D {
                var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
                t = CATransform3DRotate(t, degrees * .pi / 180, 0, 0, 1)
                return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
            }
            let jiggle = CAKeyframeAnimation(keyPath: "transform")
            jiggle.values = [tilt(-0.7), tilt(0.7), tilt(-0.7)].map { NSValue(caTransform3D: $0) }
            // Additive, so a card still settling from a drop keeps moving while it jiggles.
            jiggle.isAdditive = true
            jiggle.duration = 0.26
            jiggle.repeatCount = .infinity
            jiggle.timeOffset = Double(index) * 0.07
            layer.add(jiggle, forKey: "jiggle")
        }
    }

    /// While editing, only the resize handles receive clicks; the grid owns card reordering.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard editing else { return super.hitTest(point) }
        guard frame.contains(point) else { return nil }
        for handle in handles.values.flatMap({ $0 }) where !handle.isHidden {
            if handle.bounds.contains(handle.convert(point, from: superview)) { return handle }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard editing, resizing == nil else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cards.firstIndex(where: { $0.view.frame.contains(point) }) else { return }
        let card = cards[index].view
        dragging = (index, NSPoint(x: point.x - card.frame.minX, y: point.y - card.frame.minY), cards.map(\.id))
        displaced = nil
        tracker = VelocityTracker()
        tracker.add(point, at: event.timestamp)
        card.layer?.removeAnimation(forKey: "jiggle")
        addSubview(card, positioned: .above, relativeTo: nil)
        (card as? FillView)?.stroke = Palette.accent
        // Picked up: it rises a little toward the pointer.
        Motion.lift(card, scale: 1.03)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        tracker.add(point, at: event.timestamp)
        let card = cards[drag.index].view
        card.setFrameOrigin(NSPoint(x: point.x - drag.offset.x, y: point.y - drag.offset.y))
        autoscroll(with: event)
        // Reorder once the dragged card's center enters another card's place.
        let center = NSPoint(x: card.frame.midX, y: card.frame.midY)
        let frames = frames()
        if let id = displaced, let index = cards.firstIndex(where: { $0.id == id }) {
            guard !frames[index].contains(center) else { return }
            displaced = nil
        }
        guard let target = frames.indices.first(where: { $0 != drag.index && frames[$0].contains(center) }) else { return }
        displaced = cards[target].id
        let item = cards.remove(at: drag.index)
        cards.insert(item, at: target)
        dragging?.index = target
        layoutCards(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = dragging else { return }
        dragging = nil
        displaced = nil
        // Dropped into its place, carrying on at the pointer's speed and shrinking back down.
        let card = cards[drag.index].view
        let place = frames()[drag.index]
        let release = CGPoint(x: card.frame.minX - place.minX, y: card.frame.minY - place.minY)
        card.frame = place
        Motion.settle(card, from: release, velocity: tracker.velocity(at: event.timestamp))
        layoutCards(animated: true)
        applyEditing()
        if cards.map(\.id) != drag.before { reordered?(cards.map(\.id)) }
    }
}
