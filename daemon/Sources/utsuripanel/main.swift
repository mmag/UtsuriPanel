// UtsuriPanel: serves the panel page to the phone (through adb reverse) and
// feeds it over one WebSocket: HagtAmp's display, this Mac's load, the
// servers' metrics and their disks' SMART state. Lives in the menu bar.
//
//   utsuripanel [config.json]

import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

// One at a time: the LaunchAgent's, or one opened from Finder.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    log("already running")
    exit(0)
}

// install.sh records where the config is, for when the app is opened from
// Finder.
let configPath = CommandLine.arguments.count > 1 && !CommandLine.arguments[1].hasPrefix("-")
    ? CommandLine.arguments[1]
    : UserDefaults.standard.string(forKey: "config") ?? "config.json"
let config: Config
do {
    config = try Config.load(URL(fileURLWithPath: configPath))
} catch {
    log("can't read \(configPath): \(error)")
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let hub = Hub()
let server: HTTPServer
do {
    server = try HTTPServer(port: config.port, webRoot: config.web, hub: hub)
} catch {
    log("can't listen on \(config.port): \(error)")
    exit(1)
}
server.start()

let relay = HagtampRelay(url: config.hagtamp, hub: hub)
relay.start()
let mac = MacMonitor(hub: hub)
mac.start()
let nodes = config.nodes.map { NodeMonitor(source: $0, hub: hub) }
nodes.forEach { $0.start() }
let disks = DiskMonitor(sources: config.scrutiny, hub: hub)
disks.start()
let adb = ADBKeeper(adb: config.adb, port: config.port, app: config.app)
adb.start()

let statusMenu = StatusMenu(config: config, adb: adb)
application.run()
