import AppKit
import BarTapCore

/// Debug-only (`debugCommands` enabled): renders UI pieces to PNG so layout can be reviewed
/// without screen-recording permission.
enum DebugRender {
    private static var overrideDir: URL?
    static var dir: URL {
        get {
            let d = overrideDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BarTap/render", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        set { overrideDir = newValue }
    }

    static func write(_ rep: NSBitmapImageRep?, _ name: String) {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// Menu bar images composited on a light and a dark bar, at 2x.
    static func statusImages(_ snapshot: StatsSnapshot?, options: StatsRenderer.Options) {
        for m in StatsModule.allCases {
            for mode in m.modes {
                let img = StatsRenderer.image(m, mode, snapshot, options)
                let w = img.size.width + 8, h: CGFloat = 26
                for (suffix, bg, fg) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black), ("dark", NSColor(white: 0.16, alpha: 1), NSColor.white)] {
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    rep?.size = NSSize(width: w, height: h)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = rep.map { NSGraphicsContext(bitmapImageRep: $0) } ?? nil
                    bg.setFill()
                    NSRect(x: 0, y: 0, width: w, height: h).fill()
                    // Tint the template like the menu bar does.
                    let tinted = NSImage(size: img.size, flipped: false) { r in
                        img.draw(in: r)
                        fg.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(at: NSPoint(x: 4, y: 2), from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                    write(rep, "item_\(m.rawValue)_\(mode.rawValue)_\(suffix)")
                }
            }
        }
    }

    static func view(_ view: NSView, _ name: String, dark: Bool) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        let back = NSVisualEffectView(frame: NSRect(origin: .zero, size: view.frame.size))
        back.material = .menu
        back.state = .active
        back.appearance = view.appearance
        window.contentView = back
        back.addSubview(view)
        view.frame.origin = .zero
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = back.bitmapImageRepForCachingDisplay(in: back.bounds)
        if let rep { back.cacheDisplay(in: back.bounds, to: rep) }
        write(rep, name)
        view.removeFromSuperview()
    }
}

/// Debug: proves that fixed elements never move when values change length (the "jumping arrow"
/// bug). Renders items with very different values and compares the pixels of fixed regions.
enum JitterCheck {
    private static func alphaColumns(_ img: NSImage, fromX x0: CGFloat, toX x1: CGFloat) -> [UInt8] {
        guard let rep = img.representations.first as? NSBitmapImageRep else { return [] }
        let scale = CGFloat(rep.pixelsWide) / img.size.width
        var out: [UInt8] = []
        for y in 0..<rep.pixelsHigh {
            for x in Int(x0 * scale)..<min(Int(x1 * scale), rep.pixelsWide) {
                out.append(UInt8(truncatingIfNeeded: Int((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255)))
            }
        }
        return out
    }

    static func run() -> [String: Bool] {
        let o = StatsRenderer.Options()
        var results: [String: Bool] = [:]

        // Network: arrows must be pixel-identical whatever the rates are.
        let rates: [(Double, Double)] = [(0, 0), (512, 1536), (999_000, 12_345_678), (5_000, 999), (1.2e9, 3)]
        var arrowRegions: [[UInt8]] = []
        var widths = Set<CGFloat>()
        for (up, down) in rates {
            var s = StatsSnapshot()
            s.netUp = up
            s.netDown = down
            let img = StatsRenderer.image(.network, .rates, s, o)
            widths.insert(img.size.width)
            arrowRegions.append(alphaColumns(img, fromX: 0, toX: 1 + StatsRenderer.arrowWidth + 1))
        }
        results["networkArrowsFixed"] = Set(arrowRegions.map { $0.description }).count == 1 && !(arrowRegions.first?.isEmpty ?? true)
        results["networkWidthConstant"] = widths.count == 1

        // CPU: the graph must be identical while only the percentage changes (9% → 100%).
        var graphRegions: [[UInt8]] = []
        var cpuWidths = Set<CGFloat>()
        for total in [0.09, 0.42, 1.0, 0.0] {
            var s = StatsSnapshot()
            s.cpuHistory = [0.1, 0.3, 0.5, 0.2, 0.9, 0.4, 0.6, 0.3, 0.8, 0.5]
            s.cpu = CPUUsage(total: total, user: total / 2, system: total / 2, perCore: [])
            let img = StatsRenderer.image(.cpu, .graphPercent, s, o)
            cpuWidths.insert(img.size.width)
            graphRegions.append(alphaColumns(img, fromX: 0, toX: 1 + StatsRenderer.graphWidth))
        }
        results["cpuGraphFixed"] = Set(graphRegions.map { $0.description }).count == 1
        results["cpuWidthConstant"] = cpuWidths.count == 1

        // Memory / disk pie + percentage, battery, clock: constant width whatever the value.
        var other = true
        for f in [0.01, 0.5, 0.999] {
            var s = StatsSnapshot()
            s.memory = MemoryBreakdown(total: 100, app: UInt64(f * 100), wired: 0, compressed: 0, cached: 0, free: 0)
            s.battery = BatteryInfo(percent: Int(f * 100), charging: f < 0.5, onAC: true, charged: false)
            other = other && StatsRenderer.image(.memory, .piePercent, s, o).size.width == StatsRenderer.width(.memory, .piePercent, o)
            other = other && StatsRenderer.image(.battery, .iconPercent, s, o).size.width == StatsRenderer.width(.battery, .iconPercent, o)
        }
        results["otherWidthsConstant"] = other
        return results
    }
}
