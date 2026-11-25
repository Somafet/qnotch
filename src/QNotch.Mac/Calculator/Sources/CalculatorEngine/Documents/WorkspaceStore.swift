import Foundation

struct SheetEntry: Equatable {
    var id: UUID
    var name: String
    var nulls = JSONNulls()
    init(_ id: UUID, _ name: String) { self.id = id; self.name = name }
    static func decode(_ json: NetJSON.Reader) throws -> SheetEntry {
        let name = try json.string("Name")
        var entry = SheetEntry(try json.guid("Id"), name ?? "")
        if name == nil { entry.nulls.insert("Name") }
        return entry
    }
    var json: String { NetJSON.object([("Id", NetJSON.guid(id)), ("Name", NetJSON.string(name))]) }
}

struct WorkspaceDocument: Equatable, JSONDocument {
    var version: Int
    var activeSheetId: UUID
    var dark: Bool
    var sheets: [SheetEntry]
    var nulls = JSONNulls()
    init(_ version: Int, _ activeSheetId: UUID, _ dark: Bool, _ sheets: [SheetEntry]) {
        self.version = version; self.activeSheetId = activeSheetId; self.dark = dark; self.sheets = sheets
    }
    func with(_ change: (inout WorkspaceDocument) -> Void) -> WorkspaceDocument { var copy = self; change(&copy); return copy }

    static func decode(_ json: NetJSON.Reader) throws -> WorkspaceDocument {
        let sheets = try json.array("Sheets") { try NetJSON.Reader.element($0, SheetEntry.decode) }
        var document = WorkspaceDocument(try json.int("Version"), try json.guid("ActiveSheetId"), try json.bool("Dark"), sheets?.compactMap { $0 } ?? [])
        if sheets == nil || sheets!.contains(where: { $0 == nil }) { document.nulls.insert("Sheets") }
        return document
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("ActiveSheetId", NetJSON.guid(activeSheetId)), ("Dark", NetJSON.bool(dark)),
                        ("Sheets", NetJSON.array(sheets.map(\.json)))])
    }
}

struct WorkspaceLoadResult {
    let workspace: WorkspaceDocument
    let recovered: Bool
    let migrated: Bool
}

/// A bounded metadata catalog; individual source files are read only when opened.
/// Source is committed before catalog creation and catalogs never refer to uncommitted new sheets.
/// Like `SheetStore`, the store holds `session.lock` exclusively for its lifetime, so only one store owns a data folder.
final class WorkspaceStore {
    static let maxSheets = 256
    static let maxNameLength = 80
    static let maxCatalogBytes = 256_000
    static let starterSource = "price = 120\ndiscount = 15%\nprice * discount\nprice * (1 - discount)"
    let catalogPath: String
    let directory: String
    let sheetsDirectory: String
    private var sessionLock: NetFile.Hold?
    var workspace: WorkspaceDocument?
    var loadedSheets = Set<UUID>()
    // WorkspaceStore.Functions
    var functionLibraryCache: FunctionLibrary?
    var functionCatalogVersion = 1
    var functionsRecovered = false
    // WorkspaceStore.Preferences
    var preferencesRecovered = false
    // WorkspaceStore.Versions
    var newestVersions: [UUID: DateTimeOffset] = [:]
    /// Folder scans so far, so tests and diagnostics can prove startup and switching load no history.
    var versionScans = 0

    init(_ directory: String) throws {
        self.directory = directory
        try NetFile.createDirectory(directory)
        catalogPath = (directory as NSString).appendingPathComponent("workspace.json")
        sheetsDirectory = (directory as NSString).appendingPathComponent("sheets")
        sessionLock = try NetFile.Hold((directory as NSString).appendingPathComponent("session.lock"), exclusive: true, create: true)
    }

    func load() throws -> WorkspaceLoadResult {
        workspace = nil; loadedSheets.removeAll(); functionLibraryCache = nil; newestVersions.removeAll()
        if NetFile.fileExists(catalogPath) || NetFile.fileExists(catalogPath + ".bak") {
            let loaded = try AtomicJson.load(catalogPath, Int64(WorkspaceStore.maxCatalogBytes), WorkspaceStore.validate)
            workspace = loaded.value
            try recoverFunctionSave(loaded.value)
            return WorkspaceLoadResult(workspace: loaded.value, recovered: loaded.recovered, migrated: false)
        }
        let legacyPath = (directory as NSString).appendingPathComponent("sheet.json")
        let initial: SheetDocument
        let migrated = NetFile.fileExists(legacyPath) || NetFile.fileExists(legacyPath + ".bak")
        var recovered = false
        if migrated {
            let legacy = try AtomicJson.load(legacyPath, Int64(SheetStore.maxDocumentBytes), SheetStore.validate)
            initial = legacy.value; recovered = legacy.recovered
        } else { initial = SheetDocument(1, UUID.netNew(), WorkspaceStore.starterSource, false) }
        try NetFile.createDirectory(sheetsDirectory)
        // An interrupted migration can be retried. The legacy file and its backup stay untouched.
        try AtomicJson.write(sheetPath(initial.id), initial)
        let created = WorkspaceDocument(1, initial.id, initial.dark, [SheetEntry(initial.id, "Sheet")])
        try commit(created)
        try recoverFunctionSave(created)
        return WorkspaceLoadResult(workspace: created, recovered: recovered, migrated: migrated)
    }

    func open(_ id: UUID) throws -> LoadResult {
        try requireSheet(id)
        loadedSheets.remove(id)
        let loaded = try AtomicJson.load(sheetPath(id), Int64(SheetStore.maxDocumentBytes)) { (sheet: SheetDocument) in
            try SheetStore.validate(sheet)
            if sheet.id != id { throw CalcError.invalidData("Sheet identity does not match catalog") }
        }
        let receipts = try readFunctionReceiptFile(id)
        loadedSheets.insert(id)
        return LoadResult(loaded.value, loaded.recovered || receipts.recovered, receipts.document.receipts)
    }

    func save(_ sheet: SheetDocument) throws {
        try requireSheet(sheet.id)
        if !loadedSheets.contains(sheet.id) { throw CalcError.invalidOperation("Open must succeed before saving a sheet") }
        try SheetStore.validate(sheet)
        try AtomicJson.write(sheetPath(sheet.id), sheet)
    }

    @discardableResult
    func create(_ name: String, _ source: String = "") throws -> WorkspaceDocument {
        let current = try requireWorkspace()
        if current.sheets.count == WorkspaceStore.maxSheets { throw CalcError.invalidData("Maximum \(WorkspaceStore.maxSheets) sheets") }
        try WorkspaceStore.validateName(name)
        let sheet = SheetDocument(1, UUID.netNew(), source, false)
        try SheetStore.validate(sheet)
        try AtomicJson.write(sheetPath(sheet.id), sheet)
        let next = current.with { $0.activeSheetId = sheet.id; $0.sheets.append(SheetEntry(sheet.id, name.netTrim)) }
        do { try commit(next) }
        catch {
            // The catalog did not commit. Do not accumulate a body for every failed attempt.
            do { try NetFile.delete(sheetPath(sheet.id)); try NetFile.delete(sheetPath(sheet.id) + ".bak") }
            catch let e where e.isIOException || e.isUnauthorized {}
            throw error
        }
        loadedSheets.insert(sheet.id)
        return next
    }

    @discardableResult
    func rename(_ id: UUID, _ name: String) throws -> WorkspaceDocument {
        try requireSheet(id); try WorkspaceStore.validateName(name)
        let current = try requireWorkspace()
        return try commitAndCopy(current.with { $0.sheets = $0.sheets.map { $0.id == id ? SheetEntry($0.id, name.netTrim) : $0 } })
    }

    @discardableResult
    func select(_ id: UUID) throws -> WorkspaceDocument {
        try requireSheet(id)
        return try commitAndCopy(try requireWorkspace().with { $0.activeSheetId = id })
    }

    @discardableResult
    func setDark(_ dark: Bool) throws -> WorkspaceDocument { try commitAndCopy(try requireWorkspace().with { $0.dark = dark }) }

    @discardableResult
    func delete(_ id: UUID) throws -> WorkspaceDocument {
        try requireSheet(id)
        let current = try requireWorkspace()
        if current.sheets.count == 1 { throw CalcError.invalidOperation("Keep at least one sheet") }
        let remaining = current.sheets.filter { $0.id != id }
        let next = current.with { $0.sheets = remaining; $0.activeSheetId = current.activeSheetId == id ? remaining[0].id : current.activeSheetId }
        try commit(next); loadedSheets.remove(id)
        return next
    }

    private func commitAndCopy(_ next: WorkspaceDocument) throws -> WorkspaceDocument { try commit(next); return next }

    func commit(_ next: WorkspaceDocument) throws {
        try WorkspaceStore.validate(next); try AtomicJson.write(catalogPath, next); workspace = next
        // Keep bodies referenced by current/backup catalogs. Prune only files owned by Calc.
        // Failure here does not invalidate a committed user action; retry on the next metadata change.
        do {
            var retained = Set(next.sheets.map(\.id))
            if NetFile.fileExists(catalogPath + ".bak") {
                let backup: WorkspaceDocument = try AtomicJson.read(catalogPath + ".bak", Int64(WorkspaceStore.maxCatalogBytes), WorkspaceStore.validate)
                retained.formUnion(backup.sheets.map(\.id))
            }
            for file in try NetFile.files(sheetsDirectory) {
                var name = (file as NSString).lastPathComponent
                if name.hasSuffix(".bak") { name = name.netSubstring(0, name.netLength - 4) }
                let suffix = name.hasSuffix(".json") ? ".json" : name.hasSuffix(".receipts") ? ".receipts" : nil
                guard let suffix, let id = UUID.netParseN(name.netSubstring(0, name.netLength - suffix.netLength)) else { continue }
                if !retained.contains(id) { try NetFile.delete(file) }
            }
            try pruneVersions(retained)
        } catch let e where e.isIOException || e.isInvalidData || e.isUnauthorized || e.isJsonError {}
    }

    func sheetPath(_ id: UUID) -> String { (sheetsDirectory as NSString).appendingPathComponent(id.netN + ".json") }

    func requireWorkspace() throws -> WorkspaceDocument {
        guard let current = workspace else { throw CalcError.invalidOperation("Load must succeed first") }
        try recoverFunctionSave(current)
        return current
    }

    func requireSheet(_ id: UUID) throws {
        if !(try requireWorkspace()).sheets.contains(where: { $0.id == id }) { throw CalcError.invalidData("Unknown sheet") }
    }

    static func validateName(_ name: String) throws {
        let units = Array(name.utf16)
        if units.allSatisfy(NetChar.isWhiteSpace) || units.count > maxNameLength || units.contains(where: NetChar.isControl) {
            throw CalcError.invalidData("Use a sheet name of 1–80 characters without control characters")
        }
    }
    private static func validateName(_ entry: SheetEntry) throws {
        if entry.nulls.contains("Name") { throw CalcError.invalidData("Use a sheet name of 1–80 characters without control characters") }
        try validateName(entry.name)
    }

    static func validate(_ value: WorkspaceDocument) throws {
        if value.version != 1 { throw DocumentError.unsupportedVersion }
        let ids = value.sheets.map(\.id)
        if value.nulls.contains("Sheets") || value.sheets.count < 1 || value.sheets.count > maxSheets || ids.contains(.netEmpty) ||
            Set(ids).count != ids.count || !ids.contains(value.activeSheetId) {
            throw CalcError.invalidData("Invalid sheet catalog")
        }
        for sheet in value.sheets { try validateName(sheet) }
    }

    /// `Dispose`: releases the session lock.
    func dispose() { sessionLock?.close(); sessionLock = nil }
    deinit { dispose() }
}
