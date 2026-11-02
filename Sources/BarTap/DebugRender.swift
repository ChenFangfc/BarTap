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
            for elements in m.presets {
                let img = StatsRenderer.image(m, elements, snapshot, options)
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
                    write(rep, "item_\(m.rawValue)_\(elements.map(\.rawValue).joined(separator: "+"))_\(suffix)")
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

    /// Very different values for every module: tiny, typical and huge.
    private static func snapshots() -> [StatsSnapshot] {
        let gb: UInt64 = 1_073_741_824
        return [(0.0, 0.0, 0.01), (512.0, 1536.0, 0.5), (999_000.0, 12_345_678.0, 0.999), (1.2e9, 3.0, 0.2)].map { up, down, f in
            var s = StatsSnapshot()
            s.netUp = up; s.netDown = down
            s.diskRead = down; s.diskWrite = up
            s.cpuHistory = [0.1, 0.3, 0.5, 0.2, 0.9, 0.4, 0.6, 0.3, 0.8, 0.5]
            s.cpu = CPUUsage(total: f, user: f / 2, system: f / 2, perCore: [f, 1 - f])
            s.gpu = f
            s.memory = MemoryBreakdown(total: 64 * gb, app: UInt64(f * 60) * gb + 300_000_000, wired: 0, compressed: 0, cached: 0, free: 0)
            s.volumes = [VolumeInfo(name: "Disk", mountPoint: "/", total: 4096 * gb, free: UInt64((1 - f) * 4000) * gb + 1)]
            s.sensors = SensorReadings(cpu: 20 + f * 90, cpuMax: nil, gpu: nil, battery: nil, storage: nil, ambient: nil,
                                       fans: [FanReading(rpm: f * 9000, min: 0, max: 9000)], systemPower: f * 150)
            s.battery = BatteryInfo(percent: Int(f * 100), charging: f < 0.5, onAC: true, charged: false, minutesRemaining: Int(f * 5999))
            s.power = PowerFlow(adapter: f * 140, system: f * 90, battery: (f - 0.5) * 190, source: .smc)
            s.barWatts = (f - 0.5) * 370
            s.audio = AudioState(output: AudioDevice(id: 1, name: "Out", transport: 0), volume: f, muted: f > 0.9, canMute: true)
            s.bluetooth = BluetoothState(powered: f > 0.1, devices: (0..<Int(f * 12)).map {
                BluetoothDevice(name: "D\($0)", address: "\($0)", connected: true, kind: .earbuds, left: Int(f * 100), right: $0 * 9 % 101)
            })
            s.wifi = WiFiLink(rssi: f > 0.1 ? -40 - Int(f * 50) : nil, ssid: nil)
            return s
        }
    }

    /// Pixels of the element at `index` within `elements` (an item's fixed glyph region).
    private static func region(_ img: NSImage, _ m: StatsModule, _ elements: [StatsElement], _ index: Int, upTo width: CGFloat, _ o: StatsRenderer.Options) -> [UInt8] {
        var x = StatsRenderer.inset
        for e in elements.prefix(index) { x += StatsRenderer.elementWidth(e, m, o) + StatsRenderer.gap }
        return alphaColumns(img, fromX: x, toX: x + width)
    }

    static func run() -> [String: Bool] {
        let o = StatsRenderer.Options()
        let shots = snapshots()
        var results: [String: Bool] = [:]

        // Fixed glyphs must be pixel-identical whatever the values are.
        func fixed(_ m: StatsModule, _ elements: [StatsElement], index: Int, width: CGFloat) -> Bool {
            let regions = shots.map { region(StatsRenderer.image(m, elements, $0, o), m, elements, index, upTo: width, o) }
            return Set(regions.map(\.description)).count == 1 && !(regions.first?.isEmpty ?? true)
        }
        results["networkArrowsFixed"] = fixed(.network, [.rates], index: 0, width: StatsRenderer.arrowWidth + 1)
        results["diskReadWriteLabelsFixed"] = fixed(.disk, [.readWrite], index: 0, width: 6)
        results["memoryUsedFreeLabelsFixed"] = fixed(.memory, [.usedFree], index: 0, width: 9)
        results["arrowsFixedAfterGraph"] = fixed(.network, [.graph, .rates], index: 1, width: StatsRenderer.arrowWidth + 1)
        results["labelFixed"] = fixed(.cpu, [.label, .percent], index: 0, width: StatsRenderer.elementWidth(.label, .cpu, o))
        // CPU: the graph stays identical while only the percentage changes.
        results["cpuGraphFixed"] = fixed(.cpu, [.graph, .percent], index: 0, width: StatsRenderer.graphWidth)

        // Every element and every preset keeps one width whatever the values.
        var constant = true
        for m in StatsModule.allCases {
            for elements in m.elements.map({ [$0] }) + m.presets {
                let widths = Set(shots.map { StatsRenderer.image(m, elements, $0, o).size.width })
                constant = constant && widths.count == 1 && widths.first == StatsRenderer.width(m, elements, o)
            }
        }
        results["allWidthsConstant"] = constant
        return results
    }
}
