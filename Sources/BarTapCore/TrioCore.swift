import Foundation

// Pure pieces of the Volume, Bluetooth, three-in-one and battery power-flow stats. The app feeds
// raw readings in (CoreAudio scalars, SMC bytes, system_profiler JSON, per-process energy);
// nothing here touches the system.

// MARK: Volume

public enum VolumeMath {
    /// Bars in the volume level meter.
    public static let meterBars = 8

    /// What the speaker plays: nothing while muted.
    public static func effective(_ volume: Double, muted: Bool) -> Double {
        muted ? 0 : min(max(volume.isFinite ? volume : 0, 0), 1)
    }

    /// Sound waves next to the speaker glyph: 0 = muted or silent (drawn with a slash), else 1…3.
    public static func waves(_ volume: Double, muted: Bool) -> Int {
        let v = effective(volume, muted: muted)
        if v < 0.005 { return 0 }
        if v <= 1.0 / 3 { return 1 }
        if v <= 2.0 / 3 { return 2 }
        return 3
    }

    /// Filled bars of the level meter; any audible level lights at least one.
    public static func filledBars(_ volume: Double, muted: Bool, bars: Int = meterBars) -> Int {
        let v = effective(volume, muted: muted)
        guard v >= 0.005 else { return 0 }
        return min(bars, max(1, Int((v * Double(bars)).rounded())))
    }

    public static func percentText(_ volume: Double, muted: Bool) -> String {
        "\(Int((effective(volume, muted: muted) * 100).rounded()))%"
    }

    /// Volume change for one scroll event over the item. "Up" (wheel away from you, or two fingers
    /// up) is louder whatever the natural-scrolling setting; a wheel notch is one volume-key step
    /// (1/16), a trackpad moves 1% per 4 points.
    public static func scrollDelta(deltaY: Double, precise: Bool, inverted: Bool) -> Double {
        let up = inverted ? -deltaY : deltaY
        guard up.isFinite, up != 0 else { return 0 }
        let step = precise ? up / 400 : (up > 0 ? 1.0 : -1.0) * max(1, min(abs(up), 4)) / 16
        return min(max(step, -0.25), 0.25)
    }

    /// New volume after a step, clamped; tiny residues snap to silent / full.
    public static func adjusted(_ volume: Double, by delta: Double) -> Double {
        let v = min(max(volume + delta, 0), 1)
        if v < 0.004 { return 0 }
        if v > 0.996 { return 1 }
        return v
    }

    /// A scroll step, mute included: while muted, turning it down changes nothing and turning it
    /// up unmutes and continues from the level the device kept (like the volume keys).
    /// nil: leave everything as it is.
    public static func scrolled(volume: Double, muted: Bool, by delta: Double) -> (volume: Double, muted: Bool)? {
        guard delta != 0, !(muted && delta < 0) else { return nil }
        return (adjusted(volume, by: delta), false)
    }
}

// MARK: Wi-Fi

public enum WiFiMath {
    /// Signal arcs: 0 = not connected (or Wi-Fi off), 1…3 by RSSI.
    public static func bars(rssi: Int?) -> Int {
        guard let r = rssi, r < 0 else { return 0 }
        if r >= -62 { return 3 }
        if r >= -74 { return 2 }
        return 1
    }
}

// MARK: Battery power flow

/// Where the power goes, in watts. `battery` is signed: > 0 charging, < 0 discharging.
public struct PowerFlow: Equatable {
    public enum Source: String { case smc, telemetry, gauge }
    public var adapter: Double?     // delivered by the power adapter (nil: none connected)
    public var system: Double?      // what the Mac uses
    public var battery: Double?     // into (+) or out of (−) the battery
    public var display: Double?     // built-in display backlight (part of `system`)
    public var source: Source

    public init(adapter: Double?, system: Double?, battery: Double?, display: Double? = nil, source: Source) {
        self.adapter = adapter; self.system = system; self.battery = battery; self.display = display; self.source = source
    }

    /// Which way the battery's power moves, with a small dead band so a trickle reads as idle.
    public enum Direction: Equatable { case charging, discharging, idle }
    public var direction: Direction {
        guard let b = battery else { return .idle }
        if b > 0.3 { return .charging }
        if b < -0.3 { return .discharging }
        return .idle
    }
}

public enum PowerFlowMath {
    /// A battery reading whose sign can't be trusted (byte order, firmware conventions), signed by
    /// what the battery is doing: on battery power it can only discharge, while charging it can
    /// only take power in. On AC without charging (full, held at a limit) it tops up the
    /// difference only when the Mac draws more than the adapter gives; otherwise the sensor's
    /// own sign stands (a trickle either way).
    public static func signed(_ watts: Double, onAC: Bool, charging: Bool, adapter: Double?, system: Double?) -> Double {
        let w = abs(watts)
        if !onAC { return -w }
        if charging { return w }
        if let a = adapter, let s = system, s > a + 1 { return -w }
        return watts
    }

    /// SMC readings: adapter in (PDTR, W), system total (PSTR, W), battery current (B0AC, mA,
    /// negative while discharging) and voltage (B0AV, mV), display (PDBR, W). Implausible values
    /// are dropped.
    public static func fromSMC(adapterIn: Double?, systemTotal: Double?, batteryMilliamps: Double?, batteryMillivolts: Double?,
                               display: Double?, onAC: Bool, charging: Bool) -> PowerFlow? {
        let system = systemTotal.flatMap { $0 > 0.05 && $0 < 1000 ? $0 : nil }
        var adapter: Double?
        if onAC, let a = adapterIn, a.isFinite, a >= 0, a < 1000 { adapter = a }
        var battery: Double?
        if let ma = batteryMilliamps, let mv = batteryMillivolts, mv > 2_500, mv < 30_000, abs(ma) < 20_000 {
            battery = signed(ma * mv / 1_000_000, onAC: onAC, charging: charging, adapter: adapter, system: system)
        }
        guard system != nil || adapter != nil || battery != nil else { return nil }
        let shownDisplay = display.flatMap { $0 > 0.05 && $0 < 200 ? $0 : nil }
        return PowerFlow(adapter: adapter, system: system, battery: battery, display: shownDisplay, source: .smc)
    }

    /// AppleSmartBattery's PowerTelemetryData (milliwatts): SystemPowerIn is what reaches the Mac
    /// from the adapter, SystemLoad what it uses, BatteryPower the battery's share (its sign is
    /// not documented, so it is signed by state, or derived from the difference).
    public static func fromTelemetry(_ t: [String: Any], onAC: Bool, charging: Bool) -> PowerFlow? {
        func watts(_ k: String) -> Double? {
            guard let n = t[k] as? NSNumber else { return nil }
            let mw = n.doubleValue
            return mw.isFinite && abs(mw) < 1_000_000 ? mw / 1000 : nil
        }
        let input = watts("SystemPowerIn")
        let load = watts("SystemLoad")
        guard input != nil || load != nil else { return nil }
        let adapter = onAC ? input : nil
        var battery: Double?
        if let b = watts("BatteryPower"), abs(b) > 0.05 {
            battery = signed(b, onAC: onAC, charging: charging, adapter: adapter, system: load)
        } else if let i = input, let l = load {
            battery = onAC ? i - l : -l
        }
        return PowerFlow(adapter: adapter, system: load, battery: battery, source: .telemetry)
    }

    /// The menu bar's charge/discharge rate in whole watts: "+23 W", "−8 W", "0 W". Whole watts
    /// change less often (each changed menu bar image costs the menu bar host a few ms).
    public static func barText(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "–" }
        let a = Int(abs(w).rounded())
        return a == 0 ? "0 W" : (w > 0 ? "+" : "−") + "\(a) W"
    }

    /// The bar's figure, smoothed over a few seconds (power draw jumps around second to second).
    /// Plugging in or out, or a large jump, starts over so the bar follows at once.
    public static func smoothed(previous: Double?, current: Double, alpha: Double = 0.35) -> Double {
        guard let p = previous, p.isFinite, (p >= 0) == (current >= 0), abs(current - p) < 15 else { return current }
        return p + alpha * (current - p)
    }

    /// The dropdown's charge/discharge rate: "+23 W", "−8.4 W", "0 W".
    public static func wattsText(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "–" }
        let a = abs(w)
        if a < 0.05 { return "0 W" }
        let number = a < 10 ? String(format: "%.1f", a) : String(format: "%.0f", a)
        return (w > 0 ? "+" : "−") + number + " W"
    }

    /// Watts in the dropdown: "37.4 W".
    public static func plain(_ w: Double?) -> String {
        guard let w, w.isFinite else { return "–" }
        return String(format: "%.1f W", abs(w))
    }
}

public extension SMCValue {
    /// Integer keys in either byte order. Apple-silicon SMCs report the battery gauge's keys
    /// (B0AV, B0AC, B0CT…) little-endian; Intel SMCs are big-endian.
    static func integer(type: String, bytes b: [UInt8], littleEndian: Bool) -> Double? {
        func word(_ n: Int) -> UInt64? {
            guard b.count >= n else { return nil }
            let part = Array(b.prefix(n))
            return (littleEndian ? part.reversed() : part).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "ui8 ": return word(1).map { Double($0) }
        case "si8 ": return word(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "ui16": return word(2).map { Double($0) }
        case "si16": return word(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "ui32": return word(4).map { Double($0) }
        case "si32": return word(4).map { Double(Int32(truncatingIfNeeded: $0)) }
        default: return decode(type: type, bytes: b)
        }
    }
}

// MARK: Bluetooth

public struct BluetoothDevice: Equatable {
    public enum Kind: String { case earbuds, headphones, speaker, mouse, keyboard, trackpad, gamepad, phone, tablet, watch, computer, other }
    public var name: String
    public var address: String
    public var connected: Bool
    public var kind: Kind
    public var battery: Int?          // single battery (mice, keyboards, most headphones)
    public var left: Int?             // earbuds
    public var right: Int?
    public var caseBattery: Int?
    /// Bluetooth Low Energy only (no classic connection to open or close).
    public var lowEnergyOnly = false

    public init(name: String, address: String, connected: Bool, kind: Kind, battery: Int? = nil, left: Int? = nil, right: Int? = nil,
                caseBattery: Int? = nil, lowEnergyOnly: Bool = false) {
        self.name = name; self.address = address; self.connected = connected; self.kind = kind; self.battery = battery
        self.left = left; self.right = right; self.caseBattery = caseBattery; self.lowEnergyOnly = lowEnergyOnly
    }

    /// The lowest level of the parts in use (earbuds count, their case doesn't).
    public var lowestBattery: Int? {
        let worn = [left, right].compactMap { $0 }
        if !worn.isEmpty { return worn.min() }
        return battery ?? caseBattery
    }

    public var hasBattery: Bool { battery != nil || left != nil || right != nil || caseBattery != nil }
}

public struct BluetoothState: Equatable {
    public var powered: Bool
    /// Connected first, then paired, each by name.
    public var devices: [BluetoothDevice]

    public init(powered: Bool, devices: [BluetoothDevice]) { self.powered = powered; self.devices = devices }

    public var connected: [BluetoothDevice] { devices.filter(\.connected) }

    /// The connected device closest to empty, and its level.
    public var lowest: BluetoothDevice? {
        connected.filter { $0.lowestBattery != nil }.min { ($0.lowestBattery ?? 101) < ($1.lowestBattery ?? 101) }
    }

    /// The first connected pair of earbuds (left/right levels).
    public var earbuds: BluetoothDevice? { connected.first { $0.left != nil || $0.right != nil } }
}

/// `system_profiler SPBluetoothDataType -json` (macOS 13+ layout: device_connected /
/// device_not_connected arrays of { name: properties }). Read-only, and no privacy prompt.
public enum BluetoothProfile {
    public static func parse(_ data: Data) -> BluetoothState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]], let c = controllers.first else { return nil }
        let state = (c["controller_properties"] as? [String: Any])?["controller_state"] as? String
        var devices: [BluetoothDevice] = []
        var seen = Set<String>()
        // Connected lists first, so a device listed twice keeps its connected entry.
        let lists = c.keys.filter { $0.hasPrefix("device_") && c[$0] is [Any] }.sorted { a, b in
            let ca = !a.contains("not"), cb = !b.contains("not")
            return ca != cb ? ca : a < b
        }
        for key in lists {
            let connected = key.contains("connected") && !key.contains("not_connected")
            for entry in c[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let p = value as? [String: Any] else { continue }
                    let address = (p["device_address"] as? String ?? "").uppercased()
                    let id = address.isEmpty ? "name:" + name : address
                    guard seen.insert(id).inserted else { continue }
                    let services = p["device_services"] as? String ?? ""
                    devices.append(BluetoothDevice(
                        name: name, address: address, connected: connected,
                        kind: kind(minorType: p["device_minorType"] as? String, name: name, hasEarbuds: p["device_batteryLevelLeft"] != nil || p["device_batteryLevelRight"] != nil),
                        battery: percent(p["device_batteryLevelMain"] ?? p["device_batteryLevel"]),
                        left: percent(p["device_batteryLevelLeft"]), right: percent(p["device_batteryLevelRight"]),
                        caseBattery: percent(p["device_batteryLevelCase"]),
                        lowEnergyOnly: services.contains("BLE") && !services.contains("A2DP") && !services.contains("HFP") && !services.contains("HID ")))
                }
            }
        }
        // A device paired twice (classic + Low Energy) shows once: hide a disconnected twin of a
        // connected device with the same name and kind.
        let live = Set(devices.filter(\.connected).map { "\($0.name)|\($0.kind.rawValue)" })
        devices.removeAll { !$0.connected && live.contains("\($0.name)|\($0.kind.rawValue)") }
        devices.sort { a, b in
            a.connected != b.connected ? a.connected : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return BluetoothState(powered: state.map { $0 == "attrib_on" } ?? !devices.isEmpty, devices: devices)
    }

    /// "85%", "85 %" or 85 → 85.
    public static func percent(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return (0...100).contains(n.intValue) ? n.intValue : nil }
        guard let s = any as? String else { return nil }
        let digits = s.filter(\.isNumber)
        guard !digits.isEmpty, let v = Int(digits), (0...100).contains(v) else { return nil }
        return v
    }

    public static func kind(minorType: String?, name: String, hasEarbuds: Bool) -> BluetoothDevice.Kind {
        if hasEarbuds || name.localizedCaseInsensitiveContains("AirPods") || name.localizedCaseInsensitiveContains("Buds") { return .earbuds }
        switch (minorType ?? "").lowercased() {
        case "headphones", "headset", "handsfree", "hands-free device": return .headphones
        case "speaker", "loudspeaker", "portable audio", "hifi audio device", "car audio": return .speaker
        case "mouse": return .mouse
        case "keyboard": return .keyboard
        case "trackpad", "digitizer tablet", "pointing device": return .trackpad
        case "gamepad", "joystick", "gaming controller": return .gamepad
        case "smartphone", "phone", "cellular": return .phone
        case "tablet": return .tablet
        case "watch", "wearable": return .watch
        case "desktop", "laptop", "computer": return .computer
        default: break
        }
        if name.localizedCaseInsensitiveContains("iPad") { return .tablet }
        if name.localizedCaseInsensitiveContains("iPhone") { return .phone }
        return .other
    }
}

// MARK: Energy by app

public enum AppGrouping {
    /// The outermost app bundle in an executable's path, so helpers, XPC services and login items
    /// inside an app count as that app (".../Google Chrome.app/…/Google Chrome Helper.app/…" →
    /// ".../Google Chrome.app"). nil for tools outside any app.
    public static func appBundle(inPath path: String) -> String? {
        guard let r = path.range(of: ".app/", options: .caseInsensitive) ?? (path.lowercased().hasSuffix(".app") ? path.range(of: ".app", options: [.caseInsensitive, .backwards]) : nil) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// "Google Chrome" for ".../Google Chrome.app".
    public static func appName(bundlePath: String) -> String {
        let last = (bundlePath as NSString).lastPathComponent
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// A tool outside any app, by name. Some installers name the binary after its version
    /// (".../claude/versions/2.1.316"); then the nearest meaningful folder names it ("claude").
    public static func toolName(path: String?, processName: String) -> String {
        guard !processName.contains(where: \.isLetter), let path else { return processName }
        let generic: Set<String> = ["versions", "version", "current", "bin", "sbin", "libexec", "lib", "share", "local", "a"]
        for part in path.split(separator: "/").dropLast().reversed() {
            let name = part.hasPrefix(".") ? String(part.dropFirst()) : String(part)
            if name.contains(where: \.isLetter), !generic.contains(name.lowercased()) { return name }
        }
        return processName
    }
}

/// One process's energy since the previous sample, already attributed to its app (`key`).
public struct EnergySample: Equatable {
    public var key: String
    public var name: String
    public var joules: Double
    public init(key: String, name: String, joules: Double) { self.key = key; self.name = name; self.joules = joules }
}

public struct EnergyUse: Equatable {
    public var key: String
    public var name: String
    public var watts: Double
    public var processes: Int
    public init(key: String, name: String, watts: Double, processes: Int) {
        self.key = key; self.name = name; self.watts = watts; self.processes = processes
    }
}

/// Energy per app averaged over the last few samples (a steadier "right now" than one second).
public struct EnergyWindow {
    public let span: Int
    private var intervals: [(seconds: Double, joules: [String: Double], names: [String: String], counts: [String: Int])] = []

    public init(span: Int = 5) { self.span = max(1, span) }

    public var isEmpty: Bool { intervals.isEmpty }

    public mutating func add(seconds: Double, samples: [EnergySample]) {
        guard seconds > 0.05, seconds.isFinite else { return }
        var joules: [String: Double] = [:], names: [String: String] = [:], counts: [String: Int] = [:]
        for s in samples where s.joules.isFinite && s.joules >= 0 {
            joules[s.key, default: 0] += s.joules
            names[s.key] = s.name
            counts[s.key, default: 0] += 1
        }
        intervals.append((seconds, joules, names, counts))
        if intervals.count > span { intervals.removeFirst(intervals.count - span) }
    }

    public mutating func reset() { intervals.removeAll() }

    /// Apps by average power over the window, highest first; ties by name.
    public func top(_ n: Int, minimumWatts: Double = 0.005) -> [EnergyUse] {
        let seconds = intervals.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return [] }
        var joules: [String: Double] = [:], names: [String: String] = [:], counts: [String: Int] = [:]
        for i in intervals {
            for (k, j) in i.joules { joules[k, default: 0] += j }
            for (k, v) in i.names { names[k] = v }
            for (k, c) in i.counts { counts[k] = max(counts[k] ?? 0, c) }
        }
        var uses: [EnergyUse] = []
        for (key, j) in joules where j / seconds >= minimumWatts {
            uses.append(EnergyUse(key: key, name: names[key] ?? key, watts: j / seconds, processes: counts[key] ?? 1))
        }
        uses.sort { a, b in a.watts != b.watts ? a.watts > b.watts : a.name < b.name }
        return Array(uses.prefix(n))
    }
}
