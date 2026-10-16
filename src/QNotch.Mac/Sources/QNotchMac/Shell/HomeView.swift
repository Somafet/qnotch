import AppKit
import QNotchMacCore

/// Home: the registered cards in a three-column grid that scrolls when it overflows.
final class HomeView: NSScrollView {
    static let columns = 3, rowHeight: CGFloat = 148, gap: CGFloat = 10
    private let document = GridDocument()

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
            return (card, item.contribution.span)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        document.width = contentSize.width
        document.layoutCards()
    }
}

private final class GridDocument: NSView {
    var cards: [(view: NSView, span: Int)] = []
    var width: CGFloat = 0
    override var isFlipped: Bool { true }

    func layoutCards() {
        let slots = CardGrid.place(spans: cards.map(\.span), columns: HomeView.columns)
        let columns = CGFloat(HomeView.columns), gap = HomeView.gap
        let unit = floor((width - gap * (columns - 1)) / columns)
        for (card, slot) in zip(cards, slots) {
            let span = CGFloat(slot.span)
            card.view.frame = NSRect(x: CGFloat(slot.column) * (unit + gap), y: CGFloat(slot.row) * (HomeView.rowHeight + gap),
                                     width: unit * span + gap * (span - 1), height: HomeView.rowHeight)
        }
        let rows = CGFloat(CardGrid.rows(slots))
        let height = max(0, rows * HomeView.rowHeight + max(0, rows - 1) * gap)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
    }
}
