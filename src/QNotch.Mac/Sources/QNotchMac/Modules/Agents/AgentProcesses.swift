import Darwin
import Foundation
import QNotchMacCore

/// libproc reads of the user's own processes (no permission needed).
enum ProcessNative {
    static func snapshot() -> [Int32: ProcessTracker.Entry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var result: [Int32: ProcessTracker.Entry] = [:]
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            result[pid] = ProcessTracker.Entry(pid: pid, parent: Int32(info.pbi_ppid), exe: name.lowercased(),
                                               created: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
        }
        return result
    }

    /// The command line (KERN_PROCARGS2).
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Resident bytes and total CPU time (nanoseconds).
    static func usage(_ pid: Int32) -> (resident: UInt64, cpu: UInt64)? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return (info.pti_resident_size, info.pti_total_user + info.pti_total_system)
    }

    /// TCP ports the process listens on.
    static func listeningPorts(_ pid: Int32) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        var ports: [Int] = []
        for fd in fds.prefix(Int(max(0, filled)) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP, socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports.sorted()
    }

    static func created(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// SIGTERM, then SIGKILL two seconds later; a pid whose start time changed (reused) is never signalled.
    static func stop(_ members: [(pid: Int32, created: UInt64)]) {
        let alive = members.filter { created($0.pid) == $0.created }
        alive.reversed().forEach { kill($0.pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 2)
        alive.filter { created($0.pid) == $0.created }.forEach { kill($0.pid, SIGKILL) }
    }
}

/// A group as the views show it, measured.
struct AgentProcessGroup {
    var group: ProcessTracker.Group
    var memory: UInt64
    var cpu: Double?
    var ports: [Int]

    var summary: String {
        var parts = [group.members.count == 1 ? "1 process" : "\(group.members.count) processes"]
        if memory > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)) }
        if let cpu, cpu >= 1 { parts.append("\(Int(cpu.rounded()))% CPU") }
        parts += ports.map { ":\($0)" }
        return parts.joined(separator: " · ")
    }
}
