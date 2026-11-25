import Foundation

/// A document record read and written the way System.Text.Json's default `JsonSerializer` does for its C# record.
protocol JSONDocument {
    /// `JsonSerializer.Deserialize`: missing properties take default values; a null where C# later rejects null is recorded in `nulls`.
    static func decode(_ json: NetJSON.Reader) throws -> Self
    /// `JsonSerializer.Serialize`: the compact UTF-8 text, properties in C# declaration order.
    var json: String { get }
}

/// Where C# deserialized a JSON null into a reference its validator rejects. Swift records keep non-optional values (with a
/// default in place of the null) and the validator checks these marks at the point C# checks for null, so the exception type and
/// message match. Marks never take part in equality.
struct JSONNulls: Equatable, Hashable {
    private(set) var names: Set<String> = []
    init() {}
    mutating func insert(_ name: String) { names.insert(name) }
    func contains(_ name: String) -> Bool { names.contains(name) }
    var isEmpty: Bool { names.isEmpty }
    static func == (_: JSONNulls, _: JSONNulls) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// Same-directory atomic JSON documents with a last-good backup.
enum AtomicJson {
    static func read<T: JSONDocument>(_ path: String, _ maxBytes: Int64, _ validate: (T) throws -> Void) throws -> T {
        let bytes = try NetFile.readAll(path, limit: maxBytes, tooLarge: CalcError.invalidData("Document too large"),
                                        changed: CalcError.invalidData("Document changed while reading"))
        guard let reader = try NetJSON.parseObject(bytes) else { throw CalcError.invalidData("Empty document") }
        let value = try T.decode(reader)
        try validate(value)
        return value
    }

    /// Reads the document, or its backup when the document is damaged (IO, JSON or validation failure, but never a newer
    /// version). The damaged file is kept as `.corrupt-{guid}` and the backup is copied into place.
    static func load<T: JSONDocument>(_ path: String, _ maxBytes: Int64, _ validate: (T) throws -> Void) throws -> (value: T, recovered: Bool) {
        do { return (try read(path, maxBytes, validate), false) }
        catch let error where !error.isUnsupportedVersion && (error.isIOException || error.isJsonError || error.isInvalidData) {
            let backup: T = try read(path + ".bak", maxBytes, validate)
            if NetFile.fileExists(path) { try NetFile.move(path, path + ".corrupt-" + UUID.netNew().netN, overwrite: false) }
            try NetFile.copy(path + ".bak", path)
            return (backup, true)
        }
    }

    static func write<T: JSONDocument>(_ path: String, _ value: T) throws {
        let temporary = path + "." + UUID.netNew().netN + ".tmp"
        defer { if NetFile.fileExists(temporary) { try? NetFile.delete(temporary) } }
        try NetFile.writeNew(temporary, NetJSON.bytes(value.json))
        if NetFile.fileExists(path) { try NetFile.replace(temporary, path, backup: path + ".bak") }
        else { try NetFile.move(temporary, path, overwrite: false) }
    }
}
