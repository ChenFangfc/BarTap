import Foundation
import CoreGraphics
import BarTapCore

func runPowerTests() {
    test("power: energy model channels by name") {
        func part(_ n: String) -> EnergyModel.Part? { EnergyModel.part(forChannel: n) }
        expect(part("CPU Energy") == .component(.cpu) && part("DIE_1_CPU Energy") == .component(.cpu))
        expect(part("GPU Energy") == .component(.gpu))
        expect(part("ANE") == .component(.ane) && part("ANE0") == .component(.ane) && part("ANE0_1") == .component(.ane))
        expect(part("DRAM0") == .component(.memory) && part("DCS0") == .component(.memory) && part("AMCC0") == .component(.memory))
        expect(part("ISP0") == .media && part("AVE0") == .media && part("MSR0") == .media)
        // Per-core and per-cluster channels repeat the totals; SRAM and GPU sub-blocks too.
        for n in ["EACC_CPU", "PACC0_CPU", "PACC0_CPU3", "ECPUDTL05", "GPU0", "GPU SRAM0", "GPU CS0", "ANE0_SRAM", "PCIe Port 0 Energy", "DRAMX"] {
            expect(part(n) == nil, n)
        }
        expect(EnergyModel.joules(1500, unit: "mJ") == 1.5 && EnergyModel.joules(2_000_000, unit: "uJ") == 2)
        expect(EnergyModel.joules(3_000_000_000, unit: " nJ ") == 3 && EnergyModel.joules(7, unit: "J") == 7)
        expect(EnergyModel.joules(1, unit: "W") == nil)
        let w = EnergyModel.watts([("CPU Energy", 16_000, "mJ"), ("GPU Energy", 4_000_000_000, "nJ"), ("DRAM0", 1_000, "mJ"),
                                   ("DCS0", 1_000, "mJ"), ("ISP0", 200, "mJ"), ("AVE0", 200, "mJ"), ("PACC0_CPU", 99_000, "mJ")], seconds: 2)
        expect(w.components[.cpu] == 8 && w.components[.gpu] == 2 && w.components[.memory] == 1 && w.media == 0.2, "\(w)")
        expect(EnergyModel.watts([("CPU Energy", 100, "mJ")], seconds: 0).components.isEmpty, "no interval, no watts")
    }

    test("power: the rest of the Mac, smoothing, settling") {
        var r = PowerReading()
        r.system = 20
        expect(r.other == nil, "nothing measured yet")
        r.components = [.cpu: 8, .gpu: 2, .display: 3]
        expect(r.other == 7 && r.watts(.other) == 7 && r.watts(.cpu) == 8)
        r.components[.cpu] = 30
        expect(r.other == 0, "never negative")

        var a = PowerReading()
        a.onAC = true; a.adapter = 60; a.system = 20; a.battery = 38
        var b = a
        b.adapter = 70; b.system = 30
        let s = PowerMath.smoothed(a, b, alpha: 0.5)
        expect(s.adapter == 65 && s.system == 25 && s.battery == 38)
        var unplugged = b
        unplugged.onAC = false; unplugged.adapter = nil; unplugged.battery = -12
        let u = PowerMath.smoothed(a, unplugged)
        expect(u.adapter == nil && u.battery == -12 && u.system == 30, "unplugging starts over")
        var jump = b
        jump.system = 90
        expect(PowerMath.smoothed(a, jump).system == 90, "a big jump follows at once")
        var flip = a
        flip.battery = -20
        expect(PowerMath.smoothed(a, flip).battery == -20, "charging → discharging starts over")
        expect(PowerMath.smoothed(nil, b) == b)

        expect(PowerMath.settle(shown: 8.4, reading: 8.5, step: 0.15) == 8.4, "a wobble keeps the shown value")
        expect(PowerMath.settle(shown: 8.4, reading: 8.7, step: 0.15) == 8.4, "within 4%")
        expect(PowerMath.settle(shown: 8.4, reading: 8.8, step: 0.15) == 8.8)
        expect(PowerMath.settle(shown: 1.2, reading: 1.4, step: 0.15) == 1.4, "the step for small values")
        expect(PowerMath.settle(shown: 64, reading: 66, step: 0.15) == 64, "4% of a large value")
        expect(PowerMath.settle(shown: 64, reading: 67, step: 0.15) == 67)
        expect(PowerMath.settle(shown: 0.2, reading: -0.2, step: 0.15) == -0.2, "a sign change shows")
        expect(PowerMath.settle(shown: 3, reading: nil, step: 0.15) == nil)
        expect(PowerMath.settle(shown: nil, reading: 3, step: 0.15) == 3)
    }

    test("power: formatting") {
        expect(PowerMath.watts(4.24) == "4.2 W" && PowerMath.watts(9.96) == "10 W" && PowerMath.watts(64.4) == "64 W" && PowerMath.watts(nil) == "–")
        expect(PowerMath.signedWatts(39.2) == "+39 W" && PowerMath.signedWatts(-8.43) == "−8.4 W" && PowerMath.signedWatts(0.01) == "0 W")
        expect(PowerMath.volts(12.598) == "12.60 V" && PowerMath.amps(-0.623, signed: true) == "−0.62 A")
        expect(PowerMath.amps(3.1, signed: true) == "+3.10 A" && PowerMath.amps(3.1) == "3.10 A" && PowerMath.amps(0.001, signed: true) == "0.00 A")
        expect(PowerMath.wattHours(36) == "10 mWh" && PowerMath.wattHours(1512) == "0.42 Wh")
        expect(PowerMath.wattHours(11_160) == "3.1 Wh" && PowerMath.wattHours(86_400) == "24 Wh" && PowerMath.wattHours(-5) == "0 mWh")
    }

    test("power: battery and adapter details from AppleSmartBattery") {
        let d: [String: Any] = [
            "Voltage": 12596, "InstantAmperage": NSNumber(value: UInt64(bitPattern: -53)), "Temperature": 3057,
            "CycleCount": 193, "DesignCycleCount9C": 1000, "DesignCapacity": 8000, "AppleRawMaxCapacity": 7200,
            "AppleRawCurrentCapacity": 7100, "Serial": "SECRET",
            "BatteryData": ["CellVoltage": [4200, 4199, 4198], "DailyMinSoc": 66, "DailyMaxSoc": 100] as [String: Any],
            "AdapterDetails": ["Watts": 140, "AdapterVoltage": 28000, "Current": 4990, "Name": "140W USB-C Power Adapter",
                               "IsWireless": false, "SerialString": "SECRET"] as [String: Any],
            "ChargerData": ["ChargingCurrent": 3000] as [String: Any],
            "PowerTelemetryData": ["AdapterEfficiencyLoss": 2449, "BatteryPower": NSNumber(value: UInt64(bitPattern: -667))] as [String: Any],
        ]
        let p = PowerDetails.parse(d)
        expect(p.voltage == 12.596 && p.amperage == -0.053 && p.temperature == 30.57, "\(p)")
        expect(p.cycleCount == 193 && p.designCycleCount == 1000 && p.designCapacity == 8000 && p.fullChargeCapacity == 7200 && p.currentCharge == 7100)
        expect(p.healthPercent == 90)
        expect(p.cellVoltages == [4.2, 4.199, 4.198] && p.dailyMinPercent == 66 && p.dailyMaxPercent == 100)
        expect(p.adapterWatts == 140 && p.adapterVolts == 28 && p.adapterAmps == 4.99 && p.adapterName == "140W USB-C Power Adapter" && !p.wireless)
        expect(p.chargingCurrent == 3 && p.adapterLoss == 2.449)
        expect(!"\(p)".contains("SECRET"), "serial numbers are never read")
        // 16-bit current reported unsigned (older gauges), and an empty dictionary.
        expect(PowerDetails.parse(["Amperage": 65_000]).amperage == -0.536)
        let empty = PowerDetails.parse([:])
        expect(empty.voltage == nil && empty.healthPercent == nil && empty.cellVoltages.isEmpty && empty.adapterName == nil)
    }

    test("power: the flow diagram balances in every state") {
        func links(_ d: PowerDiagram) -> [String] { d.links.map { "\($0.from.rawValue)>\($0.to.rawValue)" } }
        // Charging: the adapter feeds the Mac and the battery.
        var c = PowerReading()
        c.onAC = true; c.charging = true; c.adapter = 64; c.system = 23; c.battery = 39
        c.components = [.cpu: 8, .gpu: 2, .memory: 2, .display: 3, .ane: 0.01]
        var d = PowerDiagram.make(c)
        expect(d.columns == [[.adapter], [.mac, .batteryIn], [.cpu, .gpu, .memory, .display, .other]], "\(d.columns)")
        expect(links(d).prefix(2) == ["adapter>mac", "adapter>batteryIn"])
        expect(abs(d.watts(.adapter) - 62) < 1e-9 && abs(d.watts(.mac) - 23) < 1e-9 && d.watts(.batteryIn) == 39)
        expect(abs(d.watts(.other) - 8) < 0.02, "other = 23 − 15 (ANE below the minimum still counts)")
        // On battery.
        var b = PowerReading()
        b.onAC = false; b.system = 8.2; b.battery = -8.4; b.components = [.cpu: 2]
        d = PowerDiagram.make(b)
        expect(d.columns.first == [.batteryOut] && links(d).first == "batteryOut>mac" && abs(d.watts(.batteryOut) - 8.2) < 1e-9)
        // The battery helps an adapter that can't keep up: the Mac's draw split between them.
        var h = PowerReading()
        h.onAC = true; h.adapter = 60; h.system = 80; h.battery = -20
        d = PowerDiagram.make(h)
        expect(d.columns.first == [.adapter, .batteryOut] && abs(d.watts(.adapter) - 60) < 1e-9 && abs(d.watts(.batteryOut) - 20) < 1e-9)
        expect(d.columns.count == 2, "no parts measured: no parts column")
        // Plugged in and full: a trickle into the battery doesn't show.
        var f = PowerReading()
        f.onAC = true; f.adapter = 25; f.system = 24.5; f.battery = 0.1
        d = PowerDiagram.make(f)
        expect(links(d) == ["adapter>mac"])
        // A desktop: the power supply, no battery.
        var m = PowerReading()
        m.hasBattery = false; m.onAC = true; m.system = 30; m.components = [.cpu: 10, .gpu: 5]
        d = PowerDiagram.make(m)
        expect(links(d) == ["adapter>mac", "mac>cpu", "mac>gpu", "mac>other"] && abs(d.watts(.other) - 15) < 1e-9)
        // Parts that add up to more than the total are scaled to it.
        var o = PowerReading()
        o.onAC = true; o.adapter = 20; o.system = 10; o.components = [.cpu: 12, .gpu: 8]
        d = PowerDiagram.make(o)
        expect(abs(d.watts(.cpu) - 6) < 1e-9 && abs(d.watts(.gpu) - 4) < 1e-9 && !d.columns.joined().contains(.other))
        // Nothing known.
        expect(PowerDiagram.make(PowerReading()).isEmpty)
    }

    test("power: diagram layout") {
        var c = PowerReading()
        c.onAC = true; c.charging = true; c.adapter = 64; c.system = 30; c.battery = 30
        c.components = [.cpu: 10, .gpu: 5, .memory: 3, .display: 4]
        let d = PowerDiagram.make(c)
        let bounds = CGRect(x: 0, y: 20, width: 360, height: 130)
        let l = PowerDiagramLayout.make(d, in: bounds, columnX: [60, 160, 260], nodeWidth: 8, gap: 5, minHeight: 2)
        expect(l.boxes.count == 8 && l.bands.count == 7, "\(l.boxes.count) boxes, \(l.bands.count) bands")
        for b in l.boxes { expect(b.rect.minY >= bounds.minY - 0.01 && b.rect.maxY <= bounds.maxY + 0.01, "\(b.node) inside") }
        // The fullest column (adapter = mac + battery + gap) fills the height.
        guard let mac = l.box(.mac), let bat = l.box(.batteryIn), let adapter = l.box(.adapter) else { expect(false); return }
        // (Each box keeps the minimum height in reserve, so the column ends a few points short.)
        expect(abs(mac.rect.height - bat.rect.height) < 0.01 && bounds.maxY - bat.rect.maxY < 3 && mac.rect.minY - bounds.minY < 3, "\(mac.rect) \(bat.rect)")
        // Each band's thickness is its share; the adapter's two leave in target order without overlap.
        let out = l.bands.filter { $0.link.from == .adapter }
        expect(out.count == 2 && out[0].link.to == .mac && abs(out[0].bottom0 - out[1].top0) < 0.01)
        expect(abs(out[0].top0 - adapter.rect.minY) < 0.01 && abs(out[1].bottom0 - adapter.rect.maxY) < 0.01)
        for b in l.bands {
            expect(abs((b.bottom0 - b.top0) - (b.bottom1 - b.top1)) < 0.01, "same thickness at both ends")
            expect(b.x0 < b.x1)
        }
        // The Mac's outgoing bands fill its box from top to bottom, in the parts' order.
        let parts = l.bands.filter { $0.link.from == .mac }
        expect(parts.map(\.link.to) == [.cpu, .gpu, .memory, .display, .other], "\(parts.map(\.link.to))")
        expect(zip(parts, parts.dropFirst()).allSatisfy { abs($0.bottom0 - $1.top0) < 0.01 })
        // A tiny part still gets a visible box, with its band centred on it.
        var t = PowerReading()
        t.onAC = true; t.adapter = 20; t.system = 20; t.components = [.cpu: 19.9, .ane: 0.06]
        let tl = PowerDiagramLayout.make(PowerDiagram.make(t), in: bounds, columnX: [60, 160, 260], nodeWidth: 8, gap: 5, minHeight: 2)
        if let ane = tl.box(.ane), let band = tl.bands.first(where: { $0.link.to == .ane }) {
            expect(ane.rect.height >= 2 && band.top1 >= ane.rect.minY - 0.01 && band.bottom1 <= ane.rect.maxY + 0.01)
        } else {
            expect(false, "ANE box")
        }
        expect(PowerDiagramLayout.make(PowerDiagram(columns: [], links: []), in: bounds, columnX: [0], nodeWidth: 8, gap: 5).boxes.isEmpty)
    }

    test("power: labels spread apart, in bounds and in order") {
        let s = PowerDiagramLayout.spread([50, 52, 54, 120], spacing: 14, lower: 0, upper: 200)
        expect(s[1] - s[0] >= 14 - 1e-9 && s[2] - s[1] >= 14 - 1e-9 && s[3] == 120, "\(s)")
        let edge = PowerDiagramLayout.spread([195, 198, 199], spacing: 14, lower: 0, upper: 200)
        expect(edge[2] <= 200 && edge[1] <= edge[2] - 14 + 1e-9 && edge[0] <= edge[1] - 14 + 1e-9, "\(edge)")
        let low = PowerDiagramLayout.spread([-5, 1], spacing: 14, lower: 0, upper: 200)
        expect(low[0] >= 0 && low[1] - low[0] >= 14 - 1e-9, "\(low)")
        let unordered = PowerDiagramLayout.spread([80, 10, 81], spacing: 14, lower: 0, upper: 200)
        expect(unordered[1] == 10 && unordered[2] - unordered[0] >= 14 - 1e-9, "each label keeps its own index")
        expect(PowerDiagramLayout.spread([], spacing: 14, lower: 0, upper: 10).isEmpty)
    }

    test("power: menu bar elements and presets") {
        let m = StatsModule.power
        expect(m.presets.allSatisfy { m.sanitized($0) == $0 }, "every preset is valid")
        expect(m.presets[0] == [.powerIcon, .powerSystem])
        expect(m.elements.contains(.powerCPU) && m.elements.contains(.cycleCount) && !m.elements.contains(.batteryPower))
        expect(StatsModule.battery.sanitized([.powerSystem]) == nil, "power elements belong to the Power item")
        let (d, discard) = scratchDefaults()
        defer { discard() }
        let s = Settings(defaults: d)
        expect(s.statsElements(.power) == [.powerIcon, .powerSystem])
        s.setStatsElements(.power, [.powerCPU, .powerGPU, .powerCPU, .percent])
        expect(s.statsElements(.power) == [.powerCPU, .powerGPU], "repeats and other modules' elements dropped")
    }

    test("menu bar figures wait for a real change") {
        var v = HeldValue()
        expect(v.update(0.07, now: 0, significant: HeldValue.percent) == 0.07, "first reading shows")
        expect(v.update(0.08, now: 1, significant: HeldValue.percent) == 0.07, "a point waits")
        expect(v.update(0.10, now: 2, significant: HeldValue.percent) == 0.10, "two points show")
        expect(v.update(0.11, now: 3, significant: HeldValue.percent) == 0.10)
        expect(v.update(0.11, now: 7, significant: HeldValue.percent) == 0.11, "a small change shows after 5 s")
        expect(v.update(nil, now: 8, significant: HeldValue.percent) == nil && v.shown == nil)
        expect(HeldValue.rate(2048, 3072) == false && HeldValue.rate(2048, 20_000) == true, "8 KB/s floor")
        expect(HeldValue.rate(1_000_000, 1_150_000) == false && HeldValue.rate(1_000_000, 1_300_000) == true, "a fifth")
        expect(HeldValue.rate(3000, 100) == false && HeldValue.rate(100, 30_000) == true, "a trickle waits, real traffic shows")
        expect(HeldValue.temperature(46, 47) == false && HeldValue.temperature(46, 48) == true)
    }
}
