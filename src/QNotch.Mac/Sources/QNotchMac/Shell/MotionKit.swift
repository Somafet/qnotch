import AppKit
import QNotchMacCore

/// Core Animation building blocks for short, purposeful motion (spec/onboarding.md, Motion):
/// entrances ease out, exits ease in; springs for success moments and for anything the pointer
/// moved, which bounce only when a gesture carried momentum. Only opacity and
/// transforms animate, always toward a model value that is already final, so a snapshot or a
/// cancelled animation shows the settled state. Reduced motion keeps 120 ms crossfades and drops
/// slides, scales, staggers and loops; diagnostic runs cut everything.
extension Motion {
    /// Crossfades are allowed (everything but diagnostic runs).
    static var fades: Bool { !Runtime.diagnostics }
    /// Slides, scales, staggers, springs and loops are allowed.
    static var moves: Bool { enabled && !Runtime.diagnostics }
    static let crossfadeDuration: CFTimeInterval = 0.12

    enum Anchor { case center, top }

    /// A move (points right and visually up) and scale about the view's center or top edge, in its
    /// layer's own space. AppKit's view layers anchor at their origin, which is the bottom-left
    /// corner under a regular superview and the top-left under a flipped one.
    static func transform(for view: NSView, dx: CGFloat = 0, up: CGFloat = 0, scale: CGFloat = 1, scaleY: CGFloat? = nil,
                          anchor: Anchor = .center) -> CATransform3D {
        let flipped = view.superview?.isFlipped ?? false
        let size = view.bounds.size
        let ax = size.width / 2
        let ay = anchor == .center ? size.height / 2 : (flipped ? 0 : size.height)
        var t = CATransform3DMakeTranslation(dx, flipped ? -up : up, 0)
        t = CATransform3DTranslate(t, ax, ay, 0)
        t = CATransform3DScale(t, scale, scaleY ?? scale, 1)
        return CATransform3DTranslate(t, -ax, -ay, 0)
    }

    private static func begin(_ layer: CALayer, after delay: CFTimeInterval) -> CFTimeInterval {
        layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    }

    /// Entrance: from transparent (and moved or scaled) to the settled state. With reduced motion a
    /// 120 ms fade with no delay.
    static func enter(_ view: NSView, delay: CFTimeInterval = 0, duration: CFTimeInterval = 0.26, dx: CGFloat = 0, up: CGFloat = 0,
                      scale: CGFloat = 1, scaleY: CGFloat? = nil, anchor: Anchor = .center, fade: Bool = true) {
        guard fades, let layer = view.layer else { return }
        let full = moves
        let start = begin(layer, after: full ? delay : 0)
        var animations: [CABasicAnimation] = []
        if fade || !full {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0
            animations.append(opacity)
        }
        if full, dx != 0 || up != 0 || scale != 1 || scaleY != nil {
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: transform(for: view, dx: dx, up: up, scale: scale, scaleY: scaleY, anchor: anchor))
            move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animations.append(move)
        }
        for animation in animations {
            animation.beginTime = start
            animation.duration = full ? duration : crossfadeDuration
            animation.timingFunction = easeOut
            animation.fillMode = .backwards
            layer.add(animation, forKey: "enter." + (animation.keyPath ?? ""))
        }
    }

    /// Exit: fades (and moves or scales) out, holds the end state, then runs `done`.
    static func leave(_ view: NSView, duration: CFTimeInterval = 0.18, dx: CGFloat = 0, up: CGFloat = 0, scale: CGFloat = 1,
                      done: @escaping () -> Void) {
        guard fades, let layer = view.layer else { return done() }
        let full = moves
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        var animations: [CABasicAnimation] = []
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.toValue = 0
        animations.append(opacity)
        if full, dx != 0 || up != 0 || scale != 1 {
            let move = CABasicAnimation(keyPath: "transform")
            move.toValue = NSValue(caTransform3D: transform(for: view, dx: dx, up: up, scale: scale))
            animations.append(move)
        }
        for animation in animations {
            animation.duration = full ? duration : crossfadeDuration
            animation.timingFunction = easeIn
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "leave." + (animation.keyPath ?? ""))
        }
        CATransaction.commit()
    }

    /// A success moment: scales 0.6 → about 1.08 → 1 on a spring, fading in.
    static func pop(_ view: NSView, delay: CFTimeInterval = 0) {
        guard fades, let layer = view.layer else { return }
        let full = moves
        let start = begin(layer, after: full ? delay : 0)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.duration = full ? 0.14 : crossfadeDuration
        opacity.beginTime = start
        opacity.fillMode = .backwards
        layer.add(opacity, forKey: "pop.opacity")
        guard full else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: transform(for: view, scale: 0.6))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        // Damping ratio about 0.45: one overshoot of roughly 8%.
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 16
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        spring.beginTime = start
        spring.fillMode = .backwards
        layer.add(spring, forKey: "pop.transform")
    }

    /// Call right before changing a label's text or a button's title: the old and new contents
    /// crossfade.
    static func crossfade(_ view: NSView, duration: CFTimeInterval = 0.15) {
        guard fades, let layer = view.layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = moves ? duration : crossfadeDuration
        transition.timingFunction = easeOut
        layer.add(transition, forKey: "crossfade")
    }

    /// Animates a layer property from `old` to the model value already set, after `delay`.
    static func change(_ layer: CALayer?, _ keyPath: String, from old: Any?, delay: CFTimeInterval = 0, duration: CFTimeInterval = 0.15) {
        guard fades, let layer, let old else { return }
        let full = moves
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = old
        animation.beginTime = begin(layer, after: full ? delay : 0)
        animation.duration = full ? duration : crossfadeDuration
        animation.timingFunction = easeOut
        animation.fillMode = .backwards
        layer.add(animation, forKey: "change." + keyPath)
    }

    /// A spring set by Apple's design parameters (`Fluid.spring`): `response` in seconds and
    /// `dampingRatio` (1 settles without overshoot). `velocity` is in Core Animation's units
    /// (`Fluid.relativeVelocity`).
    static func spring(_ keyPath: String, response: CGFloat, dampingRatio: CGFloat, velocity: CGFloat = 0) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        let parameters = Fluid.spring(response: response, dampingRatio: dampingRatio)
        spring.mass = 1
        spring.stiffness = parameters.stiffness
        spring.damping = parameters.damping
        spring.initialVelocity = velocity
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Turns a view around mid-exit: from where it is on screen back to its settled state, instead
    /// of starting its entrance over from transparent.
    static func resume(_ view: NSView, duration: CFTimeInterval = 0.2) {
        guard let layer = view.layer else { return }
        let shown = layer.presentation()
        let opacity = shown?.opacity ?? layer.opacity
        let transform = shown?.transform ?? layer.transform
        layer.removeAllAnimations()
        guard fades else { return }
        var animations: [CABasicAnimation] = []
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        animations.append(fade)
        if moves {
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: transform)
            animations.append(move)
        }
        for animation in animations {
            animation.duration = moves ? duration : crossfadeDuration
            animation.timingFunction = easeOut
            layer.add(animation, forKey: "resume." + (animation.keyPath ?? ""))
        }
    }

    private static var settleCount = 0

    /// Picked up for a drag: grows to `scale` about its center and stays there until `settle`.
    static func lift(_ view: NSView, scale: CGFloat) {
        guard moves, let layer = view.layer else { return }
        let lift = spring("transform", response: 0.25, dampingRatio: 1)
        lift.isAdditive = true
        lift.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        lift.toValue = NSValue(caTransform3D: transform(for: view, scale: scale))
        lift.fillMode = .forwards
        lift.isRemovedOnCompletion = false
        layer.add(lift, forKey: "lift")
    }

    /// Moves a view whose model frame is already final from `offset` (where it shows now, relative
    /// to its new place) home on a spring that starts at the pointer's `velocity` (points per
    /// second), X and Y on their own springs. Each settle adds to any still running, so redirecting
    /// a moving view keeps its momentum. A lifted view shrinks back at the same time.
    static func settle(_ view: NSView, from offset: CGPoint, velocity: CGVector = .zero) {
        guard let layer = view.layer else { return }
        var lifted: CGFloat = 1
        if layer.animation(forKey: "lift") != nil {
            if let shown = layer.presentation()?.transform { lifted = sqrt(shown.m11 * shown.m11 + shown.m12 * shown.m12) }
            layer.removeAnimation(forKey: "lift")
        }
        guard moves else { return }
        settleCount += 1
        func add(_ from: CATransform3D, velocity: CGFloat, key: String) {
            let spring = spring("transform", response: 0.35, dampingRatio: velocity == 0 ? 1 : 0.8, velocity: velocity)
            spring.isAdditive = true
            spring.fromValue = NSValue(caTransform3D: from)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            layer.add(spring, forKey: "settle.\(key).\(settleCount)")
        }
        // Layers translate in their superview's own coordinates, flipped or not.
        if abs(offset.x) >= 0.5 {
            add(CATransform3DMakeTranslation(offset.x, 0, 0), velocity: Fluid.relativeVelocity(velocity.dx, from: offset.x, to: 0), key: "x")
        }
        if abs(offset.y) >= 0.5 {
            add(CATransform3DMakeTranslation(0, offset.y, 0), velocity: Fluid.relativeVelocity(velocity.dy, from: offset.y, to: 0), key: "y")
        }
        if abs(lifted - 1) > 0.001 {
            // Additive: the lift's own contribution, so the view shrinks from its size on screen.
            add(transform(for: view, scale: lifted), velocity: 0, key: "scale")
        }
    }

    /// Pressed look: a quick press to `scale`, and back on release.
    static func press(_ view: NSView, down: Bool, scale: CGFloat = 0.97) {
        guard moves, let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        let pressed = NSValue(caTransform3D: transform(for: view, scale: scale))
        let rest = NSValue(caTransform3D: CATransform3DIdentity)
        animation.fromValue = down ? rest : (layer.presentation()?.value(forKeyPath: "transform") as? NSValue ?? pressed)
        animation.toValue = down ? pressed : rest
        animation.duration = down ? 0.08 : 0.16
        animation.timingFunction = easeOut
        if down {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: "press")
    }
}

/// A check mark in a green disc that draws its stroke (the tour's "QNotch is ready").
final class CheckMarkView: NSView {
    private let disc = CAShapeLayer()
    private let mark = CAShapeLayer()

    init(side: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        disc.fillColor = NSColor.systemGreen.cgColor
        mark.fillColor = nil
        mark.strokeColor = NSColor.white.cgColor
        mark.lineWidth = max(1.5, side * 0.11)
        mark.lineCap = .round
        mark.lineJoin = .round
        layer?.addSublayer(disc)
        layer?.addSublayer(mark)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = bounds
        disc.path = CGPath(ellipseIn: bounds, transform: nil)
        mark.frame = bounds
        let w = bounds.width, h = bounds.height
        // Drawn in the layer's own space: y grows upward unless the view is flipped.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: (isFlipped ? 1 - y : y) * h) }
        let path = CGMutablePath()
        path.move(to: point(0.28, 0.52))
        path.addLine(to: point(0.44, 0.36))
        path.addLine(to: point(0.73, 0.66))
        mark.path = path
        CATransaction.commit()
    }

    /// Draws the stroke (strokeEnd 0 → 1); the model is already fully drawn.
    func drawStroke(delay: CFTimeInterval = 0) {
        guard Motion.fades else { return }
        let full = Motion.moves
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.beginTime = mark.convertTime(CACurrentMediaTime(), from: nil) + (full ? delay : 0)
        animation.duration = full ? 0.35 : Motion.crossfadeDuration
        animation.timingFunction = Motion.easeOut
        animation.fillMode = .backwards
        mark.add(animation, forKey: "draw")
    }
}

/// Step dots: one slot per step; the active dot widens into an accent pill. The dots are plain
/// layers, so width and color animate without a layout pass.
final class ProgressDots: NSView {
    private var dots: [CALayer] = []
    private(set) var count = 0
    private(set) var index = 0
    private static let slot: CGFloat = 18, gap: CGFloat = 4, side: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count) * Self.slot + CGFloat(max(0, count - 1)) * Self.gap, height: Self.side)
    }

    func set(count: Int, index: Int) {
        let animated = count == self.count && index != self.index && Motion.fades
        if count != self.count {
            dots.forEach { $0.removeFromSuperlayer() }
            dots = (0..<count).map { _ in
                let dot = CALayer()
                dot.cornerRadius = Self.side / 2
                layer?.addSublayer(dot)
                return dot
            }
            self.count = count
            invalidateIntrinsicContentSize()
        }
        self.index = index
        for (position, dot) in dots.enumerated() {
            let active = position == index
            // The width moves with the color; with reduced motion only the color fades.
            CATransaction.begin()
            CATransaction.setDisableActions(!(animated && Motion.moves))
            CATransaction.setAnimationDuration(0.26)
            CATransaction.setAnimationTimingFunction(Motion.easeOut)
            dot.frame = rect(at: position, active: active)
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(Motion.moves ? 0.26 : Motion.crossfadeDuration)
            dot.backgroundColor = (active ? Palette.accent : Palette.controlPressed).cgColor
            CATransaction.commit()
        }
        setAccessibilityLabel("Step \(index + 1) of \(count)")
    }

    private func rect(at position: Int, active: Bool) -> CGRect {
        let width = active ? Self.slot : Self.side
        let x = CGFloat(position) * (Self.slot + Self.gap) + (Self.slot - width) / 2
        return CGRect(x: x, y: (bounds.height - Self.side) / 2, width: width, height: Self.side)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (position, dot) in dots.enumerated() { dot.frame = rect(at: position, active: position == index) }
        CATransaction.commit()
    }
}
