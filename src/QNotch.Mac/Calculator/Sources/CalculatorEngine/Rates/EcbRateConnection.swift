import Foundation

/// The only HTTP transport of the engine (C# EcbRateConnection), created on the first explicit download or
/// enabled daily refresh. No cookies, redirects, caches or credentials; failures reach the host as `CalcError.io`
/// (or `CurrencyRateHttpError` for a status), never as a rate.
final class EcbRateConnection {
    private let transport: CurrencyRateTransport
    init(_ transport: CurrencyRateTransport = URLSessionRateTransport()) { self.transport = transport }
    func fetch(_ date: DateOnly?, now: Instant, utcOffsetSeconds: Int = 0, token: CancellationToken = .none) async throws -> CurrencyRateSnapshot {
        try await EcbRateConnection.reachable { try await EcbRateClient(transport).fetch(date, now: now, utcOffsetSeconds: utcOffsetSeconds, token: token) }
    }
    func fetchInforEuro(_ date: DateOnly?, now: Instant, utcOffsetSeconds: Int = 0, token: CancellationToken = .none) async throws -> CurrencyRateSnapshot {
        try await EcbRateConnection.reachable { try await InforEuroRateClient(transport).fetch(date, now: now, utcOffsetSeconds: utcOffsetSeconds, token: token) }
    }
    /// C# Dispose: ends the URLSession transport (a session keeps its delegate alive until invalidated).
    func close() { (transport as? URLSessionRateTransport)?.close() }
    /// C# turns HttpRequestException (no response at all) into IOException("Currency provider unreachable").
    private static func reachable(_ body: () async throws -> CurrencyRateSnapshot) async throws -> CurrencyRateSnapshot {
        do { return try await body() } catch let error as URLError {
            if error.code == .cancelled { throw CalcError.cancelled }
            throw CalcError.io("Currency provider unreachable")
        }
    }
}

/// `CurrencyRateTransport` over an ephemeral URLSession: no cookies, credential store, cache or redirects.
/// gzip/deflate bodies are decoded by URLSession, as HttpClientHandler.AutomaticDecompression does in C#.
final class URLSessionRateTransport: NSObject, CurrencyRateTransport, URLSessionTaskDelegate {
    /// Created once in `init`, before the transport is shared: a `lazy` session could be created twice by a background
    /// request and a main-thread `close()` racing on first access, and `close()` would then end the wrong one.
    private var session: URLSession!
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    /// Cancels any request in flight and releases the session.
    func close() { session.invalidateAndCancel() }
    func get(_ url: URL, accept: String, token: CancellationToken) async throws -> CurrencyRateHTTPResponse {
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.setValue(accept, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                do {
                    var chunk = Data(); chunk.reserveCapacity(8192)
                    for try await byte in bytes {
                        if token.isCancellationRequested { throw CalcError.cancelled }
                        chunk.append(byte)
                        if chunk.count == 8192 { continuation.yield(chunk); chunk.removeAll(keepingCapacity: true) }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return CurrencyRateHTTPResponse(status: http.statusCode, url: http.url, retryAfter: URLSessionRateTransport.retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
                                        contentLength: http.expectedContentLength >= 0 ? http.expectedContentLength : nil, body: body)
    }
    /// Never follow a redirect: the 3xx response itself is returned and fails as a non-success status.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    /// Retry-After as delta-seconds or an RFC 7231 HTTP date.
    static func retryAfter(_ value: String?) -> CurrencyRetryAfter? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int64(value), seconds >= 0 { return .delta(seconds: seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .date(Instant(unixTicks: Int64((date.timeIntervalSince1970 * 1000).rounded()) * Ticks.perMillisecond))
    }
}
