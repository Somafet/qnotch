import AppKit
import UniformTypeIdentifiers

/// Sidebar settings window, laid out like the Windows one (navigation left, titled pages of
/// label/detail/control rows right) and styled like System Settings. Follows the system appearance.
final class SettingsController: NSObject {
    static let contentWidth: CGFloat = 460
    private static let sidebarWidth: CGFloat = 210
    private static let pagePadding: CGFloat = 30

    private struct Page {
        let id: String
        let title: String
        let symbol: String
        let tint: NSColor
        let make: () -> NSView
    }

    private unowned let shell: ShellController
    private(set) var window: NSWindow
    private(set) var selected = "general"
    private let navigation = NSStackView()
    private let scroll = NSScrollView()
    private var rows: [String: NavRow] = [:]
    private var issue: NSTextField?
    private var issueBanner: NSView?

    init(shell: ShellController) {
        self.shell = shell
        let size = NSSize(width: Self.sidebarWidth + Self.contentWidth + Self.pagePadding * 2, height: 540)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "QNotch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let root = makeRoot()
        window.contentView = root
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: size.width), root.heightAnchor.constraint(equalToConstant: size.height)])
        window.setContentSize(size)
        window.center()
    }

    /// App pages before the module sections, with extra search words (Search, Settings source).
    static let appPages: [(id: String, title: String, symbol: String, tint: NSColor, keywords: String)] = [
        ("general", "General", "gearshape.fill", .systemGray, "display monitor motion animation preferences"),
        ("features", "Features", "square.grid.2x2.fill", .systemBlue, "modules enable disable turn on off"),
        ("hotkeys", "Hotkeys", "command", .systemIndigo, "shortcuts keyboard keys"),
        ("sounds", "Sounds", "speaker.wave.2.fill", .systemPink, "audio chime alert")
    ]

    private var pages: [Page] {
        var pages = Self.appPages.map { info in
            Page(id: info.id, title: info.title, symbol: info.symbol, tint: info.tint) { [unowned self] in self.appPage(info.id) }
        }
        for section in shell.registries.settingsSections.items {
            pages.append(Page(id: "module." + section.id, title: section.title, symbol: section.symbol, tint: section.tint) {
                [unowned self] in self.page(section.title, [section.makeView()])
            })
        }
        pages.append(Page(id: "about", title: "About", symbol: "info.circle.fill", tint: .systemGray) { [unowned self] in self.aboutPage() })
        return pages
    }

    func show(page: String? = nil) {
        rebuildNavigation()
        select(page.flatMap { id in pages.contains { $0.id == id } ? id : nil } ?? selected, animated: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A shortcut changed (recorded, taken by another app, or a module was turned off).
    func refreshShortcuts() { if window.isVisible, selected == "hotkeys", !recording { select("hotkeys", animated: false) } }
    private var recording: Bool { window.firstResponder is ShortcutRecorder }

    func refreshDisplays() { if window.isVisible, selected == "general" { select("general", animated: false) } }

    func refreshIssue() {
        let text = [shell.displayMessage, shell.store.problem ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        issue?.stringValue = text
        issueBanner?.isHidden = text.isEmpty
    }

    // MARK: Structure

    private func makeRoot() -> NSView {
        let root = NSView()
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        let divider = NSBox()
        divider.boxType = .separator
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 2
        let content = NSView()
        content.wantsLayer = true
        for view in [sidebar, divider, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return root
    }

    private func rebuildNavigation() {
        navigation.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        let pages = pages
        if !pages.contains(where: { $0.id == selected }) { selected = "general" }
        for (index, page) in pages.enumerated() {
            let item = NavRow(title: page.title, symbol: page.symbol, tint: page.tint) { [weak self] in self?.select(page.id, animated: true) }
            navigation.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
            rows[page.id] = item
            // Gaps separate app pages, module pages and About, as in System Settings.
            let next = index + 1 < pages.count ? pages[index + 1].id : nil
            if page.id == Self.appPages.last?.id || next == "about" { navigation.setCustomSpacing(14, after: item) }
        }
    }

    func select(_ id: String, animated: Bool) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        selected = id
        for (key, row) in rows { row.isSelected = key == id }
        issue = nil
        issueBanner = nil
        let content = page.make()
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(content, in: document, inset: NSEdgeInsets(top: 44, left: Self.pagePadding, bottom: 30, right: Self.pagePadding))
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        refreshIssue()
        if animated { document.wantsLayer = true; Motion.reveal(document, duration: 0.2, dy: -6) }
    }

    // MARK: Pages

    private func page(_ title: String, subtitle: String? = nil, _ groups: [NSView]) -> NSView {
        let heading = label(title, size: 22, weight: .bold)
        var views: [NSView] = [heading]
        if let subtitle {
            let note = label(subtitle, size: 12, color: .secondaryLabelColor)
            note.preferredMaxLayoutWidth = Self.contentWidth
            views.append(note)
        }
        let stack = column(views + groups, spacing: 22)
        if subtitle != nil { stack.setCustomSpacing(6, after: heading) }
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return stack
    }

    private func generalPage() -> NSView {
        let width = Self.contentWidth
        var titles = ["Main display"]
        var ids: [UInt32?] = [nil]
        for (index, screen) in NSScreen.screens.enumerated() {
            titles.append("\(screen.localizedName) (\(index + 1))")
            ids.append(ShellController.displayID(screen))
        }
        if let selected = shell.general.displayID, !ids.contains(where: { $0 == selected }) {
            titles.append("Disconnected display")
            ids.append(selected)
        }
        let picker = ActionPopUp("Display for QNotch", items: titles, selected: ids.firstIndex(where: { $0 == shell.general.displayID }) ?? 0) { [weak self] index in
            self?.shell.updateGeneral { $0.displayID = ids[index] }
            self?.refreshIssue()
        }
        let motion = ActionSwitch("Reduce motion", value: shell.general.reduceMotion) { [weak self] value in
            self?.shell.updateGeneral { $0.reduceMotion = value }
        }
        return page("General", [
            banner(),
            settingsGroup([
                settingsRow("Display", detail: "Where the notch lives. If the chosen display is disconnected, QNotch moves to the main display.", control: picker, width: width)
            ], width: width),
            settingsGroup([
                settingsRow("Reduce motion", detail: "Opens, closes and switches tabs without animation. The macOS Reduce Motion setting is always honored.", control: motion, width: width)
            ], width: width)
        ])
    }

    private func appPage(_ id: String) -> NSView {
        switch id {
        case "features": return featuresPage()
        case "hotkeys": return hotkeysPage()
        case "sounds": return soundsPage()
        default: return generalPage()
        }
    }

    private func featuresPage() -> NSView {
        let width = Self.contentWidth
        let rows = ModuleList.all.map { info -> NSView in
            let toggle = ActionSwitch(info.title, value: shell.general.isEnabled(info.id)) { [weak self] value in
                self?.shell.updateGeneral { $0.setEnabled(info.id, value) }
                self?.rebuildNavigation()
                self?.rows["features"]?.isSelected = true
            }
            return featureRow(info.title, detail: info.detail, symbol: info.symbol, tint: info.tint, control: toggle, width: width)
        }
        return page("Features", subtitle: "Turn modules on or off. A module that is off is not loaded and uses no resources. Changes apply right away.", [
            settingsGroup(rows, width: width)
        ])
    }

    private func hotkeysPage() -> NSView {
        let width = Self.contentWidth
        let rows = shell.shortcuts.items.map { shortcut -> NSView in
            let recorder = ShortcutRecorder(registry: shell.shortcuts, id: shortcut.id)
            recorder.finished = { [weak self] in self?.select("hotkeys", animated: false) }
            let reset = HoverButton(symbol: "arrow.uturn.backward", style: .icon, symbolSize: 12, label: "Reset \(shortcut.title) to \(shortcut.defaultCombo?.display ?? "off")") { [weak self] in
                self?.shell.shortcuts.reset(shortcut.id)
                self?.select("hotkeys", animated: false)
            }
            reset.tint = .secondaryLabelColor
            reset.isHidden = shortcut.combo == shortcut.defaultCombo
            var detail = shortcut.hint
            if let owner = shortcut.usedBy { detail += " Used by \(owner)." }
            else if shortcut.taken { detail += " Taken by another app. Pick another shortcut." }
            return settingsRow(shortcut.title, detail: detail, control: row([reset, recorder], spacing: 4), width: width)
        }
        return page("Hotkeys", subtitle: "Click a shortcut, then press the new keys. A shortcut needs ⌃, ⌥ or ⌘. Esc cancels; Delete turns it off.", [
            settingsGroup(rows, footer: "Hotkeys work from any app without Accessibility access. If another app already uses a key, QNotch leaves it alone.", width: width)
        ])
    }

    private func soundsPage() -> NSView {
        let width = Self.contentWidth
        let sounds = shell.sounds.items
        guard !sounds.isEmpty else {
            return page("Sounds", [settingsGroup([settingsRow("No sounds", detail: "Features that play sounds list them here when they are on.", width: width)], width: width)])
        }
        let names = SoundRegistry.systemNames
        let rows = sounds.map { sound -> NSView in
            let current = shell.sounds.choice(for: sound.id)
            var titles = names
            var values = names
            if current.hasPrefix("/") { titles.append(SoundRegistry.title(of: current)); values.append(current) }
            titles.append("Choose File…")
            let popUp = ActionPopUp(sound.title, items: titles, selected: values.firstIndex(of: current) ?? names.firstIndex(of: sound.defaultName) ?? 0) { [weak self] index in
                guard let self else { return }
                if index < values.count {
                    self.shell.sounds.choose(sound.id, values[index])
                    self.shell.sounds.play(sound.id)
                } else { self.chooseSoundFile(sound.id) }
                self.select("sounds", animated: false)
            }
            let play = HoverButton(symbol: "play.fill", style: .icon, symbolSize: 11, label: "Play \(sound.title)") { [weak self] in self?.shell.sounds.play(sound.id) }
            play.tint = .secondaryLabelColor
            let reset = HoverButton(symbol: "arrow.uturn.backward", style: .icon, symbolSize: 12, label: "Reset \(sound.title) to \(sound.defaultName)") { [weak self] in
                self?.shell.sounds.choose(sound.id, nil)
                self?.select("sounds", animated: false)
            }
            reset.tint = .secondaryLabelColor
            reset.isHidden = shell.sounds.isDefault(sound.id)
            return settingsRow(sound.title, detail: sound.hint, control: row([reset, play, popUp], spacing: 2), width: width)
        }
        return page("Sounds", subtitle: "Pick a system sound or your own audio file. Turn a sound on or off on its feature's page.", [
            settingsGroup(rows, footer: "Sounds follow the alert volume in System Settings, Sound.", width: width)
        ])
    }

    private func chooseSoundFile(_ id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SoundRegistry.fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.shell.sounds.choose(id, url.path)
            self.shell.sounds.play(id)
            self.select("sounds", animated: false)
        }
    }

    private func aboutPage() -> NSView {
        let width = Self.contentWidth
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let tile = FillView(fill: .black, stroke: NSColor(white: 1, alpha: 0.12), radius: 14)
        size(tile, width: 60, height: 60)
        let glyph = symbol("circle.lefthalf.filled", size: 26, weight: .medium, color: .white)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        let identity = row([tile, column([label("QNotch", size: 20, weight: .bold),
                                          label("Version \(version) · Development build", size: 12, color: .secondaryLabelColor)], spacing: 2)], spacing: 14)
        let unavailable = label("Unavailable", size: 12, color: .secondaryLabelColor)
        let stack = column([
            identity,
            settingsGroup([
                settingsRow("Automatic updates", detail: "Not available in development builds. This build makes no network requests.", control: unavailable, width: width)
            ], width: width),
            settingsGroup([
                settingsRow("Hover the notch", detail: "Opens the panel without taking the keyboard.", width: width),
                settingsRow("Click the notch", detail: "Opens it for typing. Start typing to search, or press ⌘F.", width: width),
                settingsRow("Escape or click outside", detail: "Closes the panel and returns focus to your app.", width: width),
                settingsRow("Menu bar", detail: "Open Panel, Settings and Quit are always in the QNotch menu.", width: width)
            ], header: "Using QNotch", width: width)
        ], spacing: 22)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    private func featureRow(_ title: String, detail: String, symbol name: String, tint: NSColor, control: NSView?, width: CGFloat) -> NSView {
        let icon = iconTile(name, tint: tint, size: 28)
        let rowView = settingsRow(title, detail: detail, control: control, width: width - 40)
        let wrap = row([icon, rowView], spacing: 0)
        let container = NSView()
        embed(wrap, in: container, inset: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0), fill: true)
        rowView.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        return container
    }

    private func banner() -> NSView {
        let text = label("", size: 12)
        text.preferredMaxLayoutWidth = Self.contentWidth - 60
        issue = text
        let box = FillView(fill: NSColor.systemOrange.withAlphaComponent(0.12), stroke: NSColor.systemOrange.withAlphaComponent(0.3), radius: 10)
        let content = row([symbol("exclamationmark.triangle.fill", size: 14, color: .systemOrange), text], spacing: 10)
        embed(content, in: box, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), fill: true)
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        issueBanner = box
        return box
    }

    // MARK: Diagnostics

    /// Renders every page into `directory` as settings-<id>.png (and settings.png for General).
    /// Pages are rendered from their document view: the window's own scroll and sidebar materials
    /// are composited by the system and are not reproduced by view caching on every macOS release.
    func snapshotPages(to directory: URL) throws {
        let original = selected
        for page in pages {
            select(page.id, animated: false)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let view = scroll.documentView else { continue }
            let name = page.id.replacingOccurrences(of: "module.", with: "")
            try ShellController.snapshot(view: view, to: directory.appendingPathComponent("settings-\(name).png"))
            if page.id == "general" { try ShellController.snapshot(view: view, to: directory.appendingPathComponent("settings.png")) }
        }
        select(original, animated: false)
    }
}

func iconTile(_ name: String, tint: NSColor, size side: CGFloat = 22) -> NSView {
    let tile = FillView(fill: tint, radius: side * 0.26)
    size(tile, width: side, height: side)
    let glyph = symbol(name, size: side * 0.52, weight: .semibold, color: .white)
    glyph.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(glyph)
    NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
    return tile
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Sidebar item: tinted icon tile and title; accent fill when selected.
private final class NavRow: NSButton {
    var isSelected = false { didSet { refresh(animated: oldValue != isSelected) } }
    private let background = FillView(radius: 7)
    private let text: NSTextField
    private let handler: () -> Void
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, symbol name: String, tint: NSColor, action: @escaping () -> Void) {
        handler = action
        text = line(title, size: 13)
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(title)
        let content = row([iconTile(name, tint: tint), text], spacing: 9)
        for view in [background, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh(animated: true) }

    private func refresh(animated: Bool) {
        background.setFill(isSelected ? .controlAccentColor : hovering ? NSColor.labelColor.withAlphaComponent(0.06) : nil, animated: animated)
        text.textColor = isSelected ? .white : .labelColor
        text.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}
