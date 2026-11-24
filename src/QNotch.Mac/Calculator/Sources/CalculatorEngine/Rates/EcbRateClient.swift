import Foundation

/// C# CurrencyRateHttpException (an IOException): the provider answered with a non-success status.
/// `retryAfterTicks` is the provider's Retry-After advice in .NET ticks (100 ns), clamped to 0…1 day.
struct CurrencyRateHttpError: Error, Equatable, CustomStringConvertible {
    let status: Int
    let retryAfterTicks: Int64?
    var message: String { "Currency provider returned HTTP " + String(status) }
    var description: String { message }
}

/// A Retry-After header: a delay in seconds or an HTTP date.
enum CurrencyRetryAfter: Equatable { case delta(seconds: Int64), date(Instant) }

/// One response of the HTTP layer. `url` is the URL that produced it (after redirects; nil means the request URL).
struct CurrencyRateHTTPResponse {
    var status: Int
    var url: URL?
    var retryAfter: CurrencyRetryAfter?
    /// The declared Content-Length, if any.
    var contentLength: Int64?
    /// The body in chunks, read only after a success status.
    var body: AsyncThrowingStream<Data, Error>

    init(status: Int, url: URL? = nil, retryAfter: CurrencyRetryAfter? = nil, contentLength: Int64? = nil, body: AsyncThrowingStream<Data, Error>) {
        self.status = status; self.url = url; self.retryAfter = retryAfter; self.contentLength = contentLength; self.body = body
    }
    /// A response whose whole body is `data`, delivered in one chunk.
    init(status: Int, url: URL? = nil, retryAfter: CurrencyRetryAfter? = nil, contentLength: Int64? = nil, data: Data) {
        self.init(status: status, url: url, retryAfter: retryAfter, contentLength: contentLength,
                  body: AsyncThrowingStream { continuation in continuation.yield(data); continuation.finish() })
    }
}

/// The HTTP fetch behind the rate clients (C# HttpClient). The app uses `URLSessionRateTransport`; tests use fakes.
/// One GET with `Accept: application/json`; no body, cookies, credentials or redirects.
protocol CurrencyRateTransport {
    func get(_ url: URL, accept: String, token: CancellationToken) async throws -> CurrencyRateHTTPResponse
}

/// One explicit, bounded ECB request. No clock reads, credentials, retries, sheet text or amount input.
final class EcbRateClient {
    static let provider = "ECB via Frankfurter"
    static let source = "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html"
    static let terms = "https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html"
    static let maxResponseBytes = 262144
    static let firstDate = DateOnly(1999, 1, 4)!
    /// Seconds the whole request (headers and body) may take.
    static let timeoutSeconds: UInt64 = 15

    private let transport: CurrencyRateTransport
    init(_ transport: CurrencyRateTransport) { self.transport = transport }

    static func requestUri(_ date: DateOnly?) -> URL {
        URL(string: "https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR" + (date.map { "&date=" + $0.description } ?? ""))!
    }
    /// `now` is the host's clock reading; `utcOffsetSeconds` is its offset (C# passes a local DateTimeOffset),
    /// so "today" is the host's local date as in C#.
    func fetch(_ date: DateOnly?, now: Instant, utcOffsetSeconds: Int = 0, token: CancellationToken = .none) async throws -> CurrencyRateSnapshot {
        let today = EcbRateClient.localDate(now, utcOffsetSeconds)
        if let requested = date, requested < EcbRateClient.firstDate || requested > today { throw CalcError.invalidData("ECB historical date is outside available bounds") }
        let bytes = try await EcbRateClient.download(transport, EcbRateClient.requestUri(date), now, token)
        return try EcbRateClient.parse(bytes, date, now, utcOffsetSeconds: utcOffsetSeconds)
    }
    /// C# `DateOnly.FromDateTime(dateTimeOffset.DateTime)`: the date on the reading's own clock.
    static func localDate(_ instant: Instant, _ utcOffsetSeconds: Int) -> DateOnly {
        NetDateTime(ticks: instant.unixTicks + Ticks.unixEpoch + Int64(utcOffsetSeconds) * Ticks.perSecond).date
    }

    /// Shared bounded GET for the fixed Frankfurter provider routes; never follows redirects or sends a body.
    static func download(_ transport: CurrencyRateTransport, _ url: URL, _ now: Instant, _ token: CancellationToken) async throws -> Data {
        try token.throwIfCancellationRequested()
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await receive(transport, url, now, token) }
            group.addTask {
                // The C# linked 15-second timeout: it cancels the request like the caller's token would.
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let data = first else { throw CalcError.cancelled }
            return data
        }
    }
    private static func receive(_ transport: CurrencyRateTransport, _ url: URL, _ now: Instant, _ token: CancellationToken) async throws -> Data {
        let response = try await transport.get(url, accept: "application/json", token: token)
        try token.throwIfCancellationRequested()
        if !(200...299).contains(response.status) {
            var retry: Int64?
            switch response.retryAfter {
            case .delta(let seconds): retry = seconds.multipliedReportingOverflow(by: Ticks.perSecond).overflow ? Int64.max : seconds * Ticks.perSecond
            case .date(let when): retry = when.unixTicks - now.unixTicks
            case nil: retry = nil
            }
            if let duration = retry { retry = min(max(duration, 0), Ticks.perDay) }
            throw CurrencyRateHttpError(status: response.status, retryAfterTicks: retry)
        }
        if let final = response.url, final != url { throw CalcError.invalidData("Unexpected currency provider redirect") }
        if let length = response.contentLength, length > Int64(maxResponseBytes) { throw CalcError.invalidData("Currency response exceeds size limit") }
        var buffer = Data()
        for try await chunk in response.body {
            try token.throwIfCancellationRequested(); try Task.checkCancellation()
            if buffer.count + chunk.count > maxResponseBytes { throw CalcError.invalidData("Currency response exceeds size limit") }
            buffer.append(chunk)
        }
        return buffer
    }

    static func parse(_ bytes: Data, _ requested: DateOnly?, _ retrievedAt: Instant, utcOffsetSeconds: Int = 0) throws -> CurrencyRateSnapshot {
        try parse(bytes, requested, retrievedAt, utcOffsetSeconds, provider, firstDate, 10)
    }
    /// A failure C# lets reach its `catch (… when JsonException or FormatException or …)` filter: reported as "Invalid rate response".
    private struct ResponseFault: Error {}
    /// Parses EUR-based Frankfurter v2 rows of one provider and one publication date.
    static func parse(_ bytes: Data, _ requested: DateOnly?, _ retrievedAt: Instant, _ utcOffsetSeconds: Int, _ provider: String, _ firstDate: DateOnly, _ maximumAgeDays: Int) throws -> CurrencyRateSnapshot {
        if bytes.count > maxResponseBytes { throw CalcError.invalidData("Currency response exceeds size limit") }
        do {
            guard let root = try? JSONNode.parse(bytes, maxDepth: 8) else { throw ResponseFault() }
            guard case .array(let rows) = root else { throw CalcError.invalidData("Expected ECB rate rows") }
            // JsonElement.GetProperty / GetString: a missing property or a non-string value is a fault; JSON null reads as nil.
            func property(_ row: [(String, JSONNode)], _ name: String) throws -> JSONNode {
                guard let value = row.last(where: { $0.0 == name })?.1 else { throw ResponseFault() }
                return value
            }
            func string(_ node: JSONNode) throws -> String? {
                switch node { case .string(let text): return text; case .null: return nil; default: throw ResponseFault() }
            }
            var rates: [(String, Rational)] = []; var codes = Set<String>(); var date: DateOnly?
            for row in rows {
                guard rates.count < CurrencyRateSnapshot.maxCurrencies, case .object(let fields) = row, Set(fields.map { $0.0.units }).count == fields.count else {
                    throw CalcError.invalidData("Invalid ECB row set")
                }
                // DateOnly.ParseExact(…, "yyyy-MM-dd"): null is an ArgumentNullException, other text a FormatException.
                guard let dateText = try string(try property(fields, "date")), let actual = parseDate(dateText) else { throw ResponseFault() }
                let code = try string(try property(fields, "quote"))
                let base = try string(try property(fields, "base"))
                guard base == "EUR", let code, CurrencyCatalog.validCode(code), CurrencyCatalog.tryCode(code) != nil,
                      date == nil || date == actual, case .number(let raw) = try property(fields, "rate") else {
                    throw CalcError.invalidData("Invalid ECB currency identity/date/rate")
                }
                let rate = try decimal(raw)
                if !codes.insert(code).inserted { throw CalcError.invalidData("Invalid ECB currency identity/date/rate") }
                rates.append((code, rate))
                date = actual
            }
            let endpoint = requested ?? localDate(retrievedAt, utcOffsetSeconds)
            guard let date, date >= firstDate, date <= endpoint, endpoint.dayNumber - date.dayNumber <= maximumAgeDays else {
                throw CalcError.invalidData("Rate publication date is unavailable or inconsistent")
            }
            return try CurrencyRateSnapshot(provider: provider, baseCurrency: "EUR", asOf: date, retrievedAt: retrievedAt, rates: rates)
        } catch is ResponseFault {
            throw CalcError.invalidData("Invalid rate response")
        } catch let error as CalcError {
            switch error {
            case .format, .arithmetic, .argument, .invalidOperation: throw CalcError.invalidData("Invalid rate response")
            default: throw error
            }
        }
    }
    /// Strict yyyy-MM-dd.
    static func parseDate(_ text: String) -> DateOnly? {
        let u = text.units
        guard u.count == 10, u[4] == 0x2D, u[7] == 0x2D, u.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || NetChar.isAsciiDigit($0.element) }) else { return nil }
        return DateOnly(Int(text.netSubstring(0, 4))!, Int(text.netSubstring(5, 2))!, Int(text.netSubstring(8, 2))!)
    }
    /// The JSON number's raw text as an exact rational; at most 128 characters and |exponent| <= 40.
    private static func decimal(_ text: String) throws -> Rational {
        if text.netLength > 128 { throw CalcError.invalidData("Currency rate precision limit exceeded") }
        let parts = text.split(separator: "e", omittingEmptySubsequences: false).flatMap { $0.split(separator: "E", omittingEmptySubsequences: false) }.map(String.init)
        if parts.count > 2 { throw CalcError.invalidData("Invalid currency decimal") }
        let mantissa = try Rational.parse(parts[0])
        if parts.count == 1 { return mantissa }
        guard let exponent = Int32(parts[1]), Swift.abs(Int64(exponent)) <= 40 else { throw CalcError.invalidData("Currency exponent limit exceeded") }
        let scale = try Rational(BigInt.pow(10, Int(exponent.magnitude)))
        return exponent < 0 ? try mantissa / scale : try mantissa * scale
    }
}
