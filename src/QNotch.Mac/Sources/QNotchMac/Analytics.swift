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
    static func setting(_ target: String, enabled: Bool? = nil) { record("settings", "change", target: target, enabled: enabled) }
    static func consent(_ enabled: Bool) { client?.setEnabled(enabled && !forcedOff) }
    static func withSurface(_ value: String, _ body: () -> Void) {
        let previous = surface; surface = value; defer { surface = previous }; body()
    }
}
