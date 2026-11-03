import AppKit
import CoreAudio
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
        // Volume, Bluetooth, Wi-Fi, power flow and energy by app (Apple devices, made-up levels).
        let speakers = AudioDevice(id: 1, name: "MacBook Pro Speakers", transport: 0)
        let pods = AudioDevice(id: 2, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        let mic = AudioDevice(id: 3, name: "MacBook Pro Microphone", transport: 0)
        s.audio = AudioState(output: speakers, volume: [0.56, 0.62, 0.31, 0.75][i % 4], muted: false, canMute: true, input: mic, inputVolume: 0.62,
                             outputs: [speakers, pods, AudioDevice(id: 4, name: "Studio Display Speakers", transport: 0)], inputs: [mic, pods])
        s.bluetooth = BluetoothState(powered: true, devices: [
            BluetoothDevice(name: "AirPods Pro", address: "00:00:00:00:00:01", connected: true, kind: .earbuds, left: 82, right: 79, caseBattery: 64),
            BluetoothDevice(name: "Magic Keyboard", address: "00:00:00:00:00:02", connected: true, kind: .keyboard, battery: 64),
            BluetoothDevice(name: "Magic Mouse", address: "00:00:00:00:00:03", connected: true, kind: .mouse, battery: 23),
            BluetoothDevice(name: "Magic Trackpad", address: "00:00:00:00:00:04", connected: false, kind: .trackpad),
        ])
        s.bluetoothUpdated = promoNow
        s.wifi = WiFiLink(rssi: -48, ssid: nil)
        // On battery: the battery supplies what the Mac uses (12.8 V × −0.62 A, as in `battery` above).
        s.power = PowerFlow(adapter: nil, system: 7.94, battery: -7.94, display: 2.1, source: .smc)
        s.barWatts = -7.94
        s.energy = [EnergyUse(key: "a", name: "Safari", watts: 1.94, processes: 8), EnergyUse(key: "b", name: "Xcode", watts: 1.21, processes: 5),
                    EnergyUse(key: "c", name: "Music", watts: 0.42, processes: 2), EnergyUse(key: "d", name: "Mail", watts: 0.21, processes: 3),
                    EnergyUse(key: "e", name: "Finder", watts: 0.05, processes: 1)]
        samplePower(&s, step: i, charging: false)
        let ai = sampleAI(step: i)
        s.aiDetail = ai
        s.ai = AIDisplay.make(book: ai.book, plans: ai.plans, agents: [.claudeCode, .codex, .geminiCLI], range: .today,
                              now: promoNow, calendar: .current, prices: { promoPrices.price($0) })
        return s
    }

    /// The Power item's sample: on battery (as the battery figures above), or charging from a
    /// 96 W adapter (the details' render shows every flow then). Made-up, plausible figures.
    static func samplePower(_ s: inout StatsSnapshot, step i: Int, charging: Bool) {
        let noise = { (n: Int) -> Double in let x = sin(Double(n) * 12.9898) * 43758.5453; return x - x.rounded(.down) }
        var p = PowerReading()
        p.onAC = charging
        p.charging = charging
        let cpu = charging ? 8.1 + 0.6 * noise(i) : 2.1 + 0.3 * noise(i)
        p.components = charging ? [.cpu: cpu, .gpu: 2.3, .memory: 1.9, .display: 3.1, .ane: 0.4]
                                : [.cpu: cpu, .gpu: 0.62, .memory: 0.71, .display: 2.1, .ane: 0.04]
        p.media = 0.1
        let parts = p.components.values.reduce(0, +)
        p.system = parts + (charging ? 7.2 : 2.3)
        p.battery = charging ? 36.4 : -(p.system ?? 0)
        p.adapter = charging ? (p.system ?? 0) + 36.4 + 2.2 : nil
        p.inputVolts = charging ? 20.3 : nil
        p.inputAmps = charging ? (p.adapter ?? 0) / 20.3 : nil
        p.batteryVolts = charging ? 12.61 : 12.8
        p.batteryAmps = charging ? 2.89 : -0.62
        s.powerReading = p
        var bar: [StatsElement: Double] = [.powerSystem: p.system ?? 0, .powerBattery: p.battery ?? 0, .batteryVolts: p.batteryVolts ?? 0,
                                           .batteryAmps: p.batteryAmps ?? 0, .cycleCount: 132]
        for (e, c) in [(StatsElement.powerCPU, PowerComponent.cpu), (.powerGPU, .gpu), (.powerMemory, .memory), (.powerDisplay, .display), (.powerANE, .ane)] {
            bar[e] = p.components[c]
        }
        if charging { bar[.powerIn] = p.adapter; bar[.adapterRated] = 96 }
        s.powerBar = bar
        var d = PowerDetails()
        d.voltage = p.batteryVolts; d.amperage = p.batteryAmps; d.temperature = charging ? 33 : 31
        d.cycleCount = 132; d.designCycleCount = 1000
        d.designCapacity = 6075; d.fullChargeCapacity = 5893; d.currentCharge = charging ? 3182 : 5068
        d.cellVoltages = charging ? [4.20, 4.21, 4.20] : [4.27, 4.26, 4.27]
        d.dailyMinPercent = 41; d.dailyMaxPercent = 100
        if charging {
            d.adapterName = "96W USB-C Power Adapter"; d.adapterWatts = 96; d.adapterVolts = 20; d.adapterAmps = 4.7
            d.adapterLoss = 2.1; d.chargingCurrent = 3
        }
        s.powerDetails = d
        // Two minutes of readings: a busy stretch, then calmer.
        var h = PowerHistory()
        for k in 0..<PowerHistory.capacity {
            var r = p
            let n = k + i
            let burst = 4 * pow(noise(n + 40), 3) + (k > 70 && k < 92 ? 3.5 : 0)
            let scale = charging ? 1.0 : 0.3
            r.components[.cpu] = cpu * 0.75 + burst * scale
            r.components[.gpu] = (p.components[.gpu] ?? 0) * (0.8 + 0.5 * noise(n + 300))
            r.components[.memory] = (p.components[.memory] ?? 0) * (0.9 + 0.2 * noise(n + 600))
            r.components[.ane] = (p.components[.ane] ?? 0) * (k > 100 ? 4 : 1)
            r.system = r.components.values.reduce(0, +) + (charging ? 7.2 : 2.3)
            r.adapter = charging ? (r.system ?? 0) + 36.4 + 2.2 : nil
            h.append(r)
        }
        s.powerHistory = h
        let apps: [(String, String, Double, Int, Double)] = [
            ("/Applications/Safari.app", "Safari", charging ? 2.9 : 0.84, 9, 31_000),
            ("/System/Applications/Photos.app", "Photos", charging ? 2.2 : 0.21, 4, 12_400),
            ("/System/Applications/Music.app", "Music", charging ? 0.61 : 0.33, 3, 6_200),
            ("/System/Applications/Mail.app", "Mail", 0.27, 3, 3_900),
            ("/System/Library/CoreServices/Finder.app", "Finder", 0.08, 1, 2_100),
        ]
        s.powerApps = apps.map { EnergyUse(key: $0.0, name: $0.1, watts: $0.2, processes: $0.3, joules: $0.4) }
        s.energyMeasuring = false
        if charging {
            s.battery = BatteryInfo(percent: 54, charging: true, onAC: true, charged: false, minutesRemaining: 72, cycles: 132, healthPercent: 97,
                                    temperature: 33, voltage: 12.61, amperage: 2.89, adapterWatts: 96, condition: "Normal")
            // The battery dropdown's own flow and apps, at the same moment.
            s.power = PowerFlow(adapter: p.adapter, system: p.system, battery: p.battery, display: p.components[.display], source: .smc)
            s.barWatts = p.battery
            s.energy = s.powerApps
        }
    }

    /// Fixed "now" for sample AI data, so renders are reproducible.
    static let promoNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 41)) ?? Date()
    static let promoPrices = AIPrices(bundledURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/ai-prices.json"))

    /// 90 days of plausible coding-agent usage; nobody's real numbers.
    static func sampleAI(step: Int) -> AIUsageEngine.Snapshot {
        let cal = Calendar.current
        var book = AIUsageBook()
        let noise = { (n: Int) -> Double in let x = sin(Double(n) * 12.9898) * 43758.5453; return x - x.rounded(.down) }
        for back in 0..<90 {
            guard let day = cal.date(byAdding: .day, value: -back, to: promoNow) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let busy = (weekday == 1 || weekday == 7 ? 0.25 : 1) * (0.55 + 0.9 * noise(back + 3))
            let today = back == 0 ? (0.6 + 0.04 * Double(step)) : 1
            func t(_ out: Double, _ write: Double, _ read: Double) -> TokenCounts {
                TokenCounts(input: Int64(40_000 * busy * today), output: Int64(out * busy * today),
                            cacheRead: Int64(read * busy * today), cacheWrite: Int64(write * busy * today))
            }
            book.add(AIUsageEntry(agent: .claudeCode, model: "claude-opus-5-5", date: day, tokens: t(500_000, 2_000_000, 40_000_000)), calendar: cal)
            book.add(AIUsageEntry(agent: .claudeCode, model: "claude-sonnet-5-5", date: day, tokens: t(150_000, 600_000, 9_000_000)), calendar: cal)
            book.add(AIUsageEntry(agent: .codex, model: "gpt-5.5", date: day, tokens: t(250_000, 0, 12_000_000)), calendar: cal)
            if back % 3 == 0 {
                book.add(AIUsageEntry(agent: .geminiCLI, model: "gemini-2.5-pro", date: day, tokens: t(80_000, 0, 2_000_000)), calendar: cal)
            }
        }
        let plans: [AIAgent: AIPlanStatus] = [
            .claudeCode: AIPlanStatus(agent: .claudeCode, plan: nil, windows: [
                AIPlanWindow(minutes: 300, usedPercent: 43, resetsAt: promoNow.addingTimeInterval(2 * 3600 + 20 * 60)),
                AIPlanWindow(minutes: 10_080, usedPercent: 61, resetsAt: promoNow.addingTimeInterval(3 * 86_400)),
            ], credits: nil, updated: promoNow.addingTimeInterval(-300),
               spend: AISpend(used: 1234.56, limit: 5000, currency: "USD")),
            .codex: AIPlanStatus(agent: .codex, plan: "plus", windows: [
                AIPlanWindow(minutes: 10_080, usedPercent: 18, resetsAt: promoNow.addingTimeInterval(4 * 86_400 + 3600)),
            ], credits: nil, updated: promoNow.addingTimeInterval(-60)),
        ]
        return AIUsageEngine.Snapshot(book: book, plans: plans, detected: [.claudeCode, .codex, .geminiCLI], progress: nil, updated: promoNow)
    }

    static func export(to dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("items"), withIntermediateDirectories: true)
        let o = StatsRenderer.Options(fahrenheit: false, bits: false, clockFormat: "EEE HH:mm")
        var c = DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 41)
        let clockDate = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        let items: [(StatsModule, [StatsElement])] = [(.cpu, [.graph, .percent]), (.memory, [.pie, .percent]), (.disk, [.pie, .percent]),
                                                      (.network, [.rates]), (.sensors, [.temperature]), (.time, [.clock]),
                                                      (.battery, [.battery, .percent]), (.gpu, [.graph, .percent]), (.ai, [.aiTokensCost]),
                                                      (.power, [.powerIcon, .powerTwo])]
        for step in 0..<12 {
            var s = sampleSnapshot(step: step)
            samplePower(&s, step: step, charging: true)
            for (m, elements) in items {
                let w = StatsRenderer.width(m, elements, o)
                let img = StatsRenderer.bitmap(width: w, scale: 6) { r in StatsRenderer.drawContent(m, elements, s, o, r, now: clockDate) }
                write(img, dir.appendingPathComponent("items/\(m.rawValue)_\(step).png"))
            }
        }
        c.minute = 41
        // Every preset and every single element of every module, for review and the README.
        try? fm.createDirectory(at: dir.appendingPathComponent("gallery"), withIntermediateDirectories: true)
        let sample = sampleSnapshot(step: 3)
        // Power's items show the same moment as its details (charging): every flow has a figure.
        var chargingSample = sample
        samplePower(&chargingSample, step: 3, charging: true)
        for m in StatsModule.allCases {
            let shown = m == .power ? chargingSample : sample
            for (i, elements) in m.presets.enumerated() {
                let img = StatsRenderer.bitmap(width: StatsRenderer.width(m, elements, o), scale: 6) { r in
                    StatsRenderer.drawContent(m, elements, shown, o, r, now: clockDate)
                }
                write(img, dir.appendingPathComponent("gallery/\(m.rawValue)-preset\(i).png"))
            }
            for e in m.elements {
                let img = StatsRenderer.bitmap(width: StatsRenderer.width(m, [e], o), scale: 6) { r in
                    StatsRenderer.drawContent(m, [e], shown, o, r, now: clockDate)
                }
                write(img, dir.appendingPathComponent("gallery/\(m.rawValue)-el-\(e.rawValue).png"))
            }
        }
        // AI usage, one segment per agent.
        var perAgent = o
        perAgent.aiTags = ["CC", "CX", "GM"]
        for (i, elements) in [[StatsElement.aiTokensCost], [.aiCost]].enumerated() {
            let img = StatsRenderer.bitmap(width: StatsRenderer.width(.ai, elements, perAgent), scale: 6) { r in
                StatsRenderer.drawContent(.ai, elements, sample, perAgent, r, now: clockDate)
            }
            write(img, dir.appendingPathComponent("gallery/ai-peragent\(i).png"))
        }
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
        // Default settings from a throwaway file (a named suite would leave a plist in ~/Library/Preferences).
        let scratch = NSTemporaryDirectory() + "bartap-promo-\(UUID().uuidString).plist"
        let promoSettings = Settings(defaults: UserDefaults(suiteName: scratch)!)
        defer {
            CFPreferencesAppSynchronize(scratch as CFString)
            try? fm.removeItem(atPath: scratch)
        }
        let aiPanel = AIPanel(settings: promoSettings, prices: promoPrices, agents: [.claudeCode, .codex, .geminiCLI])
        aiPanel.clock = { promoNow }
        let panels: [(String, StatsPanel)] = [("cpu", CPUPanel()), ("memory", MemoryPanel()), ("network", NetworkPanel()),
                                               ("sensors", SensorsPanel()), ("disk", DiskPanel()), ("battery", BatteryPanel()),
                                               ("ai", aiPanel), ("volume", VolumePanel(audio: nil, state: s.audio)),
                                               ("bluetooth", BluetoothPanel(state: s.bluetooth, updated: promoNow, access: .allowed)),
                                               ("trio", TrioPanel())]
        var charging = s
        samplePower(&charging, step: 3, charging: true)
        let power = PowerPanel(hasBattery: true, interval: 1)
        power.drawStill()
        let onBattery = PowerPanel(hasBattery: true, interval: 1)
        onBattery.drawStill()
        for (name, panel) in panels + [("power", power as StatsPanel), ("power_onbattery", onBattery)] {
            panel.update(name == "power" ? charging : s, o)
            panel.compact()
            for dark in [false, true] {
                capture(panel, dark: dark, scale: 2, to: dir.appendingPathComponent("panel_\(name)_\(dark ? "dark" : "light").png"))
            }
        }
        // The Chinese film's Power item (its tags are words).
        Loc.language = .zhHans
        for step in 0..<12 {
            var s = sampleSnapshot(step: step)
            samplePower(&s, step: step, charging: true)
            let e: [StatsElement] = [.powerIcon, .powerTwo]
            let img = StatsRenderer.bitmap(width: StatsRenderer.width(.power, e, o), scale: 6) { r in StatsRenderer.drawContent(.power, e, s, o, r, now: clockDate) }
            write(img, dir.appendingPathComponent("items/power_zh_\(step).png"))
        }
        Loc.language = .system
        exportFilm(to: dir.appendingPathComponent("film"), options: o)
        print("exported promo assets to \(dir.path)")
    }

    /// The film's details, in English and Chinese (light): Power without dots (the film moves
    /// them, from the flows' geometry in power_<lang>.json), Power pointing at the CPU's flow, and
    /// the panels of its montage.
    static func exportFilm(to dir: URL, options o: StatsRenderer.Options) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var charging = sampleSnapshot(step: 3)
        samplePower(&charging, step: 3, charging: true)
        let scratch = NSTemporaryDirectory() + "bartap-film-\(UUID().uuidString).plist"
        let settings = Settings(defaults: UserDefaults(suiteName: scratch)!)
        defer {
            CFPreferencesAppSynchronize(scratch as CFString)
            try? FileManager.default.removeItem(atPath: scratch)
        }
        for language in [AppLanguage.en, .zhHans] {
            Loc.language = language
            let tag = language == .en ? "en" : "zh"
            let power = PowerPanel(hasBattery: true, interval: 1)
            power.update(charging, o)
            power.compact()
            capture(power, dark: false, scale: 2, to: dir.appendingPathComponent("panel_power_\(tag).png"))
            if let data = try? JSONSerialization.data(withJSONObject: power.promoLayout(dark: false), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("power_\(tag).json"))
            }
            power.promoHover(from: "mac", to: "cpu")
            capture(power, dark: false, scale: 2, to: dir.appendingPathComponent("panel_power_hover_\(tag).png"))
            let ai = AIPanel(settings: settings, prices: promoPrices, agents: [.claudeCode, .codex, .geminiCLI])
            ai.clock = { promoNow }
            let montage: [(String, StatsPanel)] = [("cpu", CPUPanel()), ("memory", MemoryPanel()), ("network", NetworkPanel()), ("ai", ai),
                                                   ("battery", BatteryPanel()),
                                                   ("bluetooth", BluetoothPanel(state: charging.bluetooth, updated: promoNow, access: .allowed))]
            for (name, panel) in montage {
                panel.update(charging, o)
                panel.compact()
                capture(panel, dark: false, scale: 2, to: dir.appendingPathComponent("panel_\(name)_\(tag).png"))
            }
        }
        Loc.language = .system
    }

    /// Renders a view at `scale` on a solid menu-colored background (an offscreen material view
    /// has no backdrop and renders flat gray).
    static func capture(_ view: NSView, dark: Bool, scale: CGFloat, to url: URL) {
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
