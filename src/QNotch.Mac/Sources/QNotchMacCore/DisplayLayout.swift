import Foundation
import CoreGraphics

/// AppKit coordinates (origin at bottom left), in points rather than backing pixels.
public struct DisplayLayout {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeTop: CGFloat
    public let cameraGap: CGRect?

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

    public func surface(expanded: Bool) -> CGRect {
        // The housing is part of the surface, rather than an inset above a detached pill.
        // Reserve the occluded center; only the side wings contain status content.
        let top = integratesCameraHousing ? frame.maxY : hasCameraHousing ? frame.maxY - safeTop : min(frame.maxY, visibleFrame.maxY) - 6
        let available = frame.insetBy(dx: 8, dy: 8)
        let notchWidth = cameraHousing.map { $0.width + 144 } ?? 204
        let width = min(expanded ? max(360, notchWidth) : notchWidth, available.width)
        let wantedHeight = expanded ? 356 + topBandHeight : integratesCameraHousing ? safeTop + 4 : 32
        let height = min(wantedHeight, max(32, top - available.minY))
        let center = cameraHousing?.midX ?? frame.midX
        let x = min(max(center - width / 2, available.minX), available.maxX - width)
        return CGRect(x: x, y: max(available.minY, top - height), width: width, height: height)
    }

    /// Panel controls stay below the housing even though the window itself reaches the bezel.
    public var panelBody: CGRect {
        let window = surface(expanded: true)
        return CGRect(x: window.minX, y: window.minY, width: window.width, height: window.height - topBandHeight)
    }

    /// Global screen coordinates, entirely inside the auxiliary clear areas beside the camera.
    public func wings(expanded: Bool) -> (left: CGRect, right: CGRect)? {
        guard let housing = cameraHousing else { return nil }
        let window = surface(expanded: expanded)
        return (
            CGRect(x: window.minX, y: housing.minY, width: max(0, housing.minX - window.minX), height: safeTop),
            CGRect(x: housing.maxX, y: housing.minY, width: max(0, window.maxX - housing.maxX), height: safeTop)
        )
    }
}
