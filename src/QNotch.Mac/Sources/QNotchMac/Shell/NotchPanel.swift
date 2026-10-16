import AppKit
import QNotchMacCore

enum RenderDiagnostics {
    static var drawCount = 0
}

final class NotchPanel: NSPanel {
    var keyboardAllowed = false
    var clicked: (() -> Bool)?
    var escaped: (() -> Void)?
    /// Printable keys typed while no text field has focus (type-to-search).
    var typed: ((String) -> Void)?
    override var canBecomeKey: Bool { keyboardAllowed }
    override var canBecomeMain: Bool { false }
    // The layout already clamps to the selected display. AppKit's normal window constraint
    // would push a bezel-attached panel back below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {
        // Consume the opening click so it cannot also hit a newly revealed control.
        if event.type == .leftMouseDown, clicked?() == true { return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { escaped?() }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers == .command, event.charactersIgnoringModifiers == "f" { typed?(""); return }
        if modifiers.isEmpty, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            typed?(characters)
            return
        }
        super.keyDown(with: event)
    }
}

/// Notch outline. With a camera housing, the top corners flare concavely into the bezel and
/// only the bottom corners round; a floating pill rounds all four corners. Every path has the
/// same element structure so Core Animation can morph between sizes.
enum NotchShape {
    static func path(_ rect: CGRect, integrated: Bool, top: CGFloat, bottom: CGFloat) -> CGPath {
        let flare = integrated ? DisplayLayout.flare : 0
        let x0 = rect.minX + flare, x1 = rect.maxX - flare
        let width = max(0, x1 - x0)
        let b = max(0, min(bottom, width / 2, rect.height / 2))
        let k = max(0, min(integrated ? flare : top, width / 2 - 0.01, rect.height - b))
        let path = CGMutablePath()
        path.move(to: integrated ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: x0 + k, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: x0, y: rect.maxY - k), control: CGPoint(x: x0, y: rect.maxY))
        path.addLine(to: CGPoint(x: x0, y: rect.minY + b))
        path.addQuadCurve(to: CGPoint(x: x0 + b, y: rect.minY), control: CGPoint(x: x0, y: rect.minY))
        path.addLine(to: CGPoint(x: x1 - b, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: x1, y: rect.minY + b), control: CGPoint(x: x1, y: rect.minY))
        path.addLine(to: CGPoint(x: x1, y: rect.maxY - k))
        path.addQuadCurve(to: integrated ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: x1 - k, y: rect.maxY),
                          control: CGPoint(x: x1, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// Hairline just inside the sides and bottom, starting below the camera band (never beside the menu bar).
    static func outline(_ rect: CGRect, integrated: Bool, top: CGFloat, bottom: CGFloat, band: CGFloat) -> CGPath {
        let inner = integrated ? CGRect(x: rect.minX + 0.5, y: rect.minY + 0.5, width: rect.width - 1, height: rect.height - 0.5)
                               : rect.insetBy(dx: 0.5, dy: 0.5)
        let flare = integrated ? DisplayLayout.flare : 0
        let x0 = inner.minX + flare, x1 = inner.maxX - flare
        let width = max(0, x1 - x0)
        let b = max(0, min(bottom - 0.5, width / 2, inner.height / 2))
        let k = max(0, min(integrated ? max(flare, band) : top - 0.5, inner.height - b))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: inner.maxY - k))
        path.addLine(to: CGPoint(x: x0, y: inner.minY + b))
        path.addQuadCurve(to: CGPoint(x: x0 + b, y: inner.minY), control: CGPoint(x: x0, y: inner.minY))
        path.addLine(to: CGPoint(x: x1 - b, y: inner.minY))
        path.addQuadCurve(to: CGPoint(x: x1, y: inner.minY + b), control: CGPoint(x: x1, y: inner.minY))
        path.addLine(to: CGPoint(x: x1, y: inner.maxY - k))
        if !integrated {
            path.addQuadCurve(to: CGPoint(x: x1 - k, y: inner.maxY), control: CGPoint(x: x1, y: inner.maxY))
            path.addLine(to: CGPoint(x: x0 + k, y: inner.maxY))
            path.addQuadCurve(to: CGPoint(x: x0, y: inner.maxY - k), control: CGPoint(x: x0, y: inner.maxY))
        }
        return path
    }
}

/// A view whose backing layer is a shape layer, so it stacks with sibling views normally.
final class ShapeView: NSView {
    var shape: CAShapeLayer { layer as! CAShapeLayer }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Root of the notch window. Status and panel content live in `world`, whose coordinates are
/// fixed to the display rather than to the window, so the window can grow for a morph and shrink
/// afterwards without moving anything on screen. Nothing here runs while idle.
final class NotchSurfaceView: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    let world = NSView()
    private let backdrop = ShapeView()
    private let outline = ShapeView()
    private let clip = CAShapeLayer()
    private var tracking: NSTrackingArea?
    private var generation = 0
    /// Global rectangle covered by `world`.
    private(set) var worldRect = CGRect.zero
    /// Global rectangle of the settled (or currently targeted) shape.
    private(set) var shapeRect = CGRect.zero
    private(set) var integrated = false
    private(set) var band: CGFloat = 0
    private(set) var isMorphing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        world.wantsLayer = true
        addSubview(world)
        backdrop.shape.fillColor = Palette.surface.cgColor
        outline.shape.fillColor = nil
        outline.shape.strokeColor = Palette.strokeStrong.cgColor
        outline.shape.lineWidth = 1
        outline.shape.opacity = 0
        clip.fillColor = NSColor.black.cgColor
        world.addSubview(backdrop)
        world.addSubview(outline)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { RenderDiagnostics.drawCount += 1 }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }

    /// Sets the region content can occupy (the expanded surface plus room for a spring overshoot).
    func configure(world rect: CGRect, integrated: Bool, band: CGFloat) {
        worldRect = rect
        self.integrated = integrated
        self.band = band
        let bounds = CGRect(origin: .zero, size: rect.size)
        world.setFrameSize(rect.size)
        backdrop.frame = bounds
        outline.frame = bounds
        clip.frame = bounds
        syncToWindow()
    }

    /// Keeps world content fixed on screen after the window frame changes.
    func syncToWindow() {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.setFrameOrigin(NSPoint(x: worldRect.minX - window.frame.minX, y: worldRect.minY - window.frame.minY))
        CATransaction.commit()
    }

    func local(_ global: CGRect) -> CGRect { global.offsetBy(dx: -worldRect.minX, dy: -worldRect.minY) }

    /// Adds `view` to the world (if needed) at a global rectangle.
    func place(_ view: NSView, at global: CGRect, above: NSView? = nil) {
        if view.superview !== world { world.addSubview(view, positioned: .above, relativeTo: above ?? outline) }
        view.frame = local(global).integral
    }

    /// Current on-screen bounds of the shape, including an in-flight morph.
    var visibleShapeBounds: CGRect {
        guard let path = backdrop.shape.presentation()?.path ?? backdrop.shape.path else { return shapeRect }
        return path.boundingBoxOfPath.offsetBy(dx: worldRect.minX, dy: worldRect.minY)
    }

    enum Morph { case none, open, close, nudge }

    func morph(to rect: CGRect, bottom: CGFloat, top: CGFloat, outlined: Bool, style: Morph, completion: @escaping () -> Void) {
        generation += 1
        let token = generation
        shapeRect = rect
        let target = local(rect)
        let shapePath = NotchShape.path(target, integrated: integrated, top: top, bottom: bottom)
        let edgePath = NotchShape.outline(target, integrated: integrated, top: top, bottom: bottom, band: band)
        let fromShape = backdrop.shape.presentation()?.path ?? backdrop.shape.path
        let fromEdge = outline.shape.presentation()?.path ?? outline.shape.path
        let fromOpacity = outline.shape.presentation()?.opacity ?? outline.shape.opacity
        let animated = style != .none && Motion.enabled && fromShape != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.shape.path = shapePath
        clip.path = shapePath
        outline.shape.path = edgePath
        outline.shape.opacity = outlined ? 1 : 0
        if animated {
            isMorphing = true
            world.layer?.mask = clip
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == token else { return }
                self.isMorphing = false
                self.world.layer?.mask = nil
                completion()
            }
            func animation(_ key: String, from: Any?, to: Any?) -> CAAnimation {
                let animation: CABasicAnimation
                switch style {
                case .open, .nudge:
                    // Gentle spring: about 3% overshoot on open, a little livelier for a status change.
                    let spring = CASpringAnimation(keyPath: key)
                    spring.mass = 1
                    spring.stiffness = style == .open ? 290 : 340
                    spring.damping = style == .open ? 24 : 22
                    spring.duration = spring.settlingDuration
                    animation = spring
                default:
                    animation = CABasicAnimation(keyPath: key)
                    animation.duration = 0.26
                    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                }
                animation.fromValue = from
                animation.toValue = to
                return animation
            }
            backdrop.shape.add(animation("path", from: fromShape, to: shapePath), forKey: "morph")
            clip.add(animation("path", from: fromShape, to: shapePath), forKey: "morph")
            if let fromEdge { outline.shape.add(animation("path", from: fromEdge, to: edgePath), forKey: "morph") }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = outlined ? 1 : 0
            fade.duration = outlined ? 0.3 : 0.16
            outline.shape.add(fade, forKey: "fade")
        } else {
            isMorphing = false
            for layer in [backdrop.shape, outline.shape, clip] { layer.removeAllAnimations() }
            world.layer?.mask = nil
        }
        CATransaction.commit()
        if !animated { completion() }
    }
}
