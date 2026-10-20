import Darwin
import Foundation
import QNotchMacCore

/// The debug channel (spec/diagnostics.md, Debug channel): `debug.sock` in the data root, mode 0600,
/// accepting only the same user, opened only by `--debug-control` (or a diagnostic run that calls
/// `start` itself) and removed on quit. Sockets are read and written on a utility queue; each
/// request runs on the main queue, and a connection's next request waits for the previous reply,
/// so replies come back in order.
final class DebugChannel {
    static let fileName = "debug.sock"
    /// The open channel, if any.
    private(set) static var current: DebugChannel?

    /// Answers one request on the main queue: `reply` takes the response line and an optional
    /// action to run (on the main queue) once it has been written, which `quit` uses.
    typealias Handler = (DebugProtocol.Request, _ reply: @escaping (Data, (() -> Void)?) -> Void) -> Void

    struct Failure: Error, CustomStringConvertible { let description: String }

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "qnotch.debug.channel", qos: .userInitiated)
    private var listener: DispatchSourceRead?
    private var connections: Set<DebugConnection> = []

    /// Opens the channel for the running shell in `directory` (the data root). Idempotent for the
    /// same directory. The smoke test's `debug-channel` check can call this, then talk to `path`
    /// with `DebugClient.send` from a background queue.
    @discardableResult
    static func start(shell: ShellController, directory: URL) throws -> DebugChannel {
        let path = directory.appendingPathComponent(fileName).path
        if let current, current.path == path { return current }
        stop()
        let commands = DebugCommands(shell: shell, dataDirectory: directory)
        let channel = try DebugChannel(path: path) { request, reply in commands.handle(request, reply: reply) }
        current = channel
        return channel
    }

    /// Closes the channel and removes its socket (on quit).
    static func stop() {
        current?.close()
        current = nil
    }

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure(description: "the data folder path is too long for a socket") }
        try Self.removeStale(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: String(cString: strerror(errno))) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            if bound == 0 { unlink(path) }
            throw Failure(description: message)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listener = source
    }

    deinit { close() }

    /// A leftover socket from a run that did not quit cleanly is removed; a live one (another
    /// instance answers) or anything that is not a socket is left alone and fails the start.
    static func removeStale(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw Failure(description: "\(path) exists and is not this user's socket") }
        guard DebugClient.isListening(path) else { unlink(path); return }
        throw Failure(description: "another QNotch already has the debug channel open at \(path)")
    }

    func close() {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        unlink(path)
        queue.sync { connections.forEach { $0.close() }; connections.removeAll() }
    }

    private func acceptAll(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { break }
            // Same user only (the socket's mode already says so), and a handful of clients at a time.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(), connections.count < 8 else { Darwin.close(client); continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = DebugConnection(fd: client, handler: handler) { [weak self] connection in
                self?.queue.async { self?.connections.remove(connection) }
            }
            connections.insert(connection)
            connection.start()
        }
    }
}

/// One client. Reads, the request queue and writes run on its own serial queue.
private final class DebugConnection: Hashable {
    private let fd: Int32
    private let handler: DebugChannel.Handler
    private let finished: (DebugConnection) -> Void
    private let serial = DispatchQueue(label: "qnotch.debug.connection", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var lines = DebugLineBuffer()
    private var waiting: [DebugLineBuffer.Event] = []
    private var busy = false
    private var readClosed = false
    private var closed = false

    init(fd: Int32, handler: @escaping DebugChannel.Handler, finished: @escaping (DebugConnection) -> Void) {
        self.fd = fd
        self.handler = handler
        self.finished = finished
    }
    static func == (a: DebugConnection, b: DebugConnection) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    func start() {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serial)
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            guard count == 0 || (errno != EAGAIN && errno != EINTR) else { return }
            // The client finished sending: answer what it sent, then close.
            readClosed = true
            source?.suspend()
            if !busy, waiting.isEmpty { closeNow() }
            return
        }
        waiting += lines.append(Data(chunk[0..<count]))
        next()
    }

    /// Hands the next request to the main queue once the previous one has been answered.
    private func next() {
        while !busy, !closed {
            guard !waiting.isEmpty else { if readClosed { closeNow() }; return }
            let event = waiting.removeFirst()
            guard case .line(let line) = event else { guard write(DebugProtocol.failure(id: nil, error: DebugProtocol.tooLarge)) else { return }; continue }
            switch DebugProtocol.parse(line) {
            case .failure(let failure):
                guard write(DebugProtocol.failure(id: failure.id, error: failure.message)) else { return }
            case .success(let request):
                busy = true
                let handler = handler
                DispatchQueue.main.async {
                    handler(request) { [weak self] reply, after in
                        guard let self else { after.map { DispatchQueue.main.async(execute: $0) }; return }
                        self.serial.async {
                            let written = self.write(reply)
                            self.busy = false
                            // Runs even when the client left before the reply (quit still quits).
                            if let after { DispatchQueue.main.async(execute: after) }
                            if written { self.next() }
                        }
                    }
                }
            }
        }
    }

    /// Writes a whole reply; closes the connection and returns false when the client is gone.
    private func write(_ data: Data) -> Bool {
        guard !closed else { return false }
        let complete = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written } else if written < 0, errno == EAGAIN || errno == EINTR { usleep(1000) } else { return false }
            }
            return true
        }
        if !complete { closeNow() }
        return complete
    }

    /// From another queue (the channel closing).
    func close() { serial.async { self.closeNow() } }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        // The read source owns the descriptor and closes it once cancelled; a suspended source
        // must be resumed before it can be cancelled.
        if let source {
            if readClosed { source.resume() }
            source.cancel()
        } else { Darwin.close(fd) }
        finished(self)
    }
}
