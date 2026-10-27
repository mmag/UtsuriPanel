import Foundation

/// Keeps the phone pointed at us: whenever a phone is connected without our
/// port reversed (it was just plugged in, rebooted, or adb restarted), sets
/// up `adb reverse` again and opens the panel app. Restarts the app when it
/// holds too much memory, and reads the phone's battery for the menu.
final class ADBKeeper {
    /// The page leaks some 45 MB a day from ~100 MB at start. Held for weeks,
    /// it filled the phone's 1.7 GB; the phone thrashed its swap, drew more
    /// than the USB port gives and kept dropping off the bus.
    private static let memoryLimitKB = 300 * 1024

    private let adb: String
    private let port: UInt16
    private let app: String
    private let package: String
    private let queue = DispatchQueue(label: "utsuripanel.adb")
    private var timer: DispatchSourceTimer?
    private var reportedMissing = false
    private var serial: String?
    private var hasPanel: [String: Bool] = [:]
    private var checks = 0

    init(adb: String, port: UInt16, app: String) {
        self.adb = adb
        self.port = port
        self.app = app
        package = String(app.prefix { $0 != "/" })
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
        // adb may also see other devices (a TV on the network, a second phone),
        // listed in any order: the phone is the one with the panel app.
        var phone: [Substring]?
        var present = Set<String>()
        for line in devices.split(separator: "\n").dropFirst() {
            let fields: [Substring] = line.split(separator: " ")
            guard fields.count >= 2, fields[1] == "device" else { continue }
            present.insert(String(fields[0]))
            if phone == nil, hasApp(String(fields[0])) { phone = fields }
        }
        hasPanel = hasPanel.filter { present.contains($0.key) }
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

        // Offline, Google apps' token refreshes end in Play services' sign-in
        // error screens ("not connected to a network") over the panel.
        if let focus = run(["-s", serial, "shell", "dumpsys window windows | grep mCurrentFocus"]),
           focus.contains("com.google.android.gms/"), focus.contains(".auth.") || focus.contains(".signin.") {
            _ = run(["-s", serial, "shell", "am", "start", "-n", app])
            log("phone \(serial): a Google sign-in screen covered the panel, panel brought back")
        }

        checks += 1
        if checks % 120 == 0, let used = memory(serial), used > Self.memoryLimitKB {
            _ = run(["-s", serial, "shell", "am", "force-stop", package])
            _ = run(["-s", serial, "shell", "am", "start", "-n", app])
            log("phone \(serial): panel app held \(used / 1024) MB, restarted")
        }

        guard appeared || checks % 6 == 0 else { return }
        let battery = run(["-s", serial, "shell", "dumpsys", "battery"]).map(Self.battery)
        Status.update {
            $0.phone = .init(serial: serial, model: model, battery: battery?.level, charging: battery?.charging ?? false)
        }
    }

    /// Whether the panel app is installed, asked once per connection.
    private func hasApp(_ serial: String) -> Bool {
        if let known = hasPanel[serial] { return known }
        // "package:app.utsuripanel"; the argument is a substring filter
        guard let packages = run(["-s", serial, "shell", "pm", "list", "packages", package]) else { return false }
        let installed = packages.split(whereSeparator: \.isNewline).contains { $0 == "package:\(package)" }
        hasPanel[serial] = installed
        return installed
    }

    /// The panel app's PSS in KB, from `dumpsys meminfo`'s summary line
    /// "TOTAL:    96687      TOTAL SWAP (KB):     8736"; nil when it isn't running.
    private func memory(_ serial: String) -> Int? {
        guard let text = run(["-s", serial, "shell", "dumpsys", "meminfo", package]),
              let total = text.split(whereSeparator: \.isNewline).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("TOTAL:") })
        else { return nil }
        return total.split(separator: " ").dropFirst().first.flatMap { Int($0) }
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
