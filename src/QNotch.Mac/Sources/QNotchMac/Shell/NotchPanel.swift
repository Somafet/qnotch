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
    override func accessibilityPerformPress() -> Bool { pressed?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        RenderDiagnostics.drawCount += 1
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }
}
