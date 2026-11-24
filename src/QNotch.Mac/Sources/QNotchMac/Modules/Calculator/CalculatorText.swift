import Foundation

/// The Calculator's interface strings, from the Windows catalog (src/QNotch.Calculator.Engine/Assets/UiStrings.json) in the
/// interface language (`language`); texts the catalog does not have, or that name Mac shortcuts, stay in English.
/// Results, errors and calculation steps come from the engine and are not part of it.
enum CalculatorText {
    /// The tab and Settings section name, like every QNotch module name, stays in English (Windows registers "Calculator").
    static let title = "Calculator"
    static var sheets: String { ui("sheets") }
    static var newSheet: String { ui("newSheet") }
    static let newSheetTip = "New sheet (⌘T)"
    static func newSheetName(_ number: Int) -> String { ui("newSheetName", number) }
    static let firstSheetName = "Sheet"
    static var sheetExpressions: String { ui("sheetExpressions") }
    static var placeholder: String { ui("placeholder") }
    static var sheetUnavailable: String { ui("sheetUnavailable") }
    static var finishTextInput: String { ui("finishTextInput") }
    static var saveFailed: String { ui("saveFailed") }
    static var settingsUnavailable: String { ui("settingsUnavailable") }
    static var undo: String { ui("undo") }
    static func closedSheet(_ name: String) -> String { ui("closedSheet", name) }
    static func closedSheets(_ name: String, _ others: Int) -> String { ui("closedSheets", name, others) }
    static var closeSheet: String { ui("closeSheet") }
    static var allSheets: String { ui("allSheets") }
    static var filterSheets: String { ui("filterSheets") }
    static var scrollTabsLeft: String { ui("scrollTabsLeft") }
    static var scrollTabsRight: String { ui("scrollTabsRight") }
    static func sheetLimit(_ limit: Int) -> String { ui("sheetLimit", limit) }
    static func sheetLimitPending(_ limit: Int) -> String { ui("sheetLimitPending", limit) }
    static var invalidSheetName: String { ui("invalidSheetName") }
    static var renameMenu: String { ui("renameMenu") }
    static var renameSheet: String { ui("renameSheet") }
    static var rename: String { ui("rename") }
    static var sheetName: String { ui("sheetName") }
    static var cancel: String { ui("cancel") }
    static var close: String { ui("close") }
    static var explanation: String { ui("explanation") }
    static var explainMenu: String { ui("explainMenu") }
    static var calculationSteps: String { ui("calculationSteps") }
    static func resultName(_ line: Int, _ shown: String) -> String { ui("resultName", line, shown) }
    static func resultNameCopy(_ line: Int, _ shown: String) -> String { ui("resultNameCopy", line, shown) }
    static let resultHelp = "Return copies the result. F1 opens its explanation."
    static let copy = "Copy"
    static var copied: String { ui("copied") }
    static var clipboardUnavailable: String { ui("clipboardUnavailable") }
    static var copyKeepsText: String { ui("copyKeepsText") }
    static func uses(_ lines: [Int]) -> String { "Uses " + lines.prefix(16).map { "L\($0 + 1)" }.joined(separator: ", ") }
    static let settings = "Settings…"

    // Variables and figures
    static var renameVariable: String { ui("renameVariable") }
    static var variableNameTaken: String { ui("variableNameTaken") }
    static var invalidVariableName: String { ui("invalidVariableName") }
    static var other: String { ui("other") }
    static func moreSlices(_ count: Int) -> String { "+ \(count) more" }

    // Settings
    static var general: String { ui("general") }
    static var appearance: String { ui("appearance") }
    static var workdayCalendar: String { ui("workdayCalendar") }
    static func systemRegion(_ region: String) -> String { ui("systemRegion", region) }
    static var unavailable: String { ui("unavailable") }
    static var germany: String { ui("germany") }
    static var us: String { ui("us") }
    static var weekdays: String { ui("weekdays") }
    static var textSize: String { ui("textSize") }
    static var decimalPlaces: String { ui("decimalPlaces") }
    static var automatic: String { ui("automatic") }
    static var numberFormat: String { ui("numberFormat") }
    static func systemFormat(_ example: String) -> String { ui("systemFormat", example) }
    static var currencyRates: String { ui("currencyRates") }
    static var defaultCurrency: String { ui("defaultCurrency") }
    static let defaultCurrencyTip = "Plain amounts of money are shown in this currency."
    static var none: String { ui("none") }
    static var download: String { ui("download") }
    static var openLink: String { ui("openLink") }

    // Currency rates
    static var downloadingRates: String { ui("downloadingRates") }
    static var euNotSaved: String { ui("euNotSaved") }
    static var ecbNotSaved: String { ui("ecbNotSaved") }
    static var historyUnavailable: String { ui("historyUnavailable") }
    static var ratesUnavailable: String { ui("ratesUnavailable") }
    static var euMultiple: String { ui("euMultiple") }
    static var ecbMultiple: String { ui("ecbMultiple") }
    static func euDate(_ date: String) -> String { ui("euDate", date) }
    static func ecbDate(_ date: String) -> String { ui("ecbDate", date) }
    static var euMixed: String { ui("euMixed") }
    static var ecbMixed: String { ui("ecbMixed") }
    static var ecbHistoryCached: String { ui("ecbHistoryCached") }
    static func euStale(_ date: String) -> String { ui("euStale", date) }
    static func ecbStale(_ date: String) -> String { ui("ecbStale", date) }
    static var ratesTipMonthly: String { ui("ratesTipMonthly") }
    static var ratesTip: String { ui("ratesTip") }
    static func currencyRatesName(_ status: String) -> String { ui("currencyRatesNameStatus", status) }
    static var downloadLatest: String { ui("downloadLatest") }
    static var downloadLatestTip: String { ui("downloadLatestTip") }
    static var downloadMonthly: String { ui("downloadMonthly") }
    static var downloadMonthlyTip: String { ui("downloadMonthlyTip") }
    static func downloadHistory(_ count: Int) -> String { ui("downloadHistory", count) }
    static func downloadHistoryTip(_ dates: String) -> String { ui("downloadHistoryTip", dates) }
    static var cancelDownload: String { ui("cancelDownload") }
    static var autoRates: String { ui("autoRates") }
    static var autoRatesTipMonthly: String { ui("autoRatesTipMonthly") }
    static var autoRatesTip: String { ui("autoRatesTip") }
    static var rateSourceMonthly: String { ui("rateSourceMonthly") }
    static var rateSource: String { ui("rateSource") }

}
