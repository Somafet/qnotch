import Foundation
import CalculatorEngine

/// The texts of the saved-documents features (history, sync, sharing, import, help), read from the Windows catalog
/// (UiStrings.json) in the interface language: the Language setting, otherwise the system's first supported language.
extension CalculatorText {
    /// The interface language code in use ("en", "de"…). The workspace sets it from the preferences.
    static var language = CalculatorInterfaceText.resolve(nil)

    /// A catalog text by key, with .NET placeholders `{0}`, `{1}` filled in. Mac shortcuts replace the Windows ones it names.
    static func ui(_ key: String, _ arguments: Any...) -> String {
        var text = CalculatorInterfaceText.string(key, language: language) ?? key
        for (index, argument) in arguments.enumerated() { text = text.replacingOccurrences(of: "{\(index)}", with: "\(argument)") }
        return text
    }

    static var recoveredBackup: String { ui("recoveredBackup") }
    static var historyNotSaved: String { ui("historyNotSaved") }
    static var historyMissing: String { ui("historyUnavailable") }
    static func skippedVersions(_ count: Int) -> String { count == 1 ? ui("skippedOne") : ui("skippedMany", count) }
    static var versionHistory: String { ui("versionHistory") }
    static var noVersions: String { ui("noVersions") }
    static var restore: String { ui("restore") }
    static func restorePrompt(_ label: String) -> String { ui("restorePrompt", label) }
    static var versions: String { ui("versions") }
    static var versionPreview: String { ui("versionPreview") }
    static var restoreVersion: String { ui("restoreVersion") }
    static var restoreFailed: String { ui("restoreFailed") }
    static var historyMenu: String { ui("historyMenu") }

    static var syncUnavailable: String { ui("syncUnavailable") }
    static var syncFolderUnavailable: String { ui("syncFolderUnavailable") }
    static var syncFailed: String { ui("syncFailed") }
    static var syncWaiting: String { ui("syncWaiting") }
    static func syncConflicts(_ count: Int) -> String { count == 1 ? ui("syncConflictOne") : ui("syncConflictMany", count) }
    static var chooseSyncFolder: String { ui("chooseSyncFolder") }
    static var syncFolder: String { ui("syncFolder") }
    /// The Windows text names OneDrive; on the Mac iCloud Drive is the obvious place.
    static var syncFolderTip: String { language == "en" ? "Keep sheets in a folder you choose, such as an iCloud Drive or Dropbox folder" : ui("syncFolderTip") }
    static var chooseFolder: String { ui("chooseFolder") }
    static var changeFolder: String { ui("changeFolder") }
    static var stopSyncing: String { ui("stopSyncing") }
    static var stopSyncingTip: String { ui("stopSyncingTip") }

    static var share: String { ui("share") }
    static var copyShareLink: String { ui("copyShareLink") }
    static var localLinkCopied: String { ui("localLinkCopied") }
    static var linkCopied: String { ui("linkCopied") }
    static var shareViewerMissing: String { ui("shareViewerMissing") }
    static var shareSettingsUnavailable: String { ui("shareSettingsUnavailable") }
    static var copyResults: String { ui("copyResults") }
    static var copyTotal: String { ui("copyTotal") }
    static var copyTable: String { ui("copyTable") }
    static var copyImage: String { ui("copyImage") }
    static var copyTransparentImage: String { ui("copyTransparentImage") }
    static var exportMenu: String { ui("exportMenu") }
    static var printMenu: String { ui("printMenu") }
    static var resultsCopied: String { ui("resultsCopied") }
    static var totalCopied: String { ui("totalCopied") }
    static var tableCopied: String { ui("tableCopied") }
    static var imageCopied: String { ui("imageCopied") }
    static func linesOmitted(_ done: String, _ omitted: Int) -> String { omitted == 0 ? done : ui("linesOmitted", done, omitted) }
    static var exportSheet: String { ui("exportSheet") }
    static var exported: String { ui("exported") }
    static var exportFailed: String { ui("exportFailed") }
    static var sentToPrinter: String { ui("sentToPrinter") }
    static var printFailed: String { ui("printFailed") }

    static var importTitle: String { ui("importTitle") }
    static var importStopped: String { ui("importStopped") }
    static var importing: String { ui("importing") }
    static func notImported(_ file: String, _ reason: String) -> String { ui("notImported", file, reason) }
    static func importedAs(_ file: String, _ name: String) -> String { ui("importedAs", file, name) }
    static func importLine(_ line: Int, _ message: String) -> String { ui("importLine", line, message) }
    static func moreFilesNotImported(_ count: Int, _ limit: Int) -> String { ui("moreFilesNotImported", count, limit) }
    static func moreNotes(_ count: Int) -> String { ui("moreNotes", count) }
    static func imported(_ count: Int) -> String { count == 1 ? ui("importedOne") : ui("importedMany", count) }
    static var importMenu: String { ui("importMenu") }
    /// The drop screen's tile (Windows CalculatorModule.ImportTargets).
    static var importAsSheets: String { language == "en" ? "Import as sheets" : ui("importMenu").replacingOccurrences(of: "…", with: "") }

    static var help: String { ui("help") }
    static var thirdPartyNotices: String { ui("thirdPartyNotices") }
    static var thirdPartyNoticesTip: String { ui("thirdPartyNoticesTip") }
    static var helpUnavailable: String { ui("helpUnavailable") }
    static var about: String { ui("about") }
    static var languageSetting: String { ui("language") }
    static var systemLanguage: String { ui("systemLanguage") }
    static func rolled(_ value: String) -> String { ui("rolled", value) }
    /// The Windows text says "this PC".
    /// Pages built without a store (tests).
    static let unsavedIntro = "Sheets on this page are not saved. Calculations never leave this Mac."
    static var savedIntro: String { language == "en" ? "Sheets are saved on this Mac. Calculations never leave it." : ui("calculatorSettingsIntro") }
}
