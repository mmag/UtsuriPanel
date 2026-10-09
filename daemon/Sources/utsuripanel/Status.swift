import Foundation

/// What the menu bar shows. Lives on the main thread; the parts update it
/// through `Status.update`.
final class Status {
    struct Phone {
        var serial: String
        var model: String
        var battery: Int?
        var charging = false
    }

    struct Node {
        var ok: Bool
        var cpu: Double?
        var temp: Double?
    }

    struct Disks {
        var ok = 0, warn = 0, fail = 0
        var unreachable: [String] = []
    }

    static let shared = Status()

    var phone: Phone?
    var panels = 0
    var hagtampOnline = false
    var playerState = "stopped"
    var track: String?
    var nodes: [String: Node] = [:]
    var disks: Disks?
    var onChange: (() -> Void)?

    static func update(_ change: @escaping (Status) -> Void) {
        DispatchQueue.main.async {
            change(shared)
            shared.onChange?()
        }
    }
}
