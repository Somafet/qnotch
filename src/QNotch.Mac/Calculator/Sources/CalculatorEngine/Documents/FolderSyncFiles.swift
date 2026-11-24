import Foundation

/// One sheet in the sync folder, stored as {SheetId:N}.calcsheet. Every write gets a new Revision;
/// Ancestors lists the revisions it superseded (newest first, bounded) so a reader can tell a descendant from a divergent write.
/// A tombstone (Deleted) records a deletion made in Calc. Hash covers name, source and generated values and detects truncation.
struct SyncSheetFile: Equatable, JSONDocument {
    var format: Int
    var sheetId: UUID
    var revision: UUID
    var ancestors: [UUID]
    var device: String
    var savedAt: DateTimeOffset
    var deleted: Bool
    var name: String
    var source: String
    var hash: String
    /// Omitted from JSON when null (JsonIgnoreCondition.WhenWritingNull).
    var generatedUuids: GeneratedUuidState?
    var nulls = JSONNulls()
    init(_ format: Int, _ sheetId: UUID, _ revision: UUID, _ ancestors: [UUID], _ device: String, _ savedAt: DateTimeOffset, _ deleted: Bool,
         _ name: String, _ source: String, _ hash: String, generatedUuids: GeneratedUuidState? = nil) {
        self.format = format; self.sheetId = sheetId; self.revision = revision; self.ancestors = ancestors; self.device = device; self.savedAt = savedAt
        self.deleted = deleted; self.name = name; self.source = source; self.hash = hash; self.generatedUuids = generatedUuids
    }
    func with(_ change: (inout SyncSheetFile) -> Void) -> SyncSheetFile { var copy = self; change(&copy); return copy }

    static func decode(_ json: NetJSON.Reader) throws -> SyncSheetFile {
        let ancestors = try json.array("Ancestors") { try NetJSON.Reader.guid($0, "Ancestors") }
        let device = try json.string("Device"), name = try json.string("Name"), source = try json.string("Source"), hash = try json.string("Hash")
        var file = SyncSheetFile(try json.int("Format"), try json.guid("SheetId"), try json.guid("Revision"), ancestors ?? [], device ?? "", try json.date("SavedAt"),
                                 try json.bool("Deleted"), name ?? "", source ?? "", hash ?? "", generatedUuids: try json.object("GeneratedUuids", GeneratedUuidState.decode))
        if ancestors == nil || device == nil || name == nil || source == nil || hash == nil { file.nulls.insert("Fields") }
        return file
    }
    var json: String {
        NetJSON.object([("Format", NetJSON.int(format)), ("SheetId", NetJSON.guid(sheetId)), ("Revision", NetJSON.guid(revision)),
                        ("Ancestors", NetJSON.array(ancestors.map(NetJSON.guid))), ("Device", NetJSON.string(device)), ("SavedAt", NetJSON.date(savedAt)),
                        ("Deleted", NetJSON.bool(deleted)), ("Name", NetJSON.string(name)), ("Source", NetJSON.string(source)), ("Hash", NetJSON.string(hash)),
                        ("GeneratedUuids", generatedUuids?.json)])
    }
}

enum SyncFileState { case ready, placeholder, incomplete, unsupported, locked }

/// A file found in the sync folder. Only Ready entries have contents; others are never imported or overwritten.
struct SyncFolderEntry {
    var sheetId: UUID
    let path: String
    let state: SyncFileState
    let file: SyncSheetFile?
    let length: Int64
    let ticks: Int64
    let problem: String?
}

/// Immutable folder scan, safe to take on a background thread. Canonical holds {id}.calcsheet files;
/// Duplicates holds valid sheet files under other names (provider conflict copies such as "id (1).calcsheet").
struct SyncFolderSnapshot {
    let folder: String
    let available: Bool
    let canonical: NetDictionary<UUID, SyncFolderEntry>
    let duplicates: [SyncFolderEntry]
    let staleTemporaries: [String]
    let skipped: Int
}

/// Windows file attribute bits, which describe cloud placeholders. `SyncFolderFiles.attributes` maps a Mac file onto them.
struct FileAttributes: OptionSet {
    let rawValue: UInt32
    static let readOnly = FileAttributes(rawValue: 0x1)
    static let archive = FileAttributes(rawValue: 0x20)
    static let normal = FileAttributes(rawValue: 0x80)
    static let offline = FileAttributes(rawValue: 0x1000)
    static let recallOnOpen = FileAttributes(rawValue: 0x40000)
    static let pinned = FileAttributes(rawValue: 0x80000)
    static let recallOnDataAccess = FileAttributes(rawValue: 0x400000)
}

enum SyncFolderFiles {
    static let `extension` = ".calcsheet"
    static let temporaryExtension = ".calcsheet-tmp"
    static let damagedExtension = ".calcsheet-damaged"
    static let format = 1
    static let maxAncestors = 32
    static let maxFiles = 1024
    static let maxDeviceLength = 64
    static let maxFileBytes = Int64(SheetStore.maxDocumentBytes + 64_000)
    /// One hour, in ticks.
    static let staleTemporaryAge = Ticks.perHour
    /// SF_DATALESS: a File Provider placeholder (iCloud Drive, OneDrive, Dropbox, Google Drive) whose bytes are not on this Mac.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// Cloud-provider placeholders (Files On-Demand and similar) whose bytes are not on this computer.
    /// Opening them would start a download, so the scan never reads them.
    static func isPlaceholder(_ attributes: FileAttributes) -> Bool { !attributes.intersection([.offline, .recallOnOpen, .recallOnDataAccess]).isEmpty }

    /// A Mac file's attributes in Windows terms: a dataless File Provider file recalls its data on access, and a file without write
    /// permission is read-only. Tests replace this to stand in for a provider, since only the kernel can make a file dataless.
    static var attributes: (_ path: String, _ info: NetFile.Info) -> FileAttributes = { _, info in
        var result: FileAttributes = []
        if info.flags & datalessFlag != 0 { result.insert(.recallOnDataAccess) }
        if info.mode & 0o222 == 0 { result.insert(.readOnly) }
        return result
    }

    static func canonicalPath(_ folder: String, _ id: UUID) -> String { (folder as NSString).appendingPathComponent(id.netN + `extension`) }

    static func contentHash(_ name: String, _ source: String, _ uuids: GeneratedUuidState?) -> String {
        var text = String(name.netLength) + ":" + name + String(source.netLength) + ":" + source
        if let uuids {
            text += "|" + String(uuids.statements.count)
            for statement in uuids.statements { text += ":" + statement.netN }
            text += "|" + String(uuids.bindings.count)
            for binding in uuids.bindings {
                text += ":" + binding.statement.netN + ":" + String(binding.site.netLength) + ":" + binding.site + binding.value.netN
            }
            // UUID-only state keeps its earlier hash; rolls extend it.
            if let rolls = uuids.dice, !rolls.isEmpty {
                text += "|dice" + String(rolls.count)
                for roll in rolls {
                    text += ":" + roll.statement.netN + ":" + String(roll.formula.netLength) + ":" + roll.formula + "=" + roll.faces.map(String.init).joined(separator: ",")
                }
            }
        }
        return sha256Hex(text)
    }

    /// NTFS lists a folder in upper-cased ordinal order; the scan follows it so both systems bound and order files the same way.
    static func ntfsOrder(_ a: String, _ b: String) -> Bool { String.ordinalCompare(a.netUpper, b.netUpper) < 0 }

    static func scan(_ folder: String, _ now: DateTimeOffset) -> SyncFolderSnapshot {
        var canonical = NetDictionary<UUID, SyncFolderEntry>()
        var duplicates: [SyncFolderEntry] = []
        var stale: [String] = []
        var skipped = 0
        guard NetFile.directoryExists(folder), let entries = try? NetFile.entries(folder) else {
            return SyncFolderSnapshot(folder: folder, available: false, canonical: canonical, duplicates: duplicates, staleTemporaries: stale, skipped: 0)
        }
        var seen = 0
        for name in entries.sorted(by: ntfsOrder) {
            let path = (folder as NSString).appendingPathComponent(name)
            let info = NetFile.info(path)
            if !info.exists || info.isDirectory { continue }
            if name.endsWithIgnoreCase(temporaryExtension) {
                if name.hasPrefix(".") && now.utcTicks - info.lastWriteTicks > staleTemporaryAge { stale.append(path) }
                continue
            }
            if !name.endsWithIgnoreCase(`extension`) { continue }
            seen += 1
            if seen > maxFiles { skipped += 1; continue }
            let stem = name.netSubstring(0, name.netLength - `extension`.netLength)
            let stemId = stem.netLength == 32 ? UUID.netParseN(stem) : nil
            guard var entry = read(path, stemId ?? .netEmpty) else { continue }
            if entry.state == .ready, let file = entry.file {
                if stemId == file.sheetId && stem.ordinalEquals(file.sheetId.netN) { canonical.set(file.sheetId, entry) }
                else { entry.sheetId = file.sheetId; duplicates.append(entry) }
            } else if let id = stemId, stem.ordinalEquals(id.netN) { canonical.set(id, entry) }
            else { skipped += 1 } // Unreadable files under foreign names are revisited by the next event.
        }
        return SyncFolderSnapshot(folder: folder, available: true, canonical: canonical, duplicates: duplicates, staleTemporaries: stale, skipped: skipped)
    }

    private enum ReadFailure: Error { case tooLarge, changed }

    /// Reads one file. Nil means it disappeared. A placeholder is classified from attributes alone.
    /// The read takes no lasting lock (Windows opens it with FileShare.Read | FileShare.Delete): a holder of an exclusive lock makes
    /// it Locked, but a concurrent writer can still replace the file.
    static func read(_ path: String, _ stemId: UUID) -> SyncFolderEntry? {
        let info = NetFile.info(path)
        if !info.exists || info.isDirectory { return nil }
        let ticks = info.lastWriteTicks, length = info.length
        func entry(_ state: SyncFileState, _ file: SyncSheetFile? = nil, _ length: Int64, _ ticks: Int64, _ problem: String?, id: UUID = stemId) -> SyncFolderEntry {
            SyncFolderEntry(sheetId: id, path: path, state: state, file: file, length: length, ticks: ticks, problem: problem)
        }
        if isPlaceholder(attributes(path, info)) { return entry(.placeholder, nil, length, ticks, "Not downloaded to this computer") }
        if length == 0 { return entry(.incomplete, nil, length, ticks, "Empty file") }
        if length > maxFileBytes { return entry(.incomplete, nil, length, ticks, "File too large") }
        let bytes: [UInt8]
        do { bytes = try NetFile.readAll(path, limit: maxFileBytes, tooLarge: ReadFailure.tooLarge, changed: ReadFailure.changed, holdLock: false) }
        catch ReadFailure.tooLarge { return entry(.incomplete, nil, NetFile.info(path).length, ticks, "File too large") }
        catch ReadFailure.changed { return entry(.locked, nil, length, ticks, "File changed while reading") }
        catch let e where e.isFileNotFound || e.isDirectoryNotFound { return nil }
        catch { return entry(.locked, nil, 0, 0, error.netMessage) }
        do {
            guard let reader = try NetJSON.parseObject(bytes) else { throw CalcError.invalidData("Empty sync file") }
            let file = try SyncSheetFile.decode(reader)
            try validate(file)
            return entry(.ready, file, length, ticks, nil, id: file.sheetId)
        } catch let e where e.isUnsupportedVersion { return entry(.unsupported, nil, length, ticks, e.netMessage) }
        catch { return entry(.incomplete, nil, length, ticks, error.netMessage) }
    }

    static func readCanonical(_ folder: String, _ id: UUID) -> SyncFolderEntry? { read(canonicalPath(folder, id), id) }

    static func validate(_ file: SyncSheetFile) throws {
        if file.format != format { throw DocumentError.unsupportedVersion }
        let device = Array(file.device.utf16)
        if file.sheetId.isNetEmpty || file.revision.isNetEmpty || file.nulls.contains("Fields") || file.ancestors.count > maxAncestors ||
            file.ancestors.contains(where: { $0.isNetEmpty || $0 == file.revision }) || device.count > maxDeviceLength || device.contains(where: NetChar.isControl) {
            throw CalcError.invalidData("Invalid sync file")
        }
        if file.deleted {
            if !file.name.isEmpty || !file.source.isEmpty || file.generatedUuids != nil { throw CalcError.invalidData("Invalid sync tombstone") }
        } else {
            try WorkspaceStore.validateSheetName(file.name)
            try SheetStore.validate(toSheet(file, false))
        }
        if file.hash != contentHash(file.name, file.source, file.generatedUuids) {
            throw CalcError.invalidData("Sync file content does not match its hash (incomplete download?)")
        }
    }

    static func toSheet(_ file: SyncSheetFile, _ dark: Bool) -> SheetDocument {
        SheetDocument(file.generatedUuids == nil ? 1 : 2, file.sheetId, file.source, dark, generatedUuids: file.generatedUuids)
    }

    /// Same-folder temporary file, flushed, then renamed over the canonical name. Readers see the old or the new file, never a partial one.
    static func writeAtomic(_ folder: String, _ file: SyncSheetFile) throws {
        try validate(file)
        let path = canonicalPath(folder, file.sheetId)
        let temporary = (folder as NSString).appendingPathComponent("." + file.sheetId.netN + "." + UUID.netNew().netN + temporaryExtension)
        defer { if NetFile.fileExists(temporary) { try? NetFile.delete(temporary) } }
        try NetFile.writeNew(temporary, NetJSON.bytes(file.json))
        try NetFile.move(temporary, path, overwrite: true)
    }
}
