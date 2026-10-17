import AppKit
import QNotchMacCore
import ServiceManagement
import UniformTypeIdentifiers

/// Sidebar settings window, laid out like the Windows one (navigation left, titled pages of
/// label/detail/control rows right) and styled like System Settings. Follows the system appearance.
final class SettingsController: NSObject, NSTextFieldDelegate {
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
        ("sounds", "Sounds", "speaker.wave.2.fill", .systemPink, "audio chime alert"),
        ("appearance", "Appearance", "paintbrush.fill", .systemPurple, "accent color name photo picture cards motion animation"),
        ("gamemode", "Game mode", "gamecontroller.fill", .systemGreen, "games full screen fullscreen focus")
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
        let hover = SettingsSlider("Hover delay", value: shell.general.hoverDelayMs, range: GeneralSettings.hoverRange, step: 10) { [weak self] value in
            self?.shell.updateGeneral { $0.hoverDelayMs = value }
        }
        let leave = SettingsSlider("Close delay", value: shell.general.closeDelayMs, range: GeneralSettings.closeRange, step: 50) { [weak self] value in
            self?.shell.updateGeneral { $0.closeDelayMs = value }
        }
        let pin = ActionSwitch("Keep panel open", value: shell.general.pinned) { [weak self] _ in self?.shell.togglePin() }
        return page("General", [
            banner(),
            settingsGroup([
                settingsRow("Display", detail: "Where the notch lives. If the chosen display is disconnected, QNotch moves to the main display.", control: picker, width: width)
            ], width: width),
            settingsGroup([
                settingsRow("Hover delay", detail: "How long the pointer rests on the notch before the panel opens.", control: hover, width: width),
                settingsRow("Close delay", detail: "How long after the pointer leaves before the panel closes.", control: leave, width: width),
                settingsRow("Keep panel open", detail: "The panel stays open until you close it with Escape, the pin, or the toggle hotkey. Also the pin in the panel header.", control: pin, width: width)
            ], header: "Panel", width: width),
            settingsGroup([loginRow(width: width)], width: width),
            setupGroup(width: width)
        ])
    }

    // MARK: Setup codes

    private var setupSnapshot: SetupCode.Snapshot {
        let store = shell.store
        return SetupCode.Snapshot(general: shell.general, gameMode: shell.gameMode.settings,
                                  timer: store.load("timer", default: TimerSettings()), weather: store.load("weather", default: WeatherSettings()),
                                  notifications: store.load("notifications", default: NotificationSettings()),
                                  ai: store.load("ai", default: AiSettings()), agents: store.load("agents", default: AgentsSettings()))
    }
    private var setupPlan: SetupCode.Plan?

    private func setupGroup(width: CGFloat) -> NSView {
        let note = label("", size: 11, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = width - 30
        let copy = actionButton("Copy Code") { [weak self, weak note] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SetupCode.export(self.setupSnapshot), forType: .string)
            note?.stringValue = "Copied. Paste it into QNotch on another Mac or PC."
        }
        let field = NSTextField()
        field.placeholderString = "qnotch-setup-1:…"
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        field.setAccessibilityLabel("Setup code")
        let apply = actionButton("Apply and Restart") { [weak self] in self?.applySetup() }
        apply.isEnabled = false
        let check = actionButton("Check") { [weak self, weak field, weak note, weak apply] in
            guard let self, let field else { return }
            do {
                let plan = try SetupCode.read(field.stringValue, current: self.setupSnapshot, modules: ModuleList.all.map(\.id))
                self.setupPlan = plan
                let on: [String] = plan.turnsOn.compactMap { id in ModuleList.all.first { $0.id == id }?.title }
                let changes: String = "Changes \(plan.titles.joined(separator: ", "))."
                let extra: String = on.isEmpty ? "" : " Turns on \(on.joined(separator: ", "))."
                note?.stringValue = changes + extra
                apply?.isEnabled = true
            } catch {
                self.setupPlan = nil
                note?.stringValue = (error as? SetupCode.Failure)?.message ?? "This code could not be read."
                apply?.isEnabled = false
            }
        }
        let box = NSView()
        embed(note, in: box, inset: NSEdgeInsets(top: 0, left: 14, bottom: 8, right: 14), fill: true)
        return settingsGroup([
            settingsRow("Share your setup", detail: "A code with your layout, features and preferences (no accounts, tokens, history, display or hotkeys). It also works with QNotch for Windows.", control: copy, width: width),
            settingsRow("Apply a setup code", control: row([field, check], spacing: 6), width: width),
            box,
            settingsRow("", control: apply, width: width)
        ], width: width)
    }

    private func applySetup() {
        guard let plan = setupPlan else { return }
        let store = shell.store, s = plan.result
        store.save("general", s.general)
        store.save("gamemode", s.gameMode)
        store.save("timer", s.timer)
        store.save("weather", s.weather)
        store.save("notifications", s.notifications)
        store.save("ai", s.ai)
        store.save("agents", s.agents)
        Self.relaunch()
    }

    /// Starts a new copy once this one has quit (one instance per data folder). The helper waits
    /// for this process to exit, which releases instance.lock, rather than for a fixed time;
    /// a slow teardown must not leave the new copy exiting as "already running".
    static func relaunch() {
        let bundle = Bundle.main.bundlePath
        var command = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open -n \"$0\""
        var arguments = [bundle, String(ProcessInfo.processInfo.processIdentifier)]
        if let directory = ProcessInfo.processInfo.environment["QNOTCH_MAC_DATA_DIR"] ?? {
            let args = ProcessInfo.processInfo.arguments
            return args.firstIndex(of: "--data-dir").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }() {
            command += " --args --data-dir \"$2\""
            arguments.append(directory)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command] + arguments
        try? process.run()
        NSApp.terminate(nil)
    }

    private func loginRow(width: CGFloat) -> NSView {
        let service = SMAppService.mainApp
        let status = service.status
        let toggle = ActionSwitch("Open at login", value: status == .enabled || status == .requiresApproval) { [weak self] value in
            do {
                if value { try service.register() } else { try service.unregister() }
            } catch {
                let alert = NSAlert()
                alert.messageText = value ? "QNotch could not be added to your login items." : "QNotch could not be removed from your login items."
                alert.informativeText = "You can manage login items in System Settings, General, Login Items."
                if let window = self?.window { alert.beginSheetModal(for: window) }
            }
            self?.select("general", animated: false)
        }
        var detail = "Starts QNotch when you log in. macOS lists it in System Settings, General, Login Items."
        var control: NSView = toggle
        if status == .requiresApproval {
            detail = "Waiting for your approval in System Settings, General, Login Items."
            let open = NSButton(title: "Open Login Items", target: nil, action: nil)
            open.bezelStyle = .rounded
            open.target = self
            open.action = #selector(openLoginItems)
            control = row([open, toggle], spacing: 8)
        }
        return settingsRow("Open at login", detail: detail, control: control, width: width)
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    private func appearancePage() -> NSView {
        let width = Self.contentWidth
        let accent = AccentPicker(selected: shell.general.accent) { [weak self] value in
            self?.shell.updateGeneral { $0.accent = value }
            self?.select("appearance", animated: false)
        }
        let motion = ActionSwitch("Reduce motion", value: shell.general.reduceMotion) { [weak self] value in
            self?.shell.updateGeneral { $0.reduceMotion = value }
        }
        let name = NSTextField(string: shell.general.profileName ?? "")
        name.placeholderString = GeneralSettings.displayName(chosen: nil, fullUserName: NSFullUserName())
        name.setAccessibilityLabel("Display name")
        name.widthAnchor.constraint(equalToConstant: 160).isActive = true
        name.target = self
        name.action = #selector(nameChanged(_:))
        name.delegate = self
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseProfileImage))
        choose.bezelStyle = .rounded
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeProfileImage))
        remove.bezelStyle = .rounded
        remove.isHidden = shell.profile.image == nil
        var photoControls: [NSView] = [remove, choose]
        if let image = shell.profile.image {
            let preview = NSImageView(image: image)
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 14
            preview.layer?.masksToBounds = true
            size(preview, width: 28, height: 28)
            photoControls.insert(preview, at: 0)
        }
        var cards: [NSView] = shell.registries.cards.items.map { card in
            let toggle = ActionSwitch(card.title, value: shell.general.isCardVisible(card.id)) { [weak self] value in
                self?.shell.updateGeneral { $0.setCardVisible(card.id, value) }
            }
            return settingsRow(card.title, control: toggle, width: width)
        }
        if cards.isEmpty { cards = [settingsRow("No cards", detail: "Turn on features to add their cards to Home.", width: width)] }
        return page("Appearance", [
            settingsGroup([
                settingsRow("Accent color", detail: "Buttons, progress and highlights in the notch. Automatic follows the macOS accent color.", control: accent, width: width),
                settingsRow("Reduce motion", detail: "Opens, closes and switches tabs without animation. The macOS Reduce Motion setting is always honored.", control: motion, width: width)
            ], footer: "The notch is always dark, like the hardware around it. Settings follows the macOS appearance.", width: width),
            settingsGroup([
                settingsRow("Display name", detail: "Shown in the panel header. Empty uses your account's first name.", control: name, width: width),
                settingsRow("Profile picture", detail: "A picture for the panel header. QNotch keeps a small copy.", control: row(photoControls, spacing: 8), width: width)
            ], header: "Profile", width: width),
            settingsGroup(cards, header: "Home cards", footer: "Hidden cards keep their place and come back where they were.", width: width)
        ])
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = value.isEmpty ? nil : String(value.prefix(40))
        guard next != shell.general.profileName else { return }
        shell.updateGeneral { $0.profileName = next }
    }

    @objc private func chooseProfileImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .webP].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a profile picture"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if !self.shell.setProfileImage(from: url) {
                let alert = NSAlert()
                alert.messageText = "That picture could not be used."
                alert.informativeText = "Choose a PNG, JPEG, HEIC or similar image."
                alert.beginSheetModal(for: self.window)
            }
            self.select("appearance", animated: false)
        }
    }

    @objc private func removeProfileImage() {
        _ = shell.setProfileImage(from: nil)
        select("appearance", animated: false)
    }

    private func appPage(_ id: String) -> NSView {
        switch id {
        case "features": return featuresPage()
        case "hotkeys": return hotkeysPage()
        case "sounds": return soundsPage()
        case "appearance": return appearancePage()
        case "gamemode": return gameModePage()
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

    func refreshGameMode() { if window.isVisible, selected == "gamemode" { select("gamemode", animated: false) } }

    private func gameModePage() -> NSView {
        let width = Self.contentWidth
        let game = shell.gameMode!
        let modes: [GameOverride] = [.auto, .on, .off]
        let mode = ActionPopUp("Mode", items: ["Automatic", "On", "Off"], selected: modes.firstIndex(of: game.override) ?? 0) { [weak self] index in
            self?.shell.gameMode.override = modes[index]
        }
        let auto = ActionSwitch("Automatic detection", value: game.settings.autoDetect) { value in game.set { $0.autoDetect = value } }
        let any = ActionSwitch("Any full-screen app", value: game.settings.anyFullScreen) { value in game.set { $0.anyFullScreen = value } }
        let opacity = NSSlider(value: Double(game.settings.opacity), minValue: 30, maxValue: 100, target: nil, action: nil)
        opacity.controlSize = .small
        opacity.widthAnchor.constraint(equalToConstant: 140).isActive = true
        opacity.onAction { [weak opacity] in
            guard let opacity, NSApp.currentEvent?.type != .leftMouseDragged else { return }
            game.set { $0.opacity = Int(opacity.doubleValue.rounded()) }
        }
        opacity.isContinuous = true
        opacity.setAccessibilityLabel("Opacity")
        // One switch per feature that shows something beside the notch.
        let owners = Array(Set(shell.registries.segments.items.compactMap { shell.registries.segments.owner(of: $0.id) }))
        let features = ModuleList.all.filter { owners.contains($0.id) }
        let segmentRows = features.map { info -> NSView in
            let toggle = ActionSwitch(info.title, value: !game.settings.hiddenModules.contains(info.id)) { value in
                game.set { settings in
                    settings.hiddenModules.removeAll { $0 == info.id }
                    if !value { settings.hiddenModules.append(info.id) }
                }
            }
            return settingsRow(info.title, control: toggle, width: width)
        }
        func appList(_ title: String, _ key: WritableKeyPath<GameModeSettings, [String]>, detail: String) -> NSView {
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            let add = ActionPopUp("Add an app", items: ["Add a running app…"] + running.map { $0.localizedName ?? $0.bundleIdentifier! }, selected: 0) { [weak self] index in
                guard index > 0, let id = running[index - 1].bundleIdentifier else { return }
                game.set { settings in
                    settings.always.removeAll { $0 == id }; settings.never.removeAll { $0 == id }
                    settings[keyPath: key].append(id)
                }
                self?.select("gamemode", animated: false)
            }
            var rows: [NSView] = [settingsRow(title, detail: detail, control: add, width: width)]
            for id in game.settings[keyPath: key] {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
                let remove = ActionSwitch(name, value: true) { [weak self] _ in
                    game.set { $0[keyPath: key].removeAll { $0 == id } }
                    self?.select("gamemode", animated: false)
                }
                rows.append(settingsRow(name, detail: id, control: remove, width: width))
            }
            return settingsGroup(rows, width: width)
        }
        return page("Game mode", subtitle: "While a game or full-screen app is in front, the notch steps aside: it does not open, ignores the pointer and shows only a quiet status line.", [
            settingsGroup([
                settingsRow("Mode", detail: game.status + ". ⌃⌥G cycles it; also in the QNotch menu.", control: mode, width: width),
                settingsRow("Automatic detection", detail: "A game (by its App Store category) with a window covering the whole display, checked when apps or Spaces change.", control: auto, width: width),
                settingsRow("Any full-screen app", detail: "Also step aside for full-screen apps that are not games, as QNotch for Windows does. Off, so the notch keeps working in full-screen Spaces.", control: any, width: width),
                settingsRow("Opacity", detail: "Of the status beside the notch while game mode is on.", control: opacity, width: width)
            ], width: width),
            settingsGroup(segmentRows.isEmpty ? [settingsRow("Nothing to show", width: width)] : segmentRows, header: "Show in game mode", width: width),
            appList("Always use game mode", \.always, detail: "Even in a window. Add games that do not declare the games category."),
            appList("Never use game mode", \.never, detail: "Never wins.")
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
                settingsRow("Automatic updates", detail: "Not available in development builds: installing updates needs Developer ID signing.", control: unavailable, width: width)
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

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field.accessibilityLabel() == "Display name" { nameChanged(field) }
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

/// Slider with a live "120 ms" readout; saves when the drag ends (not on every pixel).
private final class SettingsSlider: NSStackView {
    private let slider: NSSlider
    private let readout = NSTextField(labelWithString: "")
    private let step: Int
    private let changed: (Int) -> Void

    init(_ title: String, value: Int, range: ClosedRange<Int>, step: Int, changed: @escaping (Int) -> Void) {
        slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), target: nil, action: nil)
        self.step = step
        self.changed = changed
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel(title)
        slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 58).isActive = true
        addArrangedSubview(slider)
        addArrangedSubview(readout)
        show(value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var snapped: Int { Int((slider.doubleValue / Double(step)).rounded()) * step }
    private func show(_ value: Int) {
        readout.stringValue = "\(value) ms"
        slider.setAccessibilityValue("\(value) milliseconds")
    }

    @objc private func moved() {
        show(snapped)
        let event = NSApp.currentEvent?.type
        if event != .leftMouseDragged { slider.doubleValue = Double(snapped); changed(snapped) }
    }
}

/// "Automatic" plus the Windows accent swatches, as round buttons.
private final class AccentPicker: NSStackView {
    init(selected: String?, changed: @escaping (String?) -> Void) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        let options: [(String?, NSColor, String)] = [(nil, .controlAccentColor, "Automatic")] +
            GeneralSettings.accents.map { ($0, Palette.hex($0) ?? .systemBlue, $0) }
        for (value, color, title) in options {
            let button = AccentSwatch(color: color, multicolor: value == nil, selected: value == selected, label: title) { changed(value) }
            addArrangedSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Accent color")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class AccentSwatch: NSButton {
    private let handler: () -> Void
    init(color: NSColor, multicolor: Bool, selected: Bool, label: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        size(self, width: 18, height: 18)
        layer?.cornerRadius = 9
        if multicolor {
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.colors = [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemRed].map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
            gradient.cornerRadius = 9
            layer?.addSublayer(gradient)
        } else {
            layer?.backgroundColor = color.cgColor
        }
        layer?.borderWidth = selected ? 2 : 0.5
        layer?.borderColor = selected ? NSColor.labelColor.withAlphaComponent(0.85).cgColor : NSColor.black.withAlphaComponent(0.15).cgColor
        target = self
        self.action = #selector(invoke)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityValue(selected ? "selected" : nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}
