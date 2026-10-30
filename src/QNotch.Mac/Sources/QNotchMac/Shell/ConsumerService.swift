import Foundation
import Darwin
import CryptoKit
import QNotchMacCore

/// Registry is main-thread confined. The shell owns availability; modules own projections.
final class ConsumerRegistry {
    var capture: [String: (ConsumerRequest) throws -> [String: Any]] = [:]
    var status: (String) -> String = { _ in "initializing" }
    func reply(_ request: ConsumerRequest) throws -> [String: Any] {
        try request.validate()
        let state = status(request.command)
        return ["schema_version": 1, "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                "platform": "macOS", "generated_at": ConsumerJSON.instant(Date()), "module_status": state,
                "data": state == "ready" ? try capture[request.command]?(request) ?? ConsumerJSON.null as Any : ConsumerJSON.null]
    }
}

/// Installation-local secret loaded once at normal startup. Query paths never write identities.
final class ConsumerIdentity {
    private let key: SymmetricKey
    init(directory: URL) throws {
        let file = directory.appendingPathComponent("consumer.identity.json")
        if let data = try? Data(contentsOf: file), let secret = try? JSONDecoder().decode(Data.self, from: data), secret.count == 32 {
            key = SymmetricKey(data: secret)
        } else {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw ConsumerFailure("identity_unavailable") }
            let value = SymmetricKey(size: .bits256)
            let data = value.withUnsafeBytes { Data($0) }
            try JSONEncoder().encode(data).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            key = value
        }
    }
    func id(_ value: String) -> String { HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key).map { String(format: "%02x", $0) }.joined() }
}

/// Nonblocking sockets and absolute monotonic deadlines bound the entire exchange, including slow drips.
enum ConsumerWire {
    static let requestLimit = 4096, responseLimit = 1 << 20
    static func path(directory: URL) throws -> String {
        let fd = open(directory.appendingPathComponent("instance.lock").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ConsumerFailure("not_running") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG else { throw ConsumerFailure("not_running") }
        return "/tmp/qnotch-consumer-\(geteuid())-\(info.st_dev)-\(info.st_ino).sock"
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: a.sun_path) else { throw ConsumerFailure("invalid_arguments") }
        withUnsafeMutableBytes(of: &a.sun_path) { b in path.utf8CString.withUnsafeBytes { b.copyMemory(from: $0) } }
        return a
    }
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    static func peer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw ConsumerFailure("peer_rejected") }
    }
    static func wait(_ fd: Int32, _ events: Int16, _ deadline: TimeInterval) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ConsumerFailure("timeout") }
        var p = pollfd(fd: fd, events: events, revents: 0)
        guard poll(&p, 1, Int32(min(2000, ceil(remaining * 1000)))) > 0 else { throw ConsumerFailure("timeout") }
    }
    static func readLine(_ fd: Int32, limit: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, Int16(POLLIN), deadline)
            let n = read(fd, &bytes, bytes.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard n > 0 else { throw ConsumerFailure("connection_closed") }
            let end = bytes[..<n].firstIndex(of: 10) ?? n
            guard data.count + end <= limit else { throw ConsumerFailure("size_limit") }
            data.append(contentsOf: bytes[..<end])
            if end < n { return data }
        }
    }
    static func send(_ fd: Int32, data: Data, deadline: TimeInterval) throws {
        let line = data + Data([10])
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(fd, Int16(POLLOUT), deadline)
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { throw ConsumerFailure("connection_closed") }
                offset += n
            }
        }
    }
    static func query(_ request: ConsumerRequest, directory: URL) throws -> Data {
        var a = try address(path(directory: directory))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConsumerFailure("transport_error") }
        defer { close(fd) }; prepare(fd)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS else { throw ConsumerFailure("not_running") }
            try wait(fd, Int16(POLLOUT), deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw ConsumerFailure("not_running") }
        }
        try peer(fd)
        let data = try JSONEncoder().encode(request)
        guard data.count <= requestLimit else { throw ConsumerFailure("size_limit") }
        try send(fd, data: data, deadline: deadline)
        return try readLine(fd, limit: responseLimit, deadline: deadline)
    }
}

final class ConsumerService {
    private let queue = DispatchQueue(label: "qnotch.consumer")
    private var listener: DispatchSourceRead?
    private var clients = Set<Int32>() // queue confined
    let path: String
    init(path: String, registry: ConsumerRegistry) throws {
        self.path = path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw ConsumerFailure("endpoint_exists") }
            // Caller must hold the directory instance lock; no other owner can be serving this inode.
            unlink(path)
        }
        var a = try ConsumerWire.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConsumerFailure("transport_error") }
        let old = umask(0o177)
        let result = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard result == 0 else { Darwin.close(fd); throw ConsumerFailure("transport_error") }
        guard chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { Darwin.close(fd); unlink(path); throw ConsumerFailure("transport_error") }
        ConsumerWire.prepare(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                guard self.clients.count < 4, (try? ConsumerWire.peer(client)) != nil else { Darwin.close(client); continue }
                ConsumerWire.prepare(client); self.clients.insert(client)
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                DispatchQueue.global(qos: .utility).async {
                    defer { self.queue.async { self.clients.remove(client); Darwin.close(client) } }
                    do {
                        let data = try ConsumerWire.readLine(client, limit: ConsumerWire.requestLimit, deadline: deadline)
                        let request: ConsumerRequest
                        do {
                            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys).isSubset(of: ["schema_version", "command", "details", "provider", "account"]) else { throw ConsumerFailure("invalid_arguments") }
                            request = try JSONDecoder().decode(ConsumerRequest.self, from: data); try request.validate() }
                        catch let failure as ConsumerFailure { throw failure }
                        catch { throw ConsumerFailure("invalid_arguments") }
                        let box = ConsumerReplyBox()
                        DispatchQueue.main.async {
                            guard ProcessInfo.processInfo.systemUptime < deadline else { box.ready.signal(); return }
                            do { box.object = try registry.reply(request) }
                            catch let failure as ConsumerFailure { box.object = (try? JSONSerialization.jsonObject(with: failure.data)) as? [String: Any] }
                            catch { box.object = ["schema_version": 1, "error": ["code": "internal_error"]] }
                            box.ready.signal()
                        }
                        guard box.ready.wait(timeout: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)) == .success,
                              let object = box.object else { throw ConsumerFailure("timeout") }
                        let reply = ConsumerJSON.encode(object)
                        try ConsumerWire.send(client, data: reply.count <= ConsumerWire.responseLimit ? reply : ConsumerFailure("size_limit").data, deadline: deadline)
                    } catch {
                        try? ConsumerWire.send(client, data: (error as? ConsumerFailure ?? ConsumerFailure("transport_error")).data, deadline: deadline)
                    }
                }
            }
        }
        source.resume(); listener = source
    }
    func close() {
        guard let source = listener else { return }; listener = nil
        source.cancel(); unlink(path)
        queue.sync { clients.forEach { shutdown($0, SHUT_RDWR) } }
    }
    deinit { close() }
}
private final class ConsumerReplyBox { let ready = DispatchSemaphore(value: 0); var object: [String: Any]? }

public enum ConsumerClient {
    public static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first, ["usage", "agents"].contains(verb) else { return }
        if args.contains("--help") || args.contains("-h") {
            print("QNotch \(verb) --json [--details]" + (verb == "usage" ? " [--provider claude|codex] [--account ID]" : "") + " [--data-dir PATH]"); exit(0)
        }
        do {
            let (request, directory) = try ConsumerRequest.parse(args)
            let root = (directory ?? ProcessInfo.processInfo.environment["QNOTCH_MAC_DATA_DIR"]).map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QNotch.Mac")
            let data = try ConsumerWire.query(request, directory: root)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["schema_version"] as? Int == 1 else { throw ConsumerFailure("unsupported_version") }
            if let error = object["error"] as? [String: Any] { throw ConsumerFailure(error["code"] as? String ?? "protocol_error") }
            guard object["platform"] as? String == "macOS", object["module_status"] is String else { throw ConsumerFailure("protocol_error") }
            FileHandle.standardOutput.write(data + Data([10])); exit(0)
        } catch {
            let failure = error as? ConsumerFailure ?? ConsumerFailure("protocol_error")
            FileHandle.standardError.write(failure.data + Data([10]))
            exit(failure.code == "not_running" ? 3 : failure.code == "invalid_arguments" ? 4 : 1)
        }
    }
}
