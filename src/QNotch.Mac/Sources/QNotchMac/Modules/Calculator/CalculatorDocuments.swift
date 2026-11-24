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
    case unknownSheet, lastSheet, invalidName, tooLarge
    var errorDescription: String? {
        switch self {
        case .unknownSheet: "The sheet no longer exists."
        case .lastSheet: "The last sheet cannot be deleted."
        case .invalidName: CalculatorText.invalidSheetName
        case .tooLarge: "The sheet is over the size limit."
        }
    }
}

/// The Calculator's saved workspace (Windows `Calc.Documents.WorkspaceStore`): the sheet catalog, each sheet's
/// source, the preferences and the saved functions. Main thread only; `CalculatorStorage.open` may run off it.
///
/// The documents port implements this over its real store (sheets, version history, folder sync, share links,
/// import and export). Until then `InMemoryCalculatorDocuments` holds everything in memory.
protocol CalculatorDocuments: AnyObject {
    var sheets: [CalculatorSheetEntry] { get }
    var activeSheetID: UUID { get }
    func source(of id: UUID) throws -> String
    func save(_ id: UUID, source: String) throws
    /// Adds a sheet after the others and makes it active.
    @discardableResult func create(name: String, source: String) throws -> UUID
    func select(_ id: UUID) throws
    func rename(_ id: UUID, to name: String) throws
    /// One catalog change for the group; always leaves a sheet (throws `lastSheet` otherwise).
    func delete(_ ids: [UUID]) throws
    var preferences: CalculatorPreferences { get }
    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) throws
    /// Saved user functions for evaluation and Search answers; nil until the store has any.
    var functions: CalculatorFunctions? { get }
    /// Pending writes go out now (the panel closed, or QNotch quits).
    func flush()
}

/// The temporary store: no disk writes and no file format. Sheets last until QNotch quits.
final class InMemoryCalculatorDocuments: CalculatorDocuments {
    static let maxNameLength = 80

    private(set) var sheets: [CalculatorSheetEntry]
    private(set) var activeSheetID: UUID
    private var sources: [UUID: String]
    private(set) var preferences = CalculatorPreferences()
    let functions: CalculatorFunctions? = nil

    init(sheets: [(name: String, source: String)] = [(CalculatorText.firstSheetName, "")], active: Int? = nil) {
        precondition(!sheets.isEmpty)
        let entries = sheets.map { CalculatorSheetEntry(id: UUID(), name: $0.name) }
        self.sheets = entries
        sources = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), sheets.map(\.source)))
        activeSheetID = entries[active ?? 0].id
    }

    func source(of id: UUID) throws -> String {
        guard let source = sources[id] else { throw CalculatorDocumentsError.unknownSheet }
        return source
    }

    func save(_ id: UUID, source: String) throws {
        guard sources[id] != nil else { throw CalculatorDocumentsError.unknownSheet }
        guard (source as NSString).length <= CalculatorSheet.maxCharacters else { throw CalculatorDocumentsError.tooLarge }
        sources[id] = source
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
        for id in gone { sources[id] = nil }
        if gone.contains(activeSheetID) { activeSheetID = left[0].id }
    }

    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) throws { change(&preferences) }

    func flush() {}

    /// Trimmed, 1–80 UTF-16 units, no control characters (C# WorkspaceStore name rules).
    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).length <= maxNameLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CalculatorDocumentsError.invalidName }
        return trimmed
    }
}

/// Where the Calculator gets its documents and tab state. The documents port replaces the bodies of these two
/// functions (and nothing in the views): `open` returns its WorkspaceStore adapter for `directory`, and
/// `makeTabState` its SheetTabList.
enum CalculatorStorage {
    /// `directory` is `<data root>/calculator`, the Windows folder name. Runs off the main thread on first use.
    static func open(directory: URL, demo: Bool) throws -> CalculatorDocuments {
        demo ? demoDocuments() : InMemoryCalculatorDocuments()
    }

    static func makeTabState() -> CalculatorTabState { CalculatorTabList() }

    /// The snapshot run's sheets (Windows CalculatorSession.OpenDemo).
    static func demoDocuments() -> CalculatorDocuments {
        InMemoryCalculatorDocuments(sheets: [("Trip", ""), ("Rent split", "rent = 1450 EUR\nshare = 3\nrent / share"), ("Budget", demoSource)], active: 2)
    }

    static let demoSource = "# Weekend trip\nnights = 3\nhotel = 129 * nights\nfuel = 42 * 1.72\nhotel + fuel\n\n250 km in miles\n15% of 480\n2026-12-24 + 30 days\nsqrt(2) * 10"
}
