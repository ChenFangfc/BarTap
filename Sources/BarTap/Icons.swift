import AppKit
import BarTapCore

/// Template images for our status items. Template images follow light/dark/tinted menu bars
/// automatically, so we never need to observe appearance changes.
enum Icons {
    enum Badge { case warning, awake }

    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    private static var cache: [String: NSImage] = [:]

    static func toggle(style: ToggleIconStyle, expanded: Bool, badge: Badge?) -> NSImage {
        let key = "\(style.rawValue)|\(expanded)|\(String(describing: badge))"
        if let img = cache[key] { return img }
        let base: NSImage
        switch style {
        case .chevron: base = symbol(expanded ? "chevron.right" : "chevron.left")
        case .dot: base = symbol(expanded ? "circle" : "circle.fill")
        case .ellipsis: base = symbol(expanded ? "ellipsis.circle" : "ellipsis")
        case .line: base = symbol(expanded ? "line.3.horizontal.decrease" : "line.3.horizontal")
        case .grid: base = symbol(expanded ? "square.grid.2x2" : "square.grid.2x2.fill")
        case .logo: base = logoMark(mirrored: expanded)
        }
        let img = badge.map { addBadge($0, to: base) } ?? base
        img.isTemplate = true
        cache[key] = img
        return img
    }

    static func symbol(_ name: String, config: NSImage.SymbolConfiguration? = nil) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config ?? symbolConfig) ?? NSImage(size: NSSize(width: 14, height: 14))
        img.isTemplate = true
        return img
    }

    /// Thin divider drawn inside the expanded separators so section borders are visible while
    /// arranging. `double` marks the always-hidden border.
    static func divider(double: Bool) -> NSImage {
        let key = "divider|\(double)"
        if let img = cache[key] { return img }
        let size = NSSize(width: double ? 6 : 3, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 1.2, height: 14), xRadius: 0.6, yRadius: 0.6).fill()
            if double {
                NSBezierPath(roundedRect: NSRect(x: 3.8, y: 1, width: 1.2, height: 14), xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }

    /// The BarTap mark (assets/logo/bartap-mark.svg), drawn from the same SVG source as the app
    /// icon. Mirrored while icons are revealed, pointing toward where they appeared.
    static func logoMark(mirrored: Bool) -> NSImage {
        let flip = mirrored ? " transform=\"translate(390 0) scale(-1 1)\"" : ""
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="-30 -30 450 259"><g\(flip) fill="none" stroke="#000" \
        stroke-width="58" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0H339A51 51 0 0 1 390 51V199"/>\
        <path d="M56 199L188 67"/></g></svg>
        """
        let img = NSImage(data: Data(svg.utf8)) ?? symbol("chevron.left")
        img.size = NSSize(width: 21, height: 12)
        img.isTemplate = true
        return img
    }

    private static func addBadge(_ badge: Badge, to base: NSImage) -> NSImage {
        let size = NSSize(width: max(base.size.width, 14) + 5, height: max(base.size.height, 14))
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: (rect.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            NSColor.black.setFill()
            switch badge {
            case .warning:
                NSBezierPath(rect: NSRect(x: rect.width - 2.6, y: rect.height - 9, width: 1.8, height: 6)).fill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - 2.7, y: rect.height - 12, width: 2, height: 2)).fill()
            case .awake:
                NSBezierPath(ovalIn: NSRect(x: rect.width - 4.5, y: rect.height - 5, width: 4, height: 4)).fill()
            }
            return true
        }
    }

    /// SF Symbol for well-known system menu bar items, keyed by words in their AX label/identifier.
    static func systemItemSymbol(for label: String) -> String? {
        let l = label.lowercased()
        let table: [(String, String)] = [
            ("wi-fi", "wifi"), ("wi‑fi", "wifi"), ("wifi", "wifi"), ("battery", "battery.75percent"),
            ("bluetooth", "antenna.radiowaves.left.and.right"), ("sound", "speaker.wave.2.fill"),
            ("volume", "speaker.wave.2.fill"), ("clock", "clock"), ("focus", "moon.fill"),
            ("display", "display"), ("now playing", "play.circle"), ("control cent", "switch.2"),
            ("keyboard brightness", "light.max"), ("spotlight", "magnifyingglass"), ("siri", "waveform"),
            ("time machine", "clock.arrow.circlepath"), ("input", "keyboard"), ("user", "person.crop.circle"),
            ("airdrop", "dot.radiowaves.up.forward"), ("screen mirroring", "rectangle.on.rectangle"),
            ("accessibility", "accessibility"), ("vpn", "network.badge.shield.half.filled"),
            ("stage manager", "rectangle.3.group"), ("hearing", "ear"), ("weather", "cloud.sun"),
            ("无线", "wifi"), ("电池", "battery.75percent"), ("蓝牙", "antenna.radiowaves.left.and.right"),
            ("声音", "speaker.wave.2.fill"), ("时钟", "clock"), ("专注", "moon.fill"), ("控制中心", "switch.2"),
            ("输入", "keyboard"), ("显示器", "display"), ("正在播放", "play.circle"),
        ]
        return table.first { l.contains($0.0) }?.1
    }
}
