import Foundation

/// One sheet's persisted text and identity. Version 2 adds generated values (UUID bindings and dice rolls).
struct SheetDocument: Equatable, JSONDocument {
    var version: Int
    var id: UUID
    var source: String
    var dark: Bool
    /// Omitted from JSON when null (JsonIgnoreCondition.WhenWritingNull).
    var generatedUuids: GeneratedUuidState?
    var nulls = JSONNulls()

    init(_ version: Int, _ id: UUID, _ source: String, _ dark: Bool, generatedUuids: GeneratedUuidState? = nil) {
        self.version = version; self.id = id; self.source = source; self.dark = dark; self.generatedUuids = generatedUuids
    }
    /// C# `document with { … }`.
    func with(_ change: (inout SheetDocument) -> Void) -> SheetDocument { var copy = self; change(&copy); return copy }

    static func decode(_ json: NetJSON.Reader) throws -> SheetDocument {
        let source = try json.string("Source")
        var document = SheetDocument(try json.int("Version"), try json.guid("Id"), source ?? "", try json.bool("Dark"),
                                     generatedUuids: try json.object("GeneratedUuids", GeneratedUuidState.decode))
        if source == nil { document.nulls.insert("Source") }
        return document
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("Id", NetJSON.guid(id)), ("Source", NetJSON.string(source)), ("Dark", NetJSON.bool(dark)),
                        ("GeneratedUuids", generatedUuids?.json)])
    }
}

struct LoadResult {
    let document: SheetDocument
    let recovered: Bool
    let functionReceipts: [FunctionReceipt]?
    init(_ document: SheetDocument, _ recovered: Bool, _ functionReceipts: [FunctionReceipt]? = nil) {
        self.document = document; self.recovered = recovered; self.functionReceipts = functionReceipts
    }
}

/// One-sheet P0 store. Same-directory atomic replacement with last-good backup.
/// Exclusive session ownership prevents concurrent writers from overwriting one another: `session.lock` is held with an exclusive
/// `flock` for the store's lifetime (Windows holds it with FileShare.None), so a second store on the same folder, in this process
/// or another, fails with an IOException.
final class SheetStore {
    static let maxCharacters = 200_000
    static let maxDocumentBytes = 4_000_000
    private let path: String
    private var sessionLock: NetFile.Hold?
    private var canSave = false

    init(_ directory: String) throws {
        try NetFile.createDirectory(directory)
        path = (directory as NSString).appendingPathComponent("sheet.json")
        sessionLock = try NetFile.Hold((directory as NSString).appendingPathComponent("session.lock"), exclusive: true, create: true)
    }

    func load() throws -> LoadResult {
        canSave = false
        if !NetFile.fileExists(path) && !NetFile.fileExists(path + ".bak") {
            canSave = true
            return LoadResult(SheetDocument(1, UUID.netNew(), "price = 120\ndiscount = 15%\nprice * discount\nprice * (1 - discount)", false), false)
        }
        let loaded = try AtomicJson.load(path, Int64(SheetStore.maxDocumentBytes), SheetStore.validate)
        canSave = true
        return LoadResult(loaded.value, loaded.recovered)
    }

    static func validate(_ doc: SheetDocument) throws {
        if doc.version != 1 && doc.version != 2 { throw DocumentError.unsupportedVersion }
        if doc.id.isNetEmpty || doc.nulls.contains("Source") || doc.source.netLength > maxCharacters {
            throw CalcError.invalidData("Unsupported or invalid document; original preserved")
        }
        if doc.version == 1 && doc.generatedUuids != nil || doc.version == 2 && doc.generatedUuids == nil {
            throw CalcError.invalidData("Invalid generated-value document version; original preserved")
        }
        if let state = doc.generatedUuids { try GeneratedUuidSession.validate(doc.source, state) }
    }

    func save(_ doc: SheetDocument) throws {
        if !canSave { throw CalcError.invalidOperation("Load must succeed before saving") }
        try SheetStore.validate(doc)
        try AtomicJson.write(path, doc)
    }

    /// `Dispose`: releases the session lock.
    func dispose() { sessionLock?.close(); sessionLock = nil }
    deinit { dispose() }
}
