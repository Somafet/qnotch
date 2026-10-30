import Foundation
import CryptoKit

/// Fixed command catalog: no API accepts arbitrary event properties or user content.
public enum AnalyticsCatalog {
    public static let actions: [String: Set<String>] = [
        "shell": ["open_panel", "close_panel", "select_tab", "open_settings", "quit", "restart", "toggle_pin", "toggle_edit", "game_mode", "move_notch", "resize_card", "reorder_cards", "reorder_tabs", "check_updates"],
        "onboarding": ["next", "back", "skip", "finish", "change_feature", "change_login"],
        "settings": ["change_feature", "change", "setup_export", "setup_check", "setup_apply", "choose_photo", "remove_photo", "open_login_items", "choose_sound", "preview_sound"],
        "pomodoro": ["start", "pause", "reset", "set_duration"],
        "media": ["play_pause", "next", "previous", "select_session", "seek"],
        "clipboard": ["copy", "pin", "remove", "clear"],
        "notes": ["save"],
        "files": ["select", "add", "open", "reveal", "export", "clear", "remove", "share_start", "share_stop", "copy_path", "quick_look", "choose_files"],
        "search": ["submit", "run_result"],
        "github": ["connect", "disconnect", "refresh", "cancel_connect", "open_authorization", "test_connection"],
        "ai": ["launch", "set_slot", "add_app", "remove_app", "select_account", "rename_account", "refresh", "scan"],
        "agents": ["show", "dismiss", "stop_process", "connect", "disconnect"],
        "notifications": ["reveal_token", "copy_token", "invoke", "dismiss", "clear", "toggle_mute", "send_test", "renew_token"],
        "scheduled": ["pause", "resume", "remove", "reveal", "refresh"],
        "weather": ["select_place", "search", "open_forecast", "refresh"],
        "volume": ["set_volume", "toggle_mute"],
        "color_picker": ["pick", "copy"],
        "terminal": ["copy", "paste", "submit"]
    ]
    public static let targets: Set<String> = ["notifications_http_port","agents_show_cost", "agents_sound_done", "agents_sound_needs_you", "ai_claude", "ai_codex", "ai_refresh_minutes", "notifications_http_enabled", "notifications_open_on_error", "notifications_quiet_during_calls", "notifications_retention_days", "notifications_sound", "notifications_toast_seconds", "stats_battery", "stats_clock", "stats_cpu", "stats_gpu", "stats_memory", "stats_network", "weather_show_in_pill", "weather_units", "home", "media", "clipboard", "ai", "agents", "notes", "files", "notifications", "scheduled", "search", "terminal", "pomodoro", "color_picker", "stats", "capture", "weather", "display", "menu_bar_icon", "hover_delay", "close_delay", "hover_opens_segment", "pinned", "accent", "reduce_motion", "profile_name", "profile_photo", "card_visibility", "tab_visibility", "notch_visibility", "hotkey", "sound", "login", "beta_updates", "automatic_updates", "automatic_install", "game_mode", "game_auto_detect", "game_any_fullscreen", "game_opacity", "game_segment", "game_always", "game_never", "timer_sound", "timer_open_when_done", "clipboard_history", "telemetry"]
    public static let surfaces: Set<String> = ["ui", "hotkey", "cli", "tray", "onboarding"]
    public static func accepts(module: String, action: String, surface: String) -> Bool {
        actions[module]?.contains(action) == true && surfaces.contains(surface)
    }
}

public struct AnalyticsConfiguration: Decodable {
    public let key: String
    public let host: String
    public init(key: String, host: String = "https://eu.i.posthog.com") { self.key = key; self.host = host }
    public var endpoint: URL? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url.appendingPathComponent("batch/")
    }
}

public struct AnalyticsIdentity {
    public let distinctID: String, installID: String, source: String
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Called only after consent/configuration checks and on the first explicit action.
    public static func resolve(directory: URL, environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AnalyticsIdentity? {
        let file = directory.appendingPathComponent("analytics-install-id")
        let install: String
        if let value = try? String(contentsOf: file, encoding: .utf8), UUID(uuidString: value) != nil { install = value }
        else {
            install = UUID().uuidString.lowercased()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(install.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { return nil }
        }
        func read(_ url: URL) -> [String: Any]? {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let account = (read(codex.appendingPathComponent("auth.json"))?["tokens"] as? [String: Any])?["account_id"] as? String
        let claude = read(home.appendingPathComponent(".claude.json"))?["userID"] as? String
        let selected = account.flatMap { $0.isEmpty ? nil : $0 } ?? claude.flatMap { $0.isEmpty ? nil : $0 }
        return AnalyticsIdentity(distinctID: hash(selected ?? install), installID: hash(install), source: account?.isEmpty == false ? "codex" : claude?.isEmpty == false ? "claude" : "anonymous")
    }
}

private final class AnalyticsNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Main-thread owned, memory-only bounded queue. Timers exist only while work is buffered.
public final class ProductAnalytics {
    private struct Pending { let event: [String: Any]; let created: Date; var attempts: Int }
    private let configuration: AnalyticsConfiguration
    private let identityProvider: () -> AnalyticsIdentity?
    private let session: URLSession
    private let version: String
    private var identity: AnalyticsIdentity?
    private var resolving = false
    private var waiting: [(String, String, String, String?, Bool?)] = []
    private var flushRequested = false
    private var pending: [Pending] = []
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var generation = 0
    private var retryAfter: Date?
    public private(set) var enabled: Bool
    public var bufferedCount: Int { pending.count + waiting.count }
    public init(configuration: AnalyticsConfiguration, enabled: Bool, version: String,
                session: URLSession? = nil, identity: @escaping () -> AnalyticsIdentity?) {
        self.configuration = configuration; self.enabled = enabled; self.version = version
        let transport = URLSessionConfiguration.ephemeral
        transport.httpShouldSetCookies = false; transport.urlCache = nil; transport.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: transport, delegate: AnalyticsNoRedirect(), delegateQueue: nil); self.identityProvider = identity
    }
    public func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            generation += 1; timer?.invalidate(); timer = nil; task?.cancel(); task = nil
            pending.removeAll(); waiting.removeAll(); identity = nil; retryAfter = nil; resolving = false; flushRequested = false
        }
    }
    public func capture(module: String, action: String, surface: String = "ui", target: String? = nil, enabled: Bool? = nil) {
        guard self.enabled, configuration.endpoint != nil, AnalyticsCatalog.accepts(module: module, action: action, surface: surface) else { return }
        if let target, !AnalyticsCatalog.targets.contains(target) { return }
        guard let identity else {
            if waiting.count == 1000 { waiting.removeFirst() }
            waiting.append((module, action, surface, target, enabled))
            if !resolving {
                resolving = true
                let current = generation, provider = identityProvider
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let resolved = provider()
                    DispatchQueue.main.async {
                        guard let self, self.enabled, self.generation == current else { return }
                        self.resolving = false; self.identity = resolved
                        let actions = self.waiting; self.waiting.removeAll()
                        guard resolved != nil else { self.flushRequested = false; return }
                        for (module, action, surface, target, enabled) in actions { self.capture(module: module, action: action, surface: surface, target: target, enabled: enabled) }
                        if self.flushRequested { self.flushRequested = false; self.flush() }
                    }
                }
            }
            return
        }
        guard identity.distinctID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              identity.installID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              ["codex", "claude", "anonymous"].contains(identity.source) else { return }
        var properties: [String: Any] = ["install_id": identity.installID, "identity_source": identity.source,
                "schema_version": 1, "platform": "macos", "app_version": version,
                "module": module, "action": action, "surface": surface, "outcome": "requested", "$process_person_profile": false]
        if let target { properties["target"] = target }
        if let enabled { properties["enabled"] = enabled }
        let event: [String: Any] = ["event": "qnotch_action", "uuid": UUID().uuidString.lowercased(),
            "distinct_id": identity.distinctID, "timestamp": ISO8601DateFormatter().string(from: Date()), "properties": properties]
        if pending.count == 1000 { pending.removeFirst() }
        pending.append(Pending(event: event, created: Date(), attempts: 0))
        if pending.count >= 20, retryAfter == nil { flush() } else { schedule(10) }
    }
    private func schedule(_ delay: TimeInterval) {
        guard timer == nil, task == nil, !pending.isEmpty, enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, retryAfter?.timeIntervalSinceNow ?? 0), repeats: false) { [weak self] _ in
            self?.timer = nil; self?.flush()
        }
    }
    public func flush() {
        guard enabled, task == nil, let endpoint = configuration.endpoint else { return }
        if resolving { flushRequested = true; return }
        if let retryAfter, retryAfter > Date() { schedule(retryAfter.timeIntervalSinceNow); return }
        retryAfter = nil
        timer?.invalidate(); timer = nil
        pending.removeAll { Date().timeIntervalSince($0.created) >= 1800 }
        guard !pending.isEmpty else { return }
        let count = min(20, pending.count)
        var batch = Array(pending.prefix(count)); pending.removeFirst(count)
        for i in batch.indices { batch[i].attempts += 1 }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": configuration.key, "batch": batch.map { $0.event }])
        let current = generation
        task = session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.enabled, current == self.generation else { return }
                self.task = nil
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let retry = error != nil || (!(200...299).contains(status) && ![400, 401, 413].contains(status))
                if retry {
                    self.pending.insert(contentsOf: batch.filter { Date().timeIntervalSince($0.created) < 1800 }, at: 0)
                    if self.pending.count > 1000 { self.pending.removeLast(self.pending.count - 1000) }
                }
                let cap = min(300.0, 2 * pow(2, Double(min(8, batch[0].attempts - 1))))
                let delay = retry ? Double.random(in: (cap / 2)...cap) : 10
                self.retryAfter = retry ? Date().addingTimeInterval(delay) : nil
                if !retry && self.pending.count >= 20 { self.flush() } else { self.schedule(delay) }
            }
        }
        task?.resume()
    }
    deinit { timer?.invalidate(); task?.cancel(); session.invalidateAndCancel() }
}
