import Foundation

extension FunctionDefinition {
    /// C# `FunctionDefinition(string Name, IReadOnlyList<string> Parameters, string Body)`. A null part makes the decoded definition
    /// invalid; `valid` is false and the catalog validator rejects it as C#'s FunctionLibrary does.
    static func decode(_ json: NetJSON.Reader) throws -> (definition: FunctionDefinition, valid: Bool) {
        let name = try json.string("Name"), body = try json.string("Body")
        let parameters = try json.array("Parameters") { try NetJSON.Reader.string($0, "Parameters") }
        let valid = name != nil && body != nil && parameters != nil && !parameters!.contains(where: { $0 == nil })
        return (FunctionDefinition(name: name ?? "", parameters: parameters?.map { $0 ?? "" } ?? [], body: body ?? ""), valid)
    }
    var json: String {
        NetJSON.object([("Name", NetJSON.string(name)), ("Parameters", NetJSON.array(parameters.map(NetJSON.string))), ("Body", NetJSON.string(body))])
    }
}

extension FunctionReceipt {
    static func decode(_ json: NetJSON.Reader) throws -> (receipt: FunctionReceipt, valid: Bool) {
        let key = try json.string("Key")
        return (FunctionReceipt(key: key ?? "", count: try json.int("Count")), key != nil)
    }
    var json: String { NetJSON.object([("Key", NetJSON.string(key)), ("Count", NetJSON.int(count))]) }
}

struct FunctionCatalog: Equatable, JSONDocument {
    var version: Int
    var definitions: [FunctionDefinition]
    var nulls = JSONNulls()
    init(_ version: Int, _ definitions: [FunctionDefinition]) { self.version = version; self.definitions = definitions }
    static func decode(_ json: NetJSON.Reader) throws -> FunctionCatalog {
        let items = try json.array("Definitions") { try NetJSON.Reader.element($0, FunctionDefinition.decode) }
        var catalog = FunctionCatalog(try json.int("Version"), items?.compactMap { $0?.definition } ?? [])
        if items == nil { catalog.nulls.insert("Definitions") }
        else if items!.contains(where: { $0 == nil || !$0!.valid }) { catalog.nulls.insert("Definition") }
        return catalog
    }
    var json: String { NetJSON.object([("Version", NetJSON.int(version)), ("Definitions", NetJSON.array(definitions.map(\.json)))]) }
}

struct FunctionReceiptDocument: Equatable, JSONDocument {
    var version: Int
    var sheetId: UUID
    var receipts: [FunctionReceipt]
    var nulls = JSONNulls()
    init(_ version: Int, _ sheetId: UUID, _ receipts: [FunctionReceipt]) { self.version = version; self.sheetId = sheetId; self.receipts = receipts }
    static func decodeReceipts(_ json: NetJSON.Reader, _ name: String) throws -> (receipts: [FunctionReceipt], valid: Bool) {
        let items = try json.array(name) { try NetJSON.Reader.element($0, FunctionReceipt.decode) }
        return (items?.compactMap { $0?.receipt } ?? [], items != nil && !items!.contains(where: { $0 == nil || !$0!.valid }))
    }
    static func decode(_ json: NetJSON.Reader) throws -> FunctionReceiptDocument {
        let receipts = try decodeReceipts(json, "Receipts")
        var document = FunctionReceiptDocument(try json.int("Version"), try json.guid("SheetId"), receipts.receipts)
        if !receipts.valid { document.nulls.insert("Receipts") }
        return document
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("SheetId", NetJSON.guid(sheetId)), ("Receipts", NetJSON.array(receipts.map(\.json)))])
    }
}

struct FunctionSaveTransaction: Equatable, JSONDocument {
    var version: Int
    var sheet: SheetDocument
    var functions: FunctionCatalog
    var receipts: FunctionReceiptDocument
    var nulls = JSONNulls()
    init(_ version: Int, _ sheet: SheetDocument, _ functions: FunctionCatalog, _ receipts: FunctionReceiptDocument) {
        self.version = version; self.sheet = sheet; self.functions = functions; self.receipts = receipts
    }
    static func decode(_ json: NetJSON.Reader) throws -> FunctionSaveTransaction {
        let sheet = try json.object("Sheet", SheetDocument.decode), functions = try json.object("Functions", FunctionCatalog.decode)
        let receipts = try json.object("Receipts", FunctionReceiptDocument.decode)
        var transaction = FunctionSaveTransaction(try json.int("Version"), sheet ?? SheetDocument(0, .netEmpty, "", false),
                                                  functions ?? FunctionCatalog(0, []), receipts ?? FunctionReceiptDocument(0, .netEmpty, []))
        if sheet == nil || functions == nil || receipts == nil { transaction.nulls.insert("Parts") }
        return transaction
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("Sheet", sheet.json), ("Functions", functions.json), ("Receipts", receipts.json)])
    }
}

extension WorkspaceStore {
    var functionsPath: String { (directory as NSString).appendingPathComponent("functions.json") }
    var functionJournalPath: String { (directory as NSString).appendingPathComponent("function-save.json") }
    func receiptPath(_ id: UUID) -> String { (sheetsDirectory as NSString).appendingPathComponent(id.netN + ".receipts") }

    func loadFunctions() throws -> FunctionLibrary {
        _ = try requireWorkspace()
        if let cached = functionLibraryCache { return cached }
        if !NetFile.fileExists(functionsPath) && !NetFile.fileExists(functionsPath + ".bak") { functionLibraryCache = .empty; return .empty }
        let loaded = try AtomicJson.load(functionsPath, 500_000, WorkspaceStore.validateFunctions)
        let library = try FunctionLibrary(loaded.value.definitions)
        functionCatalogVersion = loaded.value.version
        // Upgrade a development/legacy catalog before a later older reader can treat new syntax as corruption.
        if functionCatalogVersion < library.minimumCatalogVersion {
            var upgraded = loaded.value; upgraded.version = library.minimumCatalogVersion
            try AtomicJson.write(functionsPath, upgraded); functionCatalogVersion = library.minimumCatalogVersion
        }
        functionsRecovered = loaded.recovered
        functionLibraryCache = library
        return library
    }

    func loadFunctionReceipts(_ id: UUID) throws -> [FunctionReceipt] {
        try requireSheet(id)
        return try readFunctionReceiptFile(id).document.receipts
    }

    func readFunctionReceiptFile(_ id: UUID) throws -> (document: FunctionReceiptDocument, recovered: Bool) {
        let path = receiptPath(id)
        if !NetFile.fileExists(path) && !NetFile.fileExists(path + ".bak") { return (FunctionReceiptDocument(1, id, []), false) }
        let loaded = try AtomicJson.load(path, 64_000) { (value: FunctionReceiptDocument) in try WorkspaceStore.validateReceipts(value, id) }
        return (loaded.value, loaded.recovered)
    }

    func saveWithFunctions(_ sheet: SheetDocument, _ update: FunctionUpdate) throws {
        try requireSheet(sheet.id)
        if !loadedSheets.contains(sheet.id) { throw CalcError.invalidOperation("Open must succeed before saving a sheet") }
        var stale = update.sourceHash != sha256Hex(sheet.source)
        if !stale { stale = update.baseFingerprint != (try loadFunctions()).fingerprint }
        if stale { throw CalcError.invalidData("Stale function update; recalculate before saving") }
        let transaction = FunctionSaveTransaction(1, sheet, FunctionCatalog(max(update.library.minimumCatalogVersion, functionCatalogVersion), update.library.definitions),
                                                  FunctionReceiptDocument(1, sheet.id, update.receipts))
        try WorkspaceStore.validateTransaction(transaction, try requireWorkspace())
        // A durable journal commits intent for all three files. Replay completes interrupted saves
        // before any subsequent workspace operation. Evaluation itself never writes this journal.
        try AtomicJson.write(functionJournalPath, transaction)
        try recoverFunctionSave(workspace!)
    }

    func recoverFunctionSave(_ current: WorkspaceDocument) throws {
        if !NetFile.fileExists(functionJournalPath) { return }
        let transaction = try AtomicJson.read(functionJournalPath, 4_000_000) { (t: FunctionSaveTransaction) in try WorkspaceStore.validateTransaction(t, current) }
        try AtomicJson.write(sheetPath(transaction.sheet.id), transaction.sheet)
        try AtomicJson.write(functionsPath, transaction.functions)
        try AtomicJson.write(receiptPath(transaction.sheet.id), transaction.receipts)
        try NetFile.delete(functionJournalPath)
        functionLibraryCache = try FunctionLibrary(transaction.functions.definitions); functionCatalogVersion = transaction.functions.version
    }

    static func validateFunctions(_ catalog: FunctionCatalog) throws {
        if catalog.version < 1 || catalog.version > FunctionLibrary.latestCatalogVersion { throw DocumentError.unsupportedVersion }
        if catalog.nulls.contains("Definitions") { throw CalcError.invalidData("Missing function definitions") }
        if catalog.nulls.contains("Definition") { throw CalcError.invalidData("Invalid or reserved function name") }
        do { _ = try FunctionLibrary(catalog.definitions) }
        catch let e as CalcError where e.isFormatOrArithmetic { throw CalcError.invalidData(e.message) }
    }

    static func validateReceipts(_ receipts: FunctionReceiptDocument, _ id: UUID) throws {
        if receipts.version != 1 { throw DocumentError.unsupportedVersion }
        if receipts.sheetId != id { throw CalcError.invalidData("Function receipt sheet identity mismatch") }
        if receipts.nulls.contains("Receipts") { throw CalcError.invalidData("Invalid function receipts") }
        do { try FunctionUpdate.validateReceipts(receipts.receipts) }
        catch let e as CalcError where e.isFormat { throw CalcError.invalidData(e.message) }
    }

    static func validateTransaction(_ transaction: FunctionSaveTransaction, _ current: WorkspaceDocument) throws {
        if transaction.version != 1 { throw DocumentError.unsupportedVersion }
        if transaction.nulls.contains("Parts") || !current.sheets.contains(where: { $0.id == transaction.sheet.id }) {
            throw CalcError.invalidData("Invalid function transaction identity")
        }
        try SheetStore.validate(transaction.sheet); try validateFunctions(transaction.functions); try validateReceipts(transaction.receipts, transaction.sheet.id)
    }
}
