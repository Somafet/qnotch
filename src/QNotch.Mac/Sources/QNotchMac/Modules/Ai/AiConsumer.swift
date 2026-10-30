import Foundation
import QNotchMacCore

extension AiModule {
    func consumerUsage(_ request: ConsumerRequest, identity: ConsumerIdentity, now: Date = Date()) throws -> [String: Any] {
        guard accounts.count <= 1024 else { throw ConsumerFailure("size_limit") }
        var entries: [[String: Any]] = []
        for account in accounts {
            entries.append(Self.consumerAccount(provider: "claude", id: identity.id("claude:" + account.path), label: name(of: account),
                enabled: settings.claude, result: claudeResults[account.path], checked: quotaChecked[account.path], bankedChecked: bankedChecked[account.path], refreshing: refreshing, details: request.details, now: now))
        }
        entries.append(Self.consumerAccount(provider: "codex", id: identity.id("codex:" + (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")), label: "Codex", enabled: settings.codex, result: codex.result, checked: quotaChecked["codex"], refreshing: refreshing, details: request.details, now: now))
        if let provider = request.provider { entries = entries.filter { $0["provider"] as? String == provider } }
        if let account = request.account {
            entries = entries.filter { $0["account_id"] as? String == account }
            guard !entries.isEmpty else { throw ConsumerFailure("invalid_arguments") }
        }
        return ["accounts": entries]
    }

    static func consumerAccount(provider: String, id: String, label: String, enabled: Bool, result: UsageResult?, checked: Date?, bankedChecked: Date? = nil, refreshing: Bool, details: Bool, now: Date) -> [String: Any] {
        let null = ConsumerJSON.null
        var object: [String: Any] = ["provider": provider, "account_id": id, "status": enabled ? "pending" : "disabled", "plan": null,
            "refreshing": enabled && refreshing, "checked_at": enabled ? ConsumerJSON.instant(checked) : null, "observed_at": null,
            "source": provider == "claude" ? "provider_api" : "session_log", "error": null, "windows": []]
        var banked: [String: Any] = ["status": enabled && provider == "codex" ? "unsupported" : "unknown", "count": null, "next_expires_at": null,
            "source": provider == "codex" ? "codex_app_server" : "provider_api", "checked_at": enabled ? ConsumerJSON.instant(bankedChecked) : null]
        if enabled {
            switch result {
            case .ok(let windows, let plan, let observed, let credits)?:
                let valid = windows.filter { ($0.resetsAt.map { $0 > now } ?? true) && $0.usedPercent.isFinite && $0.id != nil }
                if !valid.isEmpty {
                    object["status"] = "ok"; object["plan"] = plan ?? null as Any; object["observed_at"] = ConsumerJSON.instant(observed == Date.distantPast ? nil : observed)
                    object["windows"] = valid.map { w -> [String: Any] in ["id": w.id!, "label": w.label, "duration_seconds": w.durationSeconds ?? null as Any, "used_percent": w.usedPercent, "resets_at": ConsumerJSON.instant(w.resetsAt)] }
                } else { object["status"] = "unavailable"; object["error"] = ["code": "expired_reading", "message": "No unexpired quota windows remain."] }
                if let credits, credits.expiresAt.map({ $0 > now }) ?? true {
                    banked["status"] = credits.count > 0 ? "available" : "none"; banked["count"] = credits.count
                    banked["next_expires_at"] = ConsumerJSON.instant(credits.expiresAt)
                    banked["checked_at"] = ConsumerJSON.instant(bankedChecked)
                }
            case .unavailable?: object["status"] = "unavailable"; object["error"] = ["code": "provider_error", "message": "Quota reading is unavailable."]
            case nil: break
            }
        }
        object["banked_resets"] = banked
        if details { object["label"] = ConsumerJSON.text(label) }
        return object
    }
}
