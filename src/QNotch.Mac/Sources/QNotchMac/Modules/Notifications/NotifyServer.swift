import Darwin
import Foundation
import QNotchMacCore

/// Where a request came from and how to answer it. `gone` fires if a waiting sender disconnects.
final class NotifyExchange {
    private let send: (Data) -> Void
    private var answered = false
    var gone: (() -> Void)?
    init(send: @escaping (Data) -> Void) { self.send = send }
    var isAnswered: Bool { answered }
    func answer(_ line: Data) {
        guard !answered else { return }
        answered = true
        send(line)
    }
}

/// Local endpoints for posting notifications (Windows NotifyServer):
/// - a Unix domain socket in the data folder (mode 0600, the per-user replacement for the named
///   pipe): one JSON line in, one JSON line out;
/// - HTTP on 127.0.0.1 only, with a bearer token, no Origin header and a loopback Host.
/// Both are idle until someone connects. Requests are parsed on a utility queue; the module
/// handles them on the main queue.
final class NotifyServer {
    enum Kind { case socket, http }
    typealias Handler = (Data, NotifyExchange) -> Void

    private let queue = DispatchQueue(label: "qnotch.notify.server", qos: .utility)
    private var listeners: [Kind: (fd: Int32, source: DispatchSourceRead)] = [:]
    private var connections: Set<Connection> = []
    private let handler: Handler
    /// Read lazily (Keychain) the first time an HTTP request arrives.
    var token: () -> String = { "" }
    private(set) var port: UInt16 = 0
    private(set) var socketPath = ""

    init(handler: @escaping Handler) { self.handler = handler }
    deinit { stopAll() }

    // MARK: Listening

    /// Returns a status line for Settings.
    @discardableResult
    func startSocket(at path: String) -> String {
        stop(.socket)
        socketPath = path
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return "Unavailable: the data folder path is too long for a socket." }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "Unavailable: \(String(cString: strerror(errno)))" }
        unlink(path) // A stale socket from a previous run; the instance lock guarantees it is ours.
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            return "Unavailable: \(message)"
        }
        accept(on: fd, kind: .socket)
        return "Listening"
    }

    @discardableResult
    func startHTTP(port: UInt16) -> String {
        stop(.http)
        self.port = port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "Unavailable: \(String(cString: strerror(errno)))" }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian // loopback only: no firewall or Local Network prompt
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            return code == EADDRINUSE ? "Port \(port) is in use by another app. Pick another port." : "Unavailable: \(String(cString: strerror(code)))"
        }
        accept(on: fd, kind: .http)
        return "Listening on 127.0.0.1:\(port)"
    }

    func stop(_ kind: Kind) {
        guard let listener = listeners.removeValue(forKey: kind) else { return }
        listener.source.cancel()
        if kind == .socket, !socketPath.isEmpty { unlink(socketPath) }
    }

    func stopAll() {
        stop(.socket); stop(.http)
        queue.sync { connections.forEach { $0.close() }; connections.removeAll() }
    }

    private func accept(on fd: Int32, kind: Kind) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                // At most 24 connections; more are refused (waiting senders count).
                guard self.connections.count < 24 else { Darwin.close(client); continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let connection = Connection(fd: client, kind: kind, server: self)
                self.connections.insert(connection)
                connection.start()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listeners[kind] = (fd, source)
    }

    fileprivate func finished(_ connection: Connection) { connections.remove(connection) }

    // MARK: Requests (server queue)

    fileprivate func received(_ connection: Connection, line: Data) {
        let exchange = NotifyExchange { [weak connection] reply in connection?.reply(reply) }
        connection.exchange = exchange
        DispatchQueue.main.async { self.handler(line, exchange) }
    }

    fileprivate func received(_ connection: Connection, head: String) -> LocalHTTP.Request? {
        let token = DispatchQueue.main.sync { self.token() }
        do {
            return try LocalHTTP.parse(head: head, port: port, token: token)
        } catch LocalHTTP.Failure.status(let status, let message) {
            connection.reply(LocalHTTP.response(status: status, body: NotifyRules.reply(error: message)))
        } catch {
            connection.reply(LocalHTTP.response(status: 400, body: NotifyRules.reply(error: "Bad request.")))
        }
        return nil
    }

    fileprivate func received(_ connection: Connection, request: LocalHTTP.Request, body: Data) {
        let segments = request.path.split(separator: "/").map(String.init)
        let line: Data
        switch (request.method, segments.first, segments.count) {
        case ("POST", "notify", 1):
            guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return connection.reply(LocalHTTP.response(status: 400, body: NotifyRules.reply(error: "The body is not a JSON object.")))
            }
            if ["1", "true"].contains(request.query["wait"] ?? "") { object["wait"] = true }
            line = (try? JSONSerialization.data(withJSONObject: object)) ?? body
        case ("DELETE", "notify", 2):
            line = (try? JSONSerialization.data(withJSONObject: ["op": "dismiss", "id": segments[1].removingPercentEncoding ?? segments[1]])) ?? Data()
        case (_, "notify", _):
            return connection.reply(LocalHTTP.response(status: 405, body: NotifyRules.reply(error: "Use POST /notify or DELETE /notify/{id}.")))
        default:
            return connection.reply(LocalHTTP.response(status: 404, body: NotifyRules.reply(error: "Not found.")))
        }
        let exchange = NotifyExchange { [weak connection] reply in
            let failed = (try? JSONSerialization.jsonObject(with: reply)) .flatMap { ($0 as? [String: Any])?["ok"] as? Bool } != true
            connection?.reply(LocalHTTP.response(status: failed ? 400 : 200, body: reply))
        }
        connection.exchange = exchange
        DispatchQueue.main.async { self.handler(line, exchange) }
    }
}

/// One client connection; everything here runs on the server queue.
private final class Connection: Hashable {
    let fd: Int32
    let kind: NotifyServer.Kind
    weak var server: NotifyServer?
    var exchange: NotifyExchange?
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var request: LocalHTTP.Request?
    private var bodyStart = 0
    private var handedOver = false
    private var closed = false
    private var timeout: DispatchWorkItem?
    /// Serializes this connection's reads, replies and close.
    private let serial = DispatchQueue(label: "qnotch.notify.connection", qos: .utility)

    init(fd: Int32, kind: NotifyServer.Kind, server: NotifyServer) {
        self.fd = fd
        self.kind = kind
        self.server = server
    }
    static func == (a: Connection, b: Connection) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    func start() {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queueOf())
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        self.source = source
        // A request must arrive within 5 seconds (10 for HTTP heads); waiting replies have no limit.
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.handedOver else { return }
            if self.kind == .http { self.reply(LocalHTTP.response(status: 408, body: NotifyRules.reply(error: "Request timeout."))) } else { self.closeNow() }
        }
        timeout = task
        queueOf().asyncAfter(deadline: .now() + (kind == .http ? 10 : 5), execute: task)
    }

    private func queueOf() -> DispatchQueue { serial }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // The sender left: a waiting notification stops waiting.
                if handedOver, let exchange { DispatchQueue.main.async { if !exchange.isAnswered { exchange.gone?() } } }
                closeNow()
            }
            return
        }
        guard !handedOver else { return } // Bytes after a complete request are ignored.
        buffer.append(contentsOf: chunk[0..<count])
        switch kind {
        case .socket:
            if let newline = buffer.firstIndex(of: 0x0A) {
                handedOver = true
                timeout?.cancel()
                server?.received(self, line: buffer[..<newline])
            } else if buffer.count > NotifyRules.maxMessage {
                reply(NotifyRules.reply(error: "The request is larger than 64 KB."))
            }
        case .http:
            if request == nil {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > LocalHTTP.maxHead { reply(LocalHTTP.response(status: 400, body: NotifyRules.reply(error: "Headers too large."))) }
                    return
                }
                guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8),
                      let parsed = server?.received(self, head: head) else { return }
                request = parsed
                bodyStart = end.upperBound
            }
            if let request, buffer.count - bodyStart >= request.contentLength {
                handedOver = true
                timeout?.cancel()
                server?.received(self, request: request, body: buffer[bodyStart..<(bodyStart + request.contentLength)])
            }
        }
    }

    func reply(_ data: Data) {
        serial.async { [self] in
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written > 0 { offset += written } else if errno == EAGAIN { usleep(1000) } else { break }
                }
            }
            closeNow()
        }
    }

    /// From another queue (server shutdown).
    func close() { serial.async { self.closeNow() } }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        // The read source owns the descriptor and closes it once cancelled.
        if let source { source.cancel() } else { Darwin.close(fd) }
        let server = server
        DispatchQueue.main.async { server?.finishedOnServerQueue(self) }
    }
}

private extension NotifyServer {
    func finishedOnServerQueue(_ connection: Connection) { queue.async { self.finished(connection) } }
}
