import Foundation
import Darwin
import QNotchTerminalPTY

/// Main-thread, event-driven, nonblocking PTY. The window never owns this lifetime.
/// No Process/pipes, repeating timers, output logs, or unbounded pending input/output.
final class TerminalSession {
    private(set) var pid: pid_t = 0
    private(set) var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var pending = Data()
    var output: ((Data) -> Void)?
    var ended: ((Int32) -> Void)?
    private(set) var reaped = false

    static var loginShell: String {
        guard let shell = getpwuid(getuid())?.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.hasPrefix("/") && access(path, X_OK) == 0 ? path : "/bin/zsh"
    }

    func start(shell: String = TerminalSession.loginShell,
               home: String = FileManager.default.homeDirectoryForCurrentUser.path,
               columns: Int, rows: Int) throws {
        precondition(Thread.isMainThread)
        guard pid == 0 else { return }
        pid = qn_terminal_spawn(shell, home, UInt16(clamping: columns), UInt16(clamping: rows), &master)
        guard pid > 0 else {
            pid = 0
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        reaped = false
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        reader = source
        source.resume()
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        process.setEventHandler { [weak self] in self?.finish() }
        exitSource = process
        process.resume()
    }

    func send(_ bytes: Data) {
        guard master >= 0, !bytes.isEmpty else { return }
        // Refuse the whole paste rather than executing a silently truncated command.
        guard bytes.count <= 64 * 1024, pending.count + bytes.count <= 64 * 1024 else { return }
        pending.append(bytes)
        flush()
    }

    private func flush() {
        guard master >= 0 else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if errno == EINTR { continue }
            else if errno == EAGAIN {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writer = source
                    source.resume()
                }
                return
            } else { pending.removeAll(); break }
        }
        writer?.cancel(); writer = nil
    }

    @discardableResult
    private func readAvailable() -> Int {
        guard master >= 0 else { return 0 }
        // One bounded batch per main-run-loop event; the kernel PTY supplies backpressure.
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(master, &bytes, bytes.count)
        if count > 0 { output?(Data(bytes.prefix(count))) }
        else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { reader?.cancel(); reader = nil }
        return max(0, count)
    }

    func resize(columns: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size) // Kernel sends SIGWINCH to the foreground group.
    }

    private func finish() {
        guard pid > 0, !reaped else { return }
        exitSource?.cancel(); exitSource = nil
        reader?.cancel(); reader = nil
        qn_terminal_terminate(pid)
        drainAfterExit(remaining: 1024 * 1024)
    }

    private func drainAfterExit(remaining: Int) {
        guard pid > 0, !reaped else { return }
        // Finish buffered output one batch per run-loop turn, while the leader reserves its
        // session id. A detached daemon retaining the slave cannot keep this alive forever.
        let count = readAvailable()
        if count > 0, remaining > count {
            DispatchQueue.main.async { [weak self] in self?.drainAfterExit(remaining: remaining - count) }
        } else {
            let child = pid
            stop()
            ended?(child)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        exitSource?.cancel(); exitSource = nil
        let descriptor = master
        master = -1
        if pid > 0, !reaped { qn_terminal_stop(pid, descriptor); reaped = true }
        else if descriptor >= 0 { Darwin.close(descriptor) }
        pending.removeAll()
    }
}
