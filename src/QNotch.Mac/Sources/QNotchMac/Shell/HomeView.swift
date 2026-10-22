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

    init(cards: [(contribution: ViewContribution, view: NSView)]) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        documentView = document
        document.cards = cards.map { item in
            let card = CardView(title: item.contribution.title, content: item.view)
            card.identifier = NSUserInterfaceItemIdentifier("card-" + item.contribution.id)
            document.addSubview(card)
            return (item.contribution.id, card, item.contribution.span)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func revealCard(_ id: String) {
        layoutSubtreeIfNeeded()
        guard let card = document.cards.first(where: { $0.id == id }) else { return }
        document.scrollToVisible(card.view.frame)
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
    var cards: [(id: String, view: NSView, span: Int)] = []
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

    // MARK: Edit mode

    private func applyEditing() {
        for (index, card) in cards.enumerated() {
            guard let layer = card.view.layer else { continue }
            layer.removeAnimation(forKey: "jiggle")
            (card.view as? FillView)?.stroke = editing ? Palette.strokeStrong : Palette.stroke
            guard editing, Motion.enabled else { continue }
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

    /// While editing, the grid takes every click so card content stays inert.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard editing else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard editing else { return super.mouseDown(with: event) }
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
