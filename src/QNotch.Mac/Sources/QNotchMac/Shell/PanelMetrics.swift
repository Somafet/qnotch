import AppKit

/// The open panel's concentric-corner numbers ([UI conventions](../../../../../spec/ui-conventions.md),
/// "Concentric corners"; Windows `PanelMetrics`). A surface that fills a tab sits `inset` from the
/// panel's sides and bottom, so a card in a bottom corner has radius `bottomRadius - inset`. Both the
/// panel's bottom corners and those cards are circular arcs: only circles stay concentric when inset.
enum PanelMetrics {
    /// Tab content's distance from the panel's sides and bottom.
    static let inset: CGFloat = 12
    /// Space between Home cards.
    static let cardGap: CGFloat = 12
    /// Radius of the open panel's bottom corners.
    static let bottomRadius: CGFloat = 26
    /// Radius of a card that fills a tab or sits in the Home grid.
    static let cardRadius: CGFloat = bottomRadius - inset
    /// Corner style of those cards, matching the panel's circular bottom corners.
    static let cardCorner: CALayerCornerCurve = .circular
}

extension FillView {
    /// The raised card a tab fills, or a Home card: card fill, hairline, and the concentric radius and curve.
    static func panelCard() -> FillView {
        let card = FillView(fill: Palette.card, stroke: Palette.stroke, radius: PanelMetrics.cardRadius)
        card.layer?.cornerCurve = PanelMetrics.cardCorner
        return card
    }
}
