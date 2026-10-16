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

    public func surface(expanded: Bool) -> CGRect {
        // Keep every control below the housing. Never infer notch size from a model name.
        let top = hasCameraHousing ? frame.maxY - safeTop : min(frame.maxY, visibleFrame.maxY) - 6
        let available = frame.insetBy(dx: 8, dy: 8)
        let width = min(expanded ? 360 : max(204, (cameraGap?.width ?? 0) + 24), available.width)
        let height = min(expanded ? 356 : 32, max(32, top - available.minY))
        let center = cameraGap?.midX ?? frame.midX
        let x = min(max(center - width / 2, available.minX), available.maxX - width)
        return CGRect(x: x, y: max(available.minY, top - height), width: width, height: height)
    }
}
