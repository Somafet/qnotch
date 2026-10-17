import Darwin
import Foundation
import QNotchMacCore

/// `QNotch agent [codex]`: the hook Claude Code (or Codex) runs on every session event. Reads the
/// event JSON from stdin, adds the agent's process id and an app link, sends one line to the
/// running app's socket and exits. Always exits 0: a hook must never get in the agent's way.
public enum AgentHookCommand {
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "agent" else { return }
        run(codex: args.dropFirst(2).first == "codex")
        exit(0)
    }

    static func socketPath() -> String {
        let root = ProcessInfo.processInfo.environment["QNOTCH_MAC_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QNotch.Mac", isDirectory: true)
        return root.appendingPathComponent("agents.sock").path
    }

    private static func run(codex: Bool) {
        let path = socketPath()
        // QNotch or the module is off: exit at once.
        guard FileManager.default.fileExists(atPath: path) else { return }
        let input = FileHandle.standardInput.readData(ofLength: 1 << 20)
        let agent = ProcessTree.agentProcess(from: getpid())
        let session = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any])?["session_id"] as? String ?? ""
        let link = agent.flatMap { appLink(codex: codex, session: session, agent: $0) }
        guard let event = AgentEvent.from(hookInput: input, codex: codex, pid: agent, link: link, at: Date().timeIntervalSince1970),
              var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// A link that opens the session in the app it runs in: the Codex app opens a thread by the id its
    /// hooks get; the Claude app takes its own session id, only when the app itself started the agent.
    private static func appLink(codex: Bool, session: String, agent: Int32) -> String? {
        let path = ProcessTree.path(agent)
        if codex {
            return UUID(uuidString: session) != nil && path.contains("/Codex.app/") ? "codex://threads/" + session : nil
        }
        guard let parent = ProcessTree.parent(agent), ProcessTree.path(parent).contains("/Claude.app/"),
              let id = ProcessInfo.processInfo.environment["CLAUDE_CODE_HOST_SESSION_ID"] else { return nil }
        let link = "claude://code/continue?session=" + id
        return AgentEvent.isValidLink(link) ? link : nil
    }
}

/// Process-tree lookups with libproc (no permission needed for the user's own processes).
enum ProcessTree {
    static func parent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
        return Int32(info.pbi_ppid)
    }

    static func name(_ pid: Int32) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.lowercased()
    }

    static func path(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// The nearest ancestor that is the agent (claude, codex, or node for an npm install), so the notch
    /// notices a session ending without a SessionEnd (terminal closed).
    static func agentProcess(from pid: Int32) -> Int32? {
        var current = parent(pid)
        for _ in 0..<6 {
            guard let id = current else { return nil }
            let name = name(id)
            if ["claude", "codex", "node"].contains(name) || path(id).contains("/claude/versions/") { return id }
            current = parent(id)
        }
        return nil
    }
}
