import AppKit
import CalculatorEngine

/// The Calculator page in Settings (Windows CalculatorSurface.Settings). Built from the workspace's current
/// preferences and rates; every control commits through the workspace, which recalculates the sheet in front. Opening
/// the page loads the calculator (and reads the rate cache) if it is not open yet. Highlighting a text size, decimal
/// places or number format previews it on the sheet; closing the menu without choosing ends the preview. What waits
/// for saved sheets is listed, not faked.
final class CalculatorSettingsView: NSView {
    private weak var module: CalculatorModule?
    private var observation: AnyObject?
    private var content: NSView?
    private var tracking: [NSObjectProtocol] = []
    private var menuOpen = false
    private var rebuildPending = false
    private weak var workspace: CalculatorWorkspace?

    init(module: CalculatorModule) {
        self.module = module
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("calculator-settings")
        module.withWorkspace { [weak self] workspace in
            guard let self else { return }
            guard let workspace else { return self.show(Self.unavailable()) }
            self.workspace = workspace
            self.observation = workspace.observe { [weak self] change in
                guard change == .preferences || change == .status || change == .rates || change == .documents, let self else { return }
                self.rebuild()
            }
            self.show(Self.page(workspace))
            // The page shows what the cache holds, even before a sheet converts money.
            workspace.currencies.ensureLoaded {}
        }
        // An open pop-up menu is never pulled away: a change waits until it closes.
        let center = NotificationCenter.default
        tracking.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuOpen = true })
        tracking.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.menuOpen = false
            if self.rebuildPending { self.rebuild() }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        tracking.forEach(NotificationCenter.default.removeObserver)
        workspace?.preview(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { workspace?.preview(nil) }
    }

    private func rebuild() {
        guard let workspace else { return }
        if menuOpen { rebuildPending = true; return }
        rebuildPending = false
        let focused = (window?.firstResponder as? NSView)?.identifier
        show(Self.page(workspace))
        if let focused, let view = Self.find(focused, in: self) { window?.makeFirstResponder(view) }
    }

    private static func find(_ id: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == id { return view }
        for child in view.subviews { if let found = find(id, in: child) { return found } }
        return nil
    }

    private func show(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        embed(view, in: self, inset: 0, fill: true)
    }

    private static func unavailable() -> NSView {
        let note = label("Calculator unavailable. Your sheets were not changed.", size: 12, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = SettingsController.contentWidth
        return note
    }

    static func page(_ workspace: CalculatorWorkspace) -> NSView {
        let width = SettingsController.contentWidth
        let preferences = workspace.preferences
        let intro = label(workspace.keepsDocuments ? CalculatorText.savedIntro : CalculatorText.unsavedIntro, size: 12, color: .secondaryLabelColor)
        intro.preferredMaxLayoutWidth = width

        // General: the workday calendar (the interface language waits for the catalog's other languages).
        let system = Locale.current.region?.identifier ?? ""
        let regions: [(String, String?)] = [(CalculatorText.systemRegion(system.isEmpty ? CalculatorText.unavailable : system), nil),
                                            (CalculatorText.germany, "DE"), (CalculatorText.us, "US"), (CalculatorText.weekdays, "WEEKDAYS")]
        let workday = choice(CalculatorText.workdayCalendar, id: "calculator-settings-workday", regions, preferences.workdayRegion) { value in
            workspace.updatePreferences { $0.workdayRegion = value }
        }
        let languages = [(CalculatorText.systemLanguage, String?.none)] + CalculatorInterfaceText.languages.map { ($0.name, Optional($0.code)) }
        let language = choice(CalculatorText.languageSetting, id: "calculator-settings-language", languages, preferences.language) { value in
            workspace.updatePreferences { $0.language = value }
        }
        let general = settingsGroup([settingsRow(CalculatorText.languageSetting, control: language, width: width),
                                     settingsRow(CalculatorText.workdayCalendar, control: workday, width: width)], header: CalculatorText.general, width: width)

        // Appearance.
        // Each display choice previews on the sheet while highlighted (Windows PreviewComboBoxItem).
        func display<Value: Equatable>(_ title: String, id: String, _ items: [(String, Value)], _ selected: Value,
                                       _ apply: @escaping (inout CalculatorPreferences, Value) -> Void) -> NSPopUpButton {
            choice(title, id: id, items, selected, changed: { value in workspace.updatePreferences { apply(&$0, value) } },
                   preview: { value in workspace.preview { apply(&$0, value) } }, endPreview: { workspace.preview(nil) })
        }
        let sizes = CalculatorPreferences.fontSizes.map { ("\($0)", $0) }
        let textSize = display(CalculatorText.textSize, id: "calculator-settings-text-size", sizes, preferences.resolvedFontSize) { preferences, value in
            preferences.fontSize = value == CalculatorPreferences.defaultFontSize ? nil : value
        }
        let places = CalculatorPreferences.decimalChoices.map { ($0.map(String.init) ?? CalculatorText.automatic, $0) }
        let decimals = display(CalculatorText.decimalPlaces, id: "calculator-settings-decimal-places", places, preferences.decimalPlaces) { preferences, value in
            preferences.decimalPlaces = value
        }
        let format = CalculatorFormat()
        let styles = CalculatorFormat.styleIds.sorted { a, b in a == CalculatorPreferences.defaultNumberStyle && b != a }.map { id -> (String, String?) in
            let example = format.example(id)
            return id == CalculatorPreferences.defaultNumberStyle ? (CalculatorText.systemFormat(example), nil) : (example, id)
        }
        let numbers = display(CalculatorText.numberFormat, id: "calculator-settings-number-format", styles, preferences.numberStyle) { preferences, value in
            preferences.numberStyle = value
        }
        let appearance = settingsGroup([
            settingsRow(CalculatorText.textSize, control: textSize, width: width),
            settingsRow(CalculatorText.decimalPlaces, control: decimals, width: width),
            settingsRow(CalculatorText.numberFormat, control: numbers, width: width)
        ], header: CalculatorText.appearance, width: width)

        // Currency rates: the default currency, the downloads, the automatic download and the source (Windows CurrencyGroup).
        let local = Locale.current.currency?.identifier
        var codes = [preferences.defaultCurrency, local].compactMap { $0 }
        for code in CalculatorPreferences.currencyChoices where !codes.contains(code) { codes.append(code) }
        let currencies = [(CalculatorText.none, String?.none)] + codes.map { code in ("\(code)  " + (Locale.current.localizedString(forCurrencyCode: code) ?? ""), Optional(code)) }
        let currency = choice(CalculatorText.defaultCurrency, id: "calculator-settings-default-currency", currencies, preferences.defaultCurrency) { value in
            workspace.updatePreferences { $0.defaultCurrency = value }
        }
        currency.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        let rates = settingsGroup([settingsRow(CalculatorText.defaultCurrency, detail: CalculatorText.defaultCurrencyTip, control: currency, width: width)]
                                  + rateRows(workspace, width: width), header: CalculatorText.currencyRates, width: width)

        var views: [NSView] = [intro, general, appearance, rates]
        if workspace.keepsDocuments { views += [syncGroup(workspace, width: width), aboutGroup(workspace, width: width)] }
        if !workspace.status.isEmpty, workspace.status == CalculatorText.settingsUnavailable {
            let problem = label(workspace.status, size: 12, color: .systemRed)
            views.insert(problem, at: 1)
        }
        let stack = column(views, spacing: 22)
        stack.setCustomSpacing(16, after: intro)
        return stack
    }

    private static func button(_ id: String, _ title: String, enabled: Bool = true, tip: String? = nil, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = enabled
        button.toolTip = tip
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.onAction(action)
        return button
    }

    /// Off: one row to choose a folder. On: the folder with Change and Stop (Windows SyncGroup).
    private static func syncGroup(_ workspace: CalculatorWorkspace, width: CGFloat) -> NSView {
        let rows: [NSView]
        if let folder = workspace.syncFolder {
            let actions = row([button("calculator-settings-sync-change", CalculatorText.changeFolder) { chooseSyncFolder(workspace) },
                               button("calculator-settings-sync-stop", CalculatorText.stopSyncing, tip: CalculatorText.stopSyncingTip) { workspace.setSyncFolder(nil) }],
                              spacing: 6)
            let status = workspace.syncMessage?.text
            rows = [settingsRow((folder.path as NSString).abbreviatingWithTildeInPath, detail: status, control: actions, width: width) {
                $0.identifier = NSUserInterfaceItemIdentifier("calculator-settings-sync-folder")
            }]
        } else {
            rows = [settingsRow(CalculatorText.syncFolderTip, control: button("calculator-settings-sync-choose", CalculatorText.chooseFolder) { chooseSyncFolder(workspace) },
                                width: width)]
        }
        return settingsGroup(rows, header: CalculatorText.syncFolder, width: width)
    }

    /// The folder panel, starting in the current folder or iCloud Drive (Windows starts in OneDrive).
    private static func chooseSyncFolder(_ workspace: CalculatorWorkspace) {
        guard !Runtime.diagnostics else { return }
        let panel = NSOpenPanel()
        panel.title = CalculatorText.chooseSyncFolder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let iCloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if let current = workspace.syncFolder { panel.directoryURL = current }
        else if FileManager.default.fileExists(atPath: iCloud.path) { panel.directoryURL = iCloud }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.setSyncFolder(url)
    }

    /// Help and the third-party notices, opened in the browser from the data folder (Windows AboutGroup).
    private static func aboutGroup(_ workspace: CalculatorWorkspace, width: CGFloat) -> NSView {
        settingsGroup([
            settingsRow(CalculatorText.help, detail: "⌘?", control: button("calculator-settings-help", CalculatorText.openLink) { workspace.openHelp() }, width: width),
            settingsRow(CalculatorText.thirdPartyNotices, detail: CalculatorText.thirdPartyNoticesTip,
                        control: button("calculator-settings-notices", CalculatorText.openLink) { workspace.openNotices() }, width: width)
        ], header: CalculatorText.about, width: width)
    }

    /// The rates rows: the status with the latest download (or Cancel), monthly and historical downloads, the automatic
    /// download and the source link. They act like the sheet's rates menu.
    private static func rateRows(_ workspace: CalculatorWorkspace, width: CGFloat) -> [NSView] {
        let currencies = workspace.currencies
        let idle = !currencies.downloading, route = currencies.monthlyRoute
        func button(_ id: String, _ title: String, enabled: Bool = true, tip: String? = nil, _ action: @escaping () -> Void) -> NSButton {
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = enabled
            button.toolTip = tip
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.onAction(action)
            return button
        }
        func perform(_ id: String) -> () -> Void { { currencies.perform(id, workspace: workspace) } }
        let status = currencies.status + (currencies.warning.map { "\n" + $0 } ?? "")
        let latest = idle ? button("calculator-settings-download-latest", CalculatorText.download, tip: CalculatorText.downloadLatestTip, perform(CalculatorCurrencies.latestID))
                          : button("calculator-settings-cancel-download", CalculatorText.cancelDownload, perform(CalculatorCurrencies.cancelID))
        var rows = [
            settingsRow(CalculatorText.downloadLatest, detail: status, control: latest, width: width) { $0.identifier = NSUserInterfaceItemIdentifier("calculator-settings-rates-status") },
            settingsRow(CalculatorText.downloadMonthly, control: button("calculator-settings-download-monthly", CalculatorText.download, enabled: idle,
                                                                        tip: CalculatorText.downloadMonthlyTip, perform(CalculatorCurrencies.monthlyID)), width: width)
        ]
        let missing = currencies.missingDates
        if !missing.isEmpty {
            rows.append(settingsRow(CalculatorText.downloadHistory(missing.count), control: button("calculator-settings-download-history", CalculatorText.download, enabled: idle,
                tip: CalculatorText.downloadHistoryTip(missing.map(\.description).joined(separator: ", ")), perform(CalculatorCurrencies.historyID)), width: width))
        }
        let automatic = ActionSwitch(CalculatorText.autoRates, value: workspace.preferences.autoCurrencyRates) { value in
            workspace.updatePreferences { $0.autoCurrencyRates = value }
        }
        automatic.identifier = NSUserInterfaceItemIdentifier("calculator-settings-auto-rates")
        rows.append(settingsRow(CalculatorText.autoRates, detail: route ? CalculatorText.autoRatesTipMonthly : CalculatorText.autoRatesTip, control: automatic, width: width))
        rows.append(settingsRow(route ? CalculatorText.rateSourceMonthly : CalculatorText.rateSource, detail: currencies.sourceTip,
                                control: button("calculator-settings-rate-source", CalculatorText.openLink) { currencies.openSource() }, width: width))
        return rows
    }

    /// A pop-up of choices. With `preview`, highlighting a choice shows it and closing the menu without one ends it.
    private static func choice<Value: Equatable>(_ title: String, id: String, _ items: [(String, Value)], _ selected: Value,
                                                 changed: @escaping (Value) -> Void, preview: ((Value) -> Void)? = nil,
                                                 endPreview: (() -> Void)? = nil) -> NSPopUpButton {
        let popUp = PreviewPopUp(title, items: items.map(\.0), selected: items.firstIndex { $0.1 == selected } ?? 0) { index in
            guard items.indices.contains(index) else { return }
            changed(items[index].1)
        }
        if let preview {
            popUp.preview = { index in if items.indices.contains(index) { preview(items[index].1) } }
            popUp.endPreview = endPreview
        }
        popUp.identifier = NSUserInterfaceItemIdentifier(id)
        popUp.controlSize = .small
        return popUp
    }
}

/// A pop-up button whose highlighted item can be previewed (Windows PreviewComboBoxItem): the pointer or the arrow keys
/// highlight, and the preview ends when the menu closes, whether or not a choice was made.
final class PreviewPopUp: NSPopUpButton, NSMenuDelegate {
    var changed: (Int) -> Void
    var preview: ((Int) -> Void)?
    var endPreview: (() -> Void)?

    init(_ title: String, items: [String], selected: Int, changed: @escaping (Int) -> Void) {
        self.changed = changed
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        selectItem(at: selected)
        target = self
        action = #selector(pick)
        setAccessibilityLabel(title)
        menu?.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pick() { changed(indexOfSelectedItem) }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let preview, let item else { return }
        preview(menu.index(of: item))
    }
    /// After the choice (if any) is committed, so a chosen value never flickers back to the saved one first.
    func menuDidClose(_ menu: NSMenu) {
        guard let endPreview else { return }
        DispatchQueue.main.async(execute: endPreview)
    }
}
