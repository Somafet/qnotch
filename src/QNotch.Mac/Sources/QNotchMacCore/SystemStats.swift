import Foundation

/// Pure system-stat math and formatting (Windows StatsModule). Samplers feed raw counters in.
public enum SystemStats {
    /// CPU ticks summed over all cores.
    public struct Ticks: Equatable {
        public var busy: UInt64
        public var total: UInt64
        public init(busy: UInt64, total: UInt64) { self.busy = busy; self.total = total }
    }

    /// Busy share between two samples, 0...100; nil until there are two samples.
    public static func cpuPercent(from old: Ticks?, to new: Ticks) -> Double? {
        guard let old, new.total > old.total, new.busy >= old.busy else { return nil }
        return min(100, max(0, Double(new.busy - old.busy) / Double(new.total - old.total) * 100))
    }

    /// Bytes per second from two counter readings; 32-bit interface counters wrap.
    public static func rate(from old: UInt64, to new: UInt64, seconds: Double, wraps32: Bool = true) -> Double? {
        guard seconds > 0.05 else { return nil }
        let delta = new >= old ? new - old : wraps32 && old <= UInt64(UInt32.max) ? new + (UInt64(UInt32.max) + 1) - old : 0
        return Double(delta) / seconds
    }

    /// "820 KB/s" below 1 MB/s, "1.2 MB/s" above (decimal units, like Activity Monitor).
    public static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "--" }
        if value < 1_000_000 { return "\(Int((value / 1000).rounded())) KB/s" }
        return String(format: "%.1f MB/s", value / 1_000_000)
    }

    /// Compact form for the wings: "820K", "1.2M".
    public static func shortRate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "--" }
        if value < 1_000_000 { return "\(Int((value / 1000).rounded()))K" }
        return String(format: "%.1fM", value / 1_000_000)
    }

    /// "6.1/8.0 GB" in binary gigabytes, as macOS reports installed memory.
    public static func memoryText(used: UInt64, total: UInt64) -> String {
        let gib = 1_073_741_824.0
        return String(format: "%.1f/%.0f GB", Double(used) / gib, (Double(total) / gib).rounded())
    }

    public static func percentText(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "--" }

    /// Physical and Wi-Fi interfaces only: no loopback, VPN tunnels, AWDL/Low Latency WLAN,
    /// bridges, or virtual adapters, so traffic is not counted twice.
    public static func countsInterface(_ name: String, loopback: Bool) -> Bool {
        guard !loopback else { return false }
        let skipped = ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "ipsec", "vmenet", "feth", "pktap"]
        return !skipped.contains { name.hasPrefix($0) }
    }

    /// SF Symbol for a battery level, charging state included.
    public static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Which stats show beside the notch. Menu-bar duplicates (battery, clock) are off by default.
public struct StatsSettings: Codable, Equatable {
    public var wingCPU = true
    public var wingMemory = true
    public var wingGPU = false
    public var wingNetwork = false
    public var wingBattery = false
    public var wingClock = false
    public init() {}

    public var anyWing: Bool { wingCPU || wingMemory || wingGPU || wingNetwork || wingBattery || wingClock }
    public var sampledWing: Bool { wingCPU || wingMemory || wingGPU || wingNetwork }

    private enum CodingKeys: String, CodingKey { case wingCPU, wingMemory, wingGPU, wingNetwork, wingBattery, wingClock }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StatsSettings()
        wingCPU = c.value(.wingCPU, d.wingCPU); wingMemory = c.value(.wingMemory, d.wingMemory); wingGPU = c.value(.wingGPU, d.wingGPU)
        wingNetwork = c.value(.wingNetwork, d.wingNetwork); wingBattery = c.value(.wingBattery, d.wingBattery); wingClock = c.value(.wingClock, d.wingClock)
    }
}
