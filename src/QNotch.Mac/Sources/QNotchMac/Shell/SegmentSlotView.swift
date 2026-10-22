import AppKit

/// Keeps contribution identity and interaction attached to the real view when WingFit moves it.
final class SegmentSlotView: NSControl {
    var owner: String?
    var segmentID = ""
    var activate: (() -> Void)?

    override var acceptsFirstResponder: Bool { activate != nil && !isHiddenOrHasHiddenAncestor }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return activate == nil ? hit : self
    }
    override func mouseDown(with event: NSEvent) { activate?() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") { activate?() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let activate, !isHiddenOrHasHiddenAncestor else { return false }
        activate()
        return true
    }
}
