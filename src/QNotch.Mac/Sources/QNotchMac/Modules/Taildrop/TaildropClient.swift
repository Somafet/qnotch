import AppKit
import Darwin

/// Where the local Tailscale service answers its LocalAPI.
enum TaildropEndpoint: Equatable {
    /// The standalone Tailscale app (System Extension): loopback TCP with a same-user key.
    case tcp(port: UInt16, token: String)
    /// The open-source `tailscaled`: a root-owned Unix socket.
    case unix(path: String)
}

/// Finds the LocalAPI without private API or reaching into another app's sandbox.
///
/// - The standalone app writes `/Library/Tailscale/ipnport` (a symlink whose target is the port)
///   and `/Library/Tailscale/sameuserproof-<port>` (the key, readable by admin accounts). This is
///   the same discovery Tailscale's own CLI does for that edition.
/// - The open-source daemon listens on `/var/run/tailscaled.socket`.
/// - The Mac App Store edition only publishes its port and key inside its group container, which
///   another app can reach only through a privacy prompt or by scraping `lsof`; QNotch does
///   neither and says so instead.
enum TaildropDiscovery {
    enum Outcome: Equatable {
        case endpoint(TaildropEndpoint)
        case notInstalled, notRunning, appStoreEdition, noAccess
    }

    struct Paths {
        var library = "/Library/Tailscale"
        var socket = "/var/run/tailscaled.socket"
    }

    static let standaloneBundle = "io.tailscale.ipn.macsys"
    static let appStoreBundle = "io.tailscale.ipn.macos"

    static func discover(paths: Paths = Paths(), installed: (String) -> Bool = isInstalled) -> Outcome {
        let files = FileManager.default
        if let target = try? files.destinationOfSymbolicLink(atPath: paths.library + "/ipnport"),
           let port = UInt16(target.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
            let proof = paths.library + "/sameuserproof-\(port)"
            if let handle = FileHandle(forReadingAtPath: proof) {
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 256)) ?? Data()
                let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) { return .endpoint(.tcp(port: port, token: token)) }
            } else if files.fileExists(atPath: proof) {
                return .noAccess
            }
        }
        if isSocket(paths.socket) { return .endpoint(.unix(path: paths.socket)) }
        if installed(standaloneBundle) { return .notRunning }
        if installed(appStoreBundle) { return .appStoreEdition }
        return .notInstalled
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The installed Tailscale app, for Open Tailscale.
    static var appURL: URL? {
        [standaloneBundle, appStoreBundle].lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }
}

enum TaildropError: Error, Equatable, LocalizedError {
    case notRunning, noAccess, timedOut, cancelled, badResponse, tooLarge
    case http(Int, String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Tailscale is not running"
        case .noAccess: return "No access to Tailscale"
        case .timedOut: return "Tailscale did not answer in time"
        case .cancelled: return "Cancelled"
        case .badResponse: return "Tailscale sent an answer QNotch doesn't understand"
        case .tooLarge: return "Tailscale's answer was too large"
        case .http(let status, let message): return message.isEmpty ? "Tailscale answered \(status)" : message
        case .io(let message): return message
        }
    }
}

/// Cancels a running request from another thread by shutting its socket down.
final class TaildropCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if socket >= 0 { Darwin.shutdown(socket, SHUT_RDWR) }
    }

    fileprivate func attach(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        socket = fd
        return true
    }

    fileprivate func detach() { lock.lock(); socket = -1; lock.unlock() }
}

/// A minimal blocking HTTP/1.0 client for the LocalAPI (`/localapi/v0/…`). One connection per
/// request, `Connection: close`, so the answer ends at end of stream and is never chunked. Run it
/// off the main thread only. Bodies are bounded; uploads and downloads are streamed. The same-user
/// key is sent only to 127.0.0.1 and never logged.
struct TaildropClient {
    let endpoint: TaildropEndpoint
    /// Per read or write: a stalled service fails after this long.
    var timeout: TimeInterval = 10

    func get(_ path: String, limit: Int = 4 << 20) throws -> Data {
        var body = Data()
        try perform("GET", path, cancel: nil) { chunk in
            guard body.count + chunk.count <= limit else { throw TaildropError.tooLarge }
            body.append(chunk)
        }
        return body
    }

    func delete(_ path: String) throws {
        try perform("DELETE", path, bodyLength: 0, cancel: nil) { _ in }
    }

    /// Streams `file` as the request body; `progress` gets the bytes written so far.
    func put(_ path: String, file: URL, length: Int64, cancel: TaildropCancellation, progress: @escaping (Int64) -> Void) throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw TaildropError.io("The file can't be read") }
        defer { try? handle.close() }
        var client = self
        client.timeout = max(timeout, 60)
        try client.perform("PUT", path, bodyLength: length, cancel: cancel, body: { fd in
            var sent: Int64 = 0
            while sent < length {
                if cancel.isCancelled { throw TaildropError.cancelled }
                guard let chunk = try handle.read(upToCount: Int(min(256 * 1024, length - sent))), !chunk.isEmpty else {
                    throw TaildropError.io("The file changed while it was being sent")
                }
                try Self.writeAll(fd, chunk, cancel: cancel)
                sent += Int64(chunk.count)
                progress(sent)
            }
        }) { _ in }
    }

    /// Streams the answer's body into `handle`.
    func download(_ path: String, into handle: FileHandle, cancel: TaildropCancellation) throws {
        var client = self
        client.timeout = max(timeout, 60)
        try client.perform("GET", path, cancel: cancel) { chunk in try handle.write(contentsOf: chunk) }
    }

    // MARK: Transport

    private func perform(_ method: String, _ path: String, bodyLength: Int64? = nil, cancel: TaildropCancellation?,
                         body: ((Int32) throws -> Void)? = nil, sink: (Data) throws -> Void) throws {
        if cancel?.isCancelled == true { throw TaildropError.cancelled }
        let fd = try connect()
        defer { cancel?.detach(); Darwin.close(fd) }
        if let cancel, !cancel.attach(fd) { throw TaildropError.cancelled }
        var head = "\(method) /localapi/v0/\(path) HTTP/1.0\r\nHost: local-tailscaled.sock\r\nConnection: close\r\nUser-Agent: QNotch\r\n"
        if case .tcp(_, let token) = endpoint {
            head += "Authorization: Basic \(Data(":\(token)".utf8).base64EncodedString())\r\n"
        }
        if let bodyLength { head += "Content-Length: \(bodyLength)\r\n" }
        head += "\r\n"
        do {
            try Self.writeAll(fd, Data(head.utf8), cancel: cancel)
            try body?(fd)
        } catch TaildropError.io(let message) where message == Self.peerClosed {
            // The service answered early (a refusal) and closed; read that answer below.
        }
        try readResponse(fd, cancel: cancel, sink: sink)
    }

    private func connect() throws -> Int32 {
        switch endpoint {
        case .tcp(let port, _):
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TaildropError.io(Self.errnoText()) }
            configure(fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return try finishConnect(fd, result)
        case .unix(let path):
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TaildropError.io(Self.errnoText()) }
            configure(fd)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw TaildropError.notRunning }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            return try finishConnect(fd, result)
        }
    }

    private func finishConnect(_ fd: Int32, _ result: Int32) throws -> Int32 {
        guard result != 0 else { return fd }
        let code = errno
        Darwin.close(fd)
        switch code {
        case ECONNREFUSED, ENOENT: throw TaildropError.notRunning
        case EACCES, EPERM: throw TaildropError.noAccess
        case ETIMEDOUT: throw TaildropError.timedOut
        default: throw TaildropError.io(String(cString: strerror(code)))
        }
    }

    private func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    private static let peerClosed = "The connection closed"

    private static func writeAll(_ fd: Int32, _ data: Data, cancel: TaildropCancellation?) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if written > 0 { offset += written; continue }
                let code = errno
                if code == EINTR { continue }
                if cancel?.isCancelled == true { throw TaildropError.cancelled }
                if code == EAGAIN || code == EWOULDBLOCK { throw TaildropError.timedOut }
                if code == EPIPE || code == ECONNRESET { throw TaildropError.io(peerClosed) }
                throw TaildropError.io(String(cString: strerror(code)))
            }
        }
    }

    /// Parses `HTTP/1.x NNN …`, then streams the body to `sink` on 2xx; otherwise throws with the
    /// first line of the service's error text.
    private func readResponse(_ fd: Int32, cancel: TaildropCancellation?, sink: (Data) throws -> Void) throws {
        var buffer = Data()
        var status = 0
        var remaining: Int64?
        var errorText = Data()
        var headerDone = false
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if cancel?.isCancelled == true { throw TaildropError.cancelled }
                if code == EAGAIN || code == EWOULDBLOCK { throw TaildropError.timedOut }
                throw TaildropError.io(String(cString: strerror(code)))
            }
            if count == 0 { break }
            var data = Data(chunk[0..<count])
            if !headerDone {
                buffer.append(data)
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 64 * 1024 { throw TaildropError.badResponse }
                    continue
                }
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                (status, remaining) = try Self.parseHeader(header)
                data = Data(buffer[end.upperBound...])
                buffer = Data()
                headerDone = true
            }
            if let left = remaining {
                if Int64(data.count) > left { data = data.prefix(Int(left)) }
                remaining = left - Int64(data.count)
            }
            if (200..<300).contains(status) {
                if !data.isEmpty { try sink(data) }
            } else if errorText.count < 1024 {
                errorText.append(data.prefix(1024 - errorText.count))
            }
            if remaining == 0 { break }
        }
        if cancel?.isCancelled == true { throw TaildropError.cancelled }
        guard headerDone else { throw TaildropError.badResponse }
        if let remaining, remaining > 0 { throw TaildropError.io("The answer was cut short") }
        guard (200..<300).contains(status) else {
            if status == 401 { throw TaildropError.noAccess }
            throw TaildropError.http(status, Self.message(errorText))
        }
    }

    static func parseHeader(_ header: String) throws -> (status: Int, length: Int64?) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]), (100..<600).contains(status) else {
            throw TaildropError.badResponse
        }
        var length: Int64?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int64(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return (status, length)
    }

    /// The first line of an error body, bounded, without control characters.
    static func message(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = String(first.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return clean.count > 160 ? String(clean.prefix(159)) + "…" : clean
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
