import AppKit

/// A module can put page-wide actions in the fixed title row. Filters and descriptive
/// section headings stay in its body. The controls remain owned and updated by the module.
protocol TabHeaderProviding: NSView {
    var tabHeaderActions: NSView { get }
}

/// Shell-owned chrome for every registered tab except Search (its labeled field is the
/// landmark). The title never participates in a module's empty state or scroll document.
final class TabPageView: NSView, PanelKeyboardContent {
    static let titleRowHeight: CGFloat = 28
    static let bodyGap: CGFloat = 12

    let heading: NSTextField
    let header = NSView()
    let content: NSView
    let actions: NSView?

    init(id: String, title: String, content: NSView) {
        self.content = content
        heading = line(title, size: 14, weight: .semibold, color: Palette.textPrimary)
        actions = (content as? TabHeaderProviding)?.tabHeaderActions
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("tab-page-" + id)
        header.identifier = NSUserInterfaceItemIdentifier("tab-header-" + id)
        heading.setAccessibilityIdentifier("tab-title-" + id)
        // Native named group/title linkage keeps the full landmark available when truncated.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        setAccessibilityTitleUIElement(heading)
        heading.setAccessibilityLabel(title)
        heading.toolTip = title
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [header, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heading.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(heading)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.titleRowHeight),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            heading.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.bodyGap),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        if let actions {
            // Existing module buttons use 30pt icon defaults. This slot has a 28pt hit row.
            func fitButtons(_ view: NSView) {
                if view is HoverButton { size(view, height: Self.titleRowHeight) }
                view.subviews.forEach(fitButtons)
            }
            fitButtons(actions)
            actions.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(actions)
            actions.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.setContentHuggingPriority(.required, for: .horizontal)
            if let stack = actions as? NSStackView {
                // NSStackView's internal edge spaces have their own hugging priority.
                // Without this, the slot fills the row while its buttons float beside the title.
                stack.setHuggingPriority(.required, for: .horizontal)
                stack.setClippingResistancePriority(.required, for: .horizontal)
            }
            NSLayoutConstraint.activate([
                actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                actions.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor),
                actions.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
                heading.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -12)
            ])
        } else {
            heading.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusKeyboard() { (content as? PanelKeyboardContent)?.focusKeyboard() }
}
