import Foundation

struct CurrencyCacheLoad { let book: CurrencyRateBook, recovered: Bool, warning: String? }

/// C# NotSupportedException from the rate cache: a cache written by a future version, which is never overwritten.
struct CurrencyRateCacheVersionError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Bounded disposable-rate cache; never opens or writes sheet documents.
///
/// The file is shared with the Windows app (same data folder), so `currency-rates.json` is read with
/// System.Text.Json's deserialization rules and written byte for byte as C#'s `JsonSerializer` writes it:
/// `{"Version":1,"Snapshots":[{"Requested":…,"Provider":…,"Base":"EUR","AsOf":…,"RetrievedAt":…,"Rates":[{"Code":…,"Value":…}]}]}`.
/// Writers serialize through an exclusive lock on `currency-rates.json.lock` (C# FileShare.None, an flock on Unix),
/// stage `currency-rates.json.tmp`, and replace the primary keeping the previous file as `currency-rates.json.bak`.
final class CurrencyRateCache {
    static let maxBytes = 4_000_000
    private let directory: String
    init(_ directory: String) { self.directory = directory }
    private var filePath: String { (directory as NSString).appendingPathComponent("currency-rates.json") }

    /// A System.Text.Json JsonException: malformed JSON or a value of the wrong JSON type.
    private struct JSONFault: Error {}

    func load(_ token: CancellationToken = .none) throws -> CurrencyCacheLoad {
        if !CurrencyRateCache.isFile(filePath) && !CurrencyRateCache.isFile(filePath + ".bak") { return CurrencyCacheLoad(book: .empty, recovered: false, warning: nil) }
        do { return CurrencyCacheLoad(book: try CurrencyRateCache.readBook(filePath, token), recovered: false, warning: nil) }
        catch let error where CurrencyRateCache.recoverable(error) {
            if error is CurrencyRateCacheVersionError { return CurrencyCacheLoad(book: .empty, recovered: false, warning: "Unsupported rate-cache version; original preserved") }
            do { return CurrencyCacheLoad(book: try CurrencyRateCache.readBook(filePath + ".bak", token), recovered: true, warning: "Rate cache recovered from backup") }
            catch let backup where CurrencyRateCache.recoverable(backup) { return CurrencyCacheLoad(book: .empty, recovered: false, warning: "Cached currency rates unavailable") }
        }
    }
    /// C#'s filter: IOException, JsonException, ArithmeticException, NotSupportedException, FormatException,
    /// ArgumentException or InvalidOperationException. InvalidDataException (a SystemException) and cancellation escape.
    private static func recoverable(_ error: Error) -> Bool {
        if error is JSONFault || error is CurrencyRateCacheVersionError { return true }
        guard let error = error as? CalcError else { return false }
        switch error {
        case .io, .arithmetic, .notPorted, .format, .argument, .computationLimit, .invalidOperation: return true
        case .invalidData, .cancelled: return false
        }
    }
    private static func readBook(_ path: String, _ token: CancellationToken) throws -> CurrencyRateBook {
        try token.throwIfCancellationRequested()
        let bytes = try readBounded(path)
        let document = try deserialize(bytes)
        guard let document else { throw CalcError.invalidData("Empty rate cache") }
        if document.version != 1 { throw CurrencyRateCacheVersionError(message: "Specified method is not supported.") }
        guard let snapshots = document.snapshots, snapshots.count <= CurrencyRateBook.maxHistoricalSnapshots + 1 else { throw CalcError.invalidData("Too many cached rate dates") }
        var latest: CurrencyRateSnapshot?; var historical: [(DateOnly, CurrencyRateSnapshot)] = []; var dates = Set<DateOnly>()
        for item in snapshots {
            try token.throwIfCancellationRequested()
            guard let item, auditedProvider(item.provider), item.base == "EUR", let itemRates = item.rates, itemRates.count <= CurrencyRateSnapshot.maxCurrencies else {
                throw CalcError.invalidData("Invalid cached rate identity")
            }
            let rates = try itemRates.map { rate -> (String, Rational) in
                guard let rate else { throw CalcError.invalidData("Null cached rate") }
                // A null code fails the snapshot's currency-code validation, as KeyValuePair(null, …) does in C#.
                return (rate.code ?? "", try parse(rate.value))
            }
            let snapshot = try CurrencyRateSnapshot(provider: item.provider!, baseCurrency: item.base!, asOf: item.asOf, retrievedAt: item.retrievedAt, rates: rates)
            if let date = item.requested {
                if !dates.insert(date).inserted { throw CalcError.invalidData("Duplicate cached date") }
                historical.append((date, snapshot))
            } else if latest == nil { latest = snapshot }
            else { throw CalcError.invalidData("Duplicate latest currency snapshot") }
        }
        return try CurrencyRateBook(latest, historical)
    }
    private static func auditedProvider(_ provider: String?) -> Bool { provider == EcbRateClient.provider || provider == InforEuroRateClient.provider }
    private static func parse(_ value: String?) throws -> Rational {
        guard let value, value.netLength <= 256 else { throw CalcError.invalidData("Invalid cached rate precision") }
        let parts = value.netSplit("/")
        if parts.count == 1 { return try Rational.parse(value) }
        if parts.count == 2 { return try Rational.parse(parts[0]) / Rational.parse(parts[1]) }
        throw CalcError.invalidData("Invalid cached rate")
    }

    func save(_ book: CurrencyRateBook, _ token: CancellationToken = .none) throws {
        try token.throwIfCancellationRequested()
        do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        catch { throw CalcError.io("Could not create directory '" + directory + "'.") }
        let ownership = try CurrencyRateCache.exclusiveLock(filePath + ".lock")
        defer { close(ownership) }
        if CurrencyRateCache.isFile(filePath) {
            let current = try CurrencyRateCache.readAll(filePath)
            if current.count <= CurrencyRateCache.maxBytes, let root = try? JSONNode.parse(current, maxDepth: 10), // A successful new download may replace a corrupt disposable cache.
               case .object(let properties) = root, let version = properties.first(where: { $0.0 == "Version" })?.1 {
                if case .number(let text) = version, Int32(text) == 1 {} else { throw CurrencyRateCacheVersionError(message: "Future rate-cache version preserved") }
            }
        }
        var snapshots: [(DateOnly?, CurrencyRateSnapshot)] = []
        if let latest = book.latest { snapshots.append((nil, latest)) }
        snapshots += book.historical.keys.sorted().map { ($0, book.historical[$0]!) }
        if snapshots.contains(where: { !CurrencyRateCache.auditedProvider($0.1.provider) || $0.1.baseCurrency != "EUR" }) {
            throw CalcError.invalidData("Only the audited ECB/InforEuro cache format is supported")
        }
        let bytes = Data(CurrencyRateCache.serialize(snapshots).utf8)
        if bytes.count > CurrencyRateCache.maxBytes { throw CalcError.invalidData("Rate cache exceeds size limit") }
        let temporary = filePath + ".tmp"
        if CurrencyRateCache.isFile(temporary) { try CurrencyRateCache.unlinkFile(temporary) } // Only the owned fixed staging file, under an exclusive cache-writer lock.
        defer { if CurrencyRateCache.isFile(temporary) { unlink(temporary) } }
        try CurrencyRateCache.writeNew(temporary, bytes)
        try token.throwIfCancellationRequested()
        if CurrencyRateCache.isFile(filePath) { try CurrencyRateCache.replace(temporary, filePath, filePath + ".bak") }
        else { try CurrencyRateCache.move(temporary, filePath) }
    }

    // MARK: System.Text.Json document (CacheDocument / Snapshot / Rate records)

    private struct Rate { var code: String?, value: String? }
    private struct Snapshot {
        var requested: DateOnly?, provider: String?, base: String?
        var asOf = DateOnly.minValue
        var retrievedAt = Instant.minSupported
        var rates: [Rate?]?
    }
    private struct CacheDocument { var version = 0; var snapshots: [Snapshot?]? }

    private static func serialize(_ snapshots: [(DateOnly?, CurrencyRateSnapshot)]) -> String {
        var text = "{\"Version\":1,\"Snapshots\":["
        for (index, (requested, snapshot)) in snapshots.enumerated() {
            if index > 0 { text += "," }
            text += "{\"Requested\":" + (requested.map { "\"" + $0.description + "\"" } ?? "null") + ",\"Provider\":" + NetJSONText.quote(snapshot.provider) +
                ",\"Base\":" + NetJSONText.quote(snapshot.baseCurrency) + ",\"AsOf\":\"" + snapshot.asOf.description + "\",\"RetrievedAt\":\"" + isoText(snapshot.retrievedAt) + "\",\"Rates\":["
            text += snapshot.rates.keys.sorted { String.ordinalCompare($0, $1) < 0 }.map { "{\"Code\":" + NetJSONText.quote($0) + ",\"Value\":" + NetJSONText.quote(snapshot.rates[$0]!.description) + "}" }.joined(separator: ",")
            text += "]}"
        }
        return text + "]}"
    }
    /// System.Text.Json's DateTimeOffset text for a UTC value: seconds always, trailing fraction zeros trimmed, "+00:00".
    static func isoText(_ instant: Instant) -> String {
        let local = NetDateTime(ticks: instant.unixTicks + Ticks.unixEpoch)
        var fraction = pad(local.timeOfDay.fraction, 7)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return local.date.description + "T" + local.timeOfDay.hhmmss + (fraction.isEmpty ? "" : "." + fraction) + "+00:00"
    }
    /// JsonSerializer.Deserialize<CacheDocument>: case-sensitive names, unknown properties ignored, a repeated property's
    /// last value wins, absent values take their defaults; JSON null or a wrong value type is a JsonException.
    private static func deserialize(_ bytes: Data) throws -> CacheDocument? {
        guard let root = try? JSONNode.parse(bytes, maxDepth: 10) else { throw JSONFault() }
        if case .null = root { return nil }
        var document = CacheDocument()
        for (name, value) in try object(root) {
            switch name {
            case "Version":
                guard case .number(let text) = value, let version = Int32(text) else { throw JSONFault() }
                document.version = Int(version)
            case "Snapshots": document.snapshots = try array(value) { try $0.isNull ? nil : snapshot($0) }
            default: break
            }
        }
        return document
    }
    private static func snapshot(_ node: JSONNode) throws -> Snapshot {
        var snapshot = Snapshot()
        for (name, value) in try object(node) {
            switch name {
            case "Requested": snapshot.requested = value.isNull ? nil : try date(value)
            case "Provider": snapshot.provider = try string(value)
            case "Base": snapshot.base = try string(value)
            case "AsOf": snapshot.asOf = try date(value)
            case "RetrievedAt":
                guard case .string(let text) = value, let instant = parseInstant(text) else { throw JSONFault() }
                snapshot.retrievedAt = instant
            case "Rates":
                snapshot.rates = try array(value) { item in
                    if item.isNull { return nil }
                    var rate = Rate()
                    for (field, text) in try object(item) {
                        if field == "Code" { rate.code = try string(text) } else if field == "Value" { rate.value = try string(text) }
                    }
                    return rate
                }
            default: break
            }
        }
        return snapshot
    }
    private static func object(_ node: JSONNode) throws -> [(String, JSONNode)] { guard case .object(let properties) = node else { throw JSONFault() }; return properties }
    private static func array<T>(_ node: JSONNode, _ item: (JSONNode) throws -> T) throws -> [T]? {
        switch node { case .null: return nil; case .array(let items): return try items.map(item); default: throw JSONFault() }
    }
    private static func string(_ node: JSONNode) throws -> String? {
        switch node { case .null: return nil; case .string(let text): return text; default: throw JSONFault() }
    }
    private static func date(_ node: JSONNode) throws -> DateOnly {
        guard case .string(let text) = node, let date = EcbRateClient.parseDate(text) else { throw JSONFault() }
        return date
    }
    /// ISO 8601 `yyyy-MM-ddTHH:mm[:ss[.fraction]]` with `Z` or `±HH:mm`. (System.Text.Json also reads a missing
    /// offset as host-local time; QNotch never writes one, so it is rejected here like other malformed values.)
    static func parseInstant(_ text: String) -> Instant? {
        let u = text.units
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= u.count, u[start..<(start + count)].allSatisfy(NetChar.isAsciiDigit) else { return nil }
            return Int(text.netSubstring(start, count))
        }
        guard u.count >= 16, let date = EcbRateClient.parseDate(text.netSubstring(0, 10)), u[10] == 0x54,
              let hour = digits(11, 2), u[13] == 0x3A, let minute = digits(14, 2), hour < 24, minute < 60 else { return nil }
        var index = 16, second = 0, fraction: Int64 = 0
        if index < u.count && u[index] == 0x3A {
            guard let value = digits(index + 1, 2), value < 60 else { return nil }
            second = value; index += 3
            if index < u.count && u[index] == 0x2E {
                index += 1; let start = index
                while index < u.count && NetChar.isAsciiDigit(u[index]) { index += 1 }
                if index == start || index - start > 16 { return nil }
                let digits = text.netSubstring(start, min(7, index - start)).padding(toLength: 7, withPad: "0", startingAt: 0)
                fraction = Int64(digits)!
            }
        }
        var offset = 0
        if index < u.count && u[index] == 0x5A { index += 1 }
        else if index < u.count && (u[index] == 0x2B || u[index] == 0x2D) {
            guard let hours = digits(index + 1, 2), index + 3 < u.count, u[index + 3] == 0x3A, let minutes = digits(index + 4, 2), hours <= 14, minutes < 60 else { return nil }
            offset = (hours * 60 + minutes) * (u[index] == 0x2D ? -1 : 1); index += 6
        } else { return nil }
        if index != u.count { return nil }
        let local = Int64(date.dayNumber) * Ticks.perDay + Int64(hour) * Ticks.perHour + Int64(minute) * Ticks.perMinute + Int64(second) * Ticks.perSecond + fraction
        let utc = local - Int64(offset) * Ticks.perMinute
        if utc < 0 || utc > Ticks.maxDateTime { return nil }
        return Instant(unixTicks: utc - Ticks.unixEpoch)
    }

    // MARK: Files (.NET File/FileStream semantics on Unix)

    /// File.Exists: true for an existing regular file (not a directory).
    private static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }
    private static func posixError(_ path: String) -> CalcError {
        let code = errno
        switch code {
        case ENOENT: return .io("Could not find file '" + path + "'.")
        case EWOULDBLOCK: return .io("The process cannot access the file '" + path + "' because it is being used by another process.")
        case EACCES, EPERM: return .io("Access to the path '" + path + "' is denied.")
        default: return .io(String(cString: strerror(code)) + " : '" + path + "'")
        }
    }
    /// The size-bounded read of C#'s Read: refuses oversized files and files that grow while being read.
    private static func readBounded(_ path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        if descriptor < 0 { throw posixError(path) }
        defer { close(descriptor) }
        var status = stat()
        if fstat(descriptor, &status) != 0 { throw posixError(path) }
        if status.st_size > maxBytes { throw CalcError.invalidData("Rate cache exceeds size limit") }
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size)); var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if count < 0 { throw posixError(path) }
            if count == 0 { throw CalcError.io("Unable to read beyond the end of the stream.") }
            offset += count
        }
        var extra: UInt8 = 0
        if read(descriptor, &extra, 1) > 0 { throw CalcError.invalidData("Rate cache changed while reading") }
        return Data(bytes)
    }
    private static func readAll(_ path: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path) else { throw posixError(path) }
        return data
    }
    /// FileMode.OpenOrCreate with FileShare.None: .NET on Unix takes a non-blocking exclusive flock.
    private static func exclusiveLock(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if descriptor < 0 { throw posixError(path) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { let error = posixError(path); close(descriptor); throw error }
        return descriptor
    }
    /// FileMode.CreateNew, then Flush(true): written and fsynced before it can replace anything.
    private static func writeNew(_ path: String, _ data: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if descriptor < 0 { throw posixError(path) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { throw posixError(path) }
                offset += count
            }
        }
        if fsync(descriptor) != 0 { throw posixError(path) }
    }
    private static func unlinkFile(_ path: String) throws { if unlink(path) != 0 && errno != ENOENT { throw posixError(path) } }
    /// File.Replace on Unix: drop the old backup, hard-link (or copy) the destination as the new backup, then
    /// atomically rename the source over the destination.
    private static func replace(_ source: String, _ destination: String, _ backup: String) throws {
        try unlinkFile(backup)
        if link(destination, backup) != 0 {
            do { try FileManager.default.copyItem(atPath: destination, toPath: backup) } catch { throw CalcError.io("Could not copy '" + destination + "' to '" + backup + "'.") }
        }
        if rename(source, destination) != 0 { throw posixError(destination) }
    }
    /// File.Move without overwrite.
    private static func move(_ source: String, _ destination: String) throws {
        if FileManager.default.fileExists(atPath: destination) { throw CalcError.io("The file '" + destination + "' already exists.") }
        if rename(source, destination) != 0 { throw posixError(destination) }
    }
}
