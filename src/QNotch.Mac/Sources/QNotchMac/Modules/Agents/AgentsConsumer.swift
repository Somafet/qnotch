import Foundation
import QNotchMacCore

extension AgentsModule {
    func consumerAgents(_ request: ConsumerRequest, identity: ConsumerIdentity) throws -> [String: Any] {
        guard board.sessions.count + consumerUsageCache.count <= 4096, consumerUsageCache.values.reduce(0, { $0 + $1.days.count }) <= 8192 else { throw ConsumerFailure("size_limit") }
        func provider(_ session: AgentSession) -> String { ["claude", "codex"].contains(session.agent) ? session.agent : "unknown" }
        func total(_ value: AgentUsage) -> [String: Any] {
            ["tokens": value.tokens, "estimated_usd": value.unpriced ? ConsumerJSON.null : value.cost as Any, "pricing_complete": !value.unpriced]
        }
        let sessions = board.sessions.map { session -> [String: Any] in
            let state: String
            switch session.status { case .ready: state = "ready"; case .working: state = "working"; case .needsYou: state = "needs_you"; case .done: state = "done" }
            var row: [String: Any] = ["session_id": identity.id("session:" + session.id), "provider": provider(session), "status": state,
                "since": ConsumerJSON.instant(session.since), "tracking_source": session.t3Thread == nil ? "hook" : "t3"]
            if request.details { row["title"] = ConsumerJSON.text(session.title); row["project"] = ConsumerJSON.text((session.cwd as NSString).lastPathComponent) }
            return row
        }
        let ids = Set(board.sessions.map(\.id)).union(consumerUsageCache.keys)
        let usage = ids.sorted().map { id -> [String: Any] in
            let session = board.sessions.first { $0.id == id }
            let p = session.map(provider) ?? "claude"
            let cache = consumerUsageCache[id]
            let status = p != "claude" ? "unsupported" : cache == nil ? "pending" : cache!.available ? "ok" : "unavailable"
            var row: [String: Any] = ["session_id": identity.id("session:" + id), "provider": p, "status": status,
                "scope": "observed_claude_transcripts_including_subagents", "timezone": TimeZone.current.identifier,
                "checked_at": ConsumerJSON.instant(cache?.checked), "total": ConsumerJSON.null, "days": []]
            if status == "ok", let cache {
                row["total"] = total(cache.days.values.reduce(AgentUsage(), +))
                row["days"] = cache.days.keys.sorted().map { ["day": $0, "usage": total(cache.days[$0]!)] as [String: Any] }
            }
            return row
        }
        return ["coverage": "Tracked hook and T3 sessions only; retained in-memory observed Claude transcript records, no historical or cross-restart completeness.",
                "tracking": ["hooks": socketStatus == "Starting" ? "initializing" : socketStatus.lowercased().contains("listen") ? "listening" : "unavailable", "t3": consumerT3Health],
                "sessions": sessions, "usage": usage]
    }
}
