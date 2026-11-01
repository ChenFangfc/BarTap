import Foundation

/// `bartap://<command>` automation entry points (usable from Shortcuts, scripts, `open`).
public enum URLCommand: Equatable {
    case toggle, show, showAll, hide
    case search, shelf
    case clean(Bool?)               // nil = toggle
    case keepAwake(minutes: Int?)   // nil minutes = indefinitely
    case keepAwakeOff
    case pickColor
    case settings
    case resetPositions
    case debug(String)              // only honoured when debug commands are enabled

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "bartap" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.path.split(separator: "/").map { String($0).lowercased() }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch host {
        case "toggle": self = .toggle
        case "show": self = path.first == "all" ? .showAll : .show
        case "show-all", "showall": self = .showAll
        case "hide": self = .hide
        case "search": self = .search
        case "shelf": self = .shelf
        case "clean":
            switch path.first ?? q("state") ?? "" {
            case "on": self = .clean(true)
            case "off": self = .clean(false)
            default: self = .clean(nil)
            }
        case "keep-awake", "keepawake":
            if path.first == "off" || q("state") == "off" {
                self = .keepAwakeOff
            } else if let m = q("minutes").flatMap(Int.init), m > 0, m <= 24 * 60 {
                self = .keepAwake(minutes: m)
            } else {
                self = .keepAwake(minutes: nil)
            }
        case "pick-color", "color": self = .pickColor
        case "settings", "preferences": self = .settings
        case "reset-positions": self = .resetPositions
        case "debug":
            guard let p = path.first, !p.isEmpty else { return nil }
            self = .debug(p)
        default: return nil
        }
    }
}
