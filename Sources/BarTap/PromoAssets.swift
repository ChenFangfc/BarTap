import AppKit
import BarTapCore

/// `BarTap --export-promo-assets <dir>`: renders BarTap's real menu bar items, dropdowns and
/// settings pages from SAMPLE data (no personal process names, addresses or disks) for the README
/// and the promo film. Runs without creating any status items, then exits.
enum PromoAssets {
    static func sampleSnapshot(step i: Int) -> StatsSnapshot {
        var s = StatsSnapshot()
        let wave = { (k: Double) -> Double in 0.5 + 0.5 * sin(Double(i) * 0.7 + k) }
        // Deterministic noise in [0, 1): graphs look like real load, not sine waves.
        let noise = { (n: Int) -> Double in let x = sin(Double(n) * 12.9898) * 43758.5453; return x - x.rounded(.down) }
        let history = (0..<90).map { j -> Double in
            let n = j + i
            return 0.1 + 0.16 * (noise(n) + noise(n + 1)) / 2 + 0.35 * pow(noise(n + 500), 6)
        }
        s.cpuHistory = history
        let total = min(0.95, history.last ?? 0.2)
        s.cpu = CPUUsage(total: total, user: total * 0.64, system: total * 0.36,
                         perCore: (0..<12).map { c in min(1, 0.08 + 0.6 * (0.5 + 0.5 * sin(Double(c * 3 + i) * 0.9))) })
        s.coreLayout = (8, 4)
        s.loadAverage = [3.12, 2.87, 2.65]
        s.uptime = 3 * 86400 + 4 * 3600
        s.gpu = 0.18 + 0.1 * wave(1)
        s.gpuHistory = history.map { $0 * 0.6 }
        s.gpuInfo = GPUInfo(utilization: s.gpu ?? 0.2, renderer: 0.17, tiler: 0.15, memoryInUse: 1_900_000_000, memoryAllocated: 6_200_000_000)
        let gb: UInt64 = 1_073_741_824
        s.memory = MemoryBreakdown(total: 32 * gb, app: 12 * gb + UInt64(Double(gb) * wave(2)), wired: 3 * gb, compressed: 2 * gb, cached: 8 * gb, free: 6 * gb)
        s.memoryHistory = history.map { 0.55 + $0 * 0.1 }
        s.pressure = .normal
        s.swap = (512 * 1_048_576, 2 * gb)
        s.diskRead = [8e3, 1.2e6, 340e3, 2.4e6][i % 4]
        s.diskWrite = [880e3, 64e3, 5.1e6, 210e3][i % 4]
        s.diskReadHistory = (0..<90).map { j in 2.4e6 * pow(noise(j + i + 600), 5) }
        s.diskWriteHistory = (0..<90).map { j in 1.4e6 * pow(noise(j + i + 900), 4) }
        s.volumes = [VolumeInfo(name: "Macintosh HD", mountPoint: "/", total: 994 * gb, free: 412 * gb)]
        s.netDown = [2.4e6, 860e3, 15.2e6, 4.1e3, 1.1e6, 312e3][i % 6]
        s.netUp = [48e3, 1.2e3, 640e3, 12e3, 96e3, 3e3][i % 6]
        s.netDownHistory = (0..<90).map { j in 4e6 * (0.04 + 0.96 * pow(noise(j + i + 7), 4)) }
        s.netUpHistory = (0..<90).map { j in 6e5 * (0.04 + 0.96 * pow(noise(j + i + 300), 5)) }
        s.netSessionDown = 3_400_000_000
        s.netSessionUp = 420_000_000
        var u = DataUsage(day: "d0", month: "m")
        u.add(rx: 44_600_000_000, tx: 5_700_000_000, day: "d0", month: "m")
        u.add(rx: 3_400_000_000, tx: 420_000_000, day: "d1", month: "m")
        s.usage = u
        s.interfaces = [InterfaceInfo(name: "en0", addresses: ["192.168.1.20"])]
        s.netDetails = NetworkDetails(router: "192.168.1.1", dns: ["192.168.1.1"], primaryInterface: "en0",
                                      wifi: WiFiInfo(ssid: nil, rssi: -48, noise: -94, channel: 149, rateMbps: 1200))
        s.sensors = SensorReadings(cpu: 46 + 6 * wave(3), cpuMax: 61, gpu: 41, battery: 31, storage: 35, ambient: 29,
                                   fans: [FanReading(rpm: 1350, min: 1350, max: 5350), FanReading(rpm: 1522, min: 1520, max: 5780)], systemPower: 8.4 + 3 * wave(4))
        s.battery = BatteryInfo(percent: 86, charging: false, onAC: false, charged: false, minutesRemaining: 512,
                                cycles: 132, healthPercent: 97, temperature: 31, voltage: 12.8, amperage: -0.62, adapterWatts: nil, condition: "Normal")
        s.thermal = .nominal
        s.processCount = 612
        let apps = ["Safari", "Xcode", "Music", "Mail", "Finder", "Photos", "Notes"]
        s.topCPU = apps.prefix(5).enumerated().map { ProcessUsage(pid: 100 + Int32($0.offset), name: $0.element, cpu: [2.4, 1.3, 0.6, 0.3, 0.12][$0.offset], memory: 0) }
        s.topMemory = apps.prefix(5).enumerated().map { ProcessUsage(pid: 100 + Int32($0.offset), name: $0.element, cpu: 0, memory: [2_400, 1_900, 820, 610, 420][$0.offset] * 1_048_576) }
        s.topDisk = ["Photos", "Mail", "Spotlight"].enumerated().map { ProcessUsage(pid: 200 + Int32($0.offset), name: $0.element, cpu: 0, memory: 0, diskRate: [1.8e6, 240e3, 64e3][$0.offset]) }
        return s
    }

    static func export(to dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("items"), withIntermediateDirectories: true)
        let o = StatsRenderer.Options(fahrenheit: false, bits: false, clockFormat: "EEE HH:mm")
        var c = DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 41)
        let clockDate = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        let items: [(StatsModule, StatsMode)] = [(.cpu, .graphPercent), (.memory, .piePercent), (.disk, .piePercent),
                                                  (.network, .rates), (.sensors, .cpuTemperature), (.time, .clock),
                                                  (.battery, .iconPercent), (.gpu, .graphPercent)]
        for step in 0..<12 {
            let s = sampleSnapshot(step: step)
            for (m, mode) in items {
                let w = StatsRenderer.width(m, mode, o)
                let img = StatsRenderer.bitmap(width: w, scale: 6) { r in StatsRenderer.drawContent(m, mode, s, o, r, now: clockDate) }
                write(img, dir.appendingPathComponent("items/\(m.rawValue)_\(step).png"))
            }
        }
        c.minute = 41
        // Toggle glyph, collapsed and revealed.
        for (name, mirrored) in [("toggle_collapsed", false), ("toggle_revealed", true)] {
            let glyph = Icons.logoMark(mirrored: mirrored)
            let img = StatsRenderer.bitmap(width: glyph.size.width, scale: 6) { r in
                glyph.draw(in: NSRect(x: 0, y: (r.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            }
            write(img, dir.appendingPathComponent("items/\(name).png"))
        }
        // Dropdown panels with sample data, light and dark.
        let s = sampleSnapshot(step: 3)
        let panels: [(String, StatsPanel)] = [("cpu", CPUPanel()), ("memory", MemoryPanel()), ("network", NetworkPanel()),
                                               ("sensors", SensorsPanel()), ("disk", DiskPanel()), ("battery", BatteryPanel())]
        for (name, panel) in panels {
            panel.update(s, o)
            panel.compact()
            for dark in [false, true] {
                capture(panel, dark: dark, scale: 2, to: dir.appendingPathComponent("panel_\(name)_\(dark ? "dark" : "light").png"))
            }
        }
        print("exported promo assets to \(dir.path)")
    }

    /// Renders a view at `scale` on a solid menu-colored background (an offscreen material view
    /// has no backdrop and renders flat gray).
    private static func capture(_ view: NSView, dark: Bool, scale: CGFloat, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let size = view.frame.size
        let back = NSView(frame: NSRect(origin: .zero, size: size))
        back.appearance = appearance
        view.appearance = appearance
        let window = NSWindow(contentRect: back.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = back
        back.addSubview(view)
        view.frame.origin = .zero
        back.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.985, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.restoreGraphicsState()
            back.cacheDisplay(in: back.bounds, to: rep)
        }
        view.removeFromSuperview()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    private static func write(_ img: NSImage, _ url: URL) {
        guard let rep = img.representations.first as? NSBitmapImageRep,
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
