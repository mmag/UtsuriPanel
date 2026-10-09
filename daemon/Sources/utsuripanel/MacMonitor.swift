import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration

struct MacMessage: Encodable {
    struct Memory: Encodable {
        let used: Double
        let total: Double
        /// normal, warning or critical.
        let pressure: String
    }
    struct Net: Encodable {
        /// Bytes per second, over the Ethernet and Wi-Fi interfaces.
        let rx, tx: Double
        let rxHistory, txHistory: [Double]
    }
    struct Disk: Encodable {
        let total, free: Double
    }
    struct Battery: Encodable {
        let percent: Double
        let charging: Bool
        let onAC: Bool
    }

    let type = "mac"
    let name: String
    /// Percent of all cores.
    let cpu: Double
    let cpuHistory: [Double]
    let cores: [Double]
    /// "e" or "p" per core.
    let coreKinds: [String]
    let memory: Memory
    let net: Net
    let disk: Disk
    let load: [Double]
    let uptime: Double
    let battery: Battery?
}

/// This Mac's load, every 2 s.
final class MacMonitor {
    private let hub: Hub
    private let queue = DispatchQueue(label: "utsuripanel.mac")
    private var timer: DispatchSourceTimer?
    private let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    private var previousTicks: [[UInt32]] = []
    private var previousBytes: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var previousTime = Date()
    private var cpuHistory: [Double] = []
    private var rxHistory: [Double] = []
    private var txHistory: [Double] = []

    init(hub: Hub) {
        self.hub = hub
    }

    func start() {
        timer = repeating(every: 2, on: queue) { [self] in sample() }
    }

    private func sample() {
        let now = Date()
        let elapsed = now.timeIntervalSince(previousTime)
        previousTime = now
        let cores = coreUsage()
        let cpu = cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
        let (rx, tx) = networkRates(elapsed: elapsed)
        append(cpu, to: &cpuHistory)
        append(rx, to: &rxHistory)
        append(tx, to: &txHistory)
        let efficiency = sysctlInt("hw.perflevel1.logicalcpu")
        hub.publish("mac", MacMessage(
            name: name, cpu: round1(cpu), cpuHistory: cpuHistory, cores: cores.map(round1),
            // Apple silicon numbers its efficiency cores first.
            coreKinds: cores.indices.map { $0 < efficiency ? "e" : "p" },
            memory: memory(), net: .init(rx: rx, tx: tx, rxHistory: rxHistory, txHistory: txHistory),
            disk: disk(), load: loadAverage(), uptime: uptime(), battery: battery()))
    }

    /// Busy percent per core since the last sample.
    private func coreUsage() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE]
        let ticks = (0..<Int(cpuCount)).map { cpu in
            states.map { UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + Int($0)]) }
        }
        defer { previousTicks = ticks }
        return ticks.indices.map { cpu in
            let before = previousTicks.count == ticks.count ? previousTicks[cpu] : [0, 0, 0, 0]
            let delta = zip(ticks[cpu], before).map { Double($0 &- $1) }
            let all = delta.reduce(0, +)
            return all > 0 ? (all - delta[2]) / all * 100 : 0
        }
    }

    /// Used as Activity Monitor counts it: app memory, wired and compressed.
    private func memory() -> MacMessage.Memory {
        let total = Double(sysctlInt("hw.memsize"))
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let level = sysctlInt("kern.memorystatus_vm_pressure_level")
        let pressure = level >= 4 ? "critical" : level >= 2 ? "warning" : "normal"
        guard result == KERN_SUCCESS else { return .init(used: 0, total: total, pressure: pressure) }
        let app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let pages = app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return .init(used: Double(pages) * Double(vm_kernel_page_size), total: total, pressure: pressure)
    }

    private func networkRates(elapsed: Double) -> (Double, Double) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var rx = 0.0, tx = 0.0
        var bytes: [String: (rx: UInt32, tx: UInt32)] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            bytes[name] = (counters.ifi_ibytes, counters.ifi_obytes)
            // 32-bit counters: the wrapping subtraction survives a wrap.
            if let before = previousBytes[name], elapsed > 0 {
                rx += Double(counters.ifi_ibytes &- before.rx) / elapsed
                tx += Double(counters.ifi_obytes &- before.tx) / elapsed
            }
        }
        previousBytes = bytes
        return (rx, tx)
    }

    private func disk() -> MacMessage.Disk {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return .init(total: Double(values?.volumeTotalCapacity ?? 0), free: Double(values?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    private func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads
    }

    private func uptime() -> Double {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    private func battery() -> MacMessage.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return .init(percent: Double(current) / Double(maximum) * 100,
                         charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                         onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

func sysctlInt(_ name: String) -> Int {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
    return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}
