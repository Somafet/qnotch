import AppKit
import UniformTypeIdentifiers
import QNotchMacCore

protocol FileTrayDisplay: AnyObject { func reload() }

// MARK: - Home card

final class FileTrayCardView: NSView, FileTrayDisplay {
    private weak var module: FileTrayModule?
    private let count = line("", size: 12, weight: .medium, color: Palette.textSecondary)
    private let tiles = NSStackView()
    private let empty: NSView

    init(module: FileTrayModule) {
        self.module = module
        empty = column([line("Drop files here", size: 13, weight: .semibold, color: Palette.textPrimary),
                        line("Files stay where they are.", size: 11, color: Palette.textTertiary)], spacing: 2)
        super.init(frame: .zero)
        tiles.orientation = .horizontal
        tiles.spacing = 8
        let stack = column([count, tiles, empty], spacing: 10)
        embed(stack, in: self, inset: 0)
        let open = NSClickGestureRecognizer(target: self, action: #selector(openTab))
        addGestureRecognizer(open)
        toolTip = "Open the Files tab"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("File tray. Opens the Files tab.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openTab() { module?.contextShell?.selectTab("files") }

    func reload() {
        guard let module else { return }
        let items = module.items
        let missing = items.filter(\.missing).count
        count.stringValue = FileTrayList.countText(items.count, missing: missing)
        count.textColor = missing > 0 ? .systemOrange : Palette.textSecondary
        count.isHidden = items.isEmpty
        empty.isHidden = !items.isEmpty
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items.prefix(4) {
            tiles.addArrangedSubview(ThumbnailView(image: module.thumbnail(for: item, size: 40), item: item, side: 40))
        }
    }
}

// MARK: - Files tab

final class FileTrayTabView: NSView, FileTrayDisplay {
    private weak var module: FileTrayModule?
    private let scroll = NSScrollView()
    private let grid = FlippedStack()
    private let status = line("", size: 11, color: Palette.textTertiary)
    private let title = line("", size: 13, weight: .semibold, color: Palette.textPrimary)
    private let overlay = FillView(fill: Palette.accentSoft, stroke: Palette.accent, radius: 14)
    private var emptyView: NSView!
    private var buttons: [HoverButton] = []
    private var selected: URL?

    init(module: FileTrayModule) {
        self.module = module
        super.init(frame: .zero)
        let add = HoverButton("Add", symbol: "plus", style: .plain, symbolSize: 12) { [weak module] in module?.addWithPanel() }
        let share = HoverButton("Share", symbol: "square.and.arrow.up", style: .plain, symbolSize: 12) { [weak self] in
            guard let self, let module = self.module else { return }
            module.share(self.targets, from: self.buttons[1])
        }
        let export = HoverButton("Export", symbol: "square.and.arrow.down.on.square", style: .plain, symbolSize: 12) { [weak self] in
            guard let self else { return }
            self.module?.export(self.targets)
        }
        let clear = HoverButton("Clear", symbol: "xmark", style: .plain, symbolSize: 11) { [weak module] in module?.clear() }
        share.toolTip = "Share the selected file, or all files: AirDrop, Messages, Mail…"
        export.toolTip = "Copy the selected file, or all files, to a folder"
        clear.toolTip = "Empty the tray. Your files are not touched."
        buttons = [add, share, export, clear]
        let header = row([title, status, spacer(), add, share, export, clear], spacing: 6)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        grid.translatesAutoresizingMaskIntoConstraints = false
        let stack = column([header, scroll], spacing: 10)
        embed(stack, in: self, inset: 0, fill: true)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        emptyView = placeholder(symbol: "tray.and.arrow.down", title: "Drop files on the notch", detail: "They stay where they are; the tray keeps a reference.",
                                action: ("Add Files…", { [weak module] in module?.addWithPanel() }))
        embed(emptyView, in: self, inset: NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0), fill: true)
        let drop = column([symbol("tray.and.arrow.down.fill", size: 26, weight: .medium, color: Palette.accent),
                           line("Drop to add to the tray", size: 14, weight: .semibold, color: Palette.textPrimary)], spacing: 8, alignment: .centerX)
        drop.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(drop)
        NSLayoutConstraint.activate([drop.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), drop.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)])
        // Over the body only, as on Windows: the header and its buttons stay readable.
        embed(overlay, in: self, inset: NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0), fill: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The selected file, or every file in the tray that still exists.
    private var targets: [URL] {
        guard let module else { return [] }
        if let selected, module.items.contains(where: { $0.url == selected }) { return [selected] }
        return module.items.filter { !$0.missing }.map(\.url)
    }

    func reload() {
        guard let module else { return }
        let items = module.items
        overlay.isHidden = !module.dropActive
        title.stringValue = items.isEmpty ? "Files" : FileTrayList.countText(items.count, missing: items.filter(\.missing).count)
        status.stringValue = module.status ?? ""
        // The drop target replaces the empty state rather than showing it through its tint.
        emptyView.isHidden = !items.isEmpty || module.dropActive
        scroll.isHidden = items.isEmpty
        buttons.dropFirst().forEach { $0.isHidden = items.isEmpty }
        if let selected, !items.contains(where: { $0.url == selected }) { self.selected = nil }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Rows of four tiles.
        var index = 0
        while index < items.count {
            let tiles = items[index..<min(index + 4, items.count)].map { item -> NSView in
                FileTile(module: module, item: item, image: module.thumbnail(for: item, size: 56), selected: item.url == selected) { [weak self] url in
                    self?.selected = self?.selected == url ? nil : url
                    self?.reload()
                }
            }
            let line = row(tiles, spacing: 6)
            line.alignment = .top
            grid.addArrangedSubview(line)
            index += 4
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", let selected { module?.quickLook(selected) } else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }
}

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A rounded thumbnail (Quick Look) or the file's Finder icon until it arrives.
private final class ThumbnailView: NSImageView {
    init(image: NSImage?, item: FileTrayModule.Item, side: CGFloat) {
        super.init(frame: .zero)
        // The type's icon until the Quick Look thumbnail arrives (also for missing files).
        self.image = image ?? NSWorkspace.shared.icon(for: UTType(filenameExtension: item.url.pathExtension) ?? (item.url.hasDirectoryPath ? .folder : .data))
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = item.missing ? 0.4 : 1
        size(self, width: side, height: side)
        toolTip = item.missing ? "\(item.name) (missing)" : item.name
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A file in the Files tab: click selects, double-click opens, space previews, drag copies out,
/// and the context menu has everything else.
private final class FileTile: FillView, NSDraggingSource {
    private weak var module: FileTrayModule?
    private let item: FileTrayModule.Item
    private let select: (URL) -> Void
    private var tracking: NSTrackingArea?
    private var hovering = false
    private let selectedLook: Bool
    private var dragHold: AnyObject?
    private var downEvent: NSEvent?

    init(module: FileTrayModule, item: FileTrayModule.Item, image: NSImage?, selected: Bool, select: @escaping (URL) -> Void) {
        self.module = module
        self.item = item
        self.select = select
        selectedLook = selected
        super.init(fill: selected ? Palette.accentSoft : nil, stroke: selected ? Palette.accent : nil, radius: 10)
        let thumb = ThumbnailView(image: image, item: item, side: 56)
        let name = label(item.name, size: 11, color: item.missing ? Palette.textTertiary : Palette.textPrimary)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.preferredMaxLayoutWidth = 140
        let stack = column([thumb, name], spacing: 6, alignment: .centerX)
        if item.missing { stack.addArrangedSubview(line("Missing", size: 10, weight: .semibold, color: .systemOrange)) }
        embed(stack, in: self, inset: NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6), fill: true)
        size(self, width: 154)
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        menu = makeMenu()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.missing ? "\(item.name), missing" : item.name)
        toolTip = item.url.path
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityPerformPress() -> Bool { module?.open(item.url); return true }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ enabled: Bool = true, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, action: action)
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        let exists = !item.missing
        add("Open", exists) { [weak self] in guard let self else { return }; self.module?.open(self.item.url) }
        add("Quick Look", exists) { [weak self] in guard let self else { return }; self.module?.quickLook(self.item.url) }
        add("Show in Finder", exists) { [weak self] in guard let self else { return }; self.module?.reveal([self.item.url]) }
        menu.addItem(.separator())
        add("Share…", exists) { [weak self] in guard let self else { return }; self.module?.share([self.item.url], from: self) }
        add("Export to Folder…", exists) { [weak self] in guard let self else { return }; self.module?.export([self.item.url]) }
        add("Copy Path") { [weak self] in guard let self else { return }; self.module?.copyPath(self.item.url) }
        menu.addItem(.separator())
        add("Remove from Tray") { [weak self] in guard let self else { return }; self.module?.remove(self.item) }
        menu.autoenablesItems = false
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuHold = module?.contextShell?.holdOpen()
        return super.menu(for: event)
    }
    private var menuHold: AnyObject?
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        menuHold = nil
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { if !selectedLook { setFill(Palette.control, animated: true) } }
    override func mouseExited(with event: NSEvent) { if !selectedLook { setFill(nil, animated: true) } }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        if event.clickCount == 2 { module?.open(item.url); downEvent = nil }
    }

    override func mouseUp(with event: NSEvent) {
        guard downEvent != nil else { return }
        downEvent = nil
        select(item.url)
        window?.makeFirstResponder(superview(of: FileTrayTabView.self))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !item.missing else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        downEvent = nil
        dragHold = module?.contextShell?.holdOpen()
        let dragging = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        dragging.setDraggingFrame(NSRect(x: bounds.midX - 24, y: bounds.midY - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [dragging], event: down, source: self)
    }

    /// Copy or link only: the drop target can never move the original.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .link] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragHold = nil }

    private func superview<T: NSView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view, !(current is T) { view = current.superview }
        return view as? T
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}
