import Foundation

/// Narrow store operations used only by `FolderSync`. They keep the catalog-before-body
/// and backup rules of ordinary edits; imported sheets keep the identity they have on every computer.
extension WorkspaceStore {
    var dataDirectory: String { directory }
    var currentWorkspace: WorkspaceDocument { get throws { try requireWorkspace() } }

    /// The body file's last write time (DateTime ticks, UTC) and length, or nil when it is missing.
    func sheetStamp(_ id: UUID) -> (ticks: Int64, length: Int64)? {
        let info = NetFile.info(sheetPath(id))
        return info.exists && !info.isDirectory ? (info.lastWriteTicks, info.length) : nil
    }
    func readSheetForSync(_ id: UUID) throws -> SheetDocument { try requireSheet(id); return try readSaved(id) }
    static func validateSheetName(_ name: String) throws { try validateName(name) }

    func importSyncedSheet(_ sheet: SheetDocument, _ name: String) throws -> WorkspaceDocument {
        let current = try requireWorkspace()
        if current.sheets.contains(where: { $0.id == sheet.id }) { throw CalcError.invalidData("Sheet already present") }
        if current.sheets.count == WorkspaceStore.maxSheets { throw CalcError.invalidData("Maximum \(WorkspaceStore.maxSheets) sheets") }
        try WorkspaceStore.validateName(name); try SheetStore.validate(sheet)
        try NetFile.createDirectory(sheetsDirectory)
        try AtomicJson.write(sheetPath(sheet.id), sheet)
        let next = current.with { $0.sheets.append(SheetEntry(sheet.id, name)) }
        do { try commit(next) }
        catch {
            do { try NetFile.delete(sheetPath(sheet.id)); try NetFile.delete(sheetPath(sheet.id) + ".bak") }
            catch let e where e.isIOException || e.isUnauthorized {}
            throw error
        }
        return next
    }

    /// Replaces a sheet with a newer synchronized revision. The replaced content is first kept in version history.
    func applySyncedSheet(_ sheet: SheetDocument, _ name: String, _ now: DateTimeOffset) throws -> WorkspaceDocument {
        try requireSheet(sheet.id); try WorkspaceStore.validateName(name); try SheetStore.validate(sheet)
        let added = loadedSheets.insert(sheet.id).inserted
        do {
            defer { if added { loadedSheets.remove(sheet.id) } }
            do { try captureVersion(sheet.id, now, force: true) }
            catch let e where e.isIOException || e.isUnauthorized || e.isInvalidData || e.isJsonError {}
        }
        try AtomicJson.write(sheetPath(sheet.id), sheet)
        let current = try requireWorkspace()
        if !current.sheets.first(where: { $0.id == sheet.id })!.name.ordinalEquals(name) {
            try commit(current.with { $0.sheets = $0.sheets.map { $0.id == sheet.id ? SheetEntry($0.id, name) : $0 } })
        }
        return try requireWorkspace()
    }

    func removeSyncedSheet(_ id: UUID) throws -> WorkspaceDocument { try delete(id) }
}
