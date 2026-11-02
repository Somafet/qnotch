import CoreGraphics

/// Status clusters use the clear wing boundary after the flare, not the wider open panel.
public enum StatusGutters {
    public enum Side { case left, right }
    public static let inset: CGFloat = 12

    /// Keep the whole cluster clear of both the outer edge and the camera. Oversized clusters
    /// are omitted; normal segments are fitted (and may spill to the other wing) before placement.
    public static func frame(size: CGSize, in area: CGRect, side: Side) -> CGRect? {
        guard size.width > 0, size.height > 0,
              size.width <= area.width - inset * 2, size.height <= area.height else { return nil }
        let x = side == .left ? area.minX + inset : area.maxX - inset - size.width
        return CGRect(x: x, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Widest cluster on a virtual notch, where there is no camera to share the pill with.
    public static let virtualClusterLimit: CGFloat = 170
    public static let virtualWingLimit: CGFloat = 192

    /// Half-width of a virtual notch that holds both clusters with only `spacing` between them:
    /// rounded to 8 so a one-character change does not resize the pill, and symmetric about the center.
    public static func virtualWing(left: CGFloat, right: CGFloat, spacing: CGFloat) -> CGFloat {
        let total = left + right + (left > 0 && right > 0 ? spacing : 0)
        return ceil((total / 2 + inset) / 8) * 8
    }
}
