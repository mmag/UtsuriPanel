import Foundation

struct NodeMessage: Encodable {
    struct Temps: Encodable {
        let package: Double?
        let cores: [Double]
    }
    struct Memory: Encodable {
        let total, available: Double
    }
    struct Raid: Encodable {
        let device: String
        /// active, check, resync, recovering or inactive.
        let state: String
        let active, failed, spare, required: Int
        /// 0...1 while resyncing or recovering.
        let synced: Double
    }
    struct Filesystem: Encodable {
        let mount, device: String
        let size, available: Double
        let raid: String?
    }
    struct Net: Encodable {
        let device: String
        let rx, tx: Double
    }

    let type = "node"
    let name, host: String
    var ok: Bool
    var error: String?
    let os: String?
    let cpu: Double?
    let cpuHistory: [Double]
    let cores: [Double]
    let temps: Temps
    let tempHistory: [Double]
    let load: [Double]
    let memory: Memory?
    let uptime: Double?
    let raid: [Raid]
    let filesystems: [Filesystem]
    let net: Net?
}

/// A Linux server's node_exporter, every 5 s.
final class NodeMonitor {
    private let source: Config.Source
    private let hub: Hub
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var previousCPU: [String: (total: Double, idle: Double)] = [:]
    private var previousNet: (rx: Double, tx: Double, time: Date)?
    private var cpuHistory: [Double] = []
    private var tempHistory: [Double] = []
    private var last: NodeMessage?

    init(source: Config.Source, hub: Hub) {
        self.source = source
        self.hub = hub
        queue = DispatchQueue(label: "utsuripanel.node.\(source.name)")
    }

    func start() {
        timer = repeating(every: 5, on: queue) { [self] in fetch() }
    }

    private func fetch() {
        URLSession.shared.dataTask(with: URLRequest(url: source.url, timeoutInterval: 4)) { [self] data, response, error in
            queue.async { [self] in
                if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                    update(Metrics(String(decoding: data, as: UTF8.self)))
                } else {
                    failed(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
            }
        }.resume()
    }

    private func failed(_ reason: String) {
        if last?.ok != false { log("\(source.name): \(reason)") }
        let name = source.name
        Status.update { $0.nodes[name] = .init(ok: false) }
        guard var message = last else { return }
        message.ok = false
        message.error = reason
        last = message
        hub.publish("node:\(source.name)", message)
    }

    private func update(_ metrics: Metrics) {
        if last?.ok == false { log("\(source.name): back") }
        let cores = coreUsage(metrics)
        let cpu = cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count)
        let temps = temperatures(metrics)
        if let cpu { append(cpu, to: &cpuHistory) }
        if let package = temps.package { append(package, to: &tempHistory) }
        let memory = metrics.value("node_memory_MemTotal_bytes").flatMap { total in
            metrics.value("node_memory_MemAvailable_bytes").map { NodeMessage.Memory(total: total, available: $0) }
        }
        let message = NodeMessage(
            name: source.name, host: source.url.host ?? "", ok: true, error: nil,
            os: metrics.all("node_os_info").first?.labels["pretty_name"],
            cpu: cpu.map(round1), cpuHistory: cpuHistory, cores: cores.map(round1), temps: temps, tempHistory: tempHistory,
            load: ["node_load1", "node_load5", "node_load15"].compactMap { metrics.value($0) },
            memory: memory,
            uptime: metrics.value("node_boot_time_seconds").map { (metrics.value("node_time_seconds") ?? Date().timeIntervalSince1970) - $0 },
            raid: raid(metrics), filesystems: filesystems(metrics), net: network(metrics))
        last = message
        hub.publish("node:\(source.name)", message)
        let name = source.name
        Status.update { $0.nodes[name] = .init(ok: true, cpu: cpu, temp: temps.package) }
    }

    /// Busy percent per CPU since the last scrape (iowait counts as idle).
    private func coreUsage(_ metrics: Metrics) -> [Double] {
        var current: [String: (total: Double, idle: Double)] = [:]
        for sample in metrics.all("node_cpu_seconds_total") {
            let cpu = sample.labels["cpu"] ?? ""
            var times = current[cpu] ?? (0, 0)
            times.total += sample.value
            if sample.labels["mode"] == "idle" || sample.labels["mode"] == "iowait" { times.idle += sample.value }
            current[cpu] = times
        }
        defer { previousCPU = current }
        return current.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { cpu in
            guard let now = current[cpu], let before = previousCPU[cpu], now.total > before.total else { return nil }
            return min(100, max(0, (1 - (now.idle - before.idle) / (now.total - before.total)) * 100))
        }
    }

    /// The CPU package and its cores (Intel coretemp, else AMD k10temp, else
    /// the x86_pkg_temp thermal zone).
    private func temperatures(_ metrics: Metrics) -> NodeMessage.Temps {
        var chipNames: [String: String] = [:]
        for sample in metrics.all("node_hwmon_chip_names") { chipNames[sample.labels["chip"] ?? ""] = sample.labels["chip_name"] }
        var sensorLabels: [String: String] = [:]
        for sample in metrics.all("node_hwmon_sensor_label") {
            sensorLabels["\(sample.labels["chip"] ?? "")/\(sample.labels["sensor"] ?? "")"] = sample.labels["label"]
        }
        var package: Double?
        var cores: [(index: Int, value: Double)] = []
        for sample in metrics.all("node_hwmon_temp_celsius") {
            let chip = sample.labels["chip"] ?? ""
            let label = sensorLabels["\(chip)/\(sample.labels["sensor"] ?? "")"] ?? ""
            switch chipNames[chip] {
            case "coretemp":
                if label.hasPrefix("Package") {
                    package = package ?? sample.value
                } else if label.hasPrefix("Core "), let index = Int(label.dropFirst(5)) {
                    cores.append((index, sample.value))
                }
            case "k10temp":
                if label == "Tctl" || label == "Tdie" { package = package ?? sample.value }
            default:
                break
            }
        }
        if package == nil {
            package = metrics.all("node_thermal_zone_temp").first { $0.labels["type"] == "x86_pkg_temp" }?.value
        }
        return .init(package: package, cores: cores.sorted { $0.index < $1.index }.map(\.value))
    }

    private func raid(_ metrics: Metrics) -> [NodeMessage.Raid] {
        let devices = Set(metrics.all("node_md_disks").compactMap { $0.labels["device"] }).sorted()
        return devices.map { device in
            func value(_ name: String, state: String? = nil) -> Double {
                metrics.all(name).first { $0.labels["device"] == device && (state == nil || $0.labels["state"] == state) }?.value ?? 0
            }
            let blocks = value("node_md_blocks")
            return .init(
                device: device,
                state: metrics.all("node_md_state").first { $0.labels["device"] == device && $0.value == 1 }?.labels["state"] ?? "unknown",
                active: Int(value("node_md_disks", state: "active")), failed: Int(value("node_md_disks", state: "failed")),
                spare: Int(value("node_md_disks", state: "spare")), required: Int(value("node_md_disks_required")),
                synced: blocks > 0 ? value("node_md_blocks_synced") / blocks : 1)
        }
    }

    /// Real filesystems, biggest first, without /boot.
    private func filesystems(_ metrics: Metrics) -> [NodeMessage.Filesystem] {
        let types: Set = ["ext4", "ext3", "xfs", "btrfs", "zfs", "f2fs"]
        var seen = Set<String>()
        return metrics.all("node_filesystem_size_bytes").compactMap { sample -> NodeMessage.Filesystem? in
            guard let type = sample.labels["fstype"], types.contains(type),
                  let mount = sample.labels["mountpoint"], !mount.hasPrefix("/boot"),
                  let device = sample.labels["device"], seen.insert(device).inserted,
                  let available = metrics.all("node_filesystem_avail_bytes").first(where: {
                      $0.labels["device"] == device && $0.labels["mountpoint"] == mount
                  })?.value else { return nil }
            return .init(mount: mount, device: device, size: sample.value, available: available,
                         raid: device.hasPrefix("/dev/md") ? String(device.dropFirst(5)) : nil)
        }.sorted { $0.size > $1.size }
    }

    /// The busiest physical interface.
    private func network(_ metrics: Metrics) -> NodeMessage.Net? {
        let physical = metrics.all("node_network_receive_bytes_total").filter {
            let name = $0.labels["device"] ?? ""
            return ["en", "eth", "eno", "wl"].contains { name.hasPrefix($0) }
        }
        guard let busiest = physical.max(by: { $0.value < $1.value }), let device = busiest.labels["device"],
              let tx = metrics.all("node_network_transmit_bytes_total").first(where: { $0.labels["device"] == device })?.value else { return nil }
        let now = Date()
        defer { previousNet = (busiest.value, tx, now) }
        guard let before = previousNet else { return .init(device: device, rx: 0, tx: 0) }
        let elapsed = now.timeIntervalSince(before.time)
        return .init(device: device, rx: max(0, busiest.value - before.rx) / elapsed, tx: max(0, tx - before.tx) / elapsed)
    }
}

/// Prometheus text format, as much as node_exporter writes.
struct Metrics {
    struct Sample {
        let name: String
        let labels: [String: String]
        let value: Double
    }

    private var byName: [String: [Sample]] = [:]

    init(_ text: String) {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let name: Substring, labels: Substring, rest: Substring
            if let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}") {
                name = line[..<open]
                labels = line[line.index(after: open)..<close]
                rest = line[line.index(after: close)...]
            } else if let space = line.firstIndex(of: " ") {
                name = line[..<space]
                labels = ""
                rest = line[space...]
            } else {
                continue
            }
            guard let text = rest.split(separator: " ").first, let value = Double(text) else { continue }
            byName[String(name), default: []].append(Sample(name: String(name), labels: Self.labels(labels), value: value))
        }
    }

    func all(_ name: String) -> [Sample] {
        byName[name] ?? []
    }

    func value(_ name: String) -> Double? {
        byName[name]?.first?.value
    }

    /// `a="x",b="y \"quoted\""`
    private static func labels(_ text: Substring) -> [String: String] {
        var labels: [String: String] = [:]
        var i = text.startIndex
        while let equals = text[i...].firstIndex(of: "=") {
            let key = text[i..<equals].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            var j = text.index(after: equals)
            guard j < text.endIndex, text[j] == "\"" else { break }
            j = text.index(after: j)
            var value = ""
            while j < text.endIndex, text[j] != "\"" {
                if text[j] == "\\", text.index(after: j) < text.endIndex { j = text.index(after: j) }
                value.append(text[j])
                j = text.index(after: j)
            }
            labels[key] = value
            guard j < text.endIndex else { break }
            i = text.index(after: j)
        }
        return labels
    }
}
