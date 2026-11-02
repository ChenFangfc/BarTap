import Foundation

// Pure, unit-tested pieces of the system monitor. The app feeds raw counters in; nothing here
// touches the system.

/// Fixed-capacity history for graphs (oldest → newest).
public struct RingBuffer: Equatable {
    public let capacity: Int
    private var storage: [Double] = []
    private var head = 0

    public init(capacity: Int) { self.capacity = Swift.max(1, capacity) }

    public mutating func append(_ v: Double) {
        let value = v.isFinite ? v : 0
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    public var values: [Double] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    public var last: Double? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }
    public var count: Int { storage.count }
    public var max: Double { storage.max() ?? 0 }
}

// MARK: CPU

public struct CPUTicks: Equatable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    public var total: UInt64 { user &+ system &+ idle &+ nice }
}

public struct CPUUsage: Equatable {
    public var total: Double     // 0…1
    public var user: Double
    public var system: Double
    public var perCore: [Double]
    public init(total: Double, user: Double, system: Double, perCore: [Double]) {
        self.total = total; self.user = user; self.system = system; self.perCore = perCore
    }
}

public enum CPUMath {
    /// Usage between two tick snapshots. Cores that went away or reset produce 0, never negative.
    public static func usage(previous: [CPUTicks], current: [CPUTicks]) -> CPUUsage {
        var perCore: [Double] = []
        var sumUser = 0.0, sumSystem = 0.0, sumBusy = 0.0, sumAll = 0.0
        for (i, cur) in current.enumerated() {
            guard i < previous.count else { perCore.append(0); continue }
            let p = previous[i]
            let du = Double(sub(cur.user, p.user) + sub(cur.nice, p.nice))
            let ds = Double(sub(cur.system, p.system))
            let di = Double(sub(cur.idle, p.idle))
            let all = du + ds + di
            perCore.append(all > 0 ? (du + ds) / all : 0)
            sumUser += du; sumSystem += ds; sumBusy += du + ds; sumAll += all
        }
        guard sumAll > 0 else { return CPUUsage(total: 0, user: 0, system: 0, perCore: perCore) }
        return CPUUsage(total: sumBusy / sumAll, user: sumUser / sumAll, system: sumSystem / sumAll, perCore: perCore)
    }

    private static func sub(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }
}

// MARK: Counters (network, disk)

public enum CounterMath {
    /// Bytes per second between two monotonically increasing counters. A counter that went
    /// backwards (interface reset, sleep) yields 0 instead of a huge bogus spike.
    public static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double {
        guard seconds > 0.05, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }
}

// MARK: Memory

public struct MemoryBreakdown: Equatable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var free: UInt64

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, free: UInt64) {
        self.total = total; self.app = app; self.wired = wired; self.compressed = compressed; self.cached = cached; self.free = free
    }

    /// Activity Monitor's "Memory Used" = App + Wired + Compressed.
    public var used: UInt64 { app &+ wired &+ compressed }
    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

public enum MemoryMath {
    /// Same formulas as Activity Monitor (counts are pages).
    public static func breakdown(pageSize: UInt64, total: UInt64, internalPages: UInt64, purgeablePages: UInt64,
                                 externalPages: UInt64, wiredPages: UInt64, compressorPages: UInt64,
                                 freePages: UInt64, speculativePages: UInt64) -> MemoryBreakdown {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return MemoryBreakdown(total: total,
                               app: app * pageSize,
                               wired: wiredPages * pageSize,
                               compressed: compressorPages * pageSize,
                               cached: (externalPages + purgeablePages) * pageSize,
                               free: (freePages + speculativePages) * pageSize)
    }
}

public enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4
    public init(kernelLevel: Int32) { self = MemoryPressure(rawValue: Int(kernelLevel)) ?? .normal }
}

// MARK: Formatting

public enum StatFormat {
    public static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// "12 KB/s", "1.2 MB/s"; `compact` → "12K", "1.2M" for the menu bar.
    public static func rate(_ bytesPerSecond: Double, compact: Bool = false, bits: Bool = false) -> String {
        let v = max(0, bits ? bytesPerSecond * 8 : bytesPerSecond)
        let units = bits ? ["b", "Kb", "Mb", "Gb", "Tb"] : ["B", "KB", "MB", "GB", "TB"]
        var value = v, i = 0
        while value >= 1000 && i < units.count - 1 { value /= 1024; i += 1 }
        let number = value < 10 && i > 0 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        if compact { return number + (i == 0 ? (bits ? "b" : "B") : String(units[i].prefix(1))) }
        return "\(number) \(units[i])/s"
    }

    public static func bytes(_ b: UInt64, decimals: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(b), i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return i == 0 ? "\(b) B" : String(format: "%.\(decimals)f %@", value, units[i])
    }

    /// iStat-style short amounts for the two-line U:/F: element: 512M, 12.3G, 412G, 1.8T.
    public static func compactAmount(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        if g < 1 { return "\(Int((g * 1024).rounded()))M" }
        if g < 100 { return String(format: "%.1fG", g) }
        if g < 1000 { return "\(Int(g.rounded()))G" }
        return String(format: "%.1fT", g / 1024)
    }

    public static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        let v = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(v.rounded()))°"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: Alerts

public enum AlertKind: String, CaseIterable {
    case cpuAbove, memoryPressure, diskFreeBelow, temperatureAbove, batteryBelow
}

/// "Condition held continuously for N seconds" → fire once, then re-arm only after it clears.
public struct AlertTracker: Equatable {
    public var holdSeconds: Double
    private var since: Date?
    private var fired = false

    public init(holdSeconds: Double) { self.holdSeconds = holdSeconds }

    public mutating func update(conditionMet: Bool, now: Date) -> Bool {
        guard conditionMet else {
            since = nil
            fired = false
            return false
        }
        if since == nil { since = now }
        guard !fired, let start = since, now.timeIntervalSince(start) >= holdSeconds else { return false }
        fired = true
        return true
    }
}

// MARK: Sensors

public enum SensorGroup: String, CaseIterable {
    case cpu, gpu, battery, storage, ambient
}

public enum SensorClassifier {
    /// Apple-silicon SMC naming: Tp/Te = CPU clusters, Tg = GPU, TB = battery, TH = SSD,
    /// Ts/Ta = palm rest / airflow. Other families (Tf, TV, TD…) are internal rails we skip.
    public static func group(for key: String) -> SensorGroup? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }
        let p = key.prefix(2)
        switch p {
        case "Tp", "Te", "TC": return .cpu
        case "Tg", "TG": return .gpu
        case "TB": return .battery
        case "TH": return .storage
        case "Ts", "Ta", "TA": return .ambient
        default: return nil
        }
    }

    /// Evenly spaced subset so a sample costs a bounded number of SMC reads.
    public static func representative(_ keys: [String], max count: Int) -> [String] {
        let sorted = keys.sorted()
        guard sorted.count > count, count > 0 else { return sorted }
        let step = Double(sorted.count) / Double(count)
        return (0..<count).map { sorted[Int(Double($0) * step)] }
    }

    /// Plausible die/sensor temperature, to drop disconnected or non-temperature keys.
    public static func plausible(_ celsius: Double) -> Bool { celsius > 5 && celsius < 125 }
}

// MARK: Modules & settings

public enum StatsModule: String, CaseIterable {
    case cpu, gpu, memory, disk, network, sensors, battery, time, ai

    /// Elements this module can show, in the order the editor lists them.
    public var elements: [StatsElement] {
        switch self {
        case .cpu: return [.label, .graph, .bar, .pie, .ring, .percent, .cores]
        case .gpu: return [.label, .graph, .bar, .pie, .ring, .percent]
        case .memory: return [.label, .graph, .bar, .pie, .ring, .percent, .usedFree, .used, .free]
        case .disk: return [.label, .graph, .bar, .pie, .ring, .percent, .usedFree, .used, .free, .readWrite]
        case .network: return [.label, .graph, .rates]
        case .sensors: return [.label, .temperature, .fan, .tempFan, .power]
        case .battery: return [.label, .battery, .percent, .timeLeft]
        case .time: return [.clock]
        case .ai: return [.label, .aiTokens, .aiCost, .aiTokensCost, .aiPlan, .aiPlanPercent, .aiPlanTwo, .aiCredits]
        }
    }

    /// Ready-made combinations; the first is the default (the classic iStat Menus layout).
    public var presets: [[StatsElement]] {
        switch self {
        case .cpu: return [[.graph, .percent], [.graph], [.percent], [.cores], [.bar, .percent], [.ring, .percent], [.label, .percent], [.label, .graph, .percent]]
        case .gpu: return [[.graph, .percent], [.graph], [.percent], [.bar, .percent], [.ring, .percent], [.label, .percent]]
        case .memory: return [[.pie, .percent], [.usedFree], [.pie, .usedFree], [.pie], [.percent], [.used], [.bar, .percent], [.ring, .percent], [.graph, .percent], [.label, .percent]]
        case .disk: return [[.pie, .percent], [.readWrite], [.pie, .readWrite], [.usedFree], [.free], [.pie], [.percent], [.graph, .readWrite], [.label, .percent]]
        case .network: return [[.rates], [.graph], [.graph, .rates], [.label, .rates]]
        case .sensors: return [[.temperature], [.tempFan], [.temperature, .fan], [.power], [.label, .temperature]]
        case .battery: return [[.battery, .percent], [.percent], [.timeLeft], [.battery], [.battery, .timeLeft]]
        case .time: return [[.clock]]
        case .ai: return [[.aiTokensCost], [.aiCost], [.label, .aiTokens], [.aiPlan, .aiPlanPercent], [.aiPlanTwo], [.label, .aiTokensCost],
                          [.aiCredits], [.aiPlanTwo, .aiCredits]]
        }
    }

    /// Keeps only elements this module offers, without repeats; nil if nothing is left.
    public func sanitized(_ list: [StatsElement]) -> [StatsElement]? {
        var seen = Set<StatsElement>()
        let out = list.filter { elements.contains($0) && seen.insert($0).inserted }
        return out.isEmpty ? nil : out
    }
}

/// One piece of a stats menu bar item. An item is an ordered list of these, like iStat Menus'
/// "items to show in menubar", so people can combine and order them as they like.
public enum StatsElement: String, CaseIterable {
    case label        // short module name: CPU, GPU, MEM…
    case graph        // history (CPU, GPU, memory); read/write activity (disk); up/down (network)
    case bar          // one vertical meter
    case pie          // filled wedge
    case ring         // circular gauge
    case percent      // 37%
    case cores        // per-core bars (CPU)
    case usedFree     // two lines: U: 12.3G / F: 3.4G
    case used         // 12.3 GB
    case free         // 412 GB
    case readWrite    // two lines: R / W rates, labels fixed
    case rates        // two lines: ↑ / ↓ rates, arrows fixed
    case temperature  // 46°
    case fan          // 1350 rpm
    case tempFan      // two lines: 46° / 1350 rpm
    case power        // 8.4 W
    case battery      // battery glyph
    case timeLeft     // 3:12
    case clock        // the time
    case aiTokens     // 4.6M tokens in the chosen range
    case aiCost       // $12.34, API-equivalent
    case aiTokensCost // two lines: tokens / cost
    case aiPlan       // ring: the plan window closest to its limit
    case aiPlanPercent // 43%
    case aiPlanTwo    // two lines: 5h 43% / 7d 61%
    case aiCredits    // ring + $2.2K: usage credits used (or left) of the monthly limit

    /// The single display mode of BarTap 1.0, as elements.
    public static func fromLegacyMode(_ mode: String) -> [StatsElement]? {
        switch mode {
        case "graphPercent": return [.graph, .percent]
        case "graph": return [.graph]
        case "percent": return [.percent]
        case "cores": return [.cores]
        case "pie": return [.pie]
        case "piePercent": return [.pie, .percent]
        case "usedAmount": return [.used]
        case "freeAmount": return [.free]
        case "activity": return [.readWrite]
        case "rates": return [.rates]
        case "cpuTemperature": return [.temperature]
        case "temperatureAndFan": return [.tempFan]
        case "power": return [.power]
        case "iconPercent": return [.battery, .percent]
        case "timeRemaining": return [.timeLeft]
        case "clock": return [.clock]
        default: return nil
        }
    }
}

/// Data usage per day and per month, accumulated from interface counter deltas.
public struct DataUsage: Equatable {
    public var day: String
    public var month: String
    public var dayRx: UInt64 = 0, dayTx: UInt64 = 0
    public var monthRx: UInt64 = 0, monthTx: UInt64 = 0

    public init(day: String, month: String) { self.day = day; self.month = month }

    /// Adds a sample; rolls the counters over when the day or month changes.
    public mutating func add(rx: UInt64, tx: UInt64, day newDay: String, month newMonth: String) {
        if newMonth != month { month = newMonth; monthRx = 0; monthTx = 0 }
        if newDay != day { day = newDay; dayRx = 0; dayTx = 0 }
        dayRx &+= rx; dayTx &+= tx
        monthRx &+= rx; monthTx &+= tx
    }
}

public enum ClockFormat {
    public static let presets = ["EEE HH:mm", "HH:mm", "EEE h:mm a", "h:mm a", "d MMM HH:mm", "EEE d MMM HH:mm", "HH:mm:ss"]

    /// Whether a date format shows seconds (then the clock must update every second).
    public static func showsSeconds(_ format: String) -> Bool {
        // Ignore quoted literals.
        var inQuote = false
        for c in format {
            if c == "'" { inQuote.toggle(); continue }
            if !inQuote && c == "s" { return true }
        }
        return false
    }
}

public struct AlertSettings: Equatable {
    public var networkEnabled = false
    public var chargedEnabled = false
    public var cpuEnabled = false
    public var cpuPercent = 90
    public var cpuSeconds = 60
    public var memoryPressureEnabled = false
    public var diskEnabled = false
    public var diskFreeGB = 10
    public var temperatureEnabled = false
    public var temperatureC = 95
    public var batteryEnabled = false
    public var batteryPercent = 15
    public init() {}
    public var anyEnabled: Bool {
        cpuEnabled || memoryPressureEnabled || diskEnabled || temperatureEnabled || batteryEnabled || networkEnabled || chargedEnabled
    }
}

public extension Settings {
    /// Enabled modules, in menu bar order (left to right).
    var statsModules: [StatsModule] {
        get {
            var seen = Set<StatsModule>()
            return (defaults.stringArray(forKey: "stats.modules") ?? []).compactMap(StatsModule.init(rawValue:)).filter { seen.insert($0).inserted }
        }
        set {
            var seen = Set<StatsModule>()
            defaults.set(newValue.filter { seen.insert($0).inserted }.map(\.rawValue), forKey: "stats.modules")
            NotificationCenter.default.post(name: .barTapSettingsChanged, object: self, userInfo: ["key": "stats"])
        }
    }

    /// What one module's menu bar item shows, left to right.
    func statsElements(_ m: StatsModule) -> [StatsElement] {
        if let raw = defaults.stringArray(forKey: "stats.elements.\(m.rawValue)"),
           let list = m.sanitized(raw.compactMap(StatsElement.init(rawValue:))) {
            return list
        }
        // BarTap 1.0 stored one display mode per module.
        if let raw = defaults.string(forKey: "stats.mode.\(m.rawValue)"), let legacy = StatsElement.fromLegacyMode(raw),
           let list = m.sanitized(legacy) {
            return list
        }
        return m.presets[0]
    }

    func setStatsElements(_ m: StatsModule, _ list: [StatsElement]) {
        guard let clean = m.sanitized(list) else { return }
        defaults.set(clean.map(\.rawValue), forKey: "stats.elements.\(m.rawValue)")
        NotificationCenter.default.post(name: .barTapSettingsChanged, object: self, userInfo: ["key": "stats"])
    }

    /// Seconds between menu bar updates (1…10). Default 1, like iStat Menus. Unchanged values
    /// are never redrawn, which keeps the cost of a fast refresh low.
    var statsInterval: Double {
        get { let v = defaults.double(forKey: "stats.interval"); return v == 0 ? 1 : min(max(v, 1), 10) }
        set { defaults.set(min(max(newValue, 1), 10), forKey: "stats.interval"); post("stats") }
    }

    var statsFahrenheit: Bool {
        get { defaults.bool(forKey: "stats.fahrenheit") }
        set { defaults.set(newValue, forKey: "stats.fahrenheit"); post("stats") }
    }

    var statsNetworkBits: Bool {
        get { defaults.bool(forKey: "stats.networkBits") }
        set { defaults.set(newValue, forKey: "stats.networkBits"); post("stats") }
    }

    var statsShowPublicIP: Bool {
        get { defaults.bool(forKey: "stats.publicIP") }
        set { defaults.set(newValue, forKey: "stats.publicIP"); post("stats") }
    }

    /// Show every enabled metric in one status item (saves space beside the notch).
    var statsCombined: Bool {
        get { defaults.bool(forKey: "stats.combined") }
        set { defaults.set(newValue, forKey: "stats.combined"); post("stats") }
    }

    var statsColorGraphs: Bool {
        get { defaults.object(forKey: "stats.colorGraphs") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "stats.colorGraphs"); post("stats") }
    }

    var clockFormat: String {
        get { let f = defaults.string(forKey: "stats.clockFormat") ?? ""; return f.isEmpty ? "EEE HH:mm" : f }
        set { defaults.set(newValue, forKey: "stats.clockFormat"); post("stats") }
    }

    /// IANA time-zone identifiers shown in the Time dropdown.
    var worldClocks: [String] {
        get { (defaults.stringArray(forKey: "stats.worldClocks") ?? []).filter { TimeZone(identifier: $0) != nil } }
        set { defaults.set(newValue, forKey: "stats.worldClocks"); post("stats") }
    }

    var alerts: AlertSettings {
        get {
            var a = AlertSettings()
            let d = defaults
            if d.object(forKey: "alerts.network") != nil { a.networkEnabled = d.bool(forKey: "alerts.network") }
            if d.object(forKey: "alerts.charged") != nil { a.chargedEnabled = d.bool(forKey: "alerts.charged") }
            if d.object(forKey: "alerts.cpu") != nil { a.cpuEnabled = d.bool(forKey: "alerts.cpu") }
            if d.object(forKey: "alerts.cpuPercent") != nil { a.cpuPercent = min(max(d.integer(forKey: "alerts.cpuPercent"), 10), 100) }
            if d.object(forKey: "alerts.cpuSeconds") != nil { a.cpuSeconds = min(max(d.integer(forKey: "alerts.cpuSeconds"), 5), 3600) }
            if d.object(forKey: "alerts.memory") != nil { a.memoryPressureEnabled = d.bool(forKey: "alerts.memory") }
            if d.object(forKey: "alerts.disk") != nil { a.diskEnabled = d.bool(forKey: "alerts.disk") }
            if d.object(forKey: "alerts.diskGB") != nil { a.diskFreeGB = min(max(d.integer(forKey: "alerts.diskGB"), 1), 2000) }
            if d.object(forKey: "alerts.temp") != nil { a.temperatureEnabled = d.bool(forKey: "alerts.temp") }
            if d.object(forKey: "alerts.tempC") != nil { a.temperatureC = min(max(d.integer(forKey: "alerts.tempC"), 50), 120) }
            if d.object(forKey: "alerts.battery") != nil { a.batteryEnabled = d.bool(forKey: "alerts.battery") }
            if d.object(forKey: "alerts.batteryPercent") != nil { a.batteryPercent = min(max(d.integer(forKey: "alerts.batteryPercent"), 1), 99) }
            return a
        }
        set {
            let d = defaults
            d.set(newValue.networkEnabled, forKey: "alerts.network")
            d.set(newValue.chargedEnabled, forKey: "alerts.charged")
            d.set(newValue.cpuEnabled, forKey: "alerts.cpu")
            d.set(newValue.cpuPercent, forKey: "alerts.cpuPercent")
            d.set(newValue.cpuSeconds, forKey: "alerts.cpuSeconds")
            d.set(newValue.memoryPressureEnabled, forKey: "alerts.memory")
            d.set(newValue.diskEnabled, forKey: "alerts.disk")
            d.set(newValue.diskFreeGB, forKey: "alerts.diskGB")
            d.set(newValue.temperatureEnabled, forKey: "alerts.temp")
            d.set(newValue.temperatureC, forKey: "alerts.tempC")
            d.set(newValue.batteryEnabled, forKey: "alerts.battery")
            d.set(newValue.batteryPercent, forKey: "alerts.batteryPercent")
            post("alerts")
        }
    }

    internal func post(_ key: String) {
        NotificationCenter.default.post(name: .barTapSettingsChanged, object: self, userInfo: ["key": key])
    }
}

/// SMC data-type decoding (pure, so it is unit-tested).
public enum SMCValue {
    public static func decode(type: String, bytes b: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard b.count == 4 else { return nil }
            let v = Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            return v.isFinite ? v : nil
        case "fpe2": return b.count == 2 ? Double((Int(b[0]) << 6) + (Int(b[1]) >> 2)) : nil
        case "sp78": return b.count == 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case "ui8 ": return b.count >= 1 ? Double(b[0]) : nil
        case "ui16": return b.count == 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32": return b.count == 4 ? Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : nil
        default: return nil
        }
    }
}
