import Darwin
import Foundation
import IOKit
import IOKit.ps
import QNotchMacCore

/// One reading of the system. Optional values are unavailable ("n/a"), never a fake 0.
struct StatsSample: Equatable {
    var cpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var gpu: Double?
    var download: Double?
    var upload: Double?
}

/// Reads counters with public Mach, BSD and IOKit calls. Runs on the module's utility queue.
final class SystemSampler {
    private var lastTicks: SystemStats.Ticks?
    /// Last computed values, reused when two samples are too close together to measure a delta.
    private var lastCPU: Double?
    private var lastRates: (download: Double, upload: Double)?
    private var lastNet: (time: TimeInterval, received: UInt64, sent: UInt64)?
    private var gpuFailures = 0
    private let pageSize = UInt64(vm_kernel_page_size)
    let memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// Primes the delta counters, so the first sample already has a CPU share and network rate.
    init() {
        lastTicks = cpuTicks()
        if let net = networkBytes() { lastNet = (ProcessInfo.processInfo.systemUptime, net.received, net.sent) }
    }

    func sample(gpu wantsGPU: Bool) -> StatsSample {
        var result = StatsSample()
        if let ticks = cpuTicks() {
            if let cpu = SystemStats.cpuPercent(from: lastTicks, to: ticks) {
                lastCPU = cpu
                lastTicks = ticks
            } else if lastTicks == nil { lastTicks = ticks }
            // Too close to the previous sample: keep the older baseline and the last value.
            result.cpu = lastCPU
        }
        result.memoryTotal = memoryTotal
        result.memoryUsed = memoryUsed() ?? 0
        if let net = networkBytes() {
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastNet, let down = SystemStats.rate(from: last.received, to: net.received, seconds: now - last.time),
               let up = SystemStats.rate(from: last.sent, to: net.sent, seconds: now - last.time) {
                lastRates = (down, up)
                lastNet = (now, net.received, net.sent)
            } else if lastNet == nil { lastNet = (now, net.received, net.sent) }
            result.download = lastRates?.download
            result.upload = lastRates?.upload
        }
        // Gives up for the session after repeated failures (Windows GpuSampler does the same).
        if wantsGPU, gpuFailures < 5 {
            result.gpu = gpuUtilization()
            gpuFailures = result.gpu == nil ? gpuFailures + 1 : 0
        }
        return result
    }

    var gpuAvailable: Bool { gpuFailures < 5 }

    /// Sum of user, system and nice ticks over all cores (`host_processor_info`).
    private func cpuTicks() -> SystemStats.Ticks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return SystemStats.Ticks(busy: busy, total: total)
    }

    /// Activity Monitor's "Memory Used": app memory (internal minus purgeable) + wired + compressed.
    private func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    /// Byte counters of physical interfaces that are up (`getifaddrs`, AF_LINK `if_data`).
    private func networkBytes() -> (received: UInt64, sent: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let raw = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard SystemStats.countsInterface(name, loopback: flags & IFF_LOOPBACK != 0) else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }
        return (received, sent)
    }

    /// The busiest GPU's "Device Utilization %" from IOAccelerator performance statistics.
    private func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber else { continue }
            best = max(best ?? 0, min(100, max(0, value.doubleValue)))
        }
        return best
    }
}

/// Battery level and charging state, pushed by IOKit power-source notifications (no polling).
final class BatteryWatch {
    struct State: Equatable { var percent: Int; var charging: Bool }
    private(set) var state: State?
    private var source: CFRunLoopSource?
    var changed: (() -> Void)?

    /// Machines without a battery report nothing and the battery segment stays hidden.
    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryWatch>.fromOpaque(context).takeUnretainedValue().read()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        read()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    deinit { stop() }

    private func read() {
        var next: State?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                let charging = description[kIOPSIsChargingKey] as? Bool ?? false
                next = State(percent: Int((Double(current) / Double(max) * 100).rounded()), charging: charging)
            }
        }
        guard next != state else { return }
        state = next
        changed?()
    }
}
