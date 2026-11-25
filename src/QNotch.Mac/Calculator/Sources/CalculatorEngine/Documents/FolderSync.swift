import Foundation

/// What this computer last agreed with the folder about one sheet. Body stamp avoids rereading unchanged sheets.
struct SyncBase: Equatable {
    var sheetId: UUID
    var revision: UUID
    var hash: String
    var name: String
    var bodyTicks: Int64
    var bodyLength: Int64
    var nulls = JSONNulls()
    init(_ sheetId: UUID, _ revision: UUID, _ hash: String, _ name: String, _ bodyTicks: Int64, _ bodyLength: Int64) {
        self.sheetId = sheetId; self.revision = revision; self.hash = hash; self.name = name; self.bodyTicks = bodyTicks; self.bodyLength = bodyLength
    }
    static func decode(_ json: NetJSON.Reader) throws -> SyncBase {
        let hash = try json.string("Hash"), name = try json.string("Name")
        var value = SyncBase(try json.guid("SheetId"), try json.guid("Revision"), hash ?? "", name ?? "", try json.long("BodyTicks"), try json.long("BodyLength"))
        if hash == nil || name == nil { value.nulls.insert("Fields") }
        return value
    }
    var json: String {
        NetJSON.object([("SheetId", NetJSON.guid(sheetId)), ("Revision", NetJSON.guid(revision)), ("Hash", NetJSON.string(hash)), ("Name", NetJSON.string(name)),
                        ("BodyTicks", NetJSON.long(bodyTicks)), ("BodyLength", NetJSON.long(bodyLength))])
    }
}

/// Local-only sync settings and bases, stored in sync.json beside the workspace. Folder nil means off.
struct SyncStateDocument: Equatable, JSONDocument {
    var version: Int
    var folder: String?
    var bases: [SyncBase]
    var nulls = JSONNulls()
    init(_ version: Int, _ folder: String?, _ bases: [SyncBase]) { self.version = version; self.folder = folder; self.bases = bases }
    static func decode(_ json: NetJSON.Reader) throws -> SyncStateDocument {
        let bases = try json.array("Bases") { try NetJSON.Reader.element($0, SyncBase.decode) }
        var state = SyncStateDocument(try json.int("Version"), try json.string("Folder"), bases?.compactMap { $0 } ?? [])
        if bases == nil || bases!.contains(where: { $0 == nil || !$0!.nulls.isEmpty }) { state.nulls.insert("Bases") }
        return state
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("Folder", NetJSON.string(folder)), ("Bases", NetJSON.array(bases.map(\.json)))])
    }
}

enum SyncStatus { case off, folderUnavailable, synchronized, waiting, failed }

struct SyncReport {
    let status: SyncStatus
    let workspace: WorkspaceDocument?
    let changedSheets: Set<UUID>
    var published = 0, imported = 0, updated = 0, deleted = 0, conflicts = 0, restored = 0, waiting = 0, damaged = 0, failed = 0
    /// A locked file or a concurrent folder change deferred work; one bounded retry is worthwhile.
    var retrySoon = false
    /// An incomplete file is being given time to finish downloading; a pass after this delay (ticks) can set it aside.
    var recheckAfter: Int64?
    var problem: String?
    init(_ status: SyncStatus, _ workspace: WorkspaceDocument?, _ changedSheets: Set<UUID>) {
        self.status = status; self.workspace = workspace; self.changedSheets = changedSheets
    }
}

/// Three-way sheet synchronization through a user-selected folder. One pass reconciles a folder snapshot with the
/// local workspace: fast-forward when the folder descends from this computer's base, publish local edits on top of the base,
/// and otherwise keep the local sheet and import the other revision as a conflict copy. Nothing is deleted locally unless a
/// Calc tombstone descends from an unchanged base; a file removed outside Calc is restored from the local copy.
/// Placeholders, incomplete, locked and future-format files are never read into sheets or overwritten.
/// Not thread-safe: call `synchronize` on the thread that owns the store.
final class FolderSync {
    static let stateFile = "sync.json"
    static let maxBases = WorkspaceStore.maxSheets * 2
    /// Ten minutes, in ticks.
    static let incompleteGrace: Int64 = 10 * Ticks.perMinute
    /// 180 days, in ticks.
    static let tombstoneLifetime: Int64 = 180 * Ticks.perDay
    private static let trustedStampAge: Int64 = 2 * Ticks.perSecond
    private let store: WorkspaceStore
    private let device: String
    private let clock: () -> DateTimeOffset
    private var incomplete = NetDictionary<UUID, (ticks: Int64, length: Int64, since: DateTimeOffset)>()

    init(_ store: WorkspaceStore, _ device: String?, clock: (() -> DateTimeOffset)? = nil) {
        self.store = store
        let clean = String(units: (device ?? "").utf16.filter { !NetChar.isControl($0) }).netTrim
        self.device = clean.isEmpty ? "Computer" : clean.netSubstring(0, min(clean.netLength, SyncFolderFiles.maxDeviceLength))
        self.clock = clock ?? { DateTimeOffset.utcNow }
    }

    static func statePath(_ dataDirectory: String) -> String { (dataDirectory as NSString).appendingPathComponent(stateFile) }

    /// Nil when sync is off. A missing state file means off, so default startup reads nothing else.
    static func configuredFolder(_ dataDirectory: String) throws -> String? {
        let path = statePath(dataDirectory)
        if !NetFile.fileExists(path) && !NetFile.fileExists(path + ".bak") { return nil }
        return try loadState(dataDirectory).folder
    }

    /// Selects or clears the folder. A new folder starts without bases, so the first pass merges both sides by identity.
    /// Clearing never touches files in the folder.
    static func setFolder(_ dataDirectory: String, _ folder: String?) throws {
        var folder = folder
        if let chosen = folder {
            folder = try validateFolder(dataDirectory, chosen)
            if !NetFile.directoryExists(folder!) { throw DocumentError.directoryNotFound("Sync folder not found") }
        }
        let path = statePath(dataDirectory)
        if folder == nil && !NetFile.fileExists(path) && !NetFile.fileExists(path + ".bak") { return }
        let current = NetFile.fileExists(path) || NetFile.fileExists(path + ".bak") ? try tryLoadState(dataDirectory) : nil
        if let existing = current?.folder, let folder, sameFolder(existing, folder) { return }
        try AtomicJson.write(path, SyncStateDocument(1, folder, []))
    }

    static func validateFolder(_ dataDirectory: String, _ folder: String) throws -> String {
        if folder.utf16.allSatisfy(NetChar.isWhiteSpace) || !isFullyQualified(folder) { throw CalcError.invalidData("Choose a full folder path") }
        let full = fullPath(folder), data = fullPath(dataDirectory)
        if sameFolder(full, data) || inside(full, data) || inside(data, full) { throw CalcError.invalidData("Choose a folder outside the calculator's own data folder") }
        return full
    }
    /// `Path.IsPathFullyQualified` on Unix.
    static func isFullyQualified(_ path: String) -> Bool { path.hasPrefix("/") }
    /// `Path.TrimEndingDirectorySeparator(Path.GetFullPath(path))`: "." and ".." resolved, repeated and trailing separators removed.
    /// Symbolic links are not resolved, as in .NET.
    static func fullPath(_ path: String) -> String {
        let absolute = isFullyQualified(path) ? path : FileManager.default.currentDirectoryPath + "/" + path
        var parts: [Substring] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
    private static func sameFolder(_ a: String, _ b: String) -> Bool { fullPath(a).equalsIgnoreCase(fullPath(b)) }
    private static func inside(_ child: String, _ parent: String) -> Bool { child.startsWithIgnoreCase(parent == "/" ? "/" : parent + "/") }

    static func loadState(_ dataDirectory: String) throws -> SyncStateDocument {
        let path = statePath(dataDirectory)
        if !NetFile.fileExists(path) && !NetFile.fileExists(path + ".bak") { return SyncStateDocument(1, nil, []) }
        return try AtomicJson.load(path, 512_000, validateState).value
    }
    private static func tryLoadState(_ dataDirectory: String) throws -> SyncStateDocument? {
        do { return try loadState(dataDirectory) }
        catch let e where e.isIOException || e.isInvalidData || e.isJsonError || e.isUnauthorized { return nil }
    }
    private static func validateState(_ state: SyncStateDocument) throws {
        if state.version != 1 { throw DocumentError.unsupportedVersion }
        if state.nulls.contains("Bases") || state.bases.count > maxBases || state.bases.contains(where: { $0.sheetId.isNetEmpty || $0.revision.isNetEmpty }) ||
            Set(state.bases.map(\.sheetId)).count != state.bases.count || state.folder.map({ !isFullyQualified($0) }) == true {
            throw CalcError.invalidData("Invalid sync state")
        }
    }

    func scan(_ folder: String) -> SyncFolderSnapshot { SyncFolderFiles.scan(folder, clock()) }

    func synchronize(_ snapshot: SyncFolderSnapshot) throws -> SyncReport { try Pass(self, snapshot).run() }

    private struct LocalSheet { let id: UUID, name: String, hash: String, ticks: Int64, length: Int64, sheet: SheetDocument? }

    private final class Pass {
        private let owner: FolderSync
        private let snapshot: SyncFolderSnapshot
        private let store: WorkspaceStore
        private let folder: String
        private let now: DateTimeOffset
        private var changed = Set<UUID>()
        private var bases: [UUID: SyncBase] = [:]
        private var workspace = WorkspaceDocument(1, .netEmpty, false, [])
        private var workspaceChanged = false, basesChanged = false, retry = false
        private var published = 0, imported = 0, updated = 0, deleted = 0, conflicts = 0, restored = 0, waiting = 0, damaged = 0, failed = 0
        private var recheck: Int64?
        private var problem: String?

        init(_ owner: FolderSync, _ snapshot: SyncFolderSnapshot) {
            self.owner = owner; self.snapshot = snapshot; store = owner.store; folder = snapshot.folder; now = owner.clock()
        }

        func run() throws -> SyncReport {
            let state = try FolderSync.loadState(store.dataDirectory)
            guard let configured = state.folder else { return SyncReport(.off, nil, changed) }
            if !FolderSync.sameFolder(configured, folder) { var report = SyncReport(.off, nil, changed); report.retrySoon = true; return report }
            if !snapshot.available { var report = SyncReport(.folderUnavailable, nil, changed); report.problem = "Sync folder unavailable"; return report }
            for base in state.bases { bases[base.sheetId] = base }
            workspace = try store.currentWorkspace
            var seen = Set<UUID>(); var ids: [UUID] = []
            for id in workspace.sheets.map(\.id) + state.bases.map(\.sheetId) + snapshot.canonical.keys where seen.insert(id).inserted { ids.append(id) }
            for id in ids.sorted(by: UUID.netLess) { try guarded { try self.reconcile(id) } }
            for duplicate in snapshot.duplicates { try guarded { try self.duplicate(duplicate) } }
            cleanup()
            for id in owner.incomplete.keys where snapshot.canonical[id].map({ $0.state != .incomplete }) ?? true { owner.incomplete.remove(id) }
            if basesChanged {
                let ordered = Array(bases.values.sorted { UUID.netLess($0.sheetId, $1.sheetId) }.prefix(FolderSync.maxBases))
                // Sheets this pass already saved must still reach the editor when the state write fails, or its next save overwrites them.
                try guarded { try AtomicJson.write(FolderSync.statePath(store.dataDirectory), SyncStateDocument(1, configured, ordered)) }
            }
            let status: SyncStatus = failed > 0 ? .failed : waiting + damaged > 0 || retry ? .waiting : .synchronized
            var report = SyncReport(status, workspaceChanged ? workspace : nil, changed)
            report.published = published; report.imported = imported; report.updated = updated; report.deleted = deleted; report.conflicts = conflicts
            report.restored = restored; report.waiting = waiting; report.damaged = damaged; report.failed = failed; report.retrySoon = retry
            report.recheckAfter = recheck; report.problem = problem
            return report
        }

        private func guarded(_ action: () throws -> Void) throws {
            do { try action() }
            catch let e where e.isIOException || e.isUnauthorized || e.isInvalidData || e.isJsonError { failed += 1; if problem == nil { problem = e.netMessage } }
        }

        private func hasLocal(_ id: UUID) -> Bool { workspace.sheets.contains { $0.id == id } }

        private func reconcile(_ id: UUID) throws {
            let hasLocal = hasLocal(id)
            let known = bases[id]
            var entry = snapshot.canonical[id]
            if let pending = entry, pending.state != .ready {
                if !(try setAsideIfAbandoned(id, pending)) { return }
                entry = nil
            }
            let remote = entry?.file
            if !hasLocal {
                guard let known else { if let remote, !remote.deleted { try importSheet(remote) }; return }
                guard let remote, !remote.deleted else { forget(id); return }
                if remote.revision == known.revision {
                    if try write(next(id, FolderSync.ancestry(remote.revision, nil, remote.ancestors), deleted: true), expected: remote.revision) { forget(id) }
                    return
                }
                try importSheet(remote) // Edited elsewhere after this computer deleted it: the edit wins.
                return
            }
            let local = try self.local(id, known)
            let localChanged = known == nil || local.hash != known!.hash
            guard let remote else {
                // Removed outside Calc (or never published). Restore from the local copy; an unchanged sheet keeps its revision.
                if known != nil { restored += 1 }
                let revision = known != nil && !localChanged ? known!.revision : UUID.netNew()
                try publish(local, revision, known == nil || !localChanged ? [] : [known!.revision], expected: nil)
                return
            }
            if remote.deleted {
                if let known, !localChanged, remote.ancestors.contains(known.revision), workspace.sheets.count > 1 {
                    workspace = try store.removeSyncedSheet(id); workspaceChanged = true; changed.insert(id); deleted += 1; forget(id)
                    return
                }
                // Edited here (or the last sheet): keep it and publish over the tombstone.
                try publish(local, UUID.netNew(), FolderSync.ancestry(remote.revision, known?.revision, remote.ancestors), expected: remote.revision)
                return
            }
            if let known, remote.revision == known.revision {
                if localChanged { try publish(local, UUID.netNew(), FolderSync.ancestry(known.revision, nil, remote.ancestors), expected: remote.revision) }
                else if local.ticks != known.bodyTicks || local.length != known.bodyLength { remember(local, known.revision) } // Same content, newer stamp.
                return
            }
            if local.hash == remote.hash { remember(local, remote.revision); return }
            if let known, !localChanged, remote.ancestors.contains(known.revision) {
                let dark = try store.readSheetForSync(id).dark
                workspace = try store.applySyncedSheet(SyncFolderFiles.toSheet(remote, dark), remote.name, now); workspaceChanged = true
                changed.insert(id); updated += 1
                remember(try self.local(id, nil), remote.revision)
                return
            }
            // Both sides changed, or the folder holds a write that did not build on this computer's base.
            // Keep the local sheet, preserve the other revision as its own sheet, then publish local on top of both.
            if !(try conflictCopy(remote)) { return }
            try publish(local, UUID.netNew(), FolderSync.ancestry(remote.revision, known?.revision, remote.ancestors), expected: remote.revision)
        }

        private func duplicate(_ entry: SyncFolderEntry) throws {
            let file = entry.file!
            var redundant = file.deleted || hasLocal(file.revision)
            if !redundant, let canonical = snapshot.canonical[file.sheetId], canonical.file?.hash == file.hash, canonical.file?.deleted == false { redundant = true }
            if !redundant, hasLocal(file.sheetId) { redundant = try local(file.sheetId, bases[file.sheetId]).hash == file.hash }
            if !redundant { if !(try conflictCopy(file)) { return } }
            try NetFile.delete(entry.path) // Its content is now an ordinary sheet (or already was).
        }

        /// The copy's identity is the other revision's ID, so computers resolving the same conflict produce the same sheet and file.
        private func conflictCopy(_ other: SyncSheetFile) throws -> Bool {
            let id = other.revision
            if hasLocal(id) { return true }
            if workspace.sheets.count >= WorkspaceStore.maxSheets {
                failed += 1; if problem == nil { problem = "Conflict not resolved: maximum \(WorkspaceStore.maxSheets) sheets" }; return false
            }
            let suffix = " (conflict, \(other.device))"
            let limit = WorkspaceStore.maxNameLength
            var name = other.name.netLength + suffix.netLength <= limit ? other.name + suffix
                : other.name.netSubstring(0, max(1, limit - suffix.netLength)) + suffix
            if name.netLength > limit { name = name.netSubstring(0, limit) }
            let copy = other.with {
                $0.sheetId = id; $0.revision = id; $0.ancestors = []; $0.name = name
                $0.hash = SyncFolderFiles.contentHash(name, other.source, other.generatedUuids)
            }
            workspace = try store.importSyncedSheet(SyncFolderFiles.toSheet(copy, workspace.dark), name); workspaceChanged = true
            changed.insert(id); conflicts += 1
            let local = try self.local(id, nil)
            if SyncFolderFiles.readCanonical(folder, id) == nil { _ = try write(copy, expected: nil) }
            remember(local, id)
            return true
        }

        private func importSheet(_ remote: SyncSheetFile) throws {
            if workspace.sheets.count >= WorkspaceStore.maxSheets {
                failed += 1; if problem == nil { problem = "Not imported: maximum \(WorkspaceStore.maxSheets) sheets" }; return
            }
            workspace = try store.importSyncedSheet(SyncFolderFiles.toSheet(remote, workspace.dark), remote.name); workspaceChanged = true
            changed.insert(remote.sheetId); imported += 1
            remember(try local(remote.sheetId, nil), remote.revision)
        }

        private func publish(_ local: LocalSheet, _ revision: UUID, _ ancestors: [UUID], expected: UUID?) throws {
            let sheet = try local.sheet ?? store.readSheetForSync(local.id)
            let file = SyncSheetFile(SyncFolderFiles.format, local.id, revision, Array(ancestors.filter { $0 != revision }.prefix(SyncFolderFiles.maxAncestors)),
                                     owner.device, now, false, local.name, sheet.source, local.hash, generatedUuids: sheet.generatedUuids)
            if try write(file, expected: expected) { remember(local, revision); published += 1 }
        }

        /// Compare-and-replace: the folder must still hold the revision this decision was based on.
        private func write(_ file: SyncSheetFile, expected: UUID?) throws -> Bool {
            let current = SyncFolderFiles.readCanonical(folder, file.sheetId)
            let matches: Bool
            if let expected { matches = current?.state == .ready && current?.file?.revision == expected } else { matches = current == nil }
            if !matches { retry = true; return false }
            try SyncFolderFiles.writeAtomic(folder, file)
            return true
        }

        private func next(_ id: UUID, _ ancestors: [UUID], deleted: Bool) -> SyncSheetFile {
            SyncSheetFile(SyncFolderFiles.format, id, UUID.netNew(), Array(ancestors.prefix(SyncFolderFiles.maxAncestors)), owner.device, now, deleted, "", "",
                          SyncFolderFiles.contentHash("", "", nil))
        }

        /// An incomplete file that stays byte-identical past the grace period is moved aside (kept, never deleted)
        /// so local work can be published again. Placeholders, locked and future-format files are only waited on.
        private func setAsideIfAbandoned(_ id: UUID, _ entry: SyncFolderEntry) throws -> Bool {
            if entry.state == .locked { retry = true; waiting += 1; return false }
            if entry.state != .incomplete {
                waiting += 1; if problem == nil { problem = entry.state == .placeholder ? "Waiting for download" : "Sync file from a newer QNotch" }; return false
            }
            var seen = owner.incomplete[id]
            if seen == nil || seen!.ticks != entry.ticks || seen!.length != entry.length {
                seen = (entry.ticks, entry.length, now); owner.incomplete.set(id, seen!)
            }
            let elapsed = now - seen!.since
            if elapsed < FolderSync.incompleteGrace {
                waiting += 1; if problem == nil { problem = "Waiting for a complete sync file" }
                let left = FolderSync.incompleteGrace - elapsed
                recheck = recheck.map { $0 < left ? $0 : left } ?? left
                return false
            }
            let aside = (folder as NSString).appendingPathComponent(id.netN + "." + UUID.netNew().netN + SyncFolderFiles.damagedExtension)
            try NetFile.move(entry.path, aside, overwrite: false)
            owner.incomplete.remove(id); damaged += 1; if problem == nil { problem = "Damaged sync file set aside" }
            return true
        }

        private func cleanup() {
            for path in snapshot.staleTemporaries { try? NetFile.delete(path) }
            for entry in snapshot.canonical.values {
                guard let tombstone = entry.file, tombstone.deleted, bases[tombstone.sheetId] == nil, now - tombstone.savedAt > FolderSync.tombstoneLifetime,
                      !hasLocal(tombstone.sheetId) else { continue }
                if SyncFolderFiles.readCanonical(folder, tombstone.sheetId)?.file?.revision == tombstone.revision { try? NetFile.delete(entry.path) }
            }
        }

        private func local(_ id: UUID, _ known: SyncBase?) throws -> LocalSheet {
            let name = workspace.sheets.first { $0.id == id }!.name
            guard let stamp = store.sheetStamp(id) else { throw DocumentError.fileNotFound("Sheet body missing") }
            if let known, known.bodyTicks != 0, known.name.ordinalEquals(name), known.bodyTicks == stamp.ticks, known.bodyLength == stamp.length {
                return LocalSheet(id: id, name: name, hash: known.hash, ticks: stamp.ticks, length: stamp.length, sheet: nil)
            }
            let sheet = try store.readSheetForSync(id)
            guard let after = store.sheetStamp(id) else { throw DocumentError.fileNotFound("Sheet body missing") }
            // File times advance in coarse ticks, so a stamp is only trusted once it was already old when observed:
            // any later save then necessarily carries a different time. A fresh stamp forces a reread next pass.
            let trusted = DateTimeOffset.utcNow.utcTicks - after.ticks > FolderSync.trustedStampAge
            return LocalSheet(id: id, name: name, hash: SyncFolderFiles.contentHash(name, sheet.source, sheet.generatedUuids),
                              ticks: trusted ? after.ticks : 0, length: after.length, sheet: sheet)
        }
        private func remember(_ local: LocalSheet, _ revision: UUID) {
            bases[local.id] = SyncBase(local.id, revision, local.hash, local.name, local.ticks, local.length); basesChanged = true
        }
        private func forget(_ id: UUID) { if bases.removeValue(forKey: id) != nil { basesChanged = true } }
    }

    private static func ancestry(_ first: UUID, _ second: UUID?, _ rest: [UUID]) -> [UUID] {
        var list = [first]
        if let second { list.append(second) }
        list += rest
        var seen = Set<UUID>()
        return Array(list.filter { seen.insert($0).inserted }.prefix(SyncFolderFiles.maxAncestors))
    }
}
