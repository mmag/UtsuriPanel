import AppKit

/// The menu bar item: a small screen whose analyzer bars show while the
/// phone's panel is connected, and a menu with what the panel shows.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let config: Config
    private let adb: ADBKeeper
    private var connected: Bool?

    init(config: Config, adb: ADBKeeper) {
        self.config = config
        self.adb = adb
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        Status.shared.onChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    private func refreshIcon() {
        let connected = Status.shared.panels > 0
        guard connected != self.connected else { return }
        self.connected = connected
        item.button?.image = Self.icon(connected: connected)
        item.button?.toolTip = connected ? "UtsuriPanel: панель подключена" : "UtsuriPanel: панель не подключена"
    }

    /// A screen with analyzer bars, or with a flat line when no panel is
    /// connected.
    static func icon(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 11), xRadius: 2.5, yRadius: 2.5)
            screen.lineWidth = 1.5
            screen.stroke()
            let heights: [CGFloat] = connected ? [3, 6.5, 4.5, 7] : [1, 1, 1, 1]
            for (index, height) in heights.enumerated() {
                NSBezierPath(rect: NSRect(x: 4 + CGFloat(index) * 2.75, y: 3.5, width: 1.75, height: height)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = Status.shared

        if let phone = status.phone {
            let battery = phone.battery.map { " · батарея \($0) %\(phone.charging ? ", заряжается" : "")" } ?? ""
            info("Телефон: \(phone.model)\(battery)")
        } else {
            info("Телефон не подключён")
        }
        info(status.panels > 0 ? "Панель открыта" : "Панель не открыта")
        info(hagtampLine(status))
        for node in config.nodes {
            if let state = status.nodes[node.name], state.ok {
                let parts = [state.cpu.map { "CPU \(Int($0.rounded())) %" }, state.temp.map { "\(Int($0.rounded())) °C" }].compactMap { $0 }
                info("\(node.name): \(parts.joined(separator: ", "))")
            } else {
                info("\(node.name): \(status.nodes[node.name] == nil ? "…" : "нет связи")")
            }
        }
        if let disks = status.disks {
            var parts: [String] = []
            if disks.fail > 0 { parts.append("сбой: \(disks.fail)") }
            if disks.warn > 0 { parts.append("внимание: \(disks.warn)") }
            parts.append("в норме: \(disks.ok)")
            if !disks.unreachable.isEmpty { parts.append("нет связи с \(disks.unreachable.joined(separator: ", "))") }
            info("Диски: \(parts.joined(separator: ", "))")
        }

        menu.addItem(.separator())
        action("Обновить панель на телефоне", #selector(reloadPanel), key: "r", enabled: status.phone != nil)
        action("Открыть панель в браузере", #selector(openInBrowser))
        action("Показать лог", #selector(showLog))
        menu.addItem(.separator())
        action("Выйти", #selector(quit), key: "q")
    }

    private func hagtampLine(_ status: Status) -> String {
        guard status.hagtampOnline else { return "HagtAmp не запущен" }
        let track = status.track.map { " — \($0)" } ?? ""
        switch status.playerState {
        case "playing": return "HagtAmp: играет\(track)"
        case "paused": return "HagtAmp: пауза\(track)"
        default: return "HagtAmp: остановлен"
        }
    }

    private func info(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func reloadPanel() {
        adb.reloadPanel()
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(config.port)/")!)
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/utsuripanel.log"))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
