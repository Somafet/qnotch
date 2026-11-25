import Foundation
import CalculatorEngine

/// The Calculator's documents on disk: the engine's WorkspaceStore in `<data root>/calculator`, the same folder layout and files the
/// Windows Calculator reads and writes (workspace.json, sheets/, functions.json, preferences.json, versions/, sync.json). Opened off the
/// main thread; afterwards main thread only. A throwaway store (diagnostic runs) deletes its folder when it closes.
final class StoredCalculatorDocuments: CalculatorDocuments {
    private let documentStore: CalculatorDocumentStore
    let opened: CalculatorOpenedWorkspace
    private let throwaway: Bool
    private(set) var sheets: [CalculatorSheetEntry] = []
    private(set) var preferences = CalculatorPreferences()
    private(set) var functions: CalculatorFunctions?
    private var isClosed = false
    /// Now, for version capture; tests move it.
    var now: () -> Date = Date.init

    var store: CalculatorDocumentStore? { isClosed ? nil : documentStore }
    var activeSheetID: UUID { documentStore.activeSheetID }
    var directory: URL { documentStore.directory }

    init(directory: URL, throwaway: Bool = false) throws {
        let (store, opened) = try CalculatorDocumentStore.open(directory: directory)
        documentStore = store
        self.opened = opened
        self.throwaway = throwaway
        reloadCatalog()
        preferences = Self.preferences(try store.preferences())
        if let sheet = opened.sheet { functions = try? store.functions(for: sheet) }
    }

    deinit { close() }

    func reloadCatalog() { sheets = documentStore.sheets.map { CalculatorSheetEntry(id: $0.id, name: $0.name) } }

    // MARK: Sheets

    /// The sheet the workspace opened with, read already.
    var openedActive: CalculatorOpenedSheet? {
        guard let sheet = opened.sheet, sheet.id == activeSheetID, let generated = try? CalculatorGeneratedValues(sheet) else { return nil }
        return CalculatorOpenedSheet(source: sheet.source, generated: generated, recovered: sheet.recovered)
    }

    func open(_ id: UUID) throws -> CalculatorOpenedSheet {
        let sheet = try documentStore.openSheet(id)
        let opened = CalculatorOpenedSheet(source: sheet.source, generated: try CalculatorGeneratedValues(sheet), recovered: sheet.recovered)
        functions = try documentStore.functions(for: sheet)
        return opened
    }

    @discardableResult
    func save(_ id: UUID, source: String, generated: CalculatorGeneratedValues?, receipts: CalculatorFunctions?) throws -> Bool {
        let outcome = try documentStore.save(id, source: source, generated: generated, receipts: receipts)
        let changed = outcome.changed || functions.map { !$0.matches(outcome.functions) } ?? !outcome.functions.isEmpty
        functions = outcome.functions
        return changed
    }

    @discardableResult
    func create(name: String, source: String) throws -> UUID {
        let id = try documentStore.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        reloadCatalog()
        return id
    }

    func select(_ id: UUID) throws { try documentStore.select(id) }

    func rename(_ id: UUID, to name: String) throws {
        try documentStore.rename(id, to: try InMemoryCalculatorDocuments.validName(name))
        reloadCatalog()
    }

    func delete(_ ids: [UUID]) throws {
        guard sheets.contains(where: { !ids.contains($0.id) }) else { throw CalculatorDocumentsError.lastSheet }
        try documentStore.delete(ids)
        reloadCatalog()
    }

    // MARK: Preferences

    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) throws {
        var next = preferences
        change(&next)
        let saved = try documentStore.updatePreferences { stored in
            stored.fontSize = next.fontSize; stored.decimalPlaces = next.decimalPlaces; stored.numberStyle = next.numberStyle
            stored.defaultCurrency = next.defaultCurrency; stored.workdayRegion = next.workdayRegion; stored.autoCurrencyRates = next.autoCurrencyRates
            stored.language = next.language
        }
        preferences = Self.preferences(saved)
    }

    static func preferences(_ stored: CalculatorStoredPreferences) -> CalculatorPreferences {
        var preferences = CalculatorPreferences()
        preferences.fontSize = stored.fontSize; preferences.decimalPlaces = stored.decimalPlaces; preferences.numberStyle = stored.numberStyle
        preferences.defaultCurrency = stored.defaultCurrency; preferences.workdayRegion = stored.workdayRegion
        preferences.autoCurrencyRates = stored.autoCurrencyRates; preferences.language = stored.language
        return preferences
    }

    // MARK: History

    func captureVersion(_ id: UUID, force: Bool) throws -> Bool { try documentStore.captureVersion(id, now: now(), force: force) }
    func versions(of id: UUID) throws -> CalculatorVersionHistory { try documentStore.versions(of: id) }

    func restoreVersion(_ id: UUID, hash: String) throws -> CalculatorOpenedSheet {
        let sheet = try documentStore.restoreVersion(id, hash: hash, now: now())
        functions = try documentStore.functions(for: sheet)
        return CalculatorOpenedSheet(source: sheet.source, generated: try CalculatorGeneratedValues(sheet))
    }

    // MARK: Lifetime

    /// Every write is already on disk when its call returns (atomic replace); nothing is buffered.
    func flush() {}

    func close() {
        guard !isClosed else { return }
        isClosed = true
        documentStore.close()
        if throwaway { try? FileManager.default.removeItem(at: documentStore.directory) }
    }
}
