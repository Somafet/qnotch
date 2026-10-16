import Darwin
import Foundation
import QNotchMacCore

/// `QNotch notify …` (Windows `QNotch.exe notify`): sends one request to the running app over
/// its Unix socket and exits with the Windows exit codes. Runs before AppKit starts.
public enum NotifyClient {
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "notify" else { return }
        exit(run(Array(args.dropFirst(2))))
    }

    static func run(_ args: [String]) -> Int32 {
        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            print(NotifyCLI.help)
            return args.isEmpty ? 4 : 0
        }
        let payload: Data
        do {
            payload = try NotifyCLI.payload(args, parentPid: getppid(), readStdin: {
                String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }, resolvePath: { value in
                let path = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
                return FileManager.default.fileExists(atPath: path) ? path : nil
            })
        } catch let error as NotifyCLI.UsageError {
            fputs(error.message + "\n", stderr)
            return 4
        } catch {
            fputs("\(error)\n", stderr)
            return 4
        }
        let root = ProcessInfo.processInfo.environment["QNOTCH_MAC_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QNotch.Mac", isDirectory: true)
        let path = root.appendingPathComponent("notify.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let connected = fd >= 0 && withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard connected else {
            fputs("QNotch is not running, or Notifications is turned off.\n", stderr)
            return 3
        }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == payload.count else { fputs("Could not send the request.\n", stderr); return 4 }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            reply.append(contentsOf: chunk[0..<count])
            if chunk[0..<count].contains(0x0A) { break }
        }
        let outcome = NotifyCLI.outcome(reply)
        if let stdout = outcome.stdout { print(stdout) }
        if let stderr = outcome.stderr { fputs(stderr + "\n", Darwin.stderr) }
        return outcome.code
    }
}
