import Foundation

struct DisksMessage: Encodable {
    struct Disk: Encodable {
        let device, model, label: String
        let capacity: Double
        let rotational: Bool
        let temp: Double?
        let hours: Double?
        /// ok, warn (Scrutiny's risk isn't "healthy") or fail (SMART or
        /// Scrutiny's thresholds failed).
        let status: String
        let risk: String?
        let collected: String?
    }
    struct Host: Encodable {
        let name: String
        var ok: Bool
        var error: String?
        var disks: [Disk]
    }

    let type = "disks"
    let hosts: [Host]
}

/// Every Scrutiny's disk summary, every 5 minutes (its collectors run hourly
/// or daily anyway).
final class DiskMonitor {
    private let sources: [Config.Source]
    private let hub: Hub
    private let queue = DispatchQueue(label: "utsuripanel.disks")
    private var timer: DispatchSourceTimer?
    private var hosts: [String: DisksMessage.Host] = [:]

    init(sources: [Config.Source], hub: Hub) {
        self.sources = sources
        self.hub = hub
    }

    func start() {
        timer = repeating(every: 300, on: queue) { [self] in sources.forEach(fetch) }
    }

    private func fetch(_ source: Config.Source) {
        let url = source.url.appendingPathComponent("api/summary")
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { [self] data, response, error in
            queue.async { [self] in
                if let data, (response as? HTTPURLResponse)?.statusCode == 200, let disks = Self.disks(data) {
                    hosts[source.name] = .init(name: source.name, ok: true, disks: disks)
                } else {
                    let reason = error?.localizedDescription ?? "unexpected answer"
                    log("\(source.name) Scrutiny: \(reason)")
                    var host = hosts[source.name] ?? .init(name: source.name, ok: false, disks: [])
                    host.ok = false
                    host.error = reason
                    hosts[source.name] = host
                    queue.asyncAfter(deadline: .now() + 30) { [self] in fetch(source) }
                }
                let message = DisksMessage(hosts: sources.compactMap { hosts[$0.name] })
                hub.publish("disks", message)
                var summary = Status.Disks()
                for host in message.hosts {
                    if !host.ok { summary.unreachable.append(host.name) }
                    for disk in host.disks {
                        switch disk.status {
                        case "fail": summary.fail += 1
                        case "warn": summary.warn += 1
                        default: summary.ok += 1
                        }
                    }
                }
                Status.update { $0.disks = summary }
            }
        }.resume()
    }

    private static func disks(_ data: Data) -> [DisksMessage.Disk]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = (root["data"] as? [String: Any])?["summary"] as? [String: Any] else { return nil }
        return summary.values.compactMap { entry -> DisksMessage.Disk? in
            guard let entry = entry as? [String: Any] else { return nil }
            let device = entry["device"] as? [String: Any] ?? [:]
            let smart = entry["smart"] as? [String: Any] ?? [:]
            if device["archived"] as? Bool == true { return nil }
            let risk = smart["risk_category"] as? String
            let status = (device["device_status"] as? Int ?? 0) != 0 ? "fail" : risk.map { $0 == "healthy" ? "ok" : "warn" } ?? "ok"
            return .init(
                device: device["device_name"] as? String ?? "?", model: device["model_name"] as? String ?? "",
                label: device["device_label"] as? String ?? "", capacity: device["capacity"] as? Double ?? 0,
                rotational: (device["rotational_speed"] as? Int ?? 0) > 0,
                temp: smart["temp"] as? Double, hours: smart["power_on_hours"] as? Double,
                status: status, risk: risk, collected: smart["collector_date"] as? String)
        }.sorted { $0.device.localizedStandardCompare($1.device) == .orderedAscending }
    }
}
