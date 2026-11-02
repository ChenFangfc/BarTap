import AppKit
import CoreAudio
import BarTapCore

/// Headless checks for the Volume, Bluetooth, 3-in-1 and power-flow stats (handled at the top of
/// main.swift, before any settings are touched; no status items, no privacy prompts):
///
///   BarTap --trio-probe [--names]          real readings from this Mac (names redacted by default);
///          [--listener-check]              also nudges the INPUT volume 5% and back to prove the
///                                          CoreAudio listeners fire while running and not after stop
///   BarTap --trio-render <dir> [--live]    every new preset and dropdown to PNG, English + Chinese
///   BarTap --trio-cpu <seconds> [--detail] CPU of the new readers at the default 1 s interval
///
/// Never touches IOBluetooth or CoreBluetooth (those need Bluetooth permission and only run when
/// someone clicks Connect / Disconnect in the signed app).
enum TrioProbe {
    // MARK: Probe

    static func probe(names: Bool) {
        func device(_ s: String?) -> String { names ? (s ?? "-") : "<device>" }
        func app(_ s: String) -> String { names ? s : "<app>" }
        func ms(_ n: Int = 1, _ body: () -> Void) -> Double {
            let t = CFAbsoluteTimeGetCurrent()
            for _ in 0..<n { body() }
            return (CFAbsoluteTimeGetCurrent() - t) * 1000 / Double(n)
        }
        func f(_ v: Double?, _ format: String = "%.2f") -> String { v.map { String(format: format, $0) } ?? "–" }

        print("== Volume (CoreAudio property listeners)")
        let audio = AudioMonitor()
        let halMs = ms { _ = AudioMonitor.defaultDevice(output: true) }
        let startMs = ms { audio.start() }
        print(String(format: "first CoreAudio call (loads the HAL client, once per process) %.1f ms", halMs))
        if let a = audio.state {
            print("default output: \(device(a.output?.name)) transport=\(fourCC(a.output?.transport ?? 0)) volume=\(a.volume.map { StatFormat.percent($0) } ?? "no control") muted=\(a.muted) canMute=\(a.canMute)")
            print("default input:  \(device(a.input?.name)) level=\(a.inputVolume.map { StatFormat.percent($0) } ?? "no control")")
            print("selectable outputs: \(a.outputs.count) [\(a.outputs.map { fourCC($0.transport) }.joined(separator: " "))], inputs: \(a.inputs.count)")
            print("glyph: waves=\(VolumeMath.waves(a.level, muted: a.muted)) meter=\(VolumeMath.filledBars(a.level, muted: a.muted))/\(VolumeMath.meterBars) text=\(VolumeMath.percentText(a.level, muted: a.muted))")
        } else {
            print("no audio state")
        }
        print(String(format: "cost: start (listeners + device list) %.2f ms, one refresh %.3f ms", startMs, ms(20) { audio.refresh() }))
        print("listeners installed: \(audio.listenerCount)")
        if CommandLine.arguments.contains("--listener-check") { listenerCheck(audio) }
        audio.stop()

        print("\n== Bluetooth (system_profiler SPBluetoothDataType -json; no prompt)")
        let child0 = childCPU(), wall0 = Date()
        let bt = BluetoothMonitor.readProfile()
        print(String(format: "read: %.2f s wall, %.0f ms CPU in the child process", Date().timeIntervalSince(wall0), (childCPU() - child0) * 1000))
        if let bt {
            print("powered=\(bt.powered) paired=\(bt.devices.count) connected=\(bt.connected.count)")
            for d in bt.devices {
                let battery = BluetoothPanel.batteryTextPlain(d)
                print("  \(d.connected ? "connected" : "paired   ") \(device(d.name)) [\(d.kind.rawValue)\(d.lowEnergyOnly ? ", LE only" : "")]\(battery.isEmpty ? "" : " battery " + battery)")
            }
            print("menu bar: lowest=\(bt.lowest?.lowestBattery.map { "\($0)%" } ?? "–") earbuds L/R=\(bt.earbuds.map { "\($0.left ?? -1)/\($0.right ?? -1)" } ?? "–")")
        } else {
            print("no data")
        }
        print("IORegistry BatteryPercent (Apple HID devices): \(PeripheralBatteryReader.sample().count) device(s)")

        print("\n== Wi-Fi (CoreWLAN; no Location prompt)")
        let link = WiFiLinkReader.sample(detail: true)
        print("rssi=\(link.rssi.map { "\($0) dBm" } ?? "none") bars=\(link.bars)/3 powered=\(link.powered) ssid visible without prompt=\(link.ssid != nil)")
        print(String(format: "cost: %.2f ms per RSSI read (menu bar: at most every 10 s, or on a Wi-Fi path change)", ms(10) { _ = WiFiLinkReader.sample(detail: false) }))

        print("\n== Battery power flow")
        let smc = SMC()
        var b = BatteryReader.quick()
        if b != nil { BatteryReader.details(into: &b!) }
        if let b {
            print("battery: \(b.percent)% charging=\(b.charging) onAC=\(b.onAC) charged=\(b.charged) cycles=\(b.cycles ?? -1) health=\(b.healthPercent ?? -1)% temp=\(f(b.temperature, "%.1f"))°C adapter=\(b.adapterWatts.map { "\($0) W rated" } ?? "none") gauge V×A=\(f(b.voltage.flatMap { v in b.amperage.map { v * $0 } }, "%.2f")) W")
        } else {
            print("no battery")
        }
        print("SMC (\(SMC.isAppleSilicon ? "little" : "big")-endian battery keys): PDTR=\(f(smc.value("PDTR"))) W PSTR=\(f(smc.value("PSTR"))) W B0AC=\(f(smc.integer("B0AC"), "%.0f")) mA B0AV=\(f(smc.integer("B0AV"), "%.0f")) mV PDBR=\(f(smc.value("PDBR"))) W")
        let flow = PowerFlowReader.sample(smc: smc, battery: b, full: true)
        print("flow [\(flow?.source.rawValue ?? "-")]: adapter \(PowerFlowMath.plain(flow?.adapter)) → Mac \(PowerFlowMath.plain(flow?.system)), battery \(PowerFlowMath.wattsText(flow?.battery)) (\(flow.map { "\($0.direction)" } ?? "-")), display \(PowerFlowMath.plain(flow?.display))")
        if let t = BatteryReader.telemetry() {
            let tf = PowerFlowMath.fromTelemetry(t, onAC: b?.onAC ?? true, charging: b?.charging ?? false)
            print("telemetry fallback: adapter \(PowerFlowMath.plain(tf?.adapter)) → Mac \(PowerFlowMath.plain(tf?.system)), battery \(PowerFlowMath.wattsText(tf?.battery))")
        }
        print("menu bar element: \(PowerFlowMath.barText(flow?.battery))")
        print(String(format: "cost: SMC flow %.3f ms, telemetry %.3f ms, battery details %.3f ms",
                     ms(20) { _ = PowerFlowReader.sample(smc: smc, battery: b, full: false) },
                     ms(20) { _ = BatteryReader.telemetry() },
                     ms(20) { var x = b; if x != nil { BatteryReader.details(into: &x!) } }))

        print("\n== Energy by app (rusage v6 energy, 6 samples 1 s apart, helpers grouped)")
        let energy = EnergyReader()
        var top: [EnergyUse] = []
        var costs: [Double] = []
        for i in 0..<6 {
            costs.append(ms { top = energy.sample() })
            if i < 5 { Thread.sleep(forTimeInterval: 1) }
        }
        for e in top { print(String(format: "  %@ %.2f W (%d process%@)", app(e.name), e.watts, e.processes, e.processes == 1 ? "" : "es")) }
        print("cost per sample (ms): " + costs.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " (the second resolves each process's app once)")
    }

    /// Nudges the default INPUT device's volume down 5% and back to the exact previous value (it
    /// doesn't affect what anyone hears), with the monitor running and again after stop().
    private static func listenerCheck(_ audio: AudioMonitor) {
        let input = AudioMonitor.defaultDevice(output: false)
        guard input != 0, let v0 = AudioMonitor.volume(input, scope: kAudioObjectPropertyScopeInput) else { print("listener check: no input volume"); return }
        func nudge() {
            AudioMonitor.setVolume(input, scope: kAudioObjectPropertyScopeInput, Float32(max(0, v0 - 0.05)))
            AudioMonitor.setVolume(input, scope: kAudioObjectPropertyScopeInput, Float32(v0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }
        let e0 = audio.events
        nudge()
        let whileRunning = audio.events - e0
        audio.stop()
        let e1 = audio.events
        nudge()
        let afterStop = audio.events - e1
        let restored = AudioMonitor.volume(input, scope: kAudioObjectPropertyScopeInput)
        print("listener check: events while running \(whileRunning), after stop \(afterStop), listeners after stop \(audio.listenerCount); input volume restored exactly: \(restored == v0)")
    }

    private static func fourCC(_ v: UInt32) -> String {
        let s = String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        return s.trimmingCharacters(in: .controlCharacters).isEmpty ? "-" : s
    }

    /// CPU seconds of this process and of its finished children.
    static func ownCPU() -> Double { cpu(RUSAGE_SELF) }
    static func childCPU() -> Double { cpu(RUSAGE_CHILDREN) }
    private static func cpu(_ who: Int32) -> Double {
        var r = rusage()
        getrusage(who, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }

    // MARK: Render

    /// The new presets in the menu bar, plus state variations, on light and dark bars; and the new
    /// dropdowns. Sample data unless `live`.
    static func render(to dir: URL, live: Bool) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sample = live ? liveSnapshot() : PromoAssets.sampleSnapshot(step: 3)
        let o = StatsRenderer.Options()
        for language in [AppLanguage.en, .zhHans] {
            Loc.language = language
            let tag = language == .en ? "en" : "zh"
            for dark in [false, true] {
                var rows: [(String, NSImage)] = []
                for m in [StatsModule.volume, .bluetooth, .trio, .battery] {
                    for p in m.presets {
                        rows.append(("\(StatsNames.module(m)): \(StatsNames.title(p))", StatsRenderer.image(m, p, sample, o)))
                    }
                }
                for (title, s) in variations(sample) {
                    rows.append((title + " · 3-in-1", StatsRenderer.image(.trio, [.trio], s, o)))
                    rows.append((title + " · volume", StatsRenderer.image(.volume, [.speaker, .levelMeter, .percent], s, o)))
                    rows.append((title + " · bluetooth", StatsRenderer.image(.bluetooth, [.bluetoothIcon, .lowestBattery, .airPods], s, o)))
                    rows.append((title + " · battery", StatsRenderer.image(.battery, [.battery, .batteryPower], s, o)))
                }
                sheet(rows, dark: dark, to: dir.appendingPathComponent("items_\(tag)_\(dark ? "dark" : "light").png"))
            }
            if language == .en {
                // Each new glyph in each state, enlarged (rows: elements; columns: states).
                let states = [("sample", sample)] + variations(sample)
                let cells: [[NSImage]] = [(StatsModule.trio, StatsElement.trio), (.volume, .speaker), (.volume, .levelMeter),
                                          (.bluetooth, .bluetoothIcon), (.bluetooth, .lowestBattery), (.bluetooth, .airPods),
                                          (.battery, .batteryPower)].map { m, e in states.map { StatsRenderer.image(m, [e], $0.1, o) } }
                for dark in [false, true] { grid(cells, dark: dark, to: dir.appendingPathComponent("glyphs_\(dark ? "dark" : "light").png")) }
            }
            let panels: [(String, StatsPanel)] = [
                ("volume", VolumePanel(audio: nil, state: sample.audio)),
                ("bluetooth", BluetoothPanel(state: sample.bluetooth, updated: Date().addingTimeInterval(-25), access: .notAsked)),
                ("trio", TrioPanel()),
                ("battery", BatteryPanel()),
            ]
            for (name, panel) in panels {
                panel.update(sample, o)
                panel.compact()
                for dark in [false, true] {
                    PromoAssets.capture(panel, dark: dark, scale: 2, to: dir.appendingPathComponent("panel_\(name)_\(tag)_\(dark ? "dark" : "light").png"))
                }
            }
        }
        Loc.language = .system
        // Fixed widths and fixed glyph positions, all modules (the debug jitter check).
        print("jitter check: " + JitterCheck.run().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        print("rendered to \(dir.path)")
    }

    /// Edge cases for the glyphs: full and charging, low and muted, no Wi-Fi, Bluetooth off.
    private static func variations(_ base: StatsSnapshot) -> [(String, StatsSnapshot)] {
        var out: [(String, StatsSnapshot)] = []
        var a = base
        a.battery = BatteryInfo(percent: 100, charging: true, onAC: true, charged: false, minutesRemaining: 20)
        a.power = PowerFlow(adapter: 61, system: 35, battery: 23.4, source: .smc)
        a.barWatts = 23.4
        a.audio?.volume = 1
        a.wifi = WiFiLink(rssi: -40, ssid: nil)
        out.append(("charging, loud, strong", a))
        var b = base
        b.battery = BatteryInfo(percent: 12, charging: false, onAC: false, charged: false, minutesRemaining: 31)
        b.power = PowerFlow(adapter: nil, system: 14.2, battery: -14.2, source: .smc)
        b.barWatts = -14.2
        b.audio?.muted = true
        b.wifi = WiFiLink(rssi: -80, ssid: nil)
        b.bluetooth = BluetoothState(powered: true, devices: [])
        out.append(("low, muted, weak, nothing connected", b))
        var c = base
        c.battery = nil
        c.power = nil
        c.barWatts = nil
        c.audio?.volume = 0.12
        c.wifi = WiFiLink(rssi: nil, ssid: nil)
        c.bluetooth = BluetoothState(powered: false, devices: [])
        out.append(("no battery, quiet, no Wi-Fi, Bluetooth off", c))
        var d = base
        d.audio = nil
        d.bluetooth = nil
        d.wifi = nil
        out.append(("not read yet", d))
        return out
    }

    /// Images in a grid on menu bar strips at 6x.
    private static func grid(_ cells: [[NSImage]], dark: Bool, to url: URL) {
        let scale: CGFloat = 6, cellW: CGFloat = 70, cellH: CGFloat = 26
        let cols = cells.map(\.count).max() ?? 0
        let size = NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(cells.count))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        let fg = dark ? NSColor.white : NSColor.black
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (r, row) in cells.enumerated() {
            for (c, img) in row.enumerated() {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    fg.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: NSPoint(x: CGFloat(c) * cellW + 4, y: size.height - CGFloat(r + 1) * cellH + 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    /// Rows of "title  [item on a menu bar strip]" at 3x, so details are reviewable.
    private static func sheet(_ rows: [(String, NSImage)], dark: Bool, to url: URL) {
        let scale: CGFloat = 3, rowH: CGFloat = 26, titleW: CGFloat = 330
        let itemW = (rows.map(\.1.size.width).max() ?? 40) + 16
        let size = NSSize(width: titleW + itemW, height: rowH * CGFloat(rows.count) + 8)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        let bar = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let fg = dark ? NSColor.white : NSColor.black
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.08, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (i, (title, img)) in rows.enumerated() {
            let y = size.height - 4 - rowH * CGFloat(i + 1)
            (title as NSString).draw(at: NSPoint(x: 6, y: y + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: fg.withAlphaComponent(0.7)])
            bar.setFill()
            NSRect(x: titleW, y: y + 1, width: img.size.width + 12, height: rowH - 2).fill()
            // Tint the template like the menu bar does.
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                fg.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: titleW + 6, y: y + 3), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    /// This Mac's current values, read once (local layout checks; contains device names).
    private static func liveSnapshot() -> StatsSnapshot {
        var s = PromoAssets.sampleSnapshot(step: 3)
        let audio = AudioMonitor()
        audio.start()
        s.audio = audio.state
        audio.stop()
        s.bluetooth = BluetoothMonitor.readProfile()
        s.wifi = WiFiLinkReader.sample(detail: true)
        var b = BatteryReader.quick()
        if b != nil { BatteryReader.details(into: &b!) }
        s.battery = b
        s.power = PowerFlowReader.sample(smc: SMC(), battery: b, full: true)
        let energy = EnergyReader()
        _ = energy.sample()
        Thread.sleep(forTimeInterval: 2)
        s.energy = energy.sample()
        return s
    }

    // MARK: CPU

    /// Runs the new readers headlessly at the default 1 s interval and reports CPU after a 5 s
    /// warm-up: the engine with the 3-in-1 item and the battery's charge rate in the bar, the
    /// audio listeners, and the Bluetooth reader (a battery element shown → every 60 s). Each
    /// changed item image is rendered as the controller would; the menu bar host's own cost of
    /// showing it (~9 ms per changed image on three displays) is not part of this process.
    static func cpu(seconds: Double, detail: Bool) {
        _ = NSApplication.shared
        let engine = StatsEngine()
        let audio = AudioMonitor()
        let bt = BluetoothMonitor()
        let o = StatsRenderer.Options()
        let items: [(StatsModule, [StatsElement])] = [(.trio, [.trio, .percent]), (.volume, [.speaker, .percent]),
                                                      (.bluetooth, [.bluetoothIcon, .lowestBattery]), (.battery, [.battery, .batteryPower])]
        var last: StatsSnapshot?
        var drawn: [String: String] = [:]
        var images = 0, skipped = 0, ticks = 0
        func render() {
            for (m, e) in items {
                let sig = StatsRenderer.signature(m, e, last, o)
                if drawn[m.rawValue] == sig { skipped += 1; continue }
                drawn[m.rawValue] = sig
                _ = StatsRenderer.image(m, e, last, o)
                images += 1
            }
        }
        engine.onSnapshot = { s in
            var s = s
            s.audio = audio.state
            s.bluetooth = bt.state
            last = s
            ticks += 1
            render()
        }
        audio.onChange = { st in
            if last == nil { last = StatsSnapshot() }
            last?.audio = st
            render()
        }
        bt.onChange = { st, _ in
            if last == nil { last = StatsSnapshot() }
            last?.bluetooth = st
            render()
        }
        let cpu0 = ownCPU(), child0 = childCPU()
        audio.start()
        bt.periodic = true
        bt.start()
        engine.setPowerInBar(true)
        engine.configure(modules: [.trio, .battery], interval: 1)
        if detail {
            engine.setDetail(.battery, true)
            engine.setDetail(.trio, true)
            bt.setDetail(true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        let warm = (ownCPU() - cpu0, childCPU() - child0)
        let cpu1 = ownCPU(), child1 = childCPU(), t1 = Date(), ticks1 = ticks, images1 = images
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let wall = Date().timeIntervalSince(t1)
        let own = ownCPU() - cpu1, child = childCPU() - child1
        var sample = 0.0
        engine.timing { s, _ in sample = s }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        audio.stop()
        bt.stop()
        print(String(format: "warm-up (5 s, first device reads): own %.0f ms, children %.0f ms", warm.0 * 1000, warm.1 * 1000))
        print(String(format: "%@ %.0f s: own CPU %.0f ms (%.3f%%), system_profiler %.0f ms (%.3f%%), total %.3f%% of one core",
                     detail ? "dropdowns open," : "menu bar only,", wall, own * 1000, own / wall * 100, child * 1000, child / wall * 100,
                     (own + child) / wall * 100))
        print("engine ticks \(ticks - ticks1), images rendered \(images - images1), unchanged skipped \(skipped); engine sampling \(String(format: "%.2f", sample * 1000 / Double(max(ticks, 1)))) ms wall per tick")
        print("reads in total: Wi-Fi \(WiFiLinkReader.reads), power flow \(PowerFlowReader.reads), system_profiler \(BluetoothMonitor.reads)")
    }
}

extension BluetoothPanel {
    /// The dropdown's battery text in English (probe output).
    static func batteryTextPlain(_ d: BluetoothDevice) -> String {
        var parts: [String] = []
        if let l = d.left { parts.append("L \(l)%") }
        if let r = d.right { parts.append("R \(r)%") }
        if let c = d.caseBattery { parts.append("case \(c)%") }
        if parts.isEmpty, let b = d.battery { parts.append("\(b)%") }
        return parts.joined(separator: " ")
    }
}
