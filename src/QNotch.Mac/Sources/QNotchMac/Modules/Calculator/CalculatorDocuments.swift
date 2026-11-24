import Foundation
import CalculatorEngine

/// One sheet in the catalog, in strip order.
struct CalculatorSheetEntry: Equatable {
    let id: UUID
    var name: String
}

/// Display and calculation preferences (C# PreferencesDocument). Nil means the default.
struct CalculatorPreferences: Equatable {
    /// Editor and result text size in points; nil is `CalculatorPreferences.defaultFontSize`.
    var fontSize: Int?
    /// Fixed decimal places; nil is automatic.
    var decimalPlaces: Int?
    /// A `CalculatorFormat.styleIds` id; nil follows the system ("system").
    var numberStyle: String?
    /// Currency plain monetary results are shown in.
    var defaultCurrency: String?
    /// "DE", "US" or "WEEKDAYS"; nil follows the system region.
    var workdayRegion: String?
    /// Daily rate downloads while a visible sheet needs the latest rates (C# AutoCurrencyRates; off unless allowed).
    var autoCurrencyRates = false
    /// The interface language a Windows Calculator chose (C# Language); kept as it is.
    var language: String?

    static let defaultFontSize = 15
    static let fontSizes = [12, 13, 14, 15, 16, 18, 20, 22, 24, 28]
    static let decimalChoices: [Int?] = [nil, 0, 1, 2, 3, 4, 6, 8, 10]
    static let defaultNumberStyle = "system"
    /// Currencies the ECB reference rates cover, offered beside the region's own currency (Windows DefaultCurrencyChoices).
    static let currencyChoices = ["AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS", "INR", "ISK",
                                  "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR"]

    var resolvedFontSize: Int { fontSize ?? Self.defaultFontSize }
}

enum CalculatorDocumentsError: Error, LocalizedError {
    case unknownSheet, lastSheet, invalidName, tooLarge, unsupported
    var errorDescription: String? {
        switch self {
        case .unknownSheet: "The sheet no longer exists."
        case .lastSheet: "The last sheet cannot be deleted."
        case .invalidName: CalculatorText.invalidSheetName
        case .tooLarge: "The sheet is over the size limit."
        case .unsupported: "Not available for this workspace."
        }
    }
}

/// A sheet as it was read: its text, the UUIDs and rolls it holds, and whether a backup stood in for a damaged file.
struct CalculatorOpenedSheet {
    let source: String
    let generated: CalculatorGeneratedValues
    var recovered = false
}

/// The Calculator's saved workspace (Windows `Calc.Documents.WorkspaceStore`): the sheet catalog, each sheet's
/// source and generated values, the preferences, the saved functions and each sheet's version history. Main thread
/// only; `CalculatorStorage.open` may run off it.
///
/// `StoredCalculatorDocuments` keeps them in `<data root>/calculator` exactly as Windows does; `InMemoryCalculatorDocuments`
/// holds them in memory for tests and pages built for diagnostics.
protocol CalculatorDocuments: AnyObject {
    var sheets: [CalculatorSheetEntry] { get }
    var activeSheetID: UUID { get }
    /// Reads a sheet; required before it is selected or saved. The functions take on its receipts.
    func open(_ id: UUID) throws -> CalculatorOpenedSheet
    /// Writes a sheet's text and generated values; a define or forget in it joins the saved functions. `receipts` replaces the receipts
    /// read from disk (after an undone version restore). True when the functions or receipts changed: the sheet evaluates again.
    @discardableResult func save(_ id: UUID, source: String, generated: CalculatorGeneratedValues?, receipts: CalculatorFunctions?) throws -> Bool
    /// Adds a sheet after the others and makes it active.
    @discardableResult func create(name: String, source: String) throws -> UUID
    func select(_ id: UUID) throws
    func rename(_ id: UUID, to name: String) throws
    /// One catalog change for the group; always leaves a sheet (throws `lastSheet` otherwise).
    func delete(_ ids: [UUID]) throws
    var preferences: CalculatorPreferences { get }
    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) throws
    /// Saved functions with the receipts of the sheet last opened or saved; nil while there are none.
    var functions: CalculatorFunctions? { get }
    /// Pending writes go out now (the panel closed, or QNotch quits).
    func flush()
    /// Lets go of the folder (QNotch quits or the module is turned off).
    func close()

    /// The real store behind it (sync, share links, help); nil in memory, where those features are hidden.
    var store: CalculatorDocumentStore? { get }
    /// Keeps the saved content as a version (Windows CaptureHistory); true when history reflects it.
    func captureVersion(_ id: UUID, force: Bool) throws -> Bool
    func versions(of id: UUID) throws -> CalculatorVersionHistory
    /// Keeps the current content as a version, then puts the chosen one in its place.
    func restoreVersion(_ id: UUID, hash: String) throws -> CalculatorOpenedSheet
    /// The catalog changed outside the app's own calls (a sync pass).
    func reloadCatalog()
}

extension CalculatorDocuments {
    func source(of id: UUID) throws -> String { try open(id).source }
    func save(_ id: UUID, source: String) throws { try save(id, source: source, generated: nil, receipts: nil) }
}

/// Sheets in memory: no disk writes and no file format, for tests and diagnostic pages. History, sync and share links need the
/// real store and are not offered.
final class InMemoryCalculatorDocuments: CalculatorDocuments {
    static let maxNameLength = 80

    private(set) var sheets: [CalculatorSheetEntry]
    private(set) var activeSheetID: UUID
    private var sources: [UUID: String]
    private var generated: [UUID: CalculatorGeneratedValues] = [:]
    private(set) var preferences = CalculatorPreferences()
    let functions: CalculatorFunctions? = nil
    let store: CalculatorDocumentStore? = nil

    init(sheets: [(name: String, source: String)] = [(CalculatorText.firstSheetName, "")], active: Int? = nil) {
        precondition(!sheets.isEmpty)
        let entries = sheets.map { CalculatorSheetEntry(id: UUID(), name: $0.name) }
        self.sheets = entries
        sources = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), sheets.map(\.source)))
        activeSheetID = entries[active ?? 0].id
    }

    func open(_ id: UUID) throws -> CalculatorOpenedSheet {
        guard let source = sources[id] else { throw CalculatorDocumentsError.unknownSheet }
        return CalculatorOpenedSheet(source: source, generated: generated[id].flatMap { $0.source == source ? $0 : nil } ?? CalculatorGeneratedValues(source: source))
    }

    @discardableResult
    func save(_ id: UUID, source: String, generated values: CalculatorGeneratedValues?, receipts: CalculatorFunctions?) throws -> Bool {
        guard sources[id] != nil else { throw CalculatorDocumentsError.unknownSheet }
        guard (source as NSString).length <= CalculatorSheet.maxCharacters else { throw CalculatorDocumentsError.tooLarge }
        sources[id] = source
        generated[id] = values
        return false
    }

    @discardableResult
    func create(name: String, source: String) throws -> UUID {
        let name = try Self.validName(name)
        let entry = CalculatorSheetEntry(id: UUID(), name: name)
        sheets.append(entry)
        sources[entry.id] = source
        activeSheetID = entry.id
        return entry.id
    }

    func select(_ id: UUID) throws {
        guard sources[id] != nil else { throw CalculatorDocumentsError.unknownSheet }
        activeSheetID = id
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let index = sheets.firstIndex(where: { $0.id == id }) else { throw CalculatorDocumentsError.unknownSheet }
        sheets[index].name = try Self.validName(name)
    }

    func delete(_ ids: [UUID]) throws {
        let gone = Set(ids)
        let left = sheets.filter { !gone.contains($0.id) }
        guard !left.isEmpty else { throw CalculatorDocumentsError.lastSheet }
        sheets = left
        for id in gone { sources[id] = nil; generated[id] = nil }
        if gone.contains(activeSheetID) { activeSheetID = left[0].id }
    }

    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) throws { change(&preferences) }

    func flush() {}
    func close() {}
    func captureVersion(_ id: UUID, force: Bool) throws -> Bool { true }
    func versions(of id: UUID) throws -> CalculatorVersionHistory { throw CalculatorDocumentsError.unsupported }
    func restoreVersion(_ id: UUID, hash: String) throws -> CalculatorOpenedSheet { throw CalculatorDocumentsError.unsupported }
    func reloadCatalog() {}

    /// Trimmed, 1–80 UTF-16 units, no control characters (C# WorkspaceStore name rules).
    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).length <= maxNameLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CalculatorDocumentsError.invalidName }
        return trimmed
    }
}

/// Where the Calculator gets its documents and tab state.
enum CalculatorStorage {
    /// `directory` is `<data root>/calculator`, the Windows folder name. Runs off the main thread on first use. A diagnostic run
    /// (`demo`) opens the demo sheets in a throwaway folder beside it, as Windows CalculatorSession.OpenDemo does, and never reads or
    /// writes the user's sheets; the folder goes when the module stops.
    static func open(directory: URL, demo: Bool) throws -> CalculatorDocuments {
        if demo { return try demoDocuments(in: directory.deletingLastPathComponent().appendingPathComponent("calculator-demo-" + UUID().uuidString.lowercased(), isDirectory: true)) }
        return try StoredCalculatorDocuments(directory: directory)
    }

    static func makeTabState() -> CalculatorTabState { CalculatorTabList() }

    /// The snapshot run's sheets (Windows CalculatorSession.OpenDemo) in a real store.
    static func demoDocuments(in folder: URL) throws -> CalculatorDocuments {
        let documents = try StoredCalculatorDocuments(directory: folder, throwaway: true)
        let first = documents.activeSheetID
        try documents.rename(first, to: "Trip")
        _ = try documents.create(name: "Rent split", source: "rent = 1450 EUR\nshare = 3\nrent / share")
        let budget = try documents.create(name: "Budget", source: demoSource)
        _ = try documents.open(budget)
        return documents
    }

    /// The same sheets in memory, for pages built without a store.
    static func demoDocuments() -> CalculatorDocuments {
        InMemoryCalculatorDocuments(sheets: [("Trip", ""), ("Rent split", "rent = 1450 EUR\nshare = 3\nrent / share"), ("Budget", demoSource)], active: 2)
    }

    static let demoSource = "# Weekend trip\nnights = 3\nhotel = 129 * nights\nfuel = 42 * 1.72\nhotel + fuel\n\n250 km in miles\n15% of 480\n2026-12-24 + 30 days\nsqrt(2) * 10"
}
