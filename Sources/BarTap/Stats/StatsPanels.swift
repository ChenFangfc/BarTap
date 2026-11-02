import AppKit
import BarTapCore

// Dropdown contents for each stats item. Plain AppKit views inside an NSMenu, updated in place
// once per second while the menu is open (and not at all otherwise).

final class GraphView: NSView {
    var series: [[Double]] = [] { didSet { needsDisplay = true } }
    var colors: [NSColor] = [.systemBlue]
    /// nil = scale to the largest value shown (rates); otherwise values are fractions of this.
    var fixedMax: Double? = 1
    /// With fixedMax nil, the scale never goes below this (1 KB/s keeps idle network flat).
    var minimumPeak: Double = 1024
    var caption: String = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        // withAlphaComponent replaces a system color's alpha, so start from the opaque label color.
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        let peak = fixedMax ?? max(series.flatMap { $0 }.max() ?? 0, minimumPeak)
        // A caption gets its own band, so the highest value never runs through the text.
        let usable = r.height - 4 - (caption.isEmpty ? 0 : 15)
        for (i, values) in series.enumerated() where values.count >= 2 {
            let color = colors[i % colors.count]
            let step = r.width / CGFloat(89)
            let start = r.maxX - CGFloat(values.count - 1) * step
            let path = NSBezierPath()
            path.move(to: NSPoint(x: start, y: r.minY))
            for (j, v) in values.enumerated() {
                path.line(to: NSPoint(x: start + CGFloat(j) * step, y: r.minY + usable * CGFloat(min(max(v / peak, 0), 1))))
            }
            path.line(to: NSPoint(x: start + CGFloat(values.count - 1) * step, y: r.minY))
            path.close()
            color.withAlphaComponent(0.28).setFill()
            path.fill()
            let line = NSBezierPath()
            for (j, v) in values.enumerated() {
                let p = NSPoint(x: start + CGFloat(j) * step, y: r.minY + usable * CGFloat(min(max(v / peak, 0), 1)))
                j == 0 ? line.move(to: p) : line.line(to: p)
            }
            color.setStroke()
            line.lineWidth = 1.2
            line.stroke()
        }
        if !caption.isEmpty {
            (caption as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 15),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

final class CoreBarsView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var efficiencyCount = 0

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let gap: CGFloat = 3
        let w = (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * (w + gap)
            let back = NSRect(x: x, y: 0, width: w, height: bounds.height)
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: back, xRadius: 2, yRadius: 2).fill()
            // macOS lists efficiency cores first on Apple silicon.
            (i < efficiencyCount ? NSColor.systemTeal : NSColor.systemBlue).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: w, height: max(2, bounds.height * CGFloat(min(v, 1)))), xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// A vertical form of title, big value, graph and label/value rows.
class StatsPanel: NSView {
    static let width: CGFloat = 300
    let stack = NSStackView()
    private var rows: [String: NSTextField] = [:]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func finishLayout() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    func header(_ title: String) -> NSTextField {
        let big = NSTextField(labelWithString: "")
        big.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        t.textColor = .secondaryLabelColor
        let h = NSStackView(views: [t, NSView(), big])
        h.distribution = .fill
        h.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(h)
        h.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        return big
    }

    func graph(height: CGFloat = 56, colors: [NSColor], fixedMax: Double? = 1) -> GraphView {
        let g = GraphView()
        g.colors = colors
        g.fixedMax = fixedMax
        g.translatesAutoresizingMaskIntoConstraints = false
        g.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        g.heightAnchor.constraint(equalToConstant: height).isActive = true
        stack.addArrangedSubview(g)
        return g
    }

    @discardableResult
    func section(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? l)
        stack.addArrangedSubview(l)
        return l
    }

    /// A label/value row; returns the value field for updates. `key` lets callers find it again.
    @discardableResult
    func row(_ label: String, key: String? = nil, color: NSColor? = nil) -> NSTextField {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        var leading: [NSView] = [name]
        if let color {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            leading.insert(dot, at: 0)
        }
        let value = NSTextField(labelWithString: "–")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = NSStackView(views: leading + [NSView(), value])
        h.spacing = 6
        h.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(h)
        h.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        if let key { rows[key] = value }
        return value
    }

    /// Hides rows that have nothing to show (unused volume/process/interface slots) and re-sizes.
    /// Called once before the dropdown appears; rows keep that visibility while it is open so the
    /// menu never changes size under the pointer.
    func compact() {
        for case let row as NSStackView in stack.arrangedSubviews {
            let fields = row.arrangedSubviews.compactMap { $0 as? NSTextField }
            guard fields.count == 2 else { continue }
            row.isHidden = fields.allSatisfy { $0.stringValue.isEmpty }
        }
        finishLayout()
    }

    func set(_ key: String, _ text: String) {
        if rows[key]?.stringValue != text { rows[key]?.stringValue = text }
    }

    /// Fixed list of `count` rows whose labels and values both change (process lists).
    func dynamicRows(_ count: Int, prefix: String) -> [(NSTextField, NSTextField)] {
        (0..<count).map { i in
            let v = row("", key: "\(prefix)\(i)")
            let h = v.superview as! NSStackView
            let name = h.arrangedSubviews.first as! NSTextField
            return (name, v)
        }
    }

    func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {}
}

final class CPUPanel: StatsPanel {
    private var big: NSTextField!
    private var graph: GraphView!
    private var cores = CoreBarsView()
    private var procs: [(NSTextField, NSTextField)] = []

    override init() {
        super.init()
        big = header(L("CPU"))
        graph = graph(colors: [.systemBlue])
        row(L("User"), key: "user", color: .systemBlue)
        row(L("System"), key: "system", color: .systemRed)
        row(L("Idle"), key: "idle")
        section(L("Cores"))
        row(L("Efficiency cores"), key: "ecores", color: .systemTeal)
        row(L("Performance cores"), key: "pcores", color: .systemBlue)
        cores.translatesAutoresizingMaskIntoConstraints = false
        cores.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        cores.heightAnchor.constraint(equalToConstant: 30).isActive = true
        stack.addArrangedSubview(cores)
        section(L("Processes"))
        procs = dynamicRows(5, prefix: "p")
        section(L("System"))
        row("GPU", key: "gpu")
        row(L("CPU temperature"), key: "temp")
        row(L("Fans"), key: "fans")
        row(L("Load average"), key: "load")
        row(L("Processes"), key: "procs")
        row(L("Uptime"), key: "uptime")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        if let c = s.cpu {
            // macOS lists efficiency cores first on Apple silicon.
            let e = s.coreLayout.efficiency
            if e > 0, c.perCore.count > e {
                let ec = c.perCore.prefix(e), pc = c.perCore.dropFirst(e)
                set("ecores", StatFormat.percent(ec.reduce(0, +) / Double(ec.count)))
                set("pcores", StatFormat.percent(pc.reduce(0, +) / Double(pc.count)))
            }
            big.stringValue = StatFormat.percent(c.total)
            set("user", StatFormat.percent(c.user))
            set("system", StatFormat.percent(c.system))
            set("idle", StatFormat.percent(1 - c.total))
            cores.efficiencyCount = s.coreLayout.efficiency
            cores.values = c.perCore
        }
        graph.series = [s.cpuHistory]
        let cpuCount = Double(max(s.cpu?.perCore.count ?? 1, 1))
        for (i, row) in procs.enumerated() {
            if i < s.topCPU.count {
                row.0.stringValue = s.topCPU[i].name
                row.1.stringValue = StatFormat.percent(min(1, s.topCPU[i].cpu / cpuCount))
            } else {
                row.0.stringValue = ""
                row.1.stringValue = ""
            }
        }
        set("gpu", s.gpu.map { StatFormat.percent($0) } ?? "–")
        if let t = s.sensors?.cpu { set("temp", StatFormat.temperature(t, fahrenheit: o.fahrenheit)) }
        if let fans = s.sensors?.fans, !fans.isEmpty { set("fans", fans.map { "\(Int($0.rpm)) rpm" }.joined(separator: " · ")) }
        if s.loadAverage.count == 3 { set("load", s.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  ")) }
        if s.uptime > 0 { set("uptime", StatFormat.duration(s.uptime)) }
        if s.processCount > 0 { set("procs", "\(s.processCount)") }
    }
}

final class GPUPanel: StatsPanel {
    private var big: NSTextField!
    private var graph: GraphView!

    override init() {
        super.init()
        big = header("GPU")
        graph = graph(colors: [.systemPurple])
        row(L("Renderer"), key: "renderer")
        row(L("Tiler"), key: "tiler")
        row(L("Memory in use"), key: "mem")
        row(L("Memory allocated"), key: "alloc")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        big.stringValue = s.gpu.map { StatFormat.percent($0) } ?? "–"
        graph.series = [s.gpuHistory]
        if let g = s.gpuInfo {
            set("renderer", g.renderer.map { StatFormat.percent($0) } ?? "–")
            set("tiler", g.tiler.map { StatFormat.percent($0) } ?? "–")
            set("mem", g.memoryInUse.map { StatFormat.bytes($0) } ?? "–")
            set("alloc", g.memoryAllocated.map { StatFormat.bytes($0) } ?? "–")
        }
    }
}

final class MemoryPanel: StatsPanel {
    private var big: NSTextField!
    private var graph: GraphView!
    private var procs: [(NSTextField, NSTextField)] = []

    override init() {
        super.init()
        big = header(L("Memory"))
        graph = graph(colors: [.systemGreen])
        row(L("Pressure"), key: "pressure")
        row(L("App memory"), key: "app", color: .systemGreen)
        row(L("Wired"), key: "wired", color: .systemOrange)
        row(L("Compressed"), key: "compressed", color: .systemPurple)
        row(L("Cached files"), key: "cached", color: .systemGray)
        row(L("Free"), key: "free")
        row(L("Swap used"), key: "swap")
        row(L("Page ins"), key: "pageins")
        row(L("Page outs"), key: "pageouts")
        section(L("Processes"))
        procs = dynamicRows(5, prefix: "p")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        if let m = s.memory {
            big.stringValue = "\(StatFormat.bytes(m.used)) / \(StatFormat.bytes(m.total, decimals: 0))"
            set("app", StatFormat.bytes(m.app))
            set("wired", StatFormat.bytes(m.wired))
            set("compressed", StatFormat.bytes(m.compressed))
            set("cached", StatFormat.bytes(m.cached))
            set("free", StatFormat.bytes(m.free))
        }
        switch s.pressure {
        case .normal: set("pressure", L("Normal"))
        case .warning: set("pressure", L("Warning"))
        case .critical: set("pressure", L("Critical"))
        }
        set("swap", "\(StatFormat.bytes(s.swap.used)) / \(StatFormat.bytes(s.swap.total))")
        set("pageins", StatFormat.rate(s.pageInRate))
        set("pageouts", StatFormat.rate(s.pageOutRate))
        graph.series = [s.memoryHistory]
        for (i, row) in procs.enumerated() {
            if i < s.topMemory.count {
                row.0.stringValue = s.topMemory[i].name
                row.1.stringValue = StatFormat.bytes(s.topMemory[i].memory)
            } else {
                row.0.stringValue = ""
                row.1.stringValue = ""
            }
        }
    }
}

final class DiskPanel: StatsPanel {
    private var big: NSTextField!
    private var graph: GraphView!
    private var volumeRows: [(NSTextField, NSTextField)] = []

    override init() {
        super.init()
        big = header(L("Disk"))
        section(L("Volumes"))
        volumeRows = dynamicRows(4, prefix: "v")
        section(L("Activity"))
        graph = graph(colors: [.systemBlue, .systemRed], fixedMax: nil)
        row(L("Read"), key: "read", color: .systemBlue)
        row(L("Write"), key: "write", color: .systemRed)
        section(L("Processes"))
        procs = dynamicRows(5, prefix: "p")
        finishLayout()
    }

    private var procs: [(NSTextField, NSTextField)] = []

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        if let boot = StatsRenderer.bootVolume(s) {
            big.stringValue = L("%@ free", StatFormat.bytes(boot.free, decimals: 0))
        }
        for (i, row) in volumeRows.enumerated() {
            if i < s.volumes.count {
                let v = s.volumes[i]
                row.0.stringValue = v.name
                row.1.stringValue = "\(StatFormat.percent(v.usedFraction)) · \(L("%@ free", StatFormat.bytes(v.free, decimals: 0)))"
            } else {
                row.0.stringValue = ""
                row.1.stringValue = ""
            }
        }
        graph.series = [s.diskReadHistory, s.diskWriteHistory]
        set("read", StatFormat.rate(s.diskRead, bits: false))
        set("write", StatFormat.rate(s.diskWrite, bits: false))
        for (i, row) in procs.enumerated() {
            if i < s.topDisk.count {
                row.0.stringValue = s.topDisk[i].name
                row.1.stringValue = StatFormat.rate(s.topDisk[i].diskRate)
            } else {
                row.0.stringValue = i == 0 && s.processCount > 0 ? L("No disk activity") : ""
                row.1.stringValue = ""
            }
        }
    }
}

final class NetworkPanel: StatsPanel {
    private var big: NSTextField!
    private var graph: GraphView!
    private var ifaceRows: [(NSTextField, NSTextField)] = []
    var publicIP: String? { didSet { set("public", publicIP ?? "–") } }

    override init() {
        super.init()
        big = header(L("Network"))
        graph = graph(colors: [.systemBlue, .systemRed], fixedMax: nil)
        row(L("Download"), key: "down", color: .systemBlue)
        row(L("Upload"), key: "up", color: .systemRed)
        row(L("Downloaded since launch"), key: "totalDown")
        row(L("Uploaded since launch"), key: "totalUp")
        section(L("Data used"))
        row(L("Today"), key: "today")
        row(L("This month"), key: "month")
        section(L("Wi-Fi"))
        row(L("Network"), key: "ssid")
        row(L("Signal / noise"), key: "signal")
        row(L("Channel · rate"), key: "channel")
        section(L("Addresses"))
        ifaceRows = dynamicRows(3, prefix: "i")
        row(L("Router"), key: "router")
        row("DNS", key: "dns")
        row(L("Public IP"), key: "public")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        big.stringValue = "↓ " + StatFormat.rate(s.netDown, bits: o.bits)
        graph.series = [s.netDownHistory, s.netUpHistory]
        set("down", StatFormat.rate(s.netDown, bits: o.bits))
        set("up", StatFormat.rate(s.netUp, bits: o.bits))
        set("totalDown", StatFormat.bytes(s.netSessionDown))
        set("totalUp", StatFormat.bytes(s.netSessionUp))
        if let u = s.usage {
            set("today", "↓ \(StatFormat.bytes(u.dayRx))  ↑ \(StatFormat.bytes(u.dayTx))")
            set("month", "↓ \(StatFormat.bytes(u.monthRx))  ↑ \(StatFormat.bytes(u.monthTx))")
        }
        if let d = s.netDetails {
            if let w = d.wifi {
                // macOS only reveals the network name to apps with Location access.
                set("ssid", w.ssid ?? L("Connected"))
                set("signal", "\(w.rssi) / \(w.noise) dBm")
                set("channel", "\(w.channel.map(String.init) ?? "–") · \(Int(w.rateMbps)) Mbps")
            } else {
                set("ssid", L("Not connected"))
                set("signal", "–")
                set("channel", "–")
            }
            set("router", d.router ?? "–")
            set("dns", d.dns.prefix(2).joined(separator: ", ").isEmpty ? "–" : d.dns.prefix(2).joined(separator: ", "))
        }
        for (i, row) in ifaceRows.enumerated() {
            if i < s.interfaces.count {
                row.0.stringValue = s.interfaces[i].name
                row.1.stringValue = s.interfaces[i].addresses.first { !$0.contains(":") } ?? s.interfaces[i].addresses.first ?? ""
            } else {
                row.0.stringValue = ""
                row.1.stringValue = ""
            }
        }
    }
}

final class SensorsPanel: StatsPanel {
    private var big: NSTextField!

    override init() {
        super.init()
        big = header(L("Sensors"))
        section(L("Temperatures"))
        row(L("CPU (average)"), key: "cpu")
        row(L("CPU (hottest)"), key: "cpuMax")
        row("GPU", key: "gpu")
        row(L("Battery"), key: "battery")
        row(L("SSD"), key: "ssd")
        row(L("Palm rest"), key: "ambient")
        section(L("Fans"))
        row(L("Fan 1"), key: "fan0")
        row(L("Fan 2"), key: "fan1")
        section(L("Power"))
        row(L("System total"), key: "power")
        row(L("Thermal pressure"), key: "thermal")
        row(L("Low Power Mode"), key: "lowpower")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        guard let r = s.sensors else { big.stringValue = "–"; return }
        func t(_ v: Double?) -> String { v.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "–" }
        big.stringValue = t(r.cpu)
        set("cpu", t(r.cpu))
        set("cpuMax", t(r.cpuMax))
        set("gpu", t(r.gpu))
        set("battery", t(r.battery))
        set("ssd", t(r.storage))
        set("ambient", t(r.ambient))
        for i in 0..<2 {
            if i < r.fans.count {
                let f = r.fans[i]
                set("fan\(i)", f.max > 0 ? "\(Int(f.rpm)) rpm (\(Int(f.min))–\(Int(f.max)))" : "\(Int(f.rpm)) rpm")
            } else {
                set("fan\(i)", "–")
            }
        }
        set("power", r.systemPower.map { String(format: "%.1f W", $0) } ?? "–")
        switch s.thermal {
        case .nominal: set("thermal", L("Nominal"))
        case .fair: set("thermal", L("Fair"))
        case .serious: set("thermal", L("Serious (throttling)"))
        case .critical: set("thermal", L("Critical (throttling)"))
        @unknown default: set("thermal", "–")
        }
        set("lowpower", s.lowPowerMode ? L("On") : L("Off"))
    }
}

final class BatteryPanel: StatsPanel {
    private var big: NSTextField!
    private let flow = PowerFlowView()
    private var energy: [(NSTextField, NSTextField)] = []
    private var devices: [(NSTextField, NSTextField)] = []

    override init() {
        super.init()
        big = header(L("Battery"))
        row(L("Status"), key: "state")
        row(L("Time remaining"), key: "time")
        section(L("Power flow"))
        flow.translatesAutoresizingMaskIntoConstraints = false
        flow.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        flow.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(flow)
        row(L("Battery power"), key: "power")
        row(L("Power adapter"), key: "adapter")
        row(L("Display backlight"), key: "display")
        section(L("Battery health"))
        row(L("Health"), key: "health")
        row(L("Cycle count"), key: "cycles")
        row(L("Temperature"), key: "temp")
        section(L("Energy by app"))
        energy = dynamicRows(5, prefix: "e")
        // Measured only while this dropdown is open: keep the rows (compact() runs at open).
        for (i, row) in energy.enumerated() { row.0.stringValue = i == 0 ? L("Measuring…") : " " }
        section(L("Devices"))
        devices = dynamicRows(4, prefix: "d")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        guard let b = s.battery else { big.stringValue = L("No battery"); return }
        big.stringValue = "\(b.percent)%"
        set("state", b.charged ? L("Charged") : b.charging ? L("Charging") : b.onAC ? L("Not charging") : L("On battery"))
        set("time", b.minutesRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "–")
        set("health", b.healthPercent.map { "\($0)%" + (b.condition.map { " · \($0)" } ?? "") } ?? (b.condition ?? "–"))
        set("cycles", b.cycles.map(String.init) ?? "–")
        set("temp", b.temperature.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "–")
        flow.batteryPercent = b.percent
        flow.charging = b.charging
        if let f = s.power { flow.flow = f }
        // Battery power: the flow's (SMC) figure, with the gauge's voltage and current beside it.
        let watts = s.power?.battery ?? b.voltage.flatMap { v in b.amperage.map { v * $0 } }
        if let w = watts {
            let va = b.voltage.flatMap { v in b.amperage.map { String(format: " (%.2f V, %.2f A)", v, $0).replacingOccurrences(of: "-", with: "−") } } ?? ""
            set("power", PowerFlowMath.wattsText(w) + va)
        }
        set("adapter", b.adapterWatts.map { L("%d W rated", $0) } ?? (b.onAC ? L("Connected") : L("Not connected")))
        set("display", s.power?.display.map { PowerFlowMath.plain($0) } ?? "–")
        if let apps = s.energy {
            for (i, row) in energy.enumerated() {
                if i < apps.count {
                    let e = apps[i]
                    row.0.stringValue = e.processes > 1 ? "\(e.name) (\(e.processes))" : e.name
                    row.1.stringValue = e.watts < 0.1 ? String(format: "%.2f W", e.watts) : String(format: "%.1f W", e.watts)
                } else {
                    row.0.stringValue = i > 0 ? " " : s.energyMeasuring ? L("Measuring…") : L("Nothing measurable")
                    row.1.stringValue = ""
                }
            }
        }
        // The registry often lists none on macOS 26; the Bluetooth item's reading (when it's on) has them.
        let list = !s.devices.isEmpty ? s.devices
            : (s.bluetooth?.connected ?? []).compactMap { d in d.lowestBattery.map { DeviceBattery(name: d.name, percent: $0) } }
        for (i, row) in devices.enumerated() {
            if i < list.count {
                row.0.stringValue = list[i].name
                row.1.stringValue = "\(list[i].percent)%"
            } else {
                row.0.stringValue = i == 0 ? L("No Bluetooth devices report a battery") : ""
                row.1.stringValue = ""
            }
        }
    }
}

// MARK: - Time

/// Month calendar, today highlighted.
final class CalendarView: NSView {
    var date = Date() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let cal = Calendar.current
        guard let monthRange = cal.range(of: .day, in: .month, for: date),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: date)) else { return }
        let today = cal.component(.day, from: date)
        let firstWeekday = cal.component(.weekday, from: first)          // 1 = Sunday
        let offset = (firstWeekday - cal.firstWeekday + 7) % 7
        let cols = 7
        let cellW = bounds.width / CGFloat(cols), cellH: CGFloat = 20
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]
        for c in 0..<cols {
            let sym = symbols[(c + cal.firstWeekday - 1) % 7] as NSString
            let size = sym.size(withAttributes: head)
            sym.draw(at: NSPoint(x: CGFloat(c) * cellW + (cellW - size.width) / 2, y: 2), withAttributes: head)
        }
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]
        let todayAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        for day in monthRange {
            let i = offset + day - 1
            let x = CGFloat(i % cols) * cellW, y = 18 + CGFloat(i / cols) * cellH
            let s = "\(day)" as NSString
            let attrs = day == today ? todayAttr : body
            let size = s.size(withAttributes: attrs)
            if day == today {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + (cellW - 19) / 2, y: y, width: 19, height: 19)).fill()
            }
            s.draw(at: NSPoint(x: x + (cellW - size.width) / 2, y: y + (19 - size.height) / 2), withAttributes: attrs)
        }
    }
}

final class TimePanel: StatsPanel {
    private var big: NSTextField!
    private let calendar = CalendarView()
    private var clocks: [(NSTextField, NSTextField)] = []
    private let zones: [String]

    init(worldClocks: [String]) {
        zones = Array(worldClocks.prefix(8))
        super.init()
        big = header("")
        let date = NSTextField(labelWithString: "")
        date.font = .systemFont(ofSize: 12)
        date.textColor = .secondaryLabelColor
        stack.addArrangedSubview(date)
        dateLabel = date
        calendar.translatesAutoresizingMaskIntoConstraints = false
        calendar.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        calendar.heightAnchor.constraint(equalToConstant: 18 + 6 * 20).isActive = true
        stack.addArrangedSubview(calendar)
        if !zones.isEmpty {
            section(L("World clocks"))
            clocks = dynamicRows(zones.count, prefix: "z")
        }
        update(StatsSnapshot(), StatsRenderer.Options())
        finishLayout()
    }

    private var dateLabel: NSTextField!
    required init?(coder: NSCoder) { fatalError() }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        let now = Date()
        let t = DateFormatter()
        t.timeStyle = .medium
        big.stringValue = t.string(from: now)
        let d = DateFormatter()
        d.dateStyle = .full
        dateLabel.stringValue = d.string(from: now)
        if !Calendar.current.isDate(calendar.date, inSameDayAs: now) { calendar.date = now }
        for (i, row) in clocks.enumerated() where i < zones.count {
            guard let tz = TimeZone(identifier: zones[i]) else { continue }
            let f = DateFormatter()
            f.timeZone = tz
            f.dateFormat = "EEE HH:mm"
            let city = zones[i].split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zones[i]
            let hours = Double(tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
            let diff = hours == 0 ? "" : String(format: hours.truncatingRemainder(dividingBy: 1) == 0 ? " (%+.0fh)" : " (%+.1fh)", hours)
            row.0.stringValue = city + diff
            row.1.stringValue = f.string(from: now)
        }
    }
}
