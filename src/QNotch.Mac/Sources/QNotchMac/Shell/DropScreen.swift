import AppKit

/// What the drop screen shows for one drag: a header and, per drop source in order, the targets
/// it offers. Plain values, so the screen can rebuild only when something changed.
struct DropScreenModel: Equatable {
    struct Tile: Equatable {
        let sourceID: String
        let sourceTitle: String
        let id: String
        let title: String
        let subtitle: String?
        let glyph: String
        let enabled: Bool

        var identifier: String { "drop-\(sourceID)-\(id)" }
        var label: String { "\(title), \(sourceTitle)" }
    }

    struct Group: Equatable {
        let id: String
        let title: String
        let glyph: String
        let tiles: [Tile]
    }

    static let detail = "Choose where they go"
    static let nothing = "Nothing can take these files right now"

    let header: String
    let groups: [Group]
    var isEmpty: Bool { groups.isEmpty }

    /// "Drop <file name>" for one item, "Drop N items" for several.
    static func header(for files: [URL]) -> String {
        files.count == 1 ? "Drop \(files[0].lastPathComponent)" : "Drop \(files.count) items"
    }

    /// Asks every source for its targets (in source order); a source with none is left out.
    /// The drop actions are returned beside the model, keyed by tile identifier.
    static func make(files: [URL], sources: [DropSource]) -> (model: DropScreenModel, actions: [String: ([URL]) -> Void]) {
        var actions: [String: ([URL]) -> Void] = [:]
        let groups: [Group] = sources.sorted { ($0.order, $0.id) < ($1.order, $1.id) }.compactMap { source in
            let tiles = source.targets(files).map { target -> Tile in
                let tile = Tile(sourceID: source.id, sourceTitle: source.title, id: target.id, title: target.title,
                                subtitle: target.subtitle, glyph: target.glyph, enabled: target.enabled)
                actions[tile.identifier] = target.drop
                return tile
            }
            return tiles.isEmpty ? nil : Group(id: source.id, title: source.title, glyph: source.glyph, tiles: tiles)
        }
        return (DropScreenModel(header: header(for: files), groups: groups), actions)
    }
}

/// One target on the drop screen, styled like a Taildrop device tile. It takes no drags itself:
/// the notch surface is the only drag destination, so moving between tiles never exits it, and
/// the screen highlights the tile under the drag.
final class DropTile: NSControl, OutlineRoleProviding {
    let tile: DropScreenModel.Tile
    /// Accessibility press drops the dragged files here, like releasing over it.
    var pressed: (() -> Void)?
    var dropping = false {
        didSet { if dropping != oldValue { refreshLook() } }
    }
    private var enabledState: Bool
    override var isEnabled: Bool {
        get { enabledState }
        set { enabledState = newValue }
    }

    init(_ tile: DropScreenModel.Tile) {
        self.tile = tile
        enabledState = tile.enabled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 12
        let glyph = NSImage(systemSymbolName: tile.glyph, accessibilityDescription: nil) == nil ? "questionmark.square.dashed" : tile.glyph
        let icon = symbol(glyph, size: 18, color: tile.enabled ? Palette.textSecondary : Palette.textTertiary)
        size(icon, width: 28)
        let title = line(tile.title, size: 13, weight: .semibold, color: Palette.textPrimary)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var texts: [NSView] = [title]
        if let subtitle = tile.subtitle {
            let detail = line(subtitle, size: 11, color: Palette.textTertiary)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            texts.append(detail)
        }
        embed(row([icon, column(texts, spacing: 2), spacer()], spacing: 8), in: self,
              inset: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), fill: true)
        heightAnchor.constraint(equalToConstant: 58).isActive = true
        identifier = NSUserInterfaceItemIdentifier(tile.identifier)
        setAccessibilityIdentifier(tile.identifier)
        setAccessibilityLabel(tile.label)
        if let subtitle = tile.subtitle { setAccessibilityHelp(subtitle) }
        toolTip = tile.subtitle.map { "\(tile.title): \($0)" } ?? tile.title
        alphaValue = tile.enabled ? 1 : 0.45
        refreshLook()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var outlineRole: Outline.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { tile.enabled }
    override func accessibilityPerformPress() -> Bool {
        guard tile.enabled, let pressed else { return false }
        pressed()
        return true
    }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refreshLook() {
        layer?.backgroundColor = (dropping ? Palette.accentSoft : Palette.control).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (dropping ? Palette.accent : Palette.stroke).cgColor
    }
}

/// Covers the whole panel body while files are dragged over the notch: "Drop 2 items", "Choose
/// where they go", then a group per drop source with its target tiles. Rebuilt only when the
/// model changes, so a drag resting on a tile keeps its highlight.
final class DropScreenView: NSView {
    static let columns = 3
    private(set) var model: DropScreenModel?
    private var actions: [String: ([URL]) -> Void] = [:]
    private(set) var tiles: [DropTile] = []
    private let title = line("", size: 15, weight: .semibold, color: Palette.textPrimary)
    private let body = NSView()
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private weak var highlighted: DropTile?
    /// A tile was pressed with accessibility: the shell ends the screen and drops.
    var pressed: ((DropTile) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("drop-screen")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("drop-screen")
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = line(DropScreenModel.detail, size: 12, color: Palette.textTertiary)
        let header = column([title, detail], spacing: 2)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(stack, in: document, inset: NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0), fill: true)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        embed(scroll, in: body, inset: 0, fill: true)

        let content = column([header, body], spacing: 14)
        body.setContentHuggingPriority(.init(1), for: .vertical)
        body.setContentCompressionResistancePriority(.init(1), for: .vertical)
        embed(content, in: self, inset: NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16), fill: true)
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `model`; the views are rebuilt only when it differs from the one shown. Returns
    /// whether it changed. The drop actions are always replaced (they capture fresh state).
    @discardableResult
    func apply(_ model: DropScreenModel, actions: [String: ([URL]) -> Void]) -> Bool {
        self.actions = actions
        guard model != self.model else { return false }
        self.model = model
        title.stringValue = model.header
        setAccessibilityLabel(model.header + ". " + DropScreenModel.detail)
        highlighted = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []
        body.subviews.filter { $0 !== scroll }.forEach { $0.removeFromSuperview() }
        scroll.isHidden = model.isEmpty
        if model.isEmpty {
            embed(placeholder(symbol: "tray", title: DropScreenModel.nothing, detail: "Release anywhere to cancel."), in: body, inset: 0, fill: true)
            return true
        }
        for group in model.groups {
            let heading = row([symbol(group.glyph, size: 11, weight: .semibold, color: Palette.textSecondary),
                               line(group.title, size: 11, weight: .semibold, color: Palette.textSecondary)], spacing: 6)
            let grid = column([], spacing: 8)
            let made = group.tiles.map { tile -> DropTile in
                let view = DropTile(tile)
                view.pressed = { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.pressed?(view)
                }
                return view
            }
            tiles += made
            for start in stride(from: 0, to: made.count, by: Self.columns) {
                var cells: [NSView] = Array(made[start..<min(start + Self.columns, made.count)])
                while cells.count < Self.columns { cells.append(NSView()) }
                let cellRow = row(cells, spacing: 8)
                cellRow.distribution = .fillEqually
                grid.addArrangedSubview(cellRow)
                cellRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            }
            let section = column([heading, grid], spacing: 8)
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            grid.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return true
    }

    /// The tile under `point` (window coordinates), enabled or not.
    func tile(at point: NSPoint) -> DropTile? {
        tiles.first { tile in
            !tile.isHiddenOrHasHiddenAncestor && tile.visibleRect.contains(tile.convert(point, from: nil))
        }
    }

    /// Highlights the enabled tile under the drag; copy over it, refused anywhere else.
    @discardableResult
    func hover(at point: NSPoint?) -> NSDragOperation {
        let target = point.flatMap(tile(at:)).flatMap { $0.tile.enabled ? $0 : nil }
        if target !== highlighted {
            highlighted?.dropping = false
            target?.dropping = true
            highlighted = target
        }
        return target == nil ? [] : .copy
    }

    /// The drop action of an enabled tile.
    func action(for tile: DropTile) -> (([URL]) -> Void)? {
        tile.tile.enabled ? actions[tile.tile.identifier] : nil
    }
}
