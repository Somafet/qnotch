import Foundation
import CoreGraphics

/// Gesture physics after Apple's Designing Fluid Interfaces: where a flick comes to rest, how a
/// drag resists past a boundary, and springs set by response and damping ratio.
public enum Fluid {
    /// How far a flick at `velocity` (points per second) carries, decelerating like a scroll view.
    public static func project(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }

    /// How far content follows a drag `overshoot` points past a boundary: almost 1:1 at first, then
    /// less and less, never reaching `dimension`.
    public static func rubberband(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let distance = abs(overshoot)
        let followed = distance * dimension * constant / (dimension + constant * distance)
        return overshoot < 0 ? -followed : followed
    }

    /// `value` unchanged inside `range`, rubber-banding past either end.
    public static func rubberband(_ value: CGFloat, in range: ClosedRange<CGFloat>, dimension: CGFloat) -> CGFloat {
        if value < range.lowerBound { return range.lowerBound + rubberband(value - range.lowerBound, dimension: dimension) }
        if value > range.upperBound { return range.upperBound + rubberband(value - range.upperBound, dimension: dimension) }
        return value
    }

    /// Stiffness and damping (mass 1) for a spring that reaches its target in about `response`
    /// seconds. A `dampingRatio` of 1 settles without overshoot; lower values bounce.
    public static func spring(response: CGFloat, dampingRatio: CGFloat) -> (stiffness: CGFloat, damping: CGFloat) {
        let omega = 2 * .pi / response
        return (omega * omega, 2 * dampingRatio * omega)
    }

    /// `velocity` (points per second) in Core Animation's spring units: a fraction of the distance
    /// left per second, positive toward the target. Capped, so a short hop is not flung far past it.
    public static func relativeVelocity(_ velocity: CGFloat, from: CGFloat, to: CGFloat, limit: CGFloat = 10) -> CGFloat {
        let distance = to - from
        guard abs(distance) > 0.5 else { return 0 }
        return max(-limit, min(limit, velocity / distance))
    }

    /// Every value a spring passes through on its way from `from` to `to`, starting at `velocity`
    /// (points per second): the room an animation needs, overshoot included.
    public static func springExtent(from: CGFloat, to: CGFloat, velocity: CGFloat, response: CGFloat, dampingRatio: CGFloat) -> ClosedRange<CGFloat> {
        let (stiffness, damping) = spring(response: response, dampingRatio: dampingRatio)
        var x = from - to, v = velocity
        var low = min(from, to), high = max(from, to)
        let step: CGFloat = 0.001
        for _ in 0..<3000 {
            v += (-stiffness * x - damping * v) * step
            x += v * step
            low = min(low, to + x)
            high = max(high, to + x)
            if abs(x) < 0.1, abs(v) < 1 { break }
        }
        return low...high
    }
}

/// Release velocity from the latest pointer samples. A pointer that came to rest before letting
/// go has none, so a slow, careful drop never flings.
public struct VelocityTracker {
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    public init() {}

    public mutating func add(_ point: CGPoint, at time: TimeInterval) {
        samples.append((time, point))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Points per second at `time`; zero after 50 ms without movement.
    public func velocity(at time: TimeInterval) -> CGVector {
        guard let first = samples.first, let last = samples.last, time - last.time < 0.05 else { return .zero }
        let span = last.time - first.time
        guard span > 0.004 else { return .zero }
        return CGVector(dx: (last.point.x - first.point.x) / span, dy: (last.point.y - first.point.y) / span)
    }
}
