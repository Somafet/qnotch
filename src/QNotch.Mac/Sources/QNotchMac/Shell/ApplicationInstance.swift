import Darwin
import Foundation
import QNotchMacCore

/// One provider set per data directory. Recovery can only bring Settings forward; it does not
/// construct DebugCommands, publish DebugChannel.current, or open the general debug endpoint.
final class ApplicationInstance {
    enum Failure: Error, Equatable { case alreadyRunning, unavailable }

    private var descriptor: Int32
    let recoveryPath: String
    private var recovery: DebugChannel?

    private init(descriptor: Int32, recoveryPath: String) {
        self.descriptor = descriptor
        self.recoveryPath = recoveryPath
    }

    static func acquire(directory: URL) throws -> ApplicationInstance {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path,
                             O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        guard let path = recoveryPath(descriptor: fd) else { Darwin.close(fd); throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            Darwin.close(fd)
            throw busy ? Failure.alreadyRunning : Failure.unavailable
        }
        return ApplicationInstance(descriptor: fd, recoveryPath: path)
    }

    /// The locked file's identity also handles symlink aliases of a directory. A short socket
    /// name avoids AF_UNIX's 104-byte limit for deeply nested data roots. It contains no user data.
    /// Socket creation is mode 0600, refuses foreign/non-socket/live files, and checks peer uid.
    private static func recoveryPath(descriptor: Int32) -> String? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid() else { return nil }
        return "/tmp/qnotch-reopen-\(geteuid())-\(info.st_dev)-\(info.st_ino).sock"
    }

    func startRecovery(openSettings: @escaping () -> Void) throws {
        guard recovery == nil, descriptor >= 0 else { return }
        recovery = try DebugChannel(path: recoveryPath) { request, reply in
            guard request.command == "settings", request.args.isEmpty else {
                reply(DebugProtocol.failure(id: request.id, error: "Only opening Settings is supported."), nil)
                return
            }
            openSettings()
            reply(DebugProtocol.success(id: request.id, result: [:]), nil)
        }
    }

    /// Called only by the losing process, before it constructs a shell. Retry the startup race
    /// while the lock owner is still building its shell; never fall through to another instance.
    static func requestSettings(directory: URL, wait: TimeInterval = 5) -> Bool {
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard let path = recoveryPath(descriptor: fd) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + wait
        repeat {
            if case .success(let data) = DebugClient.send(Data("{\"cmd\":\"settings\"}\n".utf8), to: path, timeout: 1),
               let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               reply["ok"] as? Bool == true { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(50_000)
        } while true
        return false
    }

    func close() {
        recovery?.close()
        recovery = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { close() }
}
