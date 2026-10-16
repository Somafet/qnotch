import AppKit

// MARK: - Layout helpers

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(wrappingLabelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    view.isSelectable = false
    return view
}

/// A single-line label that truncates instead of wrapping.
func line(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    view.lineBreakMode = .byTruncatingTail
    view.cell?.truncatesLastVisibleLine = true
    return view
}

func column(_ views: [NSView], spacing: CGFloat = 12, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = spacing
    return stack
}

func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentHuggingPriority(.init(1), for: .vertical)
    return view
}

func embed(_ child: NSView, in parent: NSView, inset: NSEdgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), fill: Bool = false) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset.left),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset.right),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset.top),
        fill ? child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset.bottom)
             : child.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -inset.bottom)
    ])
}

func embed(_ child: NSView, in parent: NSView, inset: CGFloat, fill: Bool = false) {
    embed(child, in: parent, inset: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset), fill: fill)
}

func size(_ view: NSView, width: CGFloat? = nil, height: CGFloat? = nil) {
    view.translatesAutoresizingMaskIntoConstraints = false
    if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
    if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImageView {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
    let view = NSImageView(image: image)
    view.contentTintColor = color
    view.setAccessibilityElement(false)
    return view
}

// MARK: - Surfaces

/// A layer-backed rounded fill. Colors resolve against the view's own appearance, so the same
/// view works in the dark notch and in the system-appearance Settings window.
class FillView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }

    init(fill: NSColor? = nil, stroke: NSColor? = nil, radius: CGFloat = 0) {
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill?.cgColor
            layer.borderColor = stroke?.cgColor
        }
        layer.borderWidth = stroke == nil ? 0 : 1
        layer.cornerRadius = radius
    }

    /// Changes the fill with a short cross-fade (hover and selection feedback).
    func setFill(_ color: NSColor?, animated: Bool) {
        fill = color
        guard let layer else { return }
        var value: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { value = color?.cgColor }
        if animated { Motion.animate(0.14) { layer.backgroundColor = value } } else { layer.backgroundColor = value }
    }
}

/// Windows-style card: raised fill, hairline stroke, 14 pt continuous corners, optional title.
final class CardView: FillView {
    init(title: String?, content: NSView, padding: CGFloat = 14) {
        super.init(fill: Palette.card, stroke: Palette.stroke, radius: 14)
        var views: [NSView] = []
        if let title {
            views.append(line(title, size: 12, weight: .semibold, color: Palette.textSecondary))
        }
        views.append(content)
        let stack = column(views, spacing: 10)
        embed(stack, in: self, inset: padding, fill: true)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Buttons

/// A borderless button with hover and press feedback. Keyboard focus, accessibility and actions
/// stay native (NSButton); only the look is custom. The fill is the button's own layer background.
final class HoverButton: NSButton {
    enum Style { case icon, plain, accent, accentCircle, chip, tab, row }

    let style: Style
    var handler: () -> Void
    var isSelectedLook = false { didSet { if oldValue != isSelectedLook { refresh(animated: true) } } }
    var tint: NSColor? { didSet { refresh(animated: false) } }
    var text: String { didSet { refresh(animated: false); invalidateIntrinsicContentSize() } }
    var padding = NSSize(width: 12, height: 6) { didSet { invalidateIntrinsicContentSize() } }
    private var hovering = false
    private var pressing = false
    private var tracking: NSTrackingArea?
    private var fixedSize: NSSize?
    private var radius: CGFloat = 8

    init(_ title: String = "", symbol: String? = nil, style: Style, symbolSize: CGFloat = 14, label accessibility: String? = nil, action: @escaping () -> Void) {
        self.style = style
        handler = action
        text = title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        focusRingType = .exterior
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility ?? title)?
                .withSymbolConfiguration(.init(pointSize: symbolSize, weight: style == .accentCircle ? .semibold : .medium))
        }
        imagePosition = symbol == nil ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: style == .chip ? 12 : 13, weight: style == .accent || style == .chip ? .semibold : .medium)
        switch style {
        case .icon: fixedSize = NSSize(width: 32, height: 30)
        case .tab: fixedSize = NSSize(width: 40, height: 28)
        case .accentCircle: fixedSize = NSSize(width: 44, height: 44); radius = 22; layer?.cornerCurve = .circular
        case .chip: padding = NSSize(width: 12, height: 5); radius = 7
        case .row: padding = NSSize(width: 10, height: 8)
        default: break
        }
        layer?.cornerRadius = radius
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(accessibility ?? title)
        if let accessibility, title.isEmpty { toolTip = accessibility }
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { handler() }

    func setSymbol(_ name: String, size: CGFloat = 14, label: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: style == .accentCircle ? .semibold : .medium))
        setAccessibilityLabel(label)
        toolTip = label
    }

    /// Borderless: no bezel padding, so the frame (and its fill) is exactly the laid-out size.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        if let fixedSize { return fixedSize }
        let content = super.intrinsicContentSize
        return NSSize(width: ceil(content.width + padding.width * 2), height: ceil(max(content.height, 16) + padding.height * 2))
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh(animated: true) }
    override func mouseDown(with event: NSEvent) {
        pressing = true
        refresh(animated: false)
        super.mouseDown(with: event)
        pressing = false
        if let window { hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        refresh(animated: true)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hovering || pressing { hovering = false; pressing = false; refresh(animated: false) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    private func refresh(animated: Bool) {
        let fill: NSColor?
        var foreground = tint ?? Palette.textPrimary
        switch style {
        case .accent, .accentCircle:
            let accent = Palette.accent
            fill = pressing ? accent.blended(withFraction: 0.2, of: .black) : hovering ? accent.blended(withFraction: 0.15, of: .white) : accent
            foreground = Palette.onAccent
        case .plain:
            fill = pressing ? Palette.controlPressed : hovering ? Palette.controlHover : Palette.control
        case .chip:
            fill = isSelectedLook ? Palette.accentSoft : pressing ? Palette.controlPressed : hovering ? Palette.control : nil
            foreground = isSelectedLook || hovering ? Palette.textPrimary : Palette.textSecondary
        case .tab:
            fill = pressing ? Palette.control : nil
            foreground = isSelectedLook ? Palette.accent : hovering ? Palette.textPrimary : Palette.textSecondary
        case .icon, .row:
            fill = pressing ? Palette.controlPressed : hovering ? Palette.controlHover : nil
            if style == .icon, tint == nil { foreground = hovering ? Palette.textPrimary : Palette.textSecondary }
        }
        let color = fill?.cgColor
        if animated, let layer { Motion.animate(0.14) { layer.backgroundColor = color } } else { layer?.backgroundColor = color }
        contentTintColor = foreground
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style == .row ? .left : .center
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: foreground, .font: font ?? .systemFont(ofSize: 13), .paragraphStyle: paragraph
        ])
    }
}

// MARK: - Notch controls

/// Icon tab strip with one sliding indicator behind the buttons (Windows TabStrip).
final class TabBar: FillView {
    private let buttons: [HoverButton]
    private let indicator = FillView(fill: Palette.controlHover, stroke: Palette.stroke, radius: 9)
    private(set) var selected: Int
    private static let item = NSSize(width: 40, height: 28), gap: CGFloat = 2, inset: CGFloat = 3

    init(items: [(symbol: String, title: String)], selected: Int, changed: @escaping (Int) -> Void) {
        self.selected = selected
        var made: [HoverButton] = []
        for (index, item) in items.enumerated() {
            made.append(HoverButton(symbol: item.symbol, style: .tab, symbolSize: 14, label: item.title) { changed(index) })
        }
        buttons = made
        super.init(fill: Palette.control, radius: 12)
        addSubview(indicator)
        buttons.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Panel tabs")
        select(selected, animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(buttons.count)
        return NSSize(width: Self.inset * 2 + count * Self.item.width + max(0, count - 1) * Self.gap, height: Self.item.height + Self.inset * 2)
    }
    private func frame(at index: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(index) * (Self.item.width + Self.gap), y: Self.inset, width: Self.item.width, height: Self.item.height)
    }
    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() { button.frame = frame(at: index) }
        indicator.frame = frame(at: selected)
    }

    func select(_ index: Int, animated: Bool) {
        guard buttons.indices.contains(index) else { return }
        selected = index
        for (offset, button) in buttons.enumerated() { button.isSelectedLook = offset == index }
        let target = frame(at: index)
        if animated, Motion.enabled {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1)
                context.allowsImplicitAnimation = true
                indicator.frame = target
            }
        } else { indicator.frame = target }
    }
}

/// Preset chips (5 / 15 / 25 / 50). The selected chip uses the soft accent fill.
final class ChipPicker: NSStackView {
    private var chips: [(value: Int, button: HoverButton)] = []

    init(values: [Int], format: (Int) -> String, label: (Int) -> String, changed: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        for value in values {
            let chip = HoverButton(format(value), style: .chip, label: label(value)) { changed(value) }
            chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            chips.append((value, chip))
            addArrangedSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ value: Int?) {
        for chip in chips { chip.button.isSelectedLook = chip.value == value }
    }
}

/// Circular progress (track plus accent arc). Updates only when told to; it never animates by itself.
final class ProgressRing: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    var lineWidth: CGFloat { didSet { needsLayout = true } }
    var color: NSColor = Palette.accent { didSet { arc.strokeColor = color.cgColor } }

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor(white: 1, alpha: 0.12).cgColor
        arc.strokeColor = color.cgColor
        arc.strokeEnd = 1
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Start at 12 o'clock and run clockwise.
        var transform = CGAffineTransform(translationX: bounds.midX, y: bounds.midY).rotated(by: .pi / 2).scaledBy(x: 1, y: -1)
        let path = CGPath(ellipseIn: rect.offsetBy(dx: -bounds.midX, dy: -bounds.midY), transform: &transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
        CATransaction.commit()
    }

    func set(progress: CGFloat, animated: Bool) {
        let value = min(1, max(0, progress))
        guard abs(arc.strokeEnd - value) > 0.0001 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!(animated && Motion.enabled))
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        arc.strokeEnd = value
        CATransaction.commit()
    }
}

/// Thin linear progress bar.
final class ProgressBar: FillView {
    private let bar = FillView(fill: Palette.accent, radius: 2)
    private var progress: CGFloat = 0

    init() {
        super.init(fill: Palette.control, radius: 2)
        addSubview(bar)
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }
    func set(progress value: CGFloat, animated: Bool) {
        let clamped = min(1, max(0, value))
        guard abs(clamped - progress) > 0.0001 else { return }
        progress = clamped
        let target = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        if animated { Motion.animate(0.35) { bar.frame = target } } else { bar.frame = target }
    }
}

// MARK: - Settings building blocks (system appearance)

enum SettingsStyle {
    static let groupFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 1, alpha: 0.65)
    }
    static let groupStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)
    }
    /// Width available to a row's text when the settings content column is `contentWidth` wide.
    static func textWidth(contentWidth: CGFloat, control: NSView?) -> CGFloat {
        contentWidth - 28 - (control.map { $0.fittingSize.width + 20 } ?? 0)
    }
}

/// A System Settings–style row: title and optional detail on the left, control on the right.
func settingsRow(_ title: String, detail: String? = nil, control: NSView? = nil, width: CGFloat) -> NSView {
    let titleLabel = label(title, size: 13)
    var text: [NSView] = [titleLabel]
    let available = SettingsStyle.textWidth(contentWidth: width, control: control)
    titleLabel.preferredMaxLayoutWidth = available
    if let detail {
        let detailLabel = label(detail, size: 11, color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = available
        text.append(detailLabel)
    }
    let left = column(text, spacing: 3)
    left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let content = row(control.map { [left, spacer(), $0] } ?? [left, spacer()], spacing: 12)
    let container = NSView()
    embed(content, in: container, inset: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14), fill: true)
    container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    container.setAccessibilityElement(false)
    return container
}

/// Rows grouped into one rounded box with hairline separators.
func settingsGroup(_ rows: [NSView], header: String? = nil, footer: String? = nil, width: CGFloat) -> NSView {
    let box = FillView(fill: SettingsStyle.groupFill, stroke: SettingsStyle.groupStroke, radius: 10)
    var items: [NSView] = []
    for (index, item) in rows.enumerated() {
        if index > 0 {
            let separator = NSBox()
            separator.boxType = .separator
            let inset = NSView()
            embed(separator, in: inset, inset: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14), fill: true)
            items.append(inset)
        }
        items.append(item)
    }
    let stack = column(items, spacing: 0)
    embed(stack, in: box, inset: 0, fill: true)
    items.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    var outer: [NSView] = []
    if let header {
        let title = label(header, size: 13, weight: .semibold)
        outer.append(title)
    }
    outer.append(box)
    if let footer {
        let note = label(footer, size: 11, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = width - 8
        let wrap = NSView()
        embed(note, in: wrap, inset: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4), fill: true)
        outer.append(wrap)
    }
    let group = column(outer, spacing: 8)
    box.widthAnchor.constraint(equalToConstant: width).isActive = true
    return group
}

/// Native switch with a closure.
final class ActionSwitch: NSSwitch {
    var changed: (Bool) -> Void
    init(_ title: String, value: Bool, changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        state = value ? .on : .off
        controlSize = .small
        target = self
        action = #selector(toggle)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { changed(state == .on) }
}

/// Native pop-up button with a closure.
final class ActionPopUp: NSPopUpButton {
    var changed: (Int) -> Void
    init(_ title: String, items: [String], selected: Int, changed: @escaping (Int) -> Void) {
        self.changed = changed
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        selectItem(at: selected)
        target = self
        action = #selector(pick)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pick() { changed(indexOfSelectedItem) }
}

/// Horizontal level slider for the dark notch (Windows Slider style): soft track, accent fill and a
/// light knob. Native NSSlider renders inactive in a non-key panel, which is how the notch usually
/// is while hovered. Click or drag anywhere on the track; arrow keys step; VoiceOver sees a slider.
final class LevelSlider: NSControl {
    var value: Double = 0 { didSet { value = min(maxValue, max(0, value)); needsLayout = true } }
    var maxValue: Double = 100
    var step: Double = 2
    var changed: ((Double) -> Void)?
    var dimmed = false { didSet { if oldValue != dimmed { Motion.animate(0.14) { fill.animator().alphaValue = dimmed ? 0.4 : 1 } } } }
    private let track = FillView(fill: Palette.control, radius: 2)
    private let fill = FillView(fill: Palette.accent, radius: 2)
    private let knob = FillView(fill: Palette.textPrimary, radius: 7)

    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        [track, fill, knob].forEach(addSubview)
        knob.layer?.shadowOpacity = 0.35
        knob.layer?.shadowRadius = 2
        knob.layer?.shadowOffset = CGSize(width: 0, height: -1)
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }

    override func layout() {
        super.layout()
        let inset: CGFloat = 7, y = bounds.midY
        let width = max(0, bounds.width - inset * 2)
        let x = inset + width * CGFloat(maxValue > 0 ? value / maxValue : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: inset, y: y - 2, width: width, height: 4)
        fill.frame = NSRect(x: inset, y: y - 2, width: x - inset, height: 4)
        knob.frame = NSRect(x: x - 7, y: y - 7, width: 14, height: 14)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        track(event)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            track(next)
            if next.type == .leftMouseUp { break }
        }
    }

    private func track(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = Double((point.x - 7) / max(1, bounds.width - 14))
        set((fraction * maxValue).rounded())
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .downArrow?: set(value - step)
        case .rightArrow?, .upArrow?: set(value + step)
        default: super.keyDown(with: event)
        }
    }

    private func set(_ next: Double) {
        let clamped = min(maxValue, max(0, next))
        guard clamped != value else { return }
        value = clamped
        changed?(clamped)
    }

    override func accessibilityValue() -> Any? { "\(Int(value))%" }
    override func accessibilityPerformIncrement() -> Bool { set(value + step); return true }
    override func accessibilityPerformDecrement() -> Bool { set(value - step); return true }
}
