import AppKit
import QNotchMacCore

/// Visible edge anchor with a larger pointer target. Edges resize; the card body reorders.
final class HomeResizeHandle: NSView {
    let direction: Int
    var currentSize = HomeCardSize.small
    var began: (() -> Void)?
    var moved: ((CGFloat) -> Void)?
    var ended: (() -> Void)?
    var adjusted: ((Int) -> Void)?
    private var originX: CGFloat?

    init(title: String, direction: Int) {
        self.direction = direction
        super.init(frame: .zero)
        isHidden = true
        let grip = FillView(fill: Palette.accent, radius: 2)
        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)
        NSLayoutConstraint.activate([
            grip.widthAnchor.constraint(equalToConstant: 4), grip.heightAnchor.constraint(equalToConstant: 24),
            grip.centerXAnchor.constraint(equalTo: centerXAnchor), grip.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Resize \(title), \(direction < 0 ? "left" : "right") edge")
        toolTip = "Drag to resize. Arrow keys also change the width."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        guard !isHidden else { return }
        window?.makeFirstResponder(self)
        originX = event.locationInWindow.x
        began?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let originX else { return }
        moved?((event.locationInWindow.x - originX) * CGFloat(direction))
    }
    override func mouseUp(with event: NSEvent) {
        guard originX != nil else { return }
        mouseDragged(with: event)
        originX = nil
        ended?()
    }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .downArrow?: adjusted?(-1)
        case .rightArrow?, .upArrow?: adjusted?(1)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityValue() -> Any? { currentSize.title }
    override func accessibilityPerformIncrement() -> Bool { adjusted?(1); return true }
    override func accessibilityPerformDecrement() -> Bool { adjusted?(-1); return true }
}
