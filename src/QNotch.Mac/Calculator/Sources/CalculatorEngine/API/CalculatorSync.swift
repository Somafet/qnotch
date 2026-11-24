import Foundation

/// The outcome of one sync pass (C# SyncReport).
public struct CalculatorSyncReport {
    public enum Status: Sendable { case off, folderUnavailable, synchronized, waiting, failed }
    public let status: Status
    /// True when the pass changed the catalog: the store's `sheets` and `activeSheetID` are new.
    public let catalogChanged: Bool
    /// Sheets whose text the pass replaced; an editor showing one must load it again.
    public let changedSheets: Set<UUID>
    public let published: Int, imported: Int, updated: Int, deleted: Int, conflicts: Int, restored: Int, waiting: Int, damaged: Int, failed: Int
    /// The engine's English detail, for a tooltip.
    public let problem: String?

    init(_ report: SyncReport) {
        switch report.status {
        case .off: status = .off
        case .folderUnavailable: status = .folderUnavailable
        case .synchronized: status = .synchronized
        case .waiting: status = .waiting
        case .failed: status = .failed
        }
        catalogChanged = report.workspace != nil
        changedSheets = report.changedSheets
        published = report.published; imported = report.imported; updated = report.updated; deleted = report.deleted
        conflicts = report.conflicts; restored = report.restored; waiting = report.waiting; damaged = report.damaged; failed = report.failed
        problem = report.problem
    }
}

/// Optional sync through a folder the user chose (C# FolderSync and FolderSyncSession): each sheet is a `{id}.calcsheet` file there,
/// the same files Windows reads and writes, so an iCloud Drive, Dropbox or OneDrive folder keeps both computers' sheets together.
/// Off unless a folder was chosen; while off nothing exists: no watcher, timer or task.
///
/// When on, folder events and `request()` restart one debounce timer; a pass reads the folder on a background queue, then applies on the
/// store's thread through `post`. `canApply` (on that thread) can defer the pass, for example while text is being composed or a save failed.
public final class CalculatorSyncSession {
    private let session: FolderSyncSession

    public init(store: CalculatorDocumentStore, device: String, post: @escaping (@escaping () -> Void) -> Void, canApply: @escaping () -> Bool,
                completed: @escaping (CalculatorSyncReport) -> Void) {
        session = FolderSyncSession(store.store, store.directory.path, device, post: post, canApply: canApply,
                                    completed: { completed(CalculatorSyncReport($0)) })
    }

    /// Reads the configured folder and, only if one is set, starts watching and asks for a first pass.
    public func start() throws { try CalculatorDocumentError.wrap { try session.start() } }
    /// Chooses another folder (its first pass merges both sides by identity) or, with nil, stops syncing. Files in the folder are never
    /// touched by stopping.
    public func setFolder(_ folder: URL?) throws { try CalculatorDocumentError.wrap { try session.setFolder(folder?.path) } }
    /// Asks for a pass soon (after a save or a catalog change).
    public func request() { session.request() }
    public var folder: URL? { session.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    public var watching: Bool { session.watching }
    public var passes: Int { session.passes }
    /// Stops watching and cancels any pending pass.
    public func dispose() { session.dispose() }

    /// The folder `sync.json` names, or nil when sync is off. Reads nothing else.
    public static func configuredFolder(in store: CalculatorDocumentStore) throws -> URL? {
        try CalculatorDocumentError.wrap { try FolderSync.configuredFolder(store.directory.path).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }
    /// Turns sync off without a session (clearing never touches the folder's files).
    public static func clearFolder(in store: CalculatorDocumentStore) throws {
        try CalculatorDocumentError.wrap { try FolderSync.setFolder(store.directory.path, nil) }
    }
    /// Why a folder cannot be the sync folder (inside the calculator's own data folder, or not a full path), or nil.
    public static func problem(with folder: URL, in store: CalculatorDocumentStore) -> String? {
        do { _ = try FolderSync.validateFolder(store.directory.path, folder.path); return nil } catch { return error.netMessage }
    }
    /// Folder watchers alive in this process (diagnostics prove an off setting creates none).
    public static var liveWatchers: Int { FolderSyncSession.liveWatchers }
    /// The sheet file extension in the folder.
    public static let fileExtension = SyncFolderFiles.extension
}
