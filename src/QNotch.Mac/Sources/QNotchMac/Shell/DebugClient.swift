import Darwin
import Foundation
import QNotchMacCore

/// `QNotch debug …`: sends one request to a running instance's debug channel and exits with the
/// shared exit codes (0 ok, 1 failed, 3 no instance, 4 bad usage). Runs before AppKit starts.
public enum DebugClient {
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "debug" else { return }
        exit(run(Array(args.dropFirst(2))))
    }

    enum Failure: Error, Equatable { case notRunning, tooLong, io(String) }

    static func run(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            print(DebugCLI.help)
            return args.isEmpty ? 4 : 0
        }
        let invocation: DebugCLI.Invocation
        do { invocation = try DebugCLI.parse(args) } catch let error as DebugCLI.UsageError {
            fputs(error.message + "\n", stderr)
            return 4
        } catch { fputs("\(error)\n", stderr); return 4 }
        let root = (invocation.dataDirectory ?? environment["QNOTCH_MAC_DATA_DIR"]).map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QNotch.Mac", isDirectory: true)
        let path = root.appendingPathComponent(DebugChannel.fileName).path
        switch send(DebugCLI.request(invocation), to: path) {
        case .success(let reply):
            let outcome = DebugCLI.outcome(reply)
            if let stdout = outcome.stdout { print(stdout) }
            if let stderr = outcome.stderr { fputs(stderr + "\n", Darwin.stderr) }
            return outcome.code
        case .failure(.notRunning):
            fputs("No QNotch with the debug channel open at \(path). Start it with --debug-control.\n", stderr)
            return 3
        case .failure(.tooLong):
            fputs("The data directory path is too long for a socket.\n", stderr)
            return 4
        case .failure(.io(let message)):
            fputs(message + "\n", stderr)
            return 1
        }
    }

    /// Whether an instance accepts connections at `path` (a stale socket refuses them).
    static func isListening(_ path: String) -> Bool {
        guard case .success(let fd) = connect(path) else { return false }
        close(fd)
        return true
    }

    private static func connect(_ path: String) -> Result<Int32, Failure> {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .failure(.tooLong) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.io("Could not create a socket.")) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard connected else { close(fd); return .failure(.notRunning) }
        return .success(fd)
    }

    /// One request line, one reply line. Blocks; never call it on the main thread of the instance
    /// it talks to (commands run there).
    static func send(_ request: Data, to path: String, timeout: TimeInterval = 60) -> Result<Data, Failure> {
        let fd: Int32
        switch connect(path) {
        case .success(let value): fd = value
        case .failure(let failure): return .failure(failure)
        }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let sent = request.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard sent else { return .failure(.io("Could not send the request.")) }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !reply.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                return .failure(.io(count < 0 && errno == EAGAIN ? "QNotch did not answer within \(Int(timeout)) seconds." : "QNotch closed the connection without answering."))
            }
            reply.append(contentsOf: chunk[0..<count])
        }
        return .success(reply)
    }
}
