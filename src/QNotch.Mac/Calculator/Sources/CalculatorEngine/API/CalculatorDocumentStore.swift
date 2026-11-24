import Foundation

// The documents area for the Mac app: the saved workspace (C# WorkspaceStore) with its sheets, preferences, saved functions and
// version history, in the same folder layout and files as Windows. The engine's document types stay internal.

/// Why a documents operation failed. `message` is the engine's (English) text, as Windows shows in its tooltip.
public struct CalculatorDocumentError: Error, LocalizedError, CustomStringConvertible {
    public enum Kind: Sendable {
        /// Files could not be read or written (IOException), including a folder already in use by another QNotch.
        case io
        /// A document is damaged or invalid and no backup could stand in (InvalidDataException, JsonException).
        case invalidData
        /// A newer QNotch or Calculator wrote it; it is left untouched.
        case unsupportedVersion
        /// Permissions or a locked file (UnauthorizedAccessException).
        case unauthorized
        /// The call does not fit the store's state, such as saving a sheet that was never opened (InvalidOperationException).
        case invalidOperation
        /// A value the engine refuses: too long, too many lines, a bad formula (ArgumentException, FormatException, ArithmeticException).
        case invalidValue
    }
    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }
    public var description: String { message }

    init(_ error: Error) {
        message = error.netMessage
        if error.isUnsupportedVersion { kind = .unsupportedVersion }
        else if error.isUnauthorized { kind = .unauthorized }
        else if error.isInvalidData || error.isJsonError { kind = .invalidData }
        else if error.isInvalidOperation { kind = .invalidOperation }
        else if error.isIOException { kind = .io }
        else { kind = .invalidValue }
    }

    /// Runs `body`, giving every failure the public error type.
    static func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as CalculatorDocumentError { throw error } catch { throw CalculatorDocumentError(error) }
    }
}

/// One sheet in the catalog, in strip order.
public struct CalculatorStoredSheet: Hashable, Sendable {
    public let id: UUID
    public let name: String
}

/// A sheet as it was saved: its text, generated values and function receipts.
public struct CalculatorSavedSheet {
    public let id: UUID
    public let source: String
    /// A backup stood in for a damaged file (Windows "Recovered from backup").
    public let recovered: Bool
    let document: SheetDocument
    let receipts: [FunctionReceipt]
    init(_ loaded: LoadResult) {
        document = loaded.document; id = loaded.document.id; source = loaded.document.source
        recovered = loaded.recovered; receipts = loaded.functionReceipts ?? []
    }
}

/// The calculator's preferences file (C# PreferencesDocument). Nil means the default. Settings Windows keeps for its own
/// window (always on top, placement) are kept as they are.
public struct CalculatorStoredPreferences: Equatable, Sendable {
    public var workdayRegion: String?
    public var autoCurrencyRates = false
    public var fontSize: Int?
    public var decimalPlaces: Int?
    public var numberStyle: String?
    /// An interface language code (`CalculatorInterfaceText.languages`); nil follows the system.
    public var language: String?
    public var defaultCurrency: String?
    public init() {}
    init(_ document: PreferencesDocument) {
        workdayRegion = document.workdayRegion; autoCurrencyRates = document.autoCurrencyRates; fontSize = document.fontSize
        decimalPlaces = document.decimalPlaces; numberStyle = document.numberStyle; language = document.language; defaultCurrency = document.defaultCurrency
    }
    func applied(to document: PreferencesDocument) -> PreferencesDocument {
        document.with {
            $0.workdayRegion = workdayRegion; $0.autoCurrencyRates = autoCurrencyRates; $0.fontSize = fontSize; $0.decimalPlaces = decimalPlaces
            $0.numberStyle = numberStyle; $0.language = language; $0.defaultCurrency = defaultCurrency
        }
    }
    public static let minimumFontSize = PreferencesDocument.minimumFontSize, maximumFontSize = PreferencesDocument.maximumFontSize
}

/// What opening the workspace found.
public struct CalculatorOpenedWorkspace {
    /// The active sheet, or nil when it could not be read (`openFailure` says why); the app then shows it as unavailable.
    public let sheet: CalculatorSavedSheet?
    public let openFailure: String?
    /// A backup stood in for a damaged catalog, sheet, function library or preferences file.
    public let recovered: Bool
    /// A Calculator from before sheets (one `sheet.json`) was moved into the workspace.
    public let migrated: Bool
}

/// One saved version of a sheet.
public struct CalculatorSheetVersion: Hashable, Sendable {
    public let hash: String
    public let capturedAt: Date
    public let source: String
}

/// A sheet's saved versions, newest first. `skipped` counts files that could not be read.
public struct CalculatorVersionHistory: Sendable {
    public let versions: [CalculatorSheetVersion]
    public let skipped: Int
}

/// The outcome of a save: the function library after any define or forget in the sheet, and the sheet's receipts.
public struct CalculatorSaveOutcome {
    /// Library and receipts, for evaluating the sheet that was saved.
    public let functions: CalculatorFunctions
    /// The library or the receipts changed: the sheet should evaluate again.
    public let changed: Bool
}

/// The saved workspace in `<data root>/calculator` (Windows `%LocalAppData%\QNotch\calculator`), read and written exactly as the Windows
/// Calculator does: `workspace.json`, `sheets/{id}.json` and `.receipts`, `functions.json`, `preferences.json`, `versions/` and `sync.json`,
/// each replaced atomically with a `.bak` of the last good copy. The store holds the folder's `session.lock` until `close()`.
///
/// Open it on any thread; afterwards one thread (the app's main thread) owns it.
public final class CalculatorDocumentStore {
    public static let maxSheets = WorkspaceStore.maxSheets
    public static let maxNameLength = WorkspaceStore.maxNameLength
    public static let maxCharacters = SheetStore.maxCharacters
    /// The source a first workspace starts with (C# WorkspaceStore.StarterSource).
    public static let starterSource = WorkspaceStore.starterSource

    public let directory: URL
    let store: WorkspaceStore
    private var dark: [UUID: Bool] = [:]
    private var closed = false

    private init(_ directory: URL, _ store: WorkspaceStore) { self.directory = directory; self.store = store }

    /// Opens (or creates) the workspace and reads its catalog, preferences, saved functions and active sheet, as Windows
    /// CalculatorSession.Open does. Throws when the folder is in use, or a catalog is damaged beyond its backup or newer than this build.
    public static func open(directory: URL) throws -> (store: CalculatorDocumentStore, opened: CalculatorOpenedWorkspace) {
        try CalculatorDocumentError.wrap {
            let store = try WorkspaceStore(directory.path)
            do {
                let loaded = try store.load()
                _ = try store.loadPreferences()
                _ = try store.loadFunctions()
                let wrapper = CalculatorDocumentStore(directory, store)
                var sheet: CalculatorSavedSheet?
                var failure: String?
                do { sheet = try wrapper.openSheet(loaded.workspace.activeSheetId) }
                catch let error as CalculatorDocumentError where error.kind != .invalidOperation && error.kind != .invalidValue { failure = error.message }
                let recovered = loaded.recovered || sheet?.recovered == true || store.functionsRecovered || store.preferencesRecovered
                return (wrapper, CalculatorOpenedWorkspace(sheet: sheet, openFailure: failure, recovered: recovered, migrated: loaded.migrated))
            } catch { store.dispose(); throw error }
        }
    }

    /// Lets go of the folder (its session lock). Nothing can be read or written afterwards.
    public func close() {
        guard !closed else { return }
        closed = true
        store.dispose()
    }
    deinit { close() }

    // MARK: Catalog

    public var sheets: [CalculatorStoredSheet] { (store.workspace?.sheets ?? []).map { CalculatorStoredSheet(id: $0.id, name: $0.name) } }
    public var activeSheetID: UUID { store.workspace?.activeSheetId ?? .netEmpty }

    /// Reads a sheet. Required before it is saved, its history is used or it is selected.
    public func openSheet(_ id: UUID) throws -> CalculatorSavedSheet {
        try CalculatorDocumentError.wrap {
            let loaded = try store.open(id)
            dark[id] = loaded.document.dark
            return CalculatorSavedSheet(loaded)
        }
    }

    /// Adds a sheet after the others and makes it active. The source is written before the catalog names it.
    @discardableResult
    public func create(name: String, source: String = "") throws -> UUID {
        try CalculatorDocumentError.wrap {
            let next = try store.create(name, source)
            dark[next.activeSheetId] = false
            return next.activeSheetId
        }
    }

    public func select(_ id: UUID) throws { try CalculatorDocumentError.wrap { _ = try store.select(id) } }
    public func rename(_ id: UUID, to name: String) throws { try CalculatorDocumentError.wrap { _ = try store.rename(id, name) } }

    /// Deletes a group of sheets in one catalog write: all or none. At least one sheet always stays.
    public func delete(_ ids: [UUID]) throws {
        try CalculatorDocumentError.wrap {
            _ = try store.deleteMany(ids)
            for id in ids { dark[id] = nil }
        }
    }

    /// A sheet name the catalog accepts: 1–80 UTF-16 units, not only white space, no control characters.
    public static func isValidName(_ name: String) -> Bool { (try? WorkspaceStore.validateName(name)) != nil }

    // MARK: Saving

    /// Writes a sheet's text and generated values. A define or forget in the text is adopted into the function library with the sheet's
    /// receipts, in one journaled transaction (Windows Save). `receipts` replaces the receipts read from disk (after an undone restore).
    public func save(_ id: UUID, source: String, generated: CalculatorGeneratedValues?, receipts: CalculatorFunctions? = nil) throws -> CalculatorSaveOutcome {
        try CalculatorDocumentError.wrap {
            let snapshot = generated?.snapshot
            let next = SheetDocument(snapshot == nil ? 1 : 2, id, source, dark[id] ?? false, generatedUuids: snapshot)
            let library = try store.loadFunctions()
            let before = try receipts?.receipts ?? store.loadFunctionReceipts(id)
            let update = try FunctionUpdate.prepare(source, library, before)
            if update.hasChanges || receipts != nil { try store.saveWithFunctions(next, update) } else { try store.save(next) }
            return CalculatorSaveOutcome(functions: CalculatorFunctions(update.library, update.receipts),
                                         changed: library.fingerprint != update.library.fingerprint || before != update.receipts)
        }
    }

    /// The saved function library with a sheet's saved receipts.
    public func functions(for id: UUID) throws -> CalculatorFunctions {
        try CalculatorDocumentError.wrap { CalculatorFunctions(try store.loadFunctions(), try store.loadFunctionReceipts(id)) }
    }

    /// The function library and the receipts a sheet was opened with.
    public func functions(for sheet: CalculatorSavedSheet) throws -> CalculatorFunctions {
        try CalculatorDocumentError.wrap { CalculatorFunctions(try store.loadFunctions(), sheet.receipts) }
    }

    // MARK: Preferences

    public func preferences() throws -> CalculatorStoredPreferences {
        try CalculatorDocumentError.wrap { CalculatorStoredPreferences(try store.loadPreferences()) }
    }

    /// Replaces the preferences atomically. The file stays version 1 until it holds a version-2 setting, so older builds keep reading it.
    @discardableResult
    public func updatePreferences(_ change: (inout CalculatorStoredPreferences) -> Void) throws -> CalculatorStoredPreferences {
        try CalculatorDocumentError.wrap {
            CalculatorStoredPreferences(try store.updatePreferences { current in
                var shown = CalculatorStoredPreferences(current)
                change(&shown)
                return shown.applied(to: current)
            })
        }
    }

    /// The text sizes, decimal places, number styles and currencies a preferences file may hold.
    public static func isValid(_ preferences: CalculatorStoredPreferences) -> Bool {
        (try? WorkspaceStore.validatePreferences(preferences.applied(to: PreferencesDocument(2, nil)))) != nil
    }

    // MARK: Version history

    /// Keeps the sheet's saved content in its history unless the newest version matches it; without `force` the five-minute interval
    /// also applies. True when history reflects the saved content.
    @discardableResult
    public func captureVersion(_ id: UUID, now: Date = Date(), force: Bool = false) throws -> Bool {
        try CalculatorDocumentError.wrap { try store.captureVersion(id, DateTimeOffset(now), force: force) }
    }

    /// Reads the sheet's versions, newest first (at most 64). Only history uses this folder.
    public func versions(of id: UUID) throws -> CalculatorVersionHistory {
        try CalculatorDocumentError.wrap {
            let history = try store.loadVersions(id)
            return CalculatorVersionHistory(versions: history.versions.map {
                CalculatorSheetVersion(hash: $0.hash, capturedAt: $0.capturedAt.foundationDate, source: $0.sheet.source)
            }, skipped: history.skipped)
        }
    }

    /// Keeps the current content as a version, then replaces source, generated values and receipts with the chosen version in one
    /// transaction. The function library itself is not changed.
    public func restoreVersion(_ id: UUID, hash: String, now: Date = Date()) throws -> CalculatorSavedSheet {
        try CalculatorDocumentError.wrap {
            let restored = try store.restoreVersion(id, hash, DateTimeOffset(now))
            dark[id] = restored.document.dark
            return CalculatorSavedSheet(restored)
        }
    }

    /// Folder scans for history so far (diagnostics prove that opening and switching sheets read no history).
    public var versionScans: Int { store.versionScans }

    // MARK: Files written for the browser

    /// Writes Help.html into the data folder (only when it changed) and returns its path.
    public func writeHelp() throws -> URL { try CalculatorDocumentError.wrap { URL(fileURLWithPath: try CalculatorAssets.writeHelp(directory.path)) } }
    /// Writes THIRD-PARTY-NOTICES.txt into the data folder and returns its path.
    public func writeNotices() throws -> URL { try CalculatorDocumentError.wrap { URL(fileURLWithPath: try CalculatorAssets.writeNotices(directory.path)) } }
}

extension DateTimeOffset {
    init(_ date: Date) {
        let ticks = (date.timeIntervalSince1970 * Double(Ticks.perSecond)).rounded(.down)
        self.init(utcTicks: Ticks.unixEpoch + Int64(ticks))
    }
    var foundationDate: Date { Date(timeIntervalSince1970: Double(utcTicks - Ticks.unixEpoch) / Double(Ticks.perSecond)) }
}
