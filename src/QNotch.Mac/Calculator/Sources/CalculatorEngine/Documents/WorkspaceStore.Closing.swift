import Foundation

extension WorkspaceStore {
    /// Deletes a group of sheets in one catalog write: all of them or, if the write fails, none. At least one sheet always remains.
    @discardableResult
    func deleteMany(_ ids: [UUID]) throws -> WorkspaceDocument {
        let current = try requireWorkspace()
        let gone = Set(ids)
        let remaining = current.sheets.filter { !gone.contains($0.id) }
        if remaining.isEmpty { throw CalcError.invalidData("Keep at least one sheet") }
        if remaining.count == current.sheets.count { return current }
        let next = current.with { $0.sheets = remaining; $0.activeSheetId = gone.contains(current.activeSheetId) ? remaining[0].id : current.activeSheetId }
        try commit(next)
        loadedSheets.subtract(gone)
        return next
    }
}
