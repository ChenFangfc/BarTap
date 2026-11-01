import AppKit
import BarTapCore

struct FanReading: Equatable {
    var rpm: Double
    var min: Double
    var max: Double
}

struct SensorReadings: Equatable {
    var cpu: Double?
    var cpuMax: Double?
    var gpu: Double?
    var battery: Double?
    var storage: Double?
    var ambient: Double?
    var fans: [FanReading] = []
    var systemPower: Double?
}

/// Everything the menu bar items and dropdowns draw. Built on the stats queue, handed to main.
struct StatsSnapshot {
    var cpu: CPUUsage?
    var cpuHistory: [Double] = []
    var coreLayout: (performance: Int, efficiency: Int) = (0, 0)
    var loadAverage: [Double] = []
    var uptime: TimeInterval = 0
    var gpu: Double?
    var gpuInfo: GPUInfo?
    var gpuHistory: [Double] = []
    var processCount = 0
    var pageInRate: Double = 0
    var pageOutRate: Double = 0
    var topDisk: [ProcessUsage] = []
    var netDetails: NetworkDetails?
    var usage: DataUsage?
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false
    var devices: [DeviceBattery] = []
    var memory: MemoryBreakdown?
    var memoryHistory: [Double] = []
    var pressure: MemoryPressure = .normal
    var swap: (used: UInt64, total: UInt64) = (0, 0)
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var diskReadHistory: [Double] = []
    var diskWriteHistory: [Double] = []
    var volumes: [VolumeInfo] = []
    var netDown: Double = 0
    var netUp: Double = 0
    var netDownHistory: [Double] = []
    var netUpHistory: [Double] = []
    var netSessionDown: UInt64 = 0
    var netSessionUp: UInt64 = 0
    var interfaces: [InterfaceInfo] = []
    var sensors: SensorReadings?
    var battery: BatteryInfo?
    var topCPU: [ProcessUsage] = []
    var topMemory: [ProcessUsage] = []
    /// AI usage for the menu bar (computed when usage changes, not every second).
    var ai: AIDisplay?
    /// The AI reader's sums and plan limits, for the dropdown.
    var aiDetail: AIUsageEngine.Snapshot?
}

/// Samples system metrics on a private utility queue with one coalesced timer. Only what is
/// displayed, alerted on, or open in a dropdown is sampled; sampling stops entirely while the
/// displays sleep or when nothing needs it.
final class StatsEngine {
    var onSnapshot: ((StatsSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "bartap.stats", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Queue-confined state.
    private var needed: Set<StatsModule> = []
    private var detail: Set<StatsModule> = []
    private var interval: TimeInterval = 2
    private var paused = false
    private var prevTicks: [CPUTicks] = []
    private var prevNet: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private var prevDisk: (r: UInt64, w: UInt64, t: TimeInterval)?
    private var sessionNet: (rx: UInt64, tx: UInt64)?
    private var cpuHistory = RingBuffer(capacity: 90)
    private var gpuHistory = RingBuffer(capacity: 90)
    private var memHistory = RingBuffer(capacity: 90)
    private var diskRHistory = RingBuffer(capacity: 90)
    private var diskWHistory = RingBuffer(capacity: 90)
    private var netDHistory = RingBuffer(capacity: 90)
    private var netUHistory = RingBuffer(capacity: 90)
    private var smc: SMC?
    private var sensorKeys: [SensorGroup: [String]]?
    private var fanLimits: [Int: (min: Double, max: Double)] = [:]
    private var lastSensors: SensorReadings?
    private var lastSensorTime: TimeInterval = 0
    private var lastVolumes: [VolumeInfo] = []
    private var lastVolumeTime: TimeInterval = 0
    private let processes = ProcessReader()
    private let coreLayout = CPUReader.coreLayout()
    private let netDetails = NetworkDetailsReader()
    private var prevPages: (ins: UInt64, outs: UInt64, t: TimeInterval)?
    private var usage: DataUsage
    private var usageSavedAt: TimeInterval = 0
    private let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private let monthFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()

    init() {
        // Restore today's / this month's data usage.
        let d = UserDefaults.standard
        let now = Date()
        let day = dayFormatter.string(from: now), month = monthFormatter.string(from: now)
        var u = DataUsage(day: d.string(forKey: "usage.day") ?? day, month: d.string(forKey: "usage.month") ?? month)
        u.dayRx = UInt64(d.double(forKey: "usage.dayRx")); u.dayTx = UInt64(d.double(forKey: "usage.dayTx"))
        u.monthRx = UInt64(d.double(forKey: "usage.monthRx")); u.monthTx = UInt64(d.double(forKey: "usage.monthTx"))
        u.add(rx: 0, tx: 0, day: day, month: month)
        usage = u
    }

    private func saveUsage() {
        let d = UserDefaults.standard
        d.set(usage.day, forKey: "usage.day"); d.set(usage.month, forKey: "usage.month")
        d.set(Double(usage.dayRx), forKey: "usage.dayRx"); d.set(Double(usage.dayTx), forKey: "usage.dayTx")
        d.set(Double(usage.monthRx), forKey: "usage.monthRx"); d.set(Double(usage.monthTx), forKey: "usage.monthTx")
    }

    /// Persist counters now (on quit / sleep).
    func flush() { queue.sync { saveUsage() } }

    /// - Parameters:
    ///   - modules: metrics needed for menu bar items and alerts.
    func configure(modules: Set<StatsModule>, interval: TimeInterval) {
        queue.async {
            let changed = modules != self.needed || interval != self.interval
            self.needed = modules
            self.interval = interval
            if changed { self.reschedule(primeNow: true) }
        }
    }

    /// A dropdown opened/closed: sample its details (and faster) only while it is visible.
    func setDetail(_ module: StatsModule, _ on: Bool) {
        queue.async {
            if on { self.detail.insert(module) } else { self.detail.remove(module) }
            if !self.detail.contains(.cpu) && !self.detail.contains(.memory) && !self.detail.contains(.disk) { self.processes.reset() }
            self.reschedule(primeNow: on)
        }
    }

    func setPaused(_ on: Bool) {
        queue.async {
            guard self.paused != on else { return }
            self.paused = on
            // Counters jump across sleep; never compute a rate across the gap.
            self.prevTicks = []
            self.prevNet = nil
            self.prevDisk = nil
            self.prevPages = nil
            if on { self.saveUsage() }
            self.reschedule(primeNow: !on)
        }
    }

    private func reschedule(primeNow: Bool) {
        timer?.cancel()
        timer = nil
        let active = needed.union(detail)
        guard !paused, !active.isEmpty else { return }
        let period = detail.isEmpty ? interval : min(interval, 1)
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets macOS coalesce our wake-ups with others (energy).
        t.schedule(deadline: .now() + (primeNow ? 0.05 : period), repeating: period, leeway: .milliseconds(Int(period * 150)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Cumulative sampling time and tick count (debug instrumentation).
    private(set) var sampleSeconds: Double = 0
    private(set) var ticks = 0
    func timing(_ completion: @escaping (Double, Int) -> Void) {
        queue.async { let v = (self.sampleSeconds, self.ticks); DispatchQueue.main.async { completion(v.0, v.1) } }
    }

    private func tick() {
        let started = CFAbsoluteTimeGetCurrent()
        defer { sampleSeconds += CFAbsoluteTimeGetCurrent() - started; ticks += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        let active = needed.union(detail)
        var s = StatsSnapshot()
        s.coreLayout = coreLayout

        if active.contains(.cpu) {
            let ticks = CPUReader.ticks()
            if !prevTicks.isEmpty && prevTicks.count == ticks.count {
                let usage = CPUMath.usage(previous: prevTicks, current: ticks)
                s.cpu = usage
                cpuHistory.append(usage.total)
            }
            prevTicks = ticks
            s.cpuHistory = cpuHistory.values
            if detail.contains(.cpu) {
                s.loadAverage = CPUReader.loadAverage()
                s.uptime = CPUReader.uptime()
            }
        }
        if active.contains(.gpu) || detail.contains(.cpu) {
            s.gpuInfo = GPUReader.sample()
            s.gpu = s.gpuInfo?.utilization
            if let g = s.gpu { gpuHistory.append(g) }
            s.gpuHistory = gpuHistory.values
        }
        if active.contains(.memory) {
            if let m = MemoryReader.sample() {
                s.memory = m.breakdown
                memHistory.append(m.breakdown.usedFraction)
            }
            s.memoryHistory = memHistory.values
            s.pressure = MemoryReader.pressure()
            if detail.contains(.memory) {
                s.swap = MemoryReader.swap()
                if let m = MemoryReader.sample() {
                    let page = Double(vm_kernel_page_size)
                    if let p = prevPages, now - p.t > 0.05 {
                        s.pageInRate = Double(CounterMath.rate(previous: p.ins, current: m.pageIns, seconds: now - p.t)) * page
                        s.pageOutRate = Double(CounterMath.rate(previous: p.outs, current: m.pageOuts, seconds: now - p.t)) * page
                    }
                    prevPages = (m.pageIns, m.pageOuts, now)
                }
            }
        }
        if active.contains(.disk) {
            let io = DiskReader.ioCounters()
            if let p = prevDisk {
                s.diskRead = CounterMath.rate(previous: p.r, current: io.read, seconds: now - p.t)
                s.diskWrite = CounterMath.rate(previous: p.w, current: io.write, seconds: now - p.t)
                diskRHistory.append(s.diskRead)
                diskWHistory.append(s.diskWrite)
            }
            prevDisk = (io.read, io.write, now)
            s.diskReadHistory = diskRHistory.values
            s.diskWriteHistory = diskWHistory.values
            if now - lastVolumeTime > 15 || detail.contains(.disk) {
                lastVolumes = DiskReader.volumes()
                lastVolumeTime = now
            }
            s.volumes = lastVolumes
        }
        if active.contains(.network) {
            let c = NetworkReader.counters()
            if let p = prevNet {
                s.netDown = CounterMath.rate(previous: p.rx, current: c.rx, seconds: now - p.t)
                s.netUp = CounterMath.rate(previous: p.tx, current: c.tx, seconds: now - p.t)
                netDHistory.append(s.netDown)
                netUHistory.append(s.netUp)
                let date = Date()
                usage.add(rx: c.rx >= p.rx ? c.rx - p.rx : 0, tx: c.tx >= p.tx ? c.tx - p.tx : 0,
                          day: dayFormatter.string(from: date), month: monthFormatter.string(from: date))
                if now - usageSavedAt > 60 { saveUsage(); usageSavedAt = now }
            }
            s.usage = usage
            prevNet = (c.rx, c.tx, now)
            if sessionNet == nil { sessionNet = (c.rx, c.tx) }
            if let base = sessionNet {
                s.netSessionDown = c.rx >= base.rx ? c.rx - base.rx : 0
                s.netSessionUp = c.tx >= base.tx ? c.tx - base.tx : 0
            }
            s.netDownHistory = netDHistory.values
            s.netUpHistory = netUHistory.values
            if detail.contains(.network) {
                s.interfaces = NetworkReader.interfaces()
                s.netDetails = netDetails.sample()
            }
        }
        if active.contains(.sensors) || detail.contains(.cpu) {
            // Each SMC read is ~0.4 ms, so the menu bar reads a small subset every few seconds;
            // the sensors dropdown reads the full set every tick while it is open.
            let full = detail.contains(.sensors)
            if full || now - lastSensorTime >= max(interval * 2, 4) || lastSensors == nil {
                lastSensors = readSensors(full: full)
                lastSensorTime = now
            }
            s.sensors = lastSensors
            if detail.contains(.sensors) {
                s.thermal = ProcessInfo.processInfo.thermalState
                s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        if active.contains(.battery) {
            var b = BatteryReader.quick()
            if detail.contains(.battery) {
                if b != nil { BatteryReader.details(into: &b!) }
                s.devices = PeripheralBatteryReader.sample()
            }
            s.battery = b
        }
        if detail.contains(.cpu) || detail.contains(.memory) || detail.contains(.disk) {
            let all = processes.sample()
            s.processCount = all.count
            s.topCPU = Array(all.filter { $0.cpu > 0.001 }.sorted { $0.cpu > $1.cpu }.prefix(5))
            s.topMemory = Array(all.sorted { $0.memory > $1.memory }.prefix(5))
            s.topDisk = Array(all.filter { $0.diskRate > 1024 }.sorted { $0.diskRate > $1.diskRate }.prefix(5))
        }
        let snapshot = s
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }

    private func readSensors(full: Bool) -> SensorReadings? {
        if smc == nil { smc = SMC() }
        guard let smc, smc.isAvailable else { return nil }
        if sensorKeys == nil { sensorKeys = smc.discoverTemperatureKeys() }
        let keys = sensorKeys ?? [:]
        func average(_ group: SensorGroup, _ limit: Int) -> (avg: Double, max: Double)? {
            let picked = SensorClassifier.representative(keys[group] ?? [], max: limit)
            let values = picked.compactMap { smc.value($0) }.filter(SensorClassifier.plausible)
            guard !values.isEmpty else { return nil }
            return (values.reduce(0, +) / Double(values.count), values.max() ?? 0)
        }
        var r = SensorReadings()
        let cpu = average(.cpu, full ? 16 : 6)
        r.cpu = cpu?.avg
        r.cpuMax = cpu?.max
        let fanCount = Int(smc.value("FNum") ?? 0)
        for i in 0..<min(fanCount, 4) {
            guard let rpm = smc.value("F\(i)Ac") else { continue }
            if fanLimits[i] == nil { fanLimits[i] = (smc.value("F\(i)Mn") ?? 0, smc.value("F\(i)Mx") ?? 0) }
            r.fans.append(FanReading(rpm: rpm, min: fanLimits[i]?.min ?? 0, max: fanLimits[i]?.max ?? 0))
        }
        // System power is one read; the menu bar's "Power (W)" mode needs it outside the dropdown too.
        if let p = smc.value("PSTR"), p > 0, p < 1000 { r.systemPower = p }
        if full {
            r.gpu = average(.gpu, 6)?.avg
            r.battery = average(.battery, 3)?.avg
            r.storage = average(.storage, 3)?.max
            r.ambient = average(.ambient, 2)?.avg
        }
        return r
    }
}
