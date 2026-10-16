import Foundation
import CoreGraphics

/// AppKit coordinates (origin at bottom left), in points rather than backing pixels.
public struct DisplayLayout {
    /// Concave top corners that let the surface flow out of the bezel beside the camera housing.
    public static let flare: CGFloat = 6
    /// Expanded panel body, below the camera band.
    public static let panelSize = CGSize(width: 700, height: 376)

    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeTop: CGFloat
    public let cameraGap: CGRect?
    /// Sideways offset of a floating pill from the display's center (Windows NotchNudge). A notch
    /// that wraps the camera housing never moves.
    public var offset: CGFloat = 0

    public init(frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, cameraGap: CGRect?) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTop = max(0, safeTop)
        self.cameraGap = cameraGap
    }

    public var hasCameraHousing: Bool { safeTop > 0 }

    public var cameraHousing: CGRect? {
        guard hasCameraHousing, let cameraGap, cameraGap.width > 0,
              cameraGap.minX >= frame.minX, cameraGap.maxX <= frame.maxX else { return nil }
        return CGRect(x: cameraGap.minX, y: frame.maxY - safeTop, width: cameraGap.width, height: safeTop)
    }

    public var integratesCameraHousing: Bool { cameraHousing != nil }
    public var topBandHeight: CGFloat { integratesCameraHousing ? safeTop : 0 }

    /// - Parameter wing: with a camera housing, the width of each status wing beside it (0 hugs the
    ///   housing, so an idle surface is indistinguishable from the hardware). Without one, the width
    ///   of the floating pill's content.
    public func surface(expanded: Bool, wing: CGFloat = 0) -> CGRect {
        // The housing is part of the surface, rather than an inset above a detached pill.
        // Reserve the occluded center; only the side wings contain status content.
        let top = integratesCameraHousing ? frame.maxY : hasCameraHousing ? frame.maxY - safeTop : min(frame.maxY, visibleFrame.maxY) - 6
        let available = frame.insetBy(dx: 8, dy: 8)
        let collapsed: CGSize
        if let housing = cameraHousing {
            collapsed = CGSize(width: housing.width + 2 * (Self.flare + max(0, wing)), height: safeTop)
        } else {
            collapsed = CGSize(width: max(96, wing + 28), height: 32)
        }
        let width = min(expanded ? max(Self.panelSize.width, collapsed.width) : collapsed.width, available.width)
        let wantedHeight = expanded ? Self.panelSize.height + topBandHeight : collapsed.height
        let height = min(wantedHeight, max(32, top - available.minY))
        let center = cameraHousing?.midX ?? frame.midX + offset
        let x = min(max(center - width / 2, available.minX), available.maxX - width)
        return CGRect(x: x, y: max(available.minY, top - height), width: width, height: height)
    }

    /// Panel controls stay below the housing even though the window itself reaches the bezel.
    public var panelBody: CGRect {
        let window = surface(expanded: true)
        let inset = integratesCameraHousing ? Self.flare : 0
        return CGRect(x: window.minX + inset, y: window.minY, width: window.width - inset * 2, height: window.height - topBandHeight)
    }

    /// Global screen coordinates, entirely inside the auxiliary clear areas beside the camera.
    public func wings(expanded: Bool, wing: CGFloat = 0) -> (left: CGRect, right: CGRect)? {
        guard let housing = cameraHousing else { return nil }
        let window = surface(expanded: expanded, wing: wing)
        let left = window.minX + Self.flare, right = window.maxX - Self.flare
        return (
            CGRect(x: left, y: housing.minY, width: max(0, housing.minX - left), height: safeTop),
            CGRect(x: housing.maxX, y: housing.minY, width: max(0, right - housing.maxX), height: safeTop)
        )
    }
}

extension DisplayLayout {
    /// Where a released pill settles: the center or flush against an edge when within 56 points.
    public func snapped(offset: CGFloat, width: CGFloat) -> CGFloat {
        let limit = max(0, (frame.width - 16 - width) / 2)
        let clamped = min(limit, max(-limit, offset))
        if abs(clamped) < 56 { return 0 }
        if limit - abs(clamped) < 56 { return clamped < 0 ? -limit : limit }
        return clamped
    }
}
