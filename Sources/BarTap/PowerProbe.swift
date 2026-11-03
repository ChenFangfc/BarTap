import AppKit
import BarTapCore

/// Headless checks for the Power item (handled at the top of main.swift, before any settings are
/// touched; no status items, no prompts):
///
///   BarTap --power-probe [--names]               real readings from this Mac (app names redacted)
///   BarTap --power-cpu <seconds> [--parts|--detail]  CPU of the Power item at the 1 s interval:
///                                                menu bar flow only, with the chip's parts, or with
///                                                the details open (apps and battery details too)
///   BarTap --power-render <dir>                  the details and every preset from live readings,
///                                                English + Chinese, light + dark
///   BarTap --bar-redraws <seconds>               your stats items (read from BarTap's settings,
///                                                nothing written): images the menu bar would get
///                                                with held figures and without, same readings
enum PowerProbe {
    static func handle(_ args: [String]) -> Int32? {
        if args.contains("--power-probe") { probe(names: args.contains("--names")); return 0 }
        if let i = args.firstIndex(of: "--power-cpu"), i + 1 < args.count {
            cpu(seconds: Double(args[i + 1]) ?? 30, parts: args.contains("--parts"), detail: args.contains("--detail"))
            return 0
        }
        if let i = args.firstIndex(of: "--power-render"), i + 1 < args.count {
            render(to: URL(fileURLWithPath: args[i + 1]))
            return 0
        }
        if let i = args.firstIndex(of: "--bar-redraws"), i + 1 < args.count {
            redraws(seconds: Double(args[i + 1]) ?? 60)
            return 0
        }
        return nil
    }

    private static func ms(_ n: Int = 1, _ body: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { body() }
        return (CFAbsoluteTimeGetCurrent() - t) * 1000 / Double(n)
    }

    private static func threadCPU() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    private static func ownCPU() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }

    static func probe(names: Bool) {
        let smc = SMC()
        let battery = BatteryReader.quick()
        print("battery: \(battery.map { "\($0.percent)% charging=\($0.charging) onAC=\($0.onAC)" } ?? "none")")
        var cpu0 = threadCPU()
        let flow = PowerSampler.read(smc: smc, battery: battery, full: true)
        print(String(format: "SMC flow read (7 keys): %.2f ms CPU", (threadCPU() - cpu0) * 1000))
        print("adapter \(PowerMath.watts(flow.adapter)) (\(PowerMath.volts(flow.inputVolts)), \(PowerMath.amps(flow.inputAmps))), Mac \(PowerMath.watts(flow.system)), battery \(PowerMath.signedWatts(flow.battery)) (\(PowerMath.volts(flow.batteryVolts)), \(PowerMath.amps(flow.batteryAmps, signed: true))), display \(PowerMath.watts(flow.components[.display]))")
        let model = EnergyModelReader()
        cpu0 = threadCPU()
        _ = model.sample()
        let first = (threadCPU() - cpu0) * 1000
        Thread.sleep(forTimeInterval: 1)
        cpu0 = threadCPU()
        let parts = model.sample()
        print(String(format: "energy model: subscribe + first sample %.2f ms CPU, a sample %.2f ms CPU", first, (threadCPU() - cpu0) * 1000))
        if let parts {
            let list = PowerComponent.allCases.compactMap { c in parts.components[c].map { "\(c.rawValue) \(PowerMath.watts($0))" } }
            print("parts: " + list.joined(separator: ", ") + ", media \(PowerMath.watts(parts.media))")
            var r = flow
            r.components.merge(parts.components) { _, chip in chip }
            print("other (rest of the Mac): \(PowerMath.watts(r.other))")
            let d = PowerDiagram.make(r)
            print("diagram: " + d.links.map { "\($0.from.rawValue)>\($0.to.rawValue) \(PowerMath.watts($0.watts))" }.joined(separator: ", "))
        } else {
            print("no energy model on this Mac")
        }
        cpu0 = threadCPU()
        let details = PowerDetailsReader.read()
        print(String(format: "AppleSmartBattery read: %.2f ms CPU", (threadCPU() - cpu0) * 1000))
        if let d = details {
            print("battery \(PowerMath.volts(d.voltage)) \(PowerMath.amps(d.amperage, signed: true)) \(d.temperature.map { String(format: "%.1f °C", $0) } ?? "–") cycles \(d.cycleCount ?? -1)/\(d.designCycleCount ?? -1) charge \(d.currentCharge ?? -1)/\(d.fullChargeCapacity ?? -1) mAh design \(d.designCapacity ?? -1) health \(d.healthPercent ?? -1)% cells \(d.cellVoltages) today \(d.dailyMinPercent ?? -1)–\(d.dailyMaxPercent ?? -1)%")
            print("adapter \(d.adapterWatts.map { "\($0) W" } ?? "–") negotiated \(PowerMath.volts(d.adapterVolts)) × \(PowerMath.amps(d.adapterAmps)) loss \(PowerMath.watts(d.adapterLoss)) charging current \(PowerMath.amps(d.chargingCurrent)) wireless=\(d.wireless) named=\(d.adapterName != nil)")
        }
        let energy = EnergyReader()
        cpu0 = threadCPU()
        _ = energy.sample(top: 6, totals: true)
        let firstApps = (threadCPU() - cpu0) * 1000
        Thread.sleep(forTimeInterval: 1)
        cpu0 = threadCPU()
        let apps = energy.sample(top: 6, totals: true)
        print(String(format: "apps: first pass %.1f ms CPU (looks up each process's app), then %.1f ms CPU", firstApps, (threadCPU() - cpu0) * 1000))
        for (i, a) in apps.enumerated() {
            print("  \(names ? a.name : "<app \(i + 1)>") \(PowerMath.watts(a.watts)) now, \(PowerMath.wattHours(a.joules)) since it started (\(a.processes) processes)")
        }
    }

    /// The engine with only the Power item, as the app runs it, and bar images as the app makes them.
    static func cpu(seconds: Double, parts: Bool, detail: Bool) {
        _ = NSApplication.shared
        let engine = StatsEngine()
        let o = StatsRenderer.Options()
        let elements: [StatsElement] = parts ? [.powerSystem, .powerCPU, .powerGPU] : [.powerIcon, .powerSystem]
        var last: StatsSnapshot?
        var drawn = "", images = 0, skipped = 0, ticks = 0
        engine.onSnapshot = { s in
            last = s
            ticks += 1
            let sig = StatsRenderer.signature(.power, elements, last, o)
            if sig == drawn { skipped += 1; return }
            drawn = sig
            _ = StatsRenderer.image(.power, elements, last, o)
            images += 1
        }
        engine.setPowerNeeds(StatsEngine.PowerNeeds(parts: parts, display: false, details: false))
        engine.configure(modules: [.power], interval: 1)
        if detail { engine.setDetail(.power, true) }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let cpu1 = ownCPU(), t1 = Date(), ticks1 = ticks, images1 = images, skipped1 = skipped
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let wall = Date().timeIntervalSince(t1)
        let own = ownCPU() - cpu1
        var sample = 0.0, allTicks = 1
        engine.timing { s, t in sample = s; allTicks = max(t, 1) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let mode = detail ? "details open" : parts ? "menu bar with CPU/GPU parts" : "menu bar, flow only"
        print(String(format: "%@, %.0f s: own CPU %.0f ms = %.3f%% of one core; sampling %.2f ms wall per tick", mode, wall, own * 1000,
                     own / wall * 100, sample * 1000 / Double(allTicks)))
        print("ticks \(ticks - ticks1), bar images drawn \(images - images1), unchanged skipped \(skipped - skipped1)")
        if let r = last?.powerReading { print("last: Mac \(PowerMath.watts(r.system)), CPU \(PowerMath.watts(r.components[.cpu]))") }
    }

    static func redraws(seconds: Double) {
        _ = NSApplication.shared
        guard let defaults = UserDefaults(suiteName: "io.github.chenfangfc.BarTap") else { return }
        let settings = Settings(defaults: defaults)
        let modules = settings.statsModules.filter { ![.ai, .volume, .bluetooth, .time].contains($0) }
        let o = StatsRenderer.Options(fahrenheit: settings.statsFahrenheit, bits: settings.statsNetworkBits)
        let engine = StatsEngine()
        var hold = BarHold()
        var raw: [StatsModule: String] = [:], held: [StatsModule: String] = [:]
        var rawCount: [StatsModule: Int] = [:], heldCount: [StatsModule: Int] = [:]
        var ticks = 0
        engine.onSnapshot = { s in
            ticks += 1
            hold.update(s, now: ProcessInfo.processInfo.systemUptime)
            let h = hold.apply(s)
            for m in modules {
                let e = settings.statsElements(m)
                let a = StatsRenderer.signature(m, e, s, o), b = StatsRenderer.signature(m, e, h, o)
                if raw[m] != a { raw[m] = a; rawCount[m, default: 0] += 1 }
                if held[m] != b { held[m] = b; heldCount[m, default: 0] += 1 }
            }
        }
        engine.configure(modules: Set(modules), interval: settings.statsInterval)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("\(ticks) readings; images per item, without holding → with:")
        for m in modules { print("  \(m.rawValue) \(settings.statsElements(m).map(\.rawValue)): \(rawCount[m] ?? 0) → \(heldCount[m] ?? 0)") }
        let a = rawCount.values.reduce(0, +), b = heldCount.values.reduce(0, +)
        print("total \(a) → \(b) (\(a > 0 ? Int((1 - Double(b) / Double(a)) * 100) : 0)% fewer)")
    }

    static func render(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = StatsEngine()
        var last: StatsSnapshot?
        engine.onSnapshot = { last = $0 }
        engine.setPowerNeeds(StatsEngine.PowerNeeds(parts: true, display: true, details: true))
        engine.configure(modules: [.power], interval: 1)
        engine.setDetail(.power, true)
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        guard let s = last else { print("no reading"); return }
        let o = StatsRenderer.Options()
        for language in [AppLanguage.en, .zhHans] {
            Loc.language = language
            let tag = language == .en ? "en" : "zh"
            let panel = PowerPanel(hasBattery: BatteryReader.quick() != nil, interval: 1)
            panel.drawStill()
            panel.update(s, o)
            panel.compact()
            for dark in [false, true] {
                PromoAssets.capture(panel, dark: dark, scale: 2, to: dir.appendingPathComponent("panel_power_\(tag)_\(dark ? "dark" : "light").png"))
            }
            for (i, p) in StatsModule.power.presets.enumerated() {
                let img = StatsRenderer.bitmap(width: StatsRenderer.width(.power, p, o), scale: 4) { r in StatsRenderer.drawContent(.power, p, s, o, r) }
                if let rep = img.representations.first as? NSBitmapImageRep, let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dir.appendingPathComponent("preset\(i)_\(tag).png"))
                }
            }
        }
        Loc.language = .system
        print("rendered to \(dir.path)")
    }
}
