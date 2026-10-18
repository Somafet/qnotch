import Foundation

/// Volume card rules (Windows VolumeModule): whole percent steps, ±2 per scroll notch, and
/// raising the level while muted unmutes.
public struct VolumeLevel: Equatable {
    public var scalar: Float
    public var muted: Bool

    public init(scalar: Float, muted: Bool) {
        self.scalar = min(1, max(0, scalar))
        self.muted = muted
    }

    public var percent: Int { Int((scalar * 100).rounded()) }
    public var isSilent: Bool { muted || percent == 0 }
    public var text: String { muted ? "Muted" : "\(percent)%" }

    /// SF Symbol matching the level, like the macOS menu-bar Sound item.
    public var symbol: String {
        if isSilent { return "speaker.slash.fill" }
        return percent < 34 ? "speaker.wave.1.fill" : percent < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    /// The level after the user sets `percent`; moving above zero clears mute.
    public func setting(percent value: Int) -> VolumeLevel {
        let clamped = min(100, max(0, value))
        return VolumeLevel(scalar: Float(clamped) / 100, muted: muted && clamped == 0)
    }

    public func stepped(by notches: Int) -> VolumeLevel { setting(percent: percent + notches * 2) }
}
