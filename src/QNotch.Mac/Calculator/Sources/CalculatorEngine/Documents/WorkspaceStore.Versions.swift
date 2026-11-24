import Foundation

/// One restorable copy of a sheet. Receipts travel with the source so restoring never re-runs or loses a define/forget.
struct SheetVersion: Equatable, JSONDocument {
    var version: Int
    var sheetId: UUID
    var capturedAt: DateTimeOffset
    var hash: String
    var sheet: SheetDocument
    var receipts: [FunctionReceipt]
    var nulls = JSONNulls()
    init(_ version: Int, _ sheetId: UUID, _ capturedAt: DateTimeOffset, _ hash: String, _ sheet: SheetDocument, _ receipts: [FunctionReceipt]) {
        self.version = version; self.sheetId = sheetId; self.capturedAt = capturedAt; self.hash = hash; self.sheet = sheet; self.receipts = receipts
    }
    static func decode(_ json: NetJSON.Reader) throws -> SheetVersion {
        let sheet = try json.object("Sheet", SheetDocument.decode)
        let receipts = try FunctionReceiptDocument.decodeReceipts(json, "Receipts")
        var value = SheetVersion(try json.int("Version"), try json.guid("SheetId"), try json.date("CapturedAt"), try json.string("Hash") ?? "",
                                 sheet ?? SheetDocument(0, .netEmpty, "", false), receipts.receipts)
        if sheet == nil { value.nulls.insert("Sheet") }
        if !receipts.valid { value.nulls.insert("Receipts") }
        return value
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("SheetId", NetJSON.guid(sheetId)), ("CapturedAt", NetJSON.date(capturedAt)), ("Hash", NetJSON.string(hash)),
                        ("Sheet", sheet.json), ("Receipts", NetJSON.array(receipts.map(\.json)))])
    }
}

struct VersionHistory {
    let versions: [SheetVersion]
    let skipped: Int
}

/// Versions live in versions/{sheet}/{ticks}-{hash}.json, one atomic file each, and are read only while history is open.
/// Capture time is supplied by the host. Load, Open and Save never touch this folder.
extension WorkspaceStore {
    static let maxVersions = 64
    static let maxVersionBytes: Int64 = 8 * 1024 * 1024
    /// Five minutes, in ticks.
    static let versionInterval: Int64 = 5 * Ticks.perMinute
    private static let maxVersionFileBytes = SheetStore.maxDocumentBytes + 100_000
    private static let versionStemLength = 19 + 1 + 64

    struct VersionFile {
        let path: String, ticks: Int64, hash: String, length: Int64
        var at: DateTimeOffset { DateTimeOffset(utcTicks: ticks) }
        var day: Int64 { ticks / Ticks.perDay }
    }
    private var versionsDirectory: String { (directory as NSString).appendingPathComponent("versions") }
    private func versionFolder(_ id: UUID) -> String { (versionsDirectory as NSString).appendingPathComponent(id.netN) }

    /// Stores the saved content unless it matches the newest version; unforced calls also wait for the interval.
    /// True means history reflects the saved content; false means the interval deferred it.
    @discardableResult
    func captureVersion(_ id: UUID, _ now: DateTimeOffset, force: Bool = false) throws -> Bool {
        try requireOpened(id)
        if !force, let known = newestVersions[id], now - known < WorkspaceStore.versionInterval { return false }
        var files = try versionFiles(id)
        let newest = files.first
        if let newest { newestVersions[id] = newest.at }
        if !force, let newest, now - newest.at < WorkspaceStore.versionInterval { return false }
        let sheet = try readSaved(id)
        let hash = WorkspaceStore.contentHash(sheet)
        if newest?.hash == hash || newest == nil && sheet.source.isEmpty { return true }
        // Ticks keep increasing when the clock moves back, so names always sort oldest to newest.
        let at = DateTimeOffset(utcTicks: max(now.utcTicks, (newest?.ticks ?? 0) + 1))
        let folder = versionFolder(id)
        try NetFile.createDirectory(folder)
        let path = (folder as NSString).appendingPathComponent(pad(at.utcTicks, 19) + "-" + hash + ".json")
        try AtomicJson.write(path, SheetVersion(1, id, at, hash, sheet, try readFunctionReceiptFile(id).document.receipts))
        newestVersions[id] = at
        files.insert(VersionFile(path: path, ticks: at.utcTicks, hash: hash, length: NetFile.info(path).length), at: 0)
        // Bounds are retried by the next capture; a held file never fails the capture that just succeeded.
        do { try WorkspaceStore.moveDuplicates(&files); try WorkspaceStore.thin(files) }
        catch let e where e.isIOException || e.isUnauthorized {}
        return true
    }

    func loadVersions(_ id: UUID) throws -> VersionHistory {
        try requireSheet(id)
        var versions: [SheetVersion] = []; var skipped = 0
        var hashes = Set<String>()
        for file in try versionFiles(id).filter({ hashes.insert($0.hash).inserted }).prefix(WorkspaceStore.maxVersions) {
            do { versions.append(try readVersion(id, file)) }
            catch let e where e.isIOException || e.isUnauthorized || e.isInvalidData || e.isJsonError { skipped += 1 }
        }
        return VersionHistory(versions: versions, skipped: skipped)
    }

    /// Captures the current content, then replaces source, UUID bindings and receipts together through the function journal.
    /// The function library is never changed, so a restored directive neither re-applies nor undoes a later define/forget.
    func restoreVersion(_ id: UUID, _ hash: String, _ now: DateTimeOffset) throws -> LoadResult {
        try requireOpened(id)
        guard let file = try versionFiles(id).first(where: { $0.hash == hash }) else { throw CalcError.invalidData("Version unavailable") }
        let version = try readVersion(id, file)
        let dark = try readSaved(id).dark
        let restored = version.sheet.with { $0.dark = dark }
        try captureVersion(id, now, force: true)
        let library = try loadFunctions()
        let update = FunctionUpdate(library, version.receipts, sha256Hex(restored.source), true)
        update.baseFingerprint = library.fingerprint
        do { try saveWithFunctions(restored, update) }
        catch let e where e.isIOException || e.isUnauthorized { abandonRestore(id, hash); throw e }
        return LoadResult(restored, false, version.receipts)
    }

    // Replay writes the body first, so an untouched body means nothing applied. A partial replay rolls forward instead.
    private func abandonRestore(_ id: UUID, _ hash: String) {
        do { if WorkspaceStore.contentHash(try readSaved(id)) != hash { try NetFile.delete(functionJournalPath) } }
        catch {}
    }

    private func requireOpened(_ id: UUID) throws {
        try requireSheet(id)
        if !loadedSheets.contains(id) { throw CalcError.invalidOperation("Open must succeed before using sheet history") }
    }

    func readSaved(_ id: UUID) throws -> SheetDocument {
        try AtomicJson.read(sheetPath(id), Int64(SheetStore.maxDocumentBytes)) { (sheet: SheetDocument) in
            try SheetStore.validate(sheet)
            if sheet.id != id { throw CalcError.invalidData("Sheet identity does not match catalog") }
        }
    }

    private func readVersion(_ id: UUID, _ file: VersionFile) throws -> SheetVersion {
        try AtomicJson.read(file.path, Int64(WorkspaceStore.maxVersionFileBytes)) { (version: SheetVersion) in
            if version.version != 1 { throw DocumentError.unsupportedVersion }
            if version.nulls.contains("Sheet") || version.sheetId != id || version.sheet.id != id || version.capturedAt.utcTicks != file.ticks {
                throw CalcError.invalidData("Invalid sheet version")
            }
            try SheetStore.validate(version.sheet)
            if version.hash != file.hash || WorkspaceStore.contentHash(version.sheet) != file.hash { throw CalcError.invalidData("Sheet version content does not match its hash") }
            if version.nulls.contains("Receipts") { throw CalcError.invalidData("Invalid function receipts") }
            try WorkspaceStore.validateReceipts(FunctionReceiptDocument(1, id, version.receipts), id)
        }
    }

    /// Newest first. Names carry time and hash, so a scan reads no version body. Names are taken in ordinal order before the bound
    /// is applied, the order NTFS lists them in, so both systems consider the same files.
    private func versionFiles(_ id: UUID) throws -> [VersionFile] {
        versionScans += 1
        let folder = versionFolder(id)
        if !NetFile.directoryExists(folder) { return [] }
        var files: [VersionFile] = []
        let names = try NetFile.entries(folder).filter { $0.endsWithIgnoreCase(".json") }.sorted { String.ordinalCompare($0, $1) < 0 }
        for name in names.prefix(WorkspaceStore.maxVersions * 4) {
            let path = (folder as NSString).appendingPathComponent(name)
            let info = NetFile.info(path)
            guard info.exists, !info.isDirectory else { continue }
            if let stem = WorkspaceStore.versionStem(name.netSubstring(0, name.netLength - 5)) { files.append(VersionFile(path: path, ticks: stem.ticks, hash: stem.hash, length: info.length)) }
        }
        return files.stableSorted { $0.ticks > $1.ticks }
    }

    private static func versionStem(_ stem: String) -> (ticks: Int64, hash: String)? {
        let units = Array(stem.utf16)
        guard units.count == versionStemLength, units[19] == 0x2D,
              units[20...].allSatisfy({ NetChar.isAsciiDigit($0) || ($0 >= 65 && $0 <= 70) }),
              units[..<19].allSatisfy(NetChar.isAsciiDigit), let ticks = Int64(String(units: units[..<19])), ticks <= DateTimeOffset.maxValue.utcTicks else { return nil }
        return (ticks, String(units: units[20...]))
    }

    // Identical content keeps only its newest timestamp, so a repeated state returns to the top instead of being stored twice.
    private static func moveDuplicates(_ newestFirst: inout [VersionFile]) throws {
        var i = newestFirst.count - 1
        while i > 0 {
            if newestFirst[i].hash == newestFirst[0].hash { try NetFile.delete(newestFirst[i].path); newestFirst.remove(at: i) }
            i -= 1
        }
    }

    // Over a bound, delete the oldest version with a newer version on the same UTC day, or the oldest of all once every day holds one.
    private static func thin(_ newestFirst: [VersionFile]) throws {
        var files = Array(newestFirst.reversed())
        var bytes = files.reduce(0) { $0 + $1.length }
        while files.count > 1 && (files.count > maxVersions || bytes > maxVersionBytes) {
            let victim = (0..<(files.count - 1)).first { files[$0].day == files[$0 + 1].day } ?? 0
            try NetFile.delete(files[victim].path); bytes -= files[victim].length; files.remove(at: victim)
        }
    }

    // Follows the same retained set as bodies, so a sheet the backup catalog still names keeps its history.
    func pruneVersions(_ retained: Set<UUID>) throws {
        if !NetFile.directoryExists(versionsDirectory) { return }
        for folder in try NetFile.directories(versionsDirectory) {
            guard let id = UUID.netParseN((folder as NSString).lastPathComponent), !retained.contains(id) else { continue }
            for file in try NetFile.files(folder) where WorkspaceStore.ownedVersionFile(file) { try NetFile.delete(file) }
            if try NetFile.entries(folder).isEmpty { try NetFile.deleteDirectory(folder) }
            newestVersions.removeValue(forKey: id)
        }
    }

    private static func ownedVersionFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.netLength > versionStemLength && versionStem(name.netSubstring(0, versionStemLength)) != nil &&
            (name.hasSuffix(".json") || name.hasSuffix(".tmp"))
    }

    // Dark is workspace presentation and never distinguishes content. The encoding stays explicit so hashes survive serializer changes.
    static func contentHash(_ sheet: SheetDocument) -> String {
        var text = sheet.source
        if let uuids = sheet.generatedUuids {
            for statement in uuids.statements { text += "\u{0}" + statement.netN }
            for binding in uuids.bindings { text += "\u{0}" + binding.statement.netN + "\u{0}" + binding.site + "\u{0}" + binding.value.netN }
            for roll in uuids.dice ?? [] { text += "\u{0}dice\u{0}" + roll.statement.netN + "\u{0}" + roll.formula + "\u{0}" + roll.faces.map(String.init).joined(separator: ",") }
        }
        return sha256Hex(text)
    }
}
