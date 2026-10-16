import AppKit

/// The notch surface is always dark, like the hardware it extends. Values mirror the Windows dark
/// palette (Theme.Dark.xaml) so both apps read as one product; the accent follows the macOS accent.
enum Palette {
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

    /// The system accent, resolved for the dark surface.
    static var accent: NSColor {
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

    /// Fades (and optionally slides) a layer-backed view in. The model value is already final.
    static func reveal(_ view: NSView, delay: TimeInterval = 0, duration: TimeInterval = 0.24, dx: CGFloat = 0, dy: CGFloat = 0) {
        guard enabled, let layer = view.layer else { return }
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if dx != 0 || dy != 0 {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = CATransform3DMakeTranslation(dx, dy, 0)
            slide.toValue = CATransform3DIdentity
            animations.append(slide)
        }
        for animation in animations {
            animation.beginTime = begin
            animation.duration = duration
            animation.timingFunction = easeOut
            animation.fillMode = .backwards
            layer.add(animation, forKey: "reveal." + (animation as! CABasicAnimation).keyPath!)
        }
    }

    /// Fades a view out and then runs `done` (immediately when motion is off).
    static func conceal(_ view: NSView, duration: TimeInterval = 0.12, dx: CGFloat = 0, dy: CGFloat = 0, done: @escaping () -> Void) {
        guard enabled, let layer = view.layer else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let slide = CABasicAnimation(keyPath: "transform")
        slide.toValue = CATransform3DMakeTranslation(dx, dy, 0)
        for animation in [fade, slide] {
            animation.duration = duration
            animation.timingFunction = easeIn
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "conceal." + animation.keyPath!)
        }
        CATransaction.commit()
    }
}

extension NSFont {
    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        let base = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
