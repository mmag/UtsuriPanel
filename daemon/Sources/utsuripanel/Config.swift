import Foundation

struct Config: Decodable {
    struct Source: Decodable {
        let name: String
        let url: URL
    }

    let port: UInt16
    /// The page's folder; relative to the config file.
    var web: String
    /// HagtAmp's panel feed.
    let hagtamp: URL
    let adb: String
    /// The phone's panel activity, opened when the phone shows up.
    let app: String
    /// node_exporter `/metrics` URLs.
    let nodes: [Source]
    /// Scrutiny web roots.
    let scrutiny: [Source]

    static func load(_ url: URL) throws -> Config {
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        if !config.web.hasPrefix("/") {
            config.web = url.deletingLastPathComponent().appendingPathComponent(config.web).standardizedFileURL.path
        }
        return config
    }
}

private let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func log(_ message: String) {
    print("\(stampFormatter.string(from: Date())) \(message)")
}

/// Keeps the last `limit` values.
func append(_ value: Double, to history: inout [Double], limit: Int = 90) {
    history.append(value)
    if history.count > limit { history.removeFirst(history.count - limit) }
}

/// Runs `body` every `interval` seconds on `queue`, the first time right away.
func repeating(every interval: Double, on queue: DispatchQueue, _ body: @escaping () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
    timer.setEventHandler(handler: body)
    timer.resume()
    return timer
}
