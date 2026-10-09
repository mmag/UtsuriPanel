import Foundation

/// Keeps the phone pointed at us: whenever a phone is connected without our
/// port reversed (it was just plugged in, rebooted, or adb restarted), sets
/// up `adb reverse` again and opens the panel app. Also reads the phone's
/// battery for the menu.
final class ADBKeeper {
    private let adb: String
    private let port: UInt16
    private let app: String
    private let queue = DispatchQueue(label: "utsuripanel.adb")
    private var timer: DispatchSourceTimer?
    private var reportedMissing = false
    private var serial: String?
    private var checks = 0

    init(adb: String, port: UInt16, app: String) {
        self.adb = adb
        self.port = port
        self.app = app
    }

    func start() {
        timer = repeating(every: 5, on: queue) { [self] in check() }
    }

    /// Reloads the page in the phone's panel app (and brings the app up).
    func reloadPanel() {
        queue.async { [self] in
            guard let serial else { return }
            _ = run(["-s", serial, "shell", "am", "start", "-n", app, "-d", "http://localhost:\(port)/"])
            log("phone \(serial): panel reloaded")
        }
    }

    private func check() {
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            if !reportedMissing { log("no adb at \(adb)") }
            reportedMissing = true
            return
        }
        guard let devices = run(["devices", "-l"]) else { return }
        // "<serial>  device usb:… product:C6903 model:Xperia_Z1 device:honami transport_id:6"
        var phone: [Substring]?
        for line in devices.split(separator: "\n").dropFirst() {
            let fields: [Substring] = line.split(separator: " ")
            if fields.count >= 2, fields[1] == "device" {
                phone = fields
                break
            }
        }
        guard let phone else {
            if serial != nil { log("phone disconnected") }
            serial = nil
            Status.update { $0.phone = nil }
            return
        }
        let serial = String(phone[0])
        var model = serial
        if let field = phone.first(where: { $0.hasPrefix("model:") }) {
            model = String(field.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
        }
        let appeared = serial != self.serial
        self.serial = serial

        if let reversed = run(["-s", serial, "reverse", "--list"]), !reversed.contains("tcp:\(port) tcp:\(port)") {
            _ = run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
            _ = run(["-s", serial, "shell", "am", "start", "-n", app])
            log("phone \(serial): port \(port) reversed, panel opened")
        }

        checks += 1
        guard appeared || checks % 6 == 0 else { return }
        let battery = run(["-s", serial, "shell", "dumpsys", "battery"]).map(Self.battery)
        Status.update {
            $0.phone = .init(serial: serial, model: model, battery: battery?.level, charging: battery?.charging ?? false)
        }
    }

    /// `dumpsys battery`: "level: 34", "status: 2" (2 is charging).
    private static func battery(_ text: String) -> (level: Int?, charging: Bool) {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return (fields["level"].flatMap { Int($0) }, fields["status"] == "2")
    }

    /// stdout, or nil if adb failed.
    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
