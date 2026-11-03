import Foundation
import CoreGraphics

// Pure pieces of the Power item: where the Mac's power comes from and where it goes. The app
// feeds raw readings in (SMC watts, the chip's energy model in joules, AppleSmartBattery's
// properties); nothing here touches the system.

// MARK: Parts

/// What uses the Mac's power, as the diagram, the rows and the menu bar name it. The chip's
/// energy model gives CPU, GPU, memory and Neural Engine; the display is its backlight; `other`
/// is the rest of the Mac (SSD, Wi-Fi, media engines, fans, power conversion): what's left of
/// the measured total. The order is the diagram's, top to bottom, and the colors' order.
public enum PowerComponent: String, CaseIterable {
    case cpu, gpu, memory, display, ane, other
}

/// The chip's energy model (IOReport's "Energy Model" group), by channel name. Names differ by
/// chip ("CPU Energy" or "DIE_0_CPU Energy", "ANE" or "ANE0"), and per-core and per-cluster
/// channels repeat the totals, so only these count.
public enum EnergyModel {
    public enum Part: Equatable { case component(PowerComponent), media }

    public static func part(forChannel name: String) -> Part? {
        if name.hasSuffix("CPU Energy") { return .component(.cpu) }
        if name.hasSuffix("GPU Energy") { return .component(.gpu) }
        if numbered(name, "ANE") { return .component(.ane) }
        // DRAM, its controllers (DCS) and the memory cache controller (AMCC).
        if numbered(name, "DRAM") || numbered(name, "DCS") || numbered(name, "AMCC") { return .component(.memory) }
        // Camera, video encode/decode, scaler, ProRes, JPEG.
        if ["ISP", "AVE", "AVD", "MSR", "PRORES", "JPG"].contains(where: { numbered(name, $0) }) { return .media }
        return nil
    }

    /// "ANE", "ANE0", "ANE0_1": the prefix, then only digits and underscores ("ANE0_SRAM" isn't).
    static func numbered(_ name: String, _ prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return name.dropFirst(prefix.count).allSatisfy { $0.isNumber || $0 == "_" }
    }

    /// An energy counter in joules, by its unit label ("mJ", "uJ", "nJ"); nil for other units.
    public static func joules(_ value: Int64, unit: String) -> Double? {
        let v = Double(value)
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": return v
        case "mJ": return v / 1e3
        case "uJ", "µJ": return v / 1e6
        case "nJ": return v / 1e9
        default: return nil
        }
    }

    /// Watts per part over one interval, from (channel, energy delta, unit) triples.
    public static func watts(_ deltas: [(name: String, value: Int64, unit: String)], seconds: Double)
        -> (components: [PowerComponent: Double], media: Double?) {
        guard seconds > 0.05, seconds.isFinite else { return ([:], nil) }
        var out: [PowerComponent: Double] = [:]
        var media: Double?
        for d in deltas where d.value >= 0 {
            guard let part = part(forChannel: d.name), let j = joules(d.value, unit: d.unit) else { continue }
            switch part {
            case .component(let c): out[c, default: 0] += j / seconds
            case .media: media = (media ?? 0) + j / seconds
            }
        }
        return (out, media)
    }
}

// MARK: Reading

/// One moment of the Mac's power, in watts. `battery` is signed: > 0 charging, < 0 discharging.
public struct PowerReading: Equatable {
    public var hasBattery = true
    public var onAC = false
    public var charging = false
    /// What the adapter (or a desktop's power supply) delivers; nil without one.
    public var adapter: Double?
    /// What the Mac uses.
    public var system: Double?
    public var battery: Double?
    /// Measured parts (never `.other`, which is derived).
    public var components: [PowerComponent: Double] = [:]
    /// Media engines (camera, video), counted in `other`.
    public var media: Double?
    /// The adapter's voltage and current right now.
    public var inputVolts: Double?
    public var inputAmps: Double?
    /// The battery's pack voltage and current (+ into the battery).
    public var batteryVolts: Double?
    public var batteryAmps: Double?

    public init() {}

    /// The rest of the Mac: the total less the measured parts, never negative; nil until the
    /// parts are measured.
    public var other: Double? {
        guard let s = system, !components.isEmpty else { return nil }
        return max(0, s - PowerComponent.allCases.reduce(0) { $0 + ($1 == .other ? 0 : components[$1] ?? 0) })
    }

    public func watts(_ c: PowerComponent) -> Double? { c == .other ? other : components[c] }
}

public enum PowerMath {
    /// Readings jump around second to second (and the SMC's system total lags its adapter
    /// figure by a second), so the panel and the menu bar show an average of the last few
    /// seconds. Plugging in or out, or a jump of more than `reset` watts, starts over.
    public static func smoothed(_ previous: PowerReading?, _ r: PowerReading, alpha: Double = 0.45, reset: Double = 25) -> PowerReading {
        guard let p = previous, p.onAC == r.onAC, p.hasBattery == r.hasBattery else { return r }
        func mix(_ a: Double?, _ b: Double?) -> Double? {
            guard let b, b.isFinite else { return nil }
            guard let a, a.isFinite, abs(b - a) < reset, (a >= 0) == (b >= 0) || abs(b - a) < 1 else { return b }
            return a + alpha * (b - a)
        }
        var s = r
        s.adapter = mix(p.adapter, r.adapter)
        s.system = mix(p.system, r.system)
        s.battery = mix(p.battery, r.battery)
        s.media = mix(p.media, r.media)
        var parts: [PowerComponent: Double] = [:]
        for (c, w) in r.components { parts[c] = mix(p.components[c], w) }
        s.components = parts
        s.inputVolts = mix(p.inputVolts, r.inputVolts)
        s.inputAmps = mix(p.inputAmps, r.inputAmps)
        s.batteryVolts = mix(p.batteryVolts, r.batteryVolts)
        s.batteryAmps = mix(p.batteryAmps, r.batteryAmps)
        return s
    }

    /// The value the menu bar keeps showing. A reading within `step` (or 4 %) of the shown one
    /// keeps it, so a figure that wobbles doesn't redraw the bar every second (each redraw costs
    /// the menu bar host a few ms per display).
    public static func settle(shown: Double?, reading: Double?, step: Double) -> Double? {
        guard let r = reading, r.isFinite else { return nil }
        guard let s = shown, s.isFinite, (s >= 0) == (r >= 0) else { return r }
        return abs(r - s) < max(step, abs(s) * 0.04) ? s : r
    }

    /// Energy (J) in watt-hours for people: "12 mWh", "0.42 Wh", "3.1 Wh", "24 Wh".
    public static func wattHours(_ joules: Double) -> String {
        let wh = max(0, joules) / 3600
        if wh < 0.1 { return "\(Int((wh * 1000).rounded())) mWh" }
        if wh < 1 { return String(format: "%.2f Wh", wh) }
        if wh < 10 { return String(format: "%.1f Wh", wh) }
        return "\(Int(wh.rounded())) Wh"
    }

    /// "4.2 W", "23 W": one decimal below 10 W.
    public static func watts(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "–" }
        let a = abs(w)
        return (a < 9.95 ? String(format: "%.1f", a) : String(format: "%.0f", a)) + " W"
    }

    /// "+23 W", "−8.4 W", "0 W".
    public static func signedWatts(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "–" }
        if abs(w) < 0.05 { return "0 W" }
        return (w > 0 ? "+" : "−") + watts(w)
    }

    /// "12.60 V".
    public static func volts(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(format: "%.2f V", v)
    }

    /// "+3.10 A", "−0.62 A" (signed: into the battery is +), or "3.10 A".
    public static func amps(_ a: Double?, signed: Bool = false) -> String {
        guard let a, a.isFinite else { return "–" }
        let text = String(format: "%.2f A", abs(a))
        guard signed, abs(a) >= 0.005 else { return text }
        return (a > 0 ? "+" : "−") + text
    }
}

// MARK: Battery and adapter details

/// AppleSmartBattery's properties that the Power details show. Serial numbers and names of the
/// device are never read.
public struct PowerDetails: Equatable {
    public var voltage: Double?            // V
    public var amperage: Double?           // A, + into the battery
    public var temperature: Double?        // °C
    public var cycleCount: Int?
    public var designCycleCount: Int?
    public var designCapacity: Int?        // mAh
    public var fullChargeCapacity: Int?    // mAh, what a full charge holds today
    public var currentCharge: Int?         // mAh
    public var cellVoltages: [Double] = [] // V
    public var dailyMinPercent: Int?
    public var dailyMaxPercent: Int?
    public var adapterName: String?
    public var adapterWatts: Int?          // rated
    public var adapterVolts: Double?       // negotiated (USB-C PD contract)
    public var adapterAmps: Double?
    public var wireless = false
    public var chargingCurrent: Double?    // A the battery asks the charger for
    /// The adapter's own conversion loss (PowerTelemetryData, updated every few seconds).
    public var adapterLoss: Double?        // W

    public init() {}

    /// Full-charge capacity as a share of the design capacity (macOS's "Maximum Capacity" uses
    /// a smoothed figure, so it can read a few points higher).
    public var healthPercent: Int? {
        guard let d = designCapacity, d > 0, let f = fullChargeCapacity, f > 0 else { return nil }
        return min(100, Int((Double(f) / Double(d) * 100).rounded()))
    }

    public static func parse(_ d: [String: Any]) -> PowerDetails {
        func number(_ any: Any?) -> Double? {
            guard let n = any as? NSNumber else { return nil }
            // Signed values sometimes arrive as their unsigned 64-bit pattern.
            if n.uint64Value > UInt64(Int64.max) { return Double(Int64(bitPattern: n.uint64Value)) }
            let v = n.doubleValue
            return v.isFinite ? v : nil
        }
        func int(_ any: Any?) -> Int? { number(any).map { Int($0) } }
        /// Amperage keys are 16- or 64-bit signed values reported as unsigned on some Macs.
        func signedCurrent(_ any: Any?) -> Double? {
            guard let v = number(any) else { return nil }
            let i = Int64(v)
            if i > 32767 && i <= 65535 { return Double(Int16(truncatingIfNeeded: i)) }
            if i > Int64(Int32.max) && i <= Int64(UInt32.max) { return Double(Int32(truncatingIfNeeded: i)) }
            return v
        }
        var p = PowerDetails()
        if let v = number(d["Voltage"]), v > 0 { p.voltage = v / 1000 }
        if let a = signedCurrent(d["InstantAmperage"] ?? d["Amperage"]) { p.amperage = a / 1000 }
        if let t = number(d["Temperature"]), t > 0 { p.temperature = t / 100 }
        p.cycleCount = int(d["CycleCount"])
        p.designCycleCount = int(d["DesignCycleCount9C"]).flatMap { $0 > 0 ? $0 : nil }
        p.designCapacity = int(d["DesignCapacity"]).flatMap { $0 > 0 ? $0 : nil }
        p.fullChargeCapacity = int(d["AppleRawMaxCapacity"] ?? d["NominalChargeCapacity"]).flatMap { $0 > 0 ? $0 : nil }
        p.currentCharge = int(d["AppleRawCurrentCapacity"]).flatMap { $0 >= 0 ? $0 : nil }
        let data = d["BatteryData"] as? [String: Any]
        if let cells = data?["CellVoltage"] as? [NSNumber] {
            p.cellVoltages = cells.map { $0.doubleValue / 1000 }.filter { $0 > 1 && $0 < 6 }
        }
        p.dailyMinPercent = int(data?["DailyMinSoc"]).flatMap { (0...100).contains($0) ? $0 : nil }
        p.dailyMaxPercent = int(data?["DailyMaxSoc"]).flatMap { (0...100).contains($0) ? $0 : nil }
        if let a = d["AdapterDetails"] as? [String: Any] {
            if let w = int(a["Watts"]), w > 0 { p.adapterWatts = w }
            if let v = number(a["AdapterVoltage"]), v > 0 { p.adapterVolts = v / 1000 }
            if let c = number(a["Current"]), c > 0 { p.adapterAmps = c / 1000 }
            let name = (a["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            p.adapterName = name.isEmpty ? nil : name
            p.wireless = a["IsWireless"] as? Bool ?? false
        }
        if let c = number((d["ChargerData"] as? [String: Any])?["ChargingCurrent"]), c > 0 { p.chargingCurrent = c / 1000 }
        if let t = d["PowerTelemetryData"] as? [String: Any], let loss = number(t["AdapterEfficiencyLoss"]), loss >= 0, loss < 1_000_000 {
            p.adapterLoss = loss / 1000
        }
        return p
    }
}

// MARK: Diagram

/// Where the power goes, as a three-column flow: sources (adapter, battery discharging) → the
/// Mac (and the battery while it charges) → the Mac's parts. Link widths are watts and balance
/// at every node; the labels show the measured figures, which can differ by a little.
public struct PowerDiagram: Equatable {
    public enum Node: String, CaseIterable {
        case adapter, batteryOut, mac, batteryIn, cpu, gpu, memory, display, ane, other

        public var component: PowerComponent? {
            switch self {
            case .cpu: return .cpu
            case .gpu: return .gpu
            case .memory: return .memory
            case .display: return .display
            case .ane: return .ane
            case .other: return .other
            default: return nil
            }
        }

        public static func of(_ c: PowerComponent) -> Node {
            switch c {
            case .cpu: return .cpu
            case .gpu: return .gpu
            case .memory: return .memory
            case .display: return .display
            case .ane: return .ane
            case .other: return .other
            }
        }
    }

    public struct Link: Equatable {
        public var from: Node
        public var to: Node
        public var watts: Double
        public init(from: Node, to: Node, watts: Double) { self.from = from; self.to = to; self.watts = watts }
    }

    public var columns: [[Node]]
    public var links: [Link]

    public init(columns: [[Node]], links: [Link]) { self.columns = columns; self.links = links }

    /// A node's size: the larger of what flows in and out.
    public func watts(_ n: Node) -> Double {
        let inflow = links.filter { $0.to == n }.reduce(0) { $0 + $1.watts }
        let outflow = links.filter { $0.from == n }.reduce(0) { $0 + $1.watts }
        return max(inflow, outflow)
    }

    public var isEmpty: Bool { links.isEmpty }

    /// - Parameter minimum: parts below this many watts are left out (they would be slivers).
    public static func make(_ r: PowerReading, minimum: Double = 0.05) -> PowerDiagram {
        let adapter = r.onAC ? max(r.adapter ?? 0, 0) : 0
        let b = r.battery ?? 0
        let charge = b > 0.3 ? b : 0
        let discharge = b < -0.3 ? -b : 0
        // What the Mac uses: measured, or what comes in less what goes into the battery.
        var system = max(r.system ?? 0, 0)
        if system < 0.05 { system = max(0, adapter + discharge - charge) }
        guard system >= 0.05 || charge > 0 else { return PowerDiagram(columns: [], links: []) }

        var links: [Link] = []
        var sources: [Node] = []
        if adapter > 0.05 && discharge > 0 {
            // The battery tops up an adapter that can't keep up: the Mac's draw, split between them.
            let share = adapter / (adapter + discharge)
            links.append(Link(from: .adapter, to: .mac, watts: system * share))
            links.append(Link(from: .batteryOut, to: .mac, watts: system * (1 - share)))
            sources = [.adapter, .batteryOut]
        } else if adapter > 0.05 || (r.onAC && !r.hasBattery) || (r.onAC && discharge == 0) {
            if system >= 0.05 { links.append(Link(from: .adapter, to: .mac, watts: system)) }
            if charge > 0 { links.append(Link(from: .adapter, to: .batteryIn, watts: charge)) }
            sources = [.adapter]
        } else {
            if system >= 0.05 { links.append(Link(from: .batteryOut, to: .mac, watts: system)) }
            sources = [.batteryOut]
        }

        // The Mac's parts; if the model's parts add up to more than the measured total, they are
        // scaled to it (and nothing is left for "other").
        var parts: [(PowerComponent, Double)] = PowerComponent.allCases.compactMap { c in
            guard c != .other, let w = r.components[c], w.isFinite, w > 0 else { return nil }
            return (c, w)
        }
        let measured = parts.reduce(0) { $0 + $1.1 }
        if measured > system, measured > 0 { parts = parts.map { ($0.0, $0.1 * system / measured) } }
        // Nothing measured (an Intel Mac): no parts column rather than one "other" for everything.
        if !parts.isEmpty { parts.append((.other, max(0, system - parts.reduce(0) { $0 + $1.1 }))) }
        var destinations: [Node] = []
        for (c, w) in parts where w >= minimum && system >= 0.05 {
            links.append(Link(from: .mac, to: .of(c), watts: w))
            destinations.append(.of(c))
        }
        var middle: [Node] = []
        if system >= 0.05 { middle.append(.mac) }
        if charge > 0 { middle.append(.batteryIn) }
        return PowerDiagram(columns: [sources, middle, destinations].filter { !$0.isEmpty }, links: links)
    }
}

/// Node boxes and link bands of a `PowerDiagram` in a rectangle (flipped: y grows downward).
public struct PowerDiagramLayout: Equatable {
    public struct Box: Equatable {
        public var node: PowerDiagram.Node
        public var rect: CGRect
    }

    /// A link's ends: its slice of the source box's right edge and of the target box's left edge.
    public struct Band: Equatable {
        public var link: PowerDiagram.Link
        public var x0: CGFloat, top0: CGFloat, bottom0: CGFloat
        public var x1: CGFloat, top1: CGFloat, bottom1: CGFloat
    }

    public var boxes: [Box]
    public var bands: [Band]

    public init(boxes: [Box], bands: [Band]) { self.boxes = boxes; self.bands = bands }

    public func box(_ n: PowerDiagram.Node) -> Box? { boxes.first { $0.node == n } }

    /// - Parameters:
    ///   - columnX: each column's left edge.
    ///   - minHeight: the thinnest a box gets (a tiny part stays visible).
    public static func make(_ d: PowerDiagram, in bounds: CGRect, columnX: [CGFloat], nodeWidth: CGFloat,
                            gap: CGFloat, minHeight: CGFloat = 2) -> PowerDiagramLayout {
        guard !d.isEmpty, columnX.count >= d.columns.count else { return PowerDiagramLayout(boxes: [], bands: []) }
        // One scale for every column: the fullest column fills the height.
        var scale = CGFloat.greatestFiniteMagnitude
        for col in d.columns {
            let total = col.reduce(0) { $0 + d.watts($1) }
            let room = bounds.height - gap * CGFloat(max(col.count - 1, 0)) - minHeight * CGFloat(col.count)
            if total > 0 { scale = min(scale, max(room, 1) / CGFloat(total)) }
        }
        if scale == .greatestFiniteMagnitude { scale = 1 }

        var boxes: [Box] = []
        for (i, col) in d.columns.enumerated() {
            let heights = col.map { max(minHeight, CGFloat(d.watts($0)) * scale) }
            let total = heights.reduce(0, +) + gap * CGFloat(max(col.count - 1, 0))
            var y = bounds.midY - total / 2
            for (n, h) in zip(col, heights) {
                boxes.append(Box(node: n, rect: CGRect(x: columnX[i], y: y, width: nodeWidth, height: h)))
                y += h + gap
            }
        }
        func rect(_ n: PowerDiagram.Node) -> CGRect? { boxes.first { $0.node == n }?.rect }

        // Bands leave a box in the order of their targets (top first) and arrive in the order of
        // their sources, so they never cross at a box; each end is centred on its box when the
        // box was raised to the minimum height.
        var bands: [Band] = []
        var outOffset: [PowerDiagram.Node: CGFloat] = [:], inOffset: [PowerDiagram.Node: CGFloat] = [:]
        func flowHeight(_ n: PowerDiagram.Node, outgoing: Bool) -> CGFloat {
            d.links.filter { outgoing ? $0.from == n : $0.to == n }.reduce(0) { $0 + CGFloat($1.watts) * scale }
        }
        let ordered = d.links.sorted { a, b in
            let ta = rect(a.to)?.minY ?? 0, tb = rect(b.to)?.minY ?? 0
            if ta != tb { return ta < tb }
            return (rect(a.from)?.minY ?? 0) < (rect(b.from)?.minY ?? 0)
        }
        // Sorted by (target, source), so each box's outgoing links come in target order and its
        // incoming links in source order.
        for l in ordered {
            guard let s = rect(l.from), let t = rect(l.to) else { continue }
            let h = CGFloat(l.watts) * scale
            let out = outOffset[l.from] ?? (s.height - flowHeight(l.from, outgoing: true)) / 2
            let into = inOffset[l.to] ?? (t.height - flowHeight(l.to, outgoing: false)) / 2
            outOffset[l.from] = out + h
            inOffset[l.to] = into + h
            bands.append(Band(link: l, x0: s.maxX, top0: s.minY + out, bottom0: s.minY + out + h,
                              x1: t.minX, top1: t.minY + into, bottom1: t.minY + into + h))
        }
        return PowerDiagramLayout(boxes: boxes, bands: bands)
    }

    /// Label centres that keep at least `spacing` apart, as close to `wanted` as they can, all
    /// within `lower`…`upper` (labels beside small neighbouring boxes would overlap).
    public static func spread(_ wanted: [CGFloat], spacing: CGFloat, lower: CGFloat, upper: CGFloat) -> [CGFloat] {
        guard !wanted.isEmpty else { return [] }
        let order = wanted.indices.sorted { wanted[$0] < wanted[$1] }
        var ys = order.map { min(max(wanted[$0], lower), upper) }
        for _ in 0..<4 {
            for i in 1..<max(ys.count, 1) where ys[i] - ys[i - 1] < spacing { ys[i] = ys[i - 1] + spacing }
            if let last = ys.last, last > upper {
                ys[ys.count - 1] = upper
                for i in stride(from: ys.count - 2, through: 0, by: -1) where ys[i + 1] - ys[i] < spacing { ys[i] = ys[i + 1] - spacing }
            }
            if let first = ys.first, first < lower { ys[0] = lower } else { break }
        }
        var out = wanted
        for (k, i) in order.enumerated() { out[i] = ys[k] }
        return out
    }
}
