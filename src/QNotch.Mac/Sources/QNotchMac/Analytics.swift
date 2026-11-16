import Foundation
import QNotchMacCore

/// Explicit command recording; inert until a normal configured app boot enables it.
enum Analytics {
    static var client: ProductAnalytics?
    static var surface = "ui"
    static var suppressed = false
    static var forcedOff: Bool { ProcessInfo.processInfo.environment["QNOTCH_TELEMETRY_ENABLED"]?.lowercased() == "false" }
    static func configure(directory: URL, consent: Bool) {
        guard !Runtime.diagnostics else { return }
        let environment = ProcessInfo.processInfo.environment
        let resourceBundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("QNotchMac_QNotchMac.bundle")) }
            ?? Bundle(url: Bundle.main.bundleURL.appendingPathComponent("QNotchMac_QNotchMac.bundle"))
        let embedded = (resourceBundle ?? Bundle.main).url(forResource: "analytics-config", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(AnalyticsConfiguration.self, from: $0) }
        let config = AnalyticsConfiguration(key: environment["QNOTCH_POSTHOG_KEY"] ?? embedded?.key ?? "",
                                            host: environment["QNOTCH_POSTHOG_HOST"] ?? embedded?.host ?? "https://eu.i.posthog.com")
        guard config.endpoint != nil else { return }
        client = ProductAnalytics(configuration: config, enabled: consent && !forcedOff,
                                  version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") {
            AnalyticsIdentity.resolve(directory: directory, environment: environment)
        }
    }
    static func record(_ module: String, _ action: String, target: String? = nil, enabled: Bool? = nil) {
        guard !Runtime.diagnostics, !suppressed else { return }
        client?.capture(module: module, action: action, surface: module == "onboarding" ? "onboarding" : surface, target: target, enabled: enabled)
    }
    static func canonical(_ id: String) -> String {
        ["timer": "pomodoro", "filetray": "files", "note": "notes", "colorpicker": "color_picker"][id] ?? id
    }
    private static var gestures = AnalyticsGestures()
    /// A continuous control (slider drag, wheel spin, arrow-key run) records once per gesture, not per step.
    static func recordGesture(_ module: String, _ action: String) {
        guard gestures.starts(module + "/" + action, at: ProcessInfo.processInfo.systemUptime) else { return }
        record(module, action)
    }

    // MARK: Lifecycle (qnotch_active): once per launch and once per UTC day while running.

    private static var launchedOnce = false
    private static var runState: URL?
    private static var dayTimer: Timer?
    private static var modules: () -> [String] = { [] }
    /// Release builds carry QNotchReleaseBuild in Info.plist (scripts/macos/build.sh); everything else is a source build.
    static var channel: String { Bundle.main.object(forInfoDictionaryKey: "QNotchReleaseBuild") as? Bool == true ? "direct" : "source" }

    /// Called when the modules start (after the first-run tour, if any). Later calls do nothing.
    static func launched(directory: URL, modules: @escaping () -> [String]) {
        guard !Runtime.diagnostics, !launchedOnce, let client else { return }
        launchedOnce = true
        self.modules = modules
        if client.enabled {
            let file = directory.appendingPathComponent("analytics-run-state")
            let previous = AnalyticsRunState.previousExit(at: file)
            if AnalyticsRunState.mark(file, "running") { runState = file }
            client.lifecycle(reason: "launch", channel: channel, modules: modules(), previousExit: previous)
        }
        scheduleDay()
    }

    /// A normal quit: the next launch reports previous_exit clean.
    static func exited() {
        dayTimer?.invalidate(); dayTimer = nil
        if let runState { AnalyticsRunState.mark(runState, "exited") }
        runState = nil
    }

    /// One one-shot timer to just after the next UTC midnight; it re-arms itself. Sleep delays it until wake.
    private static func scheduleDay() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnight = utc.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else { return }
        dayTimer?.invalidate()
        dayTimer = Timer.scheduledTimer(withTimeInterval: max(60, midnight.timeIntervalSinceNow + 5), repeats: false) { _ in
            Analytics.dayTimer = nil
            Analytics.client?.lifecycle(reason: "day", channel: Analytics.channel, modules: Analytics.modules())
            Analytics.scheduleDay()
        }
        dayTimer?.tolerance = 60
    }

    static func setting(_ target: String, enabled: Bool? = nil) { record("settings", "change", target: target, enabled: enabled) }
    static func consent(_ enabled: Bool) { client?.setEnabled(enabled && !forcedOff) }
    static func withSurface(_ value: String, _ body: () -> Void) {
        let previous = surface; surface = value; defer { surface = previous }; body()
    }
}
