import Foundation

/// What agents started through their shell tools (Windows AgentProcesses): dev servers, watchers,
/// test runners. Fed a process snapshot; remembers what it saw, so a group whose shell or agent
/// ended (macOS reparents it to launchd) is still known, and shown as left running.
public final class ProcessTracker {
    public struct Entry: Equatable {
        public var pid: Int32
        public var parent: Int32
        /// Lowercased executable name.
        public var exe: String
        /// Start time in microseconds since 1970; identifies the process across pid reuse.
        public var created: UInt64
        public init(pid: Int32, parent: Int32, exe: String, created: UInt64) { self.pid = pid; self.parent = parent; self.exe = exe; self.created = created }
    }

    public struct Group: Equatable {
        public var root: Int32
        public var session: String
        public var project: String
        public var label: String
        public var members: [(pid: Int32, created: UInt64)]
        public var leftRunning: Bool
        public static func == (a: Group, b: Group) -> Bool {
            a.root == b.root && a.session == b.session && a.label == b.label && a.leftRunning == b.leftRunning
                && a.members.map(\.pid) == b.members.map(\.pid)
        }
    }

    final class Node {
        var parent: Int32 = 0
        var parentCreated: UInt64 = 0
        var root: Int32 = 0
        var agentPid: Int32 = 0
        var created: UInt64 = 0
        var exe = ""
        var label = ""
        var agent = false
        var dead = false
        var project = ""
    }

    static let toolShells: Set<String> = ["bash", "sh", "zsh", "dash", "fish"]
    /// Younger processes are skipped: most tool commands finish within a few seconds.
    static let minAge: UInt64 = 3_000_000
    private var nodes: [Int32: Node] = [:]

    public init() {}

    /// `sessions`: (session id, project, agent pid). `label` gives a root's command line.
    public func walk(_ snapshot: [Int32: Entry], sessions: [(id: String, project: String, pid: Int32)], now: UInt64, label: (Int32) -> String) -> [Group] {
        var children: [Int32: [Int32]] = [:]
        for entry in snapshot.values { children[entry.parent, default: []].append(entry.pid) }
        var byAgent: [Int32: (id: String, project: String)] = [:]
        for session in sessions { byAgent[session.pid] = (session.id, session.project) }

        // The agent keeps its process across /clear and /resume: only the session on top changes.
        for (pid, info) in byAgent {
            guard let entry = snapshot[pid] else { continue }
            if let node = nodes[pid], node.created == entry.created { node.project = info.project; continue }
            let node = Node()
            node.agent = true; node.agentPid = pid; node.created = entry.created; node.project = info.project; node.exe = entry.exe
            nodes[pid] = node
        }

        // New children below the living, and below the newly dead once (after that the pid may be reused).
        var queue: [Int32] = []
        for (pid, node) in nodes {
            if let entry = snapshot[pid] {
                if entry.created != node.created { nodes[pid] = nil; continue } // reused: ours ended
                queue.append(pid)
            } else if !node.dead {
                node.dead = true
                queue.append(pid)
            }
        }
        while let pid = queue.popLast() {
            guard let parent = nodes[pid] else { continue }
            for child in children[pid] ?? [] where nodes[child] == nil {
                guard let entry = snapshot[child] else { continue }
                // Only what the agent ran through its shell tools; MCP servers and helpers are its own business.
                if parent.agent && !Self.toolShells.contains(entry.exe) { continue }
                guard entry.created >= parent.created else { continue }
                let node = Node()
                node.parent = pid; node.parentCreated = parent.created; node.agentPid = parent.agentPid
                node.created = entry.created; node.exe = entry.exe
                node.root = parent.agent || (parent.root == 0 && Self.toolShells.contains(entry.exe)) ? 0 : parent.root == 0 ? child : parent.root
                if node.root == child { node.label = label(child) }
                nodes[child] = node
                queue.append(child)
            }
        }

        // Keep the living and the dead that still lead to the living.
        var keep = Set<ObjectIdentifier>()
        for node in nodes.values where !node.dead {
            var current: Node? = node
            while let x = current, keep.insert(ObjectIdentifier(x)).inserted { current = parentOf(x) }
        }
        nodes = nodes.filter { keep.contains(ObjectIdentifier($0.value)) }

        var groups: [Group] = []
        let roots = Dictionary(grouping: nodes.filter { $0.value.root != 0 && !$0.value.dead }, by: { $0.value.root })
        for (root, members) in roots {
            let top = nodes[root] ?? members.min { $0.value.created < $1.value.created }!.value
            guard now >= top.created + Self.minAge else { continue }
            // Its shell or its agent is gone: nobody will stop it.
            var orphan = false
            var current = top
            while !current.agent, !orphan {
                if current.dead { orphan = true } else if let up = parentOf(current) { current = up } else { orphan = true }
            }
            orphan = orphan || current.dead
            let agentInfo = byAgent[top.agentPid]
            if !orphan, agentInfo == nil { continue } // its row was cleared while the agent runs on
            groups.append(Group(root: root, session: orphan ? "" : agentInfo!.id, project: agentInfo?.project ?? nodes[top.agentPid]?.project ?? "",
                                label: top.label.isEmpty ? top.exe : top.label,
                                members: members.map { ($0.key, $0.value.created) }.sorted { $0.created < $1.created }, leftRunning: orphan))
        }
        return groups.sorted { ($0.leftRunning ? 1 : 0, $0.root) < ($1.leftRunning ? 1 : 0, $1.root) }
    }

    private func parentOf(_ node: Node) -> Node? {
        guard node.parent != 0, let parent = nodes[node.parent], parent.created == node.parentCreated else { return nil }
        return parent
    }

    /// "npm run dev" from "/usr/local/bin/node /usr/local/lib/node_modules/npm/bin/npm-cli.js run dev" style command lines.
    public static func label(_ arguments: [String]) -> String {
        guard let first = arguments.first else { return "" }
        let name = URL(fileURLWithPath: first).lastPathComponent
        let rest = arguments.dropFirst().map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
        return String(([name] + rest).joined(separator: " ").prefix(80))
    }
}
