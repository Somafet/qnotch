import Foundation

/// The Calculator's interface strings: the English texts of the Windows catalog
/// (src/QNotch.Calculator.Engine/Assets/UiStrings.json), with Mac shortcuts where they name one.
/// Results, errors and calculation steps come from the engine and are not part of it.
enum CalculatorText {
    static let title = "Calculator"
    static let sheets = "Sheets"
    static let newSheet = "New sheet"
    static let newSheetTip = "New sheet (⌘T)"
    static func newSheetName(_ number: Int) -> String { "Sheet \(number)" }
    static let firstSheetName = "Sheet"
    static let sheetExpressions = "Sheet expressions"
    static let placeholder = "Type a calculation…"
    static let sheetUnavailable = "Sheet unavailable"
    static let finishTextInput = "Finish text input"
    static let saveFailed = "Save failed"
    static let settingsUnavailable = "Settings unavailable"
    static let undo = "Undo"
    static func closedSheet(_ name: String) -> String { "Closed \(name)." }
    static func closedSheets(_ name: String, _ others: Int) -> String { "Closed \(name) and \(others) more." }
    static let closeSheet = "Close sheet"
    static let allSheets = "All sheets"
    static let filterSheets = "Find a sheet"
    static let scrollTabsLeft = "Show earlier sheets"
    static let scrollTabsRight = "Show later sheets"
    static func sheetLimit(_ limit: Int) -> String { "You have reached the limit of \(limit) sheets." }
    static func sheetLimitPending(_ limit: Int) -> String { "Limit of \(limit) sheets reached. Closed sheets count until Undo ends." }
    static let invalidSheetName = "Use a name without control characters."
    static let renameMenu = "Rename…"
    static let renameSheet = "Rename sheet"
    static let rename = "Rename"
    static let sheetName = "Sheet name"
    static let cancel = "Cancel"
    static let close = "Close"
    static let explanation = "Explanation"
    static let explainMenu = "Explain…"
    static let calculationSteps = "Calculation steps"
    static func resultName(_ line: Int, _ shown: String) -> String { "Line \(line): \(shown)" }
    static func resultNameCopy(_ line: Int, _ shown: String) -> String { "Line \(line): \(shown). Copy result" }
    static let resultHelp = "Return copies the result. F1 opens its explanation."
    static let copy = "Copy"
    static let copied = "Copied"
    static let clipboardUnavailable = "Clipboard unavailable"
    static let copyKeepsText = "Copy keeps the complete text"
    static func uses(_ lines: [Int]) -> String { "Uses " + lines.prefix(16).map { "L\($0 + 1)" }.joined(separator: ", ") }
    static let settings = "Settings…"

    // Variables and figures
    static let renameVariable = "Rename variable"
    static let variableNameTaken = "Another variable already has this name"
    static let invalidVariableName = "Not a valid variable name"
    static let other = "Other"
    static func moreSlices(_ count: Int) -> String { "+ \(count) more" }

    // Settings
    static let calculatorSettingsIntro = "For now, sheets last until QNotch quits. Calculations never leave this Mac."
    static let general = "General"
    static let appearance = "Appearance"
    static let workdayCalendar = "Workday calendar"
    static func systemRegion(_ region: String) -> String { "System region (\(region))" }
    static let unavailable = "unavailable"
    static let germany = "Germany · nationwide"
    static let us = "US · federal"
    static let weekdays = "Weekdays only"
    static let textSize = "Text size"
    static let decimalPlaces = "Decimal places"
    static let automatic = "Automatic"
    static let numberFormat = "Number format"
    static func systemFormat(_ example: String) -> String { "System (\(example))" }
    static let currencyRates = "Currency rates"
    static let defaultCurrency = "Default currency"
    static let defaultCurrencyTip = "Plain amounts of money are shown in this currency."
    static let none = "None"
    static let download = "Download"
    static let openLink = "Open"

    // Currency rates
    static let downloadingRates = "Downloading rates…"
    static let euNotSaved = "EU monthly · not saved"
    static let ecbNotSaved = "ECB · not saved"
    static let historyUnavailable = "History unavailable"
    static let ratesUnavailable = "Rates unavailable"
    static let euMultiple = "EU monthly · multiple dates"
    static let ecbMultiple = "ECB · multiple dates"
    static func euDate(_ date: String) -> String { "EU monthly · \(date)" }
    static func ecbDate(_ date: String) -> String { "ECB · \(date)" }
    static let euMixed = "EU monthly · mixed dates"
    static let ecbMixed = "ECB · mixed dates"
    static let ecbHistoryCached = "ECB · history cached"
    static func euStale(_ date: String) -> String { "EU monthly · stale \(date)" }
    static func ecbStale(_ date: String) -> String { "ECB · stale \(date)" }
    static let ratesTipMonthly = "EU monthly accounting rates (European Commission InforEuro, CC BY 4.0) via api.frankfurter.dev. Cached data; not live prices. Downloads send only the provider, base EUR and selected dates, never sheet text or amounts."
    static let ratesTip = "ECB daily reference rates via api.frankfurter.dev. Cached data; not live prices. Downloads send only base EUR and selected dates, never sheet text or amounts."
    static func currencyRatesName(_ status: String) -> String { "Currency reference rates: \(status)" }
    static let downloadLatest = "Download latest ECB rates"
    static let downloadLatestTip = "Network: api.frankfurter.dev; fixed base EUR only. No sheet text or amounts are sent."
    static let downloadMonthly = "Download monthly EU rates"
    static let downloadMonthlyTip = "Network: api.frankfurter.dev; European Commission InforEuro accounting rates for about 150 currencies, updated monthly; fixed provider and base EUR only. No sheet text or amounts are sent."
    static func downloadHistory(_ count: Int) -> String { "Download historical dates (\(count))" }
    static func downloadHistoryTip(_ dates: String) -> String { "Network: api.frankfurter.dev receives these dates and base EUR only: \(dates)" }
    static let cancelDownload = "Cancel download"
    static let autoRates = "Allow daily downloads while visible"
    static let autoRatesTipMonthly = "Optional network access to api.frankfurter.dev for the current rate source, only when a visible sheet needs latest rates. No sheet text or amounts are sent."
    static let autoRatesTip = "Optional network access to api.frankfurter.dev for ECB reference rates, only when a visible sheet needs latest rates. No sheet text or amounts are sent."
    static let rateSourceMonthly = "Source: European Commission (CC BY 4.0) via Frankfurter"
    static let rateSource = "Source: ECB via Frankfurter"

    static let comingTitle = "Coming to the Mac"
    static let comingSaved = "Saved sheets, settings and version history"
    static let comingSavedTip = "Sheets and these settings saved on this Mac and restored after a restart, with earlier versions and saved functions."
    static let comingSync = "Sync folder"
    static let comingSyncTip = "Keep sheets in a folder you choose, such as an iCloud Drive or Dropbox folder."
    static let comingShare = "Import, export and share"
    static let comingShareTip = "Copying results, the total, a table or an image; exports, share links and printing; Numi, Soulver and text imports."
    static let comingLanguage = "Interface language and help"
    static let comingLanguageTip = "The calculator's own language choice, help and third-party notices."
}
