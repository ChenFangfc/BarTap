import AppKit
import BarTapCore

/// `BarTap --detail-render <dir>`: the stats details panels (content, actions row, combined tabs)
/// as they open below a menu bar item, from sample data, light and dark, English and Chinese.
/// Headless: no status items, no windows on screen. The menu material can't be drawn offscreen,
/// so its color is approximated; corners, border and shadow are drawn as the window server would.
enum DetailRender {
    static func render(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sample = PromoAssets.sampleSnapshot(step: 3)
        let o = StatsRenderer.Options()
        for language in [AppLanguage.en, .zhHans] {
            Loc.language = language
            let tag = language == .en ? "en" : "zh"
            func actions(_ m: StatsModule) -> DetailFooter {
                DetailFooter(actions: DetailActions.list(for: m, muted: false, canMute: true, volumes: m == .disk ? ["Backup", "USB Stick"] : []) { _ in })
            }
            func scene(_ m: StatsModule, _ panel: StatsPanel, tabs: [StatsModule]? = nil) -> DetailContent {
                panel.update(sample, o)
                panel.compact()
                let bar = tabs.map { DetailTabs(modules: $0, selected: m) { _ in } }
                return DetailContent(panel: panel, footer: actions(m), tabs: bar)
            }
            let scenes: [(String, () -> DetailContent)] = [
                ("cpu", { scene(.cpu, CPUPanel()) }),
                ("volume", { scene(.volume, VolumePanel(audio: nil, state: sample.audio)) }),
                ("bluetooth", { scene(.bluetooth, BluetoothPanel(state: sample.bluetooth, updated: Date(), access: .allowed)) }),
                ("trio", { scene(.trio, TrioPanel()) }),
                ("disk", { scene(.disk, DiskPanel()) }),
                ("combined", { scene(.memory, MemoryPanel(), tabs: [.cpu, .memory, .network, .battery, .volume, .bluetooth, .trio]) }),
            ]
            for (name, make) in scenes {
                for dark in [false, true] {
                    write(make(), dark: dark, to: dir.appendingPathComponent("details_\(name)_\(tag)_\(dark ? "dark" : "light").png"))
                }
            }
        }
        Loc.language = .system
        print("rendered details to \(dir.path)")
    }

    /// The content below a mock menu bar (the item it belongs to highlighted), on a desktop-like
    /// background, at 2x.
    private static func write(_ content: DetailContent, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let panelSize = content.frame.size
        let margin: CGFloat = 36, barHeight: CGFloat = 26, gap: CGFloat = 3
        let size = NSSize(width: panelSize.width + 2 * margin, height: barHeight + gap + panelSize.height + margin + 8)
        let scale: CGFloat = 2
        // The content, drawn by AppKit into its own bitmap (controls need a window).
        let back = NSView(frame: NSRect(origin: .zero, size: panelSize))
        back.appearance = appearance
        content.appearance = appearance
        let window = NSWindow(contentRect: back.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = back
        back.addSubview(content)
        content.setFrameOrigin(.zero)
        back.layoutSubtreeIfNeeded()
        guard let contentRep = back.bitmapImageRepForCachingDisplay(in: back.bounds),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        appearance.performAsCurrentDrawingAppearance { back.cacheDisplay(in: back.bounds, to: contentRep) }
        content.removeFromSuperview()
        rep.size = size
        let contentImage = NSImage(size: panelSize)
        contentImage.addRepresentation(contentRep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let all = NSRect(origin: .zero, size: size)
            let wallpaper = dark ? NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
                                              ending: NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.30, alpha: 1))
                                 : NSGradient(starting: NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.93, alpha: 1),
                                              ending: NSColor(calibratedRed: 0.93, green: 0.80, blue: 0.86, alpha: 1))
            wallpaper?.draw(in: all, angle: -60)
            // Menu bar with the item highlighted.
            let bar = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
            (dark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 1, alpha: 0.55)).setFill()
            bar.fill()
            let panelRect = NSRect(x: margin, y: bar.minY - gap - panelSize.height, width: panelSize.width, height: panelSize.height)
            let item = NSRect(x: panelRect.minX + 6, y: bar.minY + 3, width: 44, height: barHeight - 6)
            (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).setFill()
            NSBezierPath(roundedRect: item, xRadius: 6, yRadius: 6).fill()
            // The window: shadow, menu-colored rounded body, hairline border.
            let shape = NSBezierPath(roundedRect: panelRect, xRadius: DetailChrome.radius, yRadius: DetailChrome.radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.55 : 0.28)
            shadow.set()
            (dark ? NSColor(calibratedWhite: 0.17, alpha: 0.96) : NSColor(calibratedWhite: 0.97, alpha: 0.96)).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            contentImage.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)).setStroke()
            let border = NSBezierPath(roundedRect: panelRect.insetBy(dx: 0.25, dy: 0.25), xRadius: DetailChrome.radius, yRadius: DetailChrome.radius)
            border.lineWidth = 0.5
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
