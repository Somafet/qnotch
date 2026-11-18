import AppKit

/// A module can put page-wide actions in a trailing action row. Filters and descriptive
/// section headings stay in its body. The controls remain owned and updated by the module.
protocol TabHeaderProviding: NSView {
    var tabHeaderActions: NSView { get }
}

/// Shell-owned wrapper for every registered tab except Search (its labeled field is the
/// landmark). There is no visible page title: the tab bar already names the active page, and
/// the page keeps its name as an accessibility group label. Pages with page-wide actions get a
/// fixed trailing action row while any of those actions is visible; otherwise (no actions, or
/// all of them hidden, like Clipboard's Clear with nothing to clear) the body starts directly
/// under the panel header.
final class TabPageView: NSView, PanelKeyboardContent {
    static let actionRowHeight: CGFloat = 28
    static let bodyGap: CGFloat = 8

    let header = NSView()
    let content: NSView
    let actions: NSView?
    private var headerHeight: NSLayoutConstraint?
    private var bodyTop: NSLayoutConstraint?
    private var hiddenObservations: [NSKeyValueObservation] = []
    private(set) var showsActionRow = false

    init(id: String, title: String, content: NSView) {
        self.content = content
        actions = (content as? TabHeaderProviding)?.tabHeaderActions
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("tab-page-" + id)
        header.identifier = NSUserInterfaceItemIdentifier("tab-header-" + id)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        for view in [header, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
        let bodyTop = content.topAnchor.constraint(equalTo: header.bottomAnchor)
        self.headerHeight = headerHeight
        self.bodyTop = bodyTop
        header.clipsToBounds = true
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            headerHeight,
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyTop,
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        if let actions {
            // Existing module buttons use 30pt icon defaults. This slot has a 28pt hit row.
            func fitButtons(_ view: NSView) {
                if view is HoverButton { size(view, height: Self.actionRowHeight) }
                view.subviews.forEach(fitButtons)
            }
            fitButtons(actions)
            actions.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(actions)
            actions.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.setContentHuggingPriority(.required, for: .horizontal)
            if let stack = actions as? NSStackView {
                // NSStackView's internal edge spaces have their own hugging priority.
                stack.setHuggingPriority(.required, for: .horizontal)
                stack.setClippingResistancePriority(.required, for: .horizontal)
            }
            // The row collapses to zero height when every action is hidden; the vertical fit
            // yields then instead of breaking.
            let top = actions.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor)
            let bottom = actions.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor)
            top.priority = .defaultHigh
            bottom.priority = .defaultHigh
            NSLayoutConstraint.activate([
                actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                actions.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor),
                top, bottom
            ])
            // Modules toggle their action buttons' visibility; collapse the row when none show.
            func observe(_ view: NSView) {
                hiddenObservations.append(view.observe(\.isHidden) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updateActionRow() }
                })
                view.subviews.forEach(observe)
            }
            observe(actions)
        }
        updateActionRow()
    }

    private func updateActionRow() {
        func visibleControl(_ view: NSView) -> Bool {
            !view.isHidden && (view is NSControl || view.subviews.contains(where: visibleControl))
        }
        let shows = actions.map(visibleControl) ?? false
        showsActionRow = shows
        headerHeight?.constant = shows ? Self.actionRowHeight : 0
        bodyTop?.constant = shows ? Self.bodyGap : 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusKeyboard() { (content as? PanelKeyboardContent)?.focusKeyboard() }
}
