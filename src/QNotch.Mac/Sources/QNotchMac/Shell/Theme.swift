import AppKit

/// The notch surface is always dark, like the hardware it extends. Values mirror the Windows dark
/// palette (Theme.Dark.xaml) so both apps read as one product; the accent follows the macOS accent.
enum Palette {
    static func hex(_ text: String) -> NSColor? {
        guard let value = UInt32(text.dropFirst(), radix: 16), text.count == 7 else { return nil }
        return rgb(value)
    }
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let surface = rgb(0x0B0B0D)
    static let card = rgb(0x17171C)
    static let cardHover = rgb(0x1E1E24)
    static let stroke = NSColor(white: 1, alpha: 0.10)
    static let strokeStrong = NSColor(white: 1, alpha: 0.16)
    static let control = NSColor(white: 1, alpha: 0.07)
    static let controlHover = NSColor(white: 1, alpha: 0.12)
    static let controlPressed = NSColor(white: 1, alpha: 0.17)
    static let textPrimary = rgb(0xF4F4F7)
    static let textSecondary = rgb(0xA1A1AD)
    static let textTertiary = rgb(0x6F6F7B)
    static let onAccent = rgb(0x0B0B0D)
    static let dark = NSAppearance(named: .darkAqua)

    /// A Settings, Appearance swatch; nil follows the macOS accent.
    static var accentOverride: NSColor?

    /// The chosen or system accent, resolved for the dark surface.
    static var accent: NSColor {
        if let accentOverride { return accentOverride }
        var color = NSColor.systemBlue
        dark?.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return color
    }
    static var accentSoft: NSColor { accent.withAlphaComponent(0.24) }
}

/// Effective "animations allowed": the user's setting AND the macOS Reduce Motion setting.
enum Motion {
    static var userReduced = false
    static var enabled: Bool { !userReduced && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// Runs `changes` inside an implicit animation, or directly when motion is off.
    static func animate(_ duration: TimeInterval, timing: CAMediaTimingFunction = easeOut,
                        _ changes: () -> Void, completion: (() -> Void)? = nil) {
        guard enabled else { changes(); completion?(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }
}

extension NSFont {
    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        let base = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
