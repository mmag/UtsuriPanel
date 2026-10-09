import CryptoKit
import Foundation
import Network

/// The page's files over HTTP, and the panel's WebSocket (any request asking
/// for an upgrade), on 127.0.0.1 only: the phone comes in through adb reverse.
final class HTTPServer {
    private let listener: NWListener
    private let webRoot: URL
    private let hub: Hub
    private let port: UInt16

    init(port: UInt16, webRoot: String, hub: Hub) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.webRoot = URL(fileURLWithPath: webRoot).standardizedFileURL
        self.hub = hub
        self.port = port
    }

    func start() {
        listener.newConnectionHandler = { [webRoot, hub] connection in
            PanelConnection(connection, webRoot: webRoot, hub: hub).start()
        }
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready: log("listening on 127.0.0.1:\(port)")
            case .failed(let error):
                log("listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: hub.queue)
    }
}

/// One HTTP request, or a panel once it upgraded to WebSocket.
final class PanelConnection {
    private let connection: NWConnection
    private let webRoot: URL
    private let hub: Hub
    private var buffer = Data()
    private var unsent = 0
    private var held: [(key: String, data: Data)] = []
    private var open = true

    init(_ connection: NWConnection, webRoot: URL, hub: Hub) {
        self.connection = connection
        self.webRoot = webRoot
        self.hub = hub
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            if case .failed = state { close() }
        }
        connection.start(queue: hub.queue)
        readRequest()
    }

    private func readRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                respond(to: head)
            } else if error != nil || complete || buffer.count > 65536 {
                close()
            } else {
                readRequest()
            }
        }
    }

    private func respond(to head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return close() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            return upgrade(key: key)
        }
        let target = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(target[0])
        if path == "/log" {
            // The page reports its errors here.
            log("page: \(target.count > 1 ? target[1].removingPercentEncoding ?? "" : "")")
            return reply(204, type: "text/plain", body: Data())
        }
        serve(path)
    }

    private func serve(_ path: String) {
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        let file = webRoot.appendingPathComponent(relative.removingPercentEncoding ?? relative).standardizedFileURL
        guard file.path.hasPrefix(webRoot.path + "/"), let body = try? Data(contentsOf: file) else {
            return reply(404, type: "text/plain; charset=utf-8", body: Data("Not found".utf8))
        }
        reply(200, type: Self.contentTypes[file.pathExtension] ?? "application/octet-stream", body: body)
    }

    private static let contentTypes = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "json": "application/json", "png": "image/png", "svg": "image/svg+xml", "woff2": "font/woff2",
    ]

    private func reply(_ status: Int, type: String, body: Data) {
        let reason = [200: "OK", 204: "No Content", 404: "Not Found"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [self] _ in close() })
    }

    // MARK: - WebSocket

    private func upgrade(key: String) {
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        send(Data(head.utf8))
        hub.add(self)
        readFrames()
    }

    /// The panel only ever closes or pings; anything else it sends is ignored.
    private func readFrames() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            while let frame = WebSocketFrame.take(from: &buffer) {
                switch frame.opcode {
                case 0x8: return close()
                case 0x9: send(WebSocketFrame.encode(opcode: 0xA, payload: frame.payload))
                default: break
                }
            }
            if error != nil || complete { close() } else { readFrames() }
        }
    }

    /// While the panel isn't reading (its screen is off, say), only the
    /// latest message of each `key` waits for it, so it never gets a backlog
    /// to play through.
    func send(text: Data, key: String) {
        guard unsent > 4 else { return send(WebSocketFrame.encode(opcode: 0x1, payload: text)) }
        if let index = held.firstIndex(where: { $0.key == key }) {
            held[index].data = text
        } else {
            held.append((key, text))
        }
    }

    /// Frames a panel that's behind skips.
    func send(binary: Data, droppable: Bool) {
        if droppable && unsent > 4 { return }
        send(WebSocketFrame.encode(opcode: 0x2, payload: binary))
    }

    private func send(_ data: Data) {
        guard open else { return }
        unsent += 1
        connection.send(content: data, completion: .contentProcessed { [self] error in
            unsent -= 1
            if error != nil { return close() }
            if unsent == 0 && !held.isEmpty {
                let waiting = held
                held = []
                for message in waiting { send(WebSocketFrame.encode(opcode: 0x1, payload: message.data)) }
            }
        })
    }

    private func close() {
        guard open else { return }
        open = false
        hub.remove(self)
        connection.cancel()
    }
}

enum WebSocketFrame {
    /// A server frame: final, unmasked.
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(contentsOf: [126, UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    /// Removes the first complete frame from `buffer`, unmasked.
    static func take(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        let head = [UInt8](buffer.prefix(14))
        guard head.count >= 2 else { return nil }
        let masked = head[1] & 0x80 != 0
        var length = Int(head[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard head.count >= 4 else { return nil }
            length = Int(head[2]) << 8 | Int(head[3])
            offset = 4
        } else if length == 127 {
            guard head.count >= 10 else { return nil }
            length = head[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let maskOffset = offset
        if masked { offset += 4 }
        guard head.count >= min(offset, 14), buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex
        var payload = Data(buffer[(start + offset)..<(start + offset + length)])
        if masked {
            let mask = [UInt8](buffer[(start + maskOffset)..<(start + maskOffset + 4)])
            for i in payload.indices { payload[i] ^= mask[(i - payload.startIndex) % 4] }
        }
        buffer.removeSubrange(start..<(start + offset + length))
        return (head[0] & 0x0F, payload)
    }
}
