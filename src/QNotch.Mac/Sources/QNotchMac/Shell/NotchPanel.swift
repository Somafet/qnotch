import AppKit

enum RenderDiagnostics {
    static var drawCount = 0
}

final class NotchPanel: NSPanel {
    var keyboardAllowed = false
    var clicked: (() -> Bool)?
    var escaped: (() -> Void)?
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
}

final class TrackingSurface: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
    override func draw(_ dirtyRect: NSRect) {
        RenderDiagnostics.drawCount += 1
        super.draw(dirtyRect)
    }
}

final class PillView: NSView {
    var pressed: (() -> Void)?
    var flatTop = false
    var cornerRadius: CGFloat = 14
    override func accessibilityPerformPress() -> Bool { pressed?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        RenderDiagnostics.drawCount += 1
        NSColor.black.setFill()
        if flatTop {
            let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
            // Fill the upper corners up to the physical bezel; only the lower corners round.
            path.appendRect(NSRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2))
            path.fill()
        } else {
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
    }
}
