import Foundation

/// One hard limit of `--measure` (spec/diagnostics.md, Measure): a maximum the measured value may reach.
public struct PerformanceLimit: Equatable {
    public let name: String
    public let limit: Double
    public let measured: Double
    public init(name: String, limit: Double, measured: Double) { self.name = name; self.limit = limit; self.measured = measured }
    public var ok: Bool { measured.isFinite && measured <= limit }
    public var json: [String: Any] { ["name": name, "limit": limit, "measured": measured, "ok": ok] }
}

/// The Mac's hard limits for a collapsed idle interval (docs/macos/performance.md, Targets and
/// limits): CPU at or below 0.1% of one core, no app draw callbacks, resident memory up to 80 MiB.
/// Startup is recorded but not a limit: no consistent cold-launch target is established.
public enum PerformanceLimits {
    public static let cpuPercentOneCore = 0.1
    public static let appDrawCallbacks = 0.0
    public static let residentBytes = 80.0 * 1024 * 1024

    /// The limits for one interval, named after its keys; `prefix` names an interval nested under its own key.
    public static func check(cpuPercent: Double, drawCallbacks: Int, residentBytes: UInt64, prefix: String = "") -> [PerformanceLimit] {
        [PerformanceLimit(name: prefix + "cpu_percent_one_core", limit: cpuPercentOneCore, measured: cpuPercent),
         PerformanceLimit(name: prefix + "app_draw_callbacks_delta", limit: appDrawCallbacks, measured: Double(drawCallbacks)),
         PerformanceLimit(name: prefix + "resident_bytes_end", limit: Self.residentBytes, measured: Double(residentBytes))]
    }
}
