import AppKit
import CalculatorEngine

/// The Calculator page in Settings (Windows CalculatorSurface.Settings). Built from the workspace's current
/// preferences; every control commits through the workspace, which recalculates the sheet in front. Opening
/// the page loads the calculator if it is not open yet. What waits for saved sheets is listed, not faked.
final class CalculatorSettingsView: NSView {
    private weak var module: CalculatorModule?
    private var observation: AnyObject?
    private var content: NSView?

    init(module: CalculatorModule) {
        self.module = module
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("calculator-settings")
        module.withWorkspace { [weak self] workspace in
            guard let self else { return }
            guard let workspace else { return self.show(Self.unavailable()) }
            self.observation = workspace.observe { [weak self, weak workspace] change in
                guard change == .preferences || change == .status, let self, let workspace else { return }
                self.show(Self.page(workspace))
            }
            self.show(Self.page(workspace))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        let intro = label(CalculatorText.calculatorSettingsIntro, size: 12, color: .secondaryLabelColor)
        intro.preferredMaxLayoutWidth = width

        // General: the workday calendar (the interface language waits for the catalog's other languages).
        let system = Locale.current.region?.identifier ?? ""
        let regions: [(String, String?)] = [(CalculatorText.systemRegion(system.isEmpty ? CalculatorText.unavailable : system), nil),
                                            (CalculatorText.germany, "DE"), (CalculatorText.us, "US"), (CalculatorText.weekdays, "WEEKDAYS")]
        let workday = choice(CalculatorText.workdayCalendar, id: "calculator-settings-workday", regions, preferences.workdayRegion) { value in
            workspace.updatePreferences { $0.workdayRegion = value }
        }
        let general = settingsGroup([settingsRow(CalculatorText.workdayCalendar, control: workday, width: width)], header: CalculatorText.general, width: width)

        // Appearance.
        let sizes = CalculatorPreferences.fontSizes.map { ("\($0)", Optional($0)) }
        let textSize = choice(CalculatorText.textSize, id: "calculator-settings-text-size", sizes, Optional(preferences.resolvedFontSize)) { value in
            workspace.updatePreferences { $0.fontSize = value == CalculatorPreferences.defaultFontSize ? nil : value }
        }
        let places = CalculatorPreferences.decimalChoices.map { ($0.map(String.init) ?? CalculatorText.automatic, $0) }
        let decimals = choice(CalculatorText.decimalPlaces, id: "calculator-settings-decimal-places", places, preferences.decimalPlaces) { value in
            workspace.updatePreferences { $0.decimalPlaces = value }
        }
        let format = CalculatorFormat()
        let styles = CalculatorFormat.styleIds.sorted { a, b in a == CalculatorPreferences.defaultNumberStyle && b != a }.map { id -> (String, String?) in
            let example = format.example(id)
            return id == CalculatorPreferences.defaultNumberStyle ? (CalculatorText.systemFormat(example), nil) : (example, id)
        }
        let numbers = choice(CalculatorText.numberFormat, id: "calculator-settings-number-format", styles, preferences.numberStyle) { value in
            workspace.updatePreferences { $0.numberStyle = value }
        }
        let appearance = settingsGroup([
            settingsRow(CalculatorText.textSize, control: textSize, width: width),
            settingsRow(CalculatorText.decimalPlaces, control: decimals, width: width),
            settingsRow(CalculatorText.numberFormat, control: numbers, width: width)
        ], header: CalculatorText.appearance, width: width)

        // Currency: the default currency. Rate downloads come with the rates port.
        let local = Locale.current.currency?.identifier
        var codes = [preferences.defaultCurrency, local].compactMap { $0 }
        for code in CalculatorPreferences.currencyChoices where !codes.contains(code) { codes.append(code) }
        let currencies = [(CalculatorText.none, String?.none)] + codes.map { code in ("\(code)  " + (Locale.current.localizedString(forCurrencyCode: code) ?? ""), Optional(code)) }
        let currency = choice(CalculatorText.defaultCurrency, id: "calculator-settings-default-currency", currencies, preferences.defaultCurrency) { value in
            workspace.updatePreferences { $0.defaultCurrency = value }
        }
        currency.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        let rates = settingsGroup([settingsRow(CalculatorText.defaultCurrency, detail: CalculatorText.defaultCurrencyTip, control: currency, width: width)],
                                  header: CalculatorText.currencyRates, width: width)

        let coming = settingsGroup([
            settingsRow(CalculatorText.comingSaved, detail: CalculatorText.comingSavedTip, width: width),
            settingsRow(CalculatorText.comingRates, detail: CalculatorText.comingRatesTip, width: width),
            settingsRow(CalculatorText.comingSync, detail: CalculatorText.comingSyncTip, width: width),
            settingsRow(CalculatorText.comingShare, detail: CalculatorText.comingShareTip, width: width),
            settingsRow(CalculatorText.comingLanguage, detail: CalculatorText.comingLanguageTip, width: width)
        ], header: CalculatorText.comingTitle, width: width)

        var views: [NSView] = [intro, general, appearance, rates, coming]
        if !workspace.status.isEmpty, workspace.status == CalculatorText.settingsUnavailable {
            let problem = label(workspace.status, size: 12, color: .systemRed)
            views.insert(problem, at: 1)
        }
        let stack = column(views, spacing: 22)
        stack.setCustomSpacing(16, after: intro)
        return stack
    }

    private static func choice<Value: Equatable>(_ title: String, id: String, _ items: [(String, Value)], _ selected: Value,
                                                 changed: @escaping (Value) -> Void) -> ActionPopUp {
        let popUp = ActionPopUp(title, items: items.map(\.0), selected: items.firstIndex { $0.1 == selected } ?? 0) { index in
            guard items.indices.contains(index) else { return }
            changed(items[index].1)
        }
        popUp.identifier = NSUserInterfaceItemIdentifier(id)
        popUp.controlSize = .small
        return popUp
    }
}
