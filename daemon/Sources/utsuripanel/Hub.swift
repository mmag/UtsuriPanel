import Foundation

/// The connected panels, and the latest message of each kind for the ones
/// that connect later. All state lives on `queue`.
final class Hub {
    let queue = DispatchQueue(label: "utsuripanel.hub")
    private var panels: [ObjectIdentifier: PanelConnection] = [:]
    private var latest: [(key: String, data: Data)] = []
    private var latestFrames: [UInt8: Data] = [:]

    func add(_ panel: PanelConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        panels[ObjectIdentifier(panel)] = panel
        for message in latest { panel.send(text: message.data, key: message.key) }
        for type in latestFrames.keys.sorted() { panel.send(binary: latestFrames[type]!, droppable: false) }
        log("panel connected (\(panels.count))")
        let count = panels.count
        Status.update { $0.panels = count }
    }

    func remove(_ panel: PanelConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        if panels.removeValue(forKey: ObjectIdentifier(panel)) != nil {
            log("panel disconnected (\(panels.count))")
            let count = panels.count
            Status.update { $0.panels = count }
        }
    }

    /// A JSON message; only the latest of each `key` is kept.
    func publish(_ key: String, json data: Data) {
        queue.async { [self] in
            if let index = latest.firstIndex(where: { $0.key == key }) {
                latest[index].data = data
            } else {
                latest.append((key, data))
            }
            for panel in panels.values { panel.send(text: data, key: key) }
        }
    }

    func publish<Message: Encodable>(_ key: String, _ message: Message) {
        do {
            publish(key, json: try JSONEncoder().encode(message))
        } catch {
            log("can't encode \(key): \(error)")
        }
    }

    /// One of HagtAmp's display frames (its first byte is the frame type). A
    /// panel that's behind skips frames rather than queueing them.
    func publishFrame(_ frame: Data) {
        queue.async { [self] in
            latestFrames[frame[frame.startIndex]] = frame
            for panel in panels.values { panel.send(binary: frame, droppable: true) }
        }
    }
}
