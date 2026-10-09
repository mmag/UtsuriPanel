import Foundation

/// Forwards HagtAmp's panel feed: its JSON messages (`skin`, `status`) and
/// its display frames. While HagtAmp isn't there, the panels get a stopped,
/// offline status.
final class HagtampRelay {
    private let url: URL
    private let hub: Hub
    private let session = URLSession(configuration: .ephemeral)
    private var online: Bool?

    init(url: URL, hub: Hub) {
        self.url = url
        self.hub = hub
    }

    func start() {
        connect()
    }

    private func connect() {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 << 20
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [self] result in
            switch result {
            case .success(let message):
                if online != true {
                    online = true
                    log("HagtAmp connected")
                    Status.update { $0.hagtampOnline = true }
                }
                switch message {
                case .string(let text): forward(Data(text.utf8))
                case .data(let frame): if frame.count > 8 { hub.publishFrame(frame) }
                @unknown default: break
                }
                receive(task)
            case .failure:
                task.cancel()
                if online != false {
                    if online == true { log("HagtAmp disconnected") }
                    online = false
                    hub.publish("status", json: Data(#"{"type":"status","state":"stopped","offline":true,"track":null}"#.utf8))
                    Status.update {
                        $0.hagtampOnline = false
                        $0.playerState = "stopped"
                        $0.track = nil
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in connect() }
            }
        }
    }

    private func forward(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        hub.publish(type, json: data)
        if type == "status" {
            let state = message["state"] as? String ?? "stopped"
            let track = (message["track"] as? [String: Any])?["display"] as? String
            Status.update {
                $0.playerState = state
                $0.track = track
            }
        }
    }
}
