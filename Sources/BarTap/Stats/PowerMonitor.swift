import Foundation
import IOKit
import Darwin
import BarTapCore

// Readers for the Power item. All run on the stats queue. Measured on an M2 Max under heavy
// load: the SMC's flow keys ≈ 0.2–0.5 ms each, one energy-model sample ≈ 1.4 ms (only the
// channels below; the whole group costs twice that), AppleSmartBattery's properties ≈ 0.5 ms.

/// The chip's energy model through IOReport (libIOReport, no root needed): CPU, GPU, memory,
/// Neural Engine and media engines, as energy used since the previous sample. Read only while
/// the Power details are open or the menu bar shows one of these parts.
final class EnergyModelReader {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private struct API {
        let copyChannels: CopyChannels
        let subscribe: CreateSubscription
        let samples: CreateSamples
        let delta: CreateDelta
        let name: ChannelString
        let unit: ChannelString
        let integer: IntegerValue
    }

    private static let api: API? = {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func f<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = f("IOReportCopyChannelsInGroup", CopyChannels.self),
              let sub = f("IOReportCreateSubscription", CreateSubscription.self),
              let samples = f("IOReportCreateSamples", CreateSamples.self),
              let delta = f("IOReportCreateSamplesDelta", CreateDelta.self),
              let name = f("IOReportChannelGetChannelName", ChannelString.self),
              let unit = f("IOReportChannelGetUnitLabel", ChannelString.self),
              let integer = f("IOReportSimpleGetIntegerValue", IntegerValue.self) else { return nil }
        return API(copyChannels: copy, subscribe: sub, samples: samples, delta: delta, name: name, unit: unit, integer: integer)
    }()

    private var subscription: CFTypeRef?
    private var channels: CFMutableDictionary?
    private var previous: (sample: CFDictionary, time: UInt64)?
    private var failed = false
    /// Samples since launch (debug).
    private(set) var reads = 0
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    /// False on Macs without the energy model (Intel) or if subscribing failed.
    var available: Bool { !failed && Self.api != nil }

    private func subscribe() {
        guard let api = Self.api, let all = api.copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() as NSMutableDictionary?,
              let list = all["IOReportChannels"] as? [NSDictionary] else { failed = true; return }
        let wanted = list.filter { ch in
            guard let n = api.name(ch as CFDictionary)?.takeUnretainedValue() as String? else { return false }
            return EnergyModel.part(forChannel: n) != nil
        }
        guard !wanted.isEmpty else { failed = true; return }
        let filtered = NSMutableDictionary(dictionary: all)
        filtered["IOReportChannels"] = wanted
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = api.subscribe(nil, filtered as CFMutableDictionary, &subscribed, 0, nil)?.takeRetainedValue(),
              let chans = subscribed?.takeRetainedValue() else { failed = true; return }
        subscription = sub
        channels = chans
    }

    /// Watts per part since the previous call; nil on the first call (and after `reset()`).
    func sample() -> (components: [PowerComponent: Double], media: Double?)? {
        guard let api = Self.api, !failed else { return nil }
        if subscription == nil { subscribe() }
        guard let sub = subscription, let chans = channels, let now = api.samples(sub, chans, nil)?.takeRetainedValue() else { return nil }
        reads += 1
        let t = mach_absolute_time()
        defer { previous = (now, t) }
        guard let p = previous, t > p.time, let delta = api.delta(p.sample, now, nil)?.takeRetainedValue() as NSDictionary?,
              let items = delta["IOReportChannels"] as? [NSDictionary] else { return nil }
        let seconds = Double((t - p.time) * timebase.numer / timebase.denom) / 1e9
        let deltas: [(name: String, value: Int64, unit: String)] = items.compactMap { item in
            let ch = item as CFDictionary
            guard let n = api.name(ch)?.takeUnretainedValue() as String? else { return nil }
            return (n, api.integer(ch, 0), api.unit(ch)?.takeUnretainedValue() as String? ?? "")
        }
        return EnergyModel.watts(deltas, seconds: seconds)
    }

    /// Forget the last sample (sleep, or nothing needs the parts for a while).
    func reset() { previous = nil }
}

/// Where the power goes right now: the SMC's live figures (adapter in, system total, battery
/// current × voltage, display backlight, the adapter's voltage and current), falling back to the
/// battery's telemetry.
enum PowerSampler {
    /// Reads since launch (debug).
    private(set) static var reads = 0

    /// - Parameter full: also the display backlight and the adapter's voltage and current.
    static func read(smc: SMC?, battery b: BatteryInfo?, full: Bool) -> PowerReading {
        reads += 1
        var r = PowerReading()
        r.hasBattery = b != nil
        r.onAC = b?.onAC ?? true
        r.charging = b?.charging ?? false
        if let smc, smc.isAvailable {
            let adapter = smc.value("PDTR").flatMap { $0.isFinite && $0 >= 0 && $0 < 1000 ? $0 : nil }
            let total = smc.value("PSTR").flatMap { $0 > 0.05 && $0 < 1000 ? $0 : nil }
            if r.onAC { r.adapter = adapter }
            if r.hasBattery, let ma = smc.integer("B0AC"), let mv = smc.integer("B0AV"), mv > 2_500, mv < 30_000, abs(ma) < 20_000 {
                let w = PowerFlowMath.signed(ma * mv / 1_000_000, onAC: r.onAC, charging: r.charging, adapter: r.adapter, system: total)
                r.battery = w
                r.batteryVolts = mv / 1000
                r.batteryAmps = (w < 0 ? -1 : 1) * abs(ma) / 1000
            }
            // The SMC's system total trails its adapter figure by about a second, so under a load
            // that changes they disagree (106 W used of 52 W in, battery idle). What comes in, less
            // what goes into the battery or plus what comes out of it, is the Mac's draw at the
            // same moment, and the flows balance; the total is the fallback.
            let battery = r.battery ?? 0
            if r.onAC, let a = adapter, a > 0.05 {
                r.system = max(0, a - max(battery, 0) + max(-battery, 0))
            } else if !r.onAC, battery < -0.05 {
                r.system = -battery
            } else {
                r.system = total
            }
            if full {
                if let d = smc.value("PDBR"), d > 0.02, d < 200 { r.components[.display] = d }
                if r.onAC, let v = smc.value("VD0R"), v > 1, v < 60 { r.inputVolts = v }
                if r.onAC, let i = smc.value("ID0R"), i >= 0, i < 20 { r.inputAmps = i }
            }
        }
        // No SMC figures (or no system total): the battery's telemetry, a few seconds behind.
        if r.system == nil, r.hasBattery, let t = BatteryReader.telemetry(),
           let flow = PowerFlowMath.fromTelemetry(t, onAC: r.onAC, charging: r.charging) {
            r.adapter = r.adapter ?? flow.adapter
            r.system = flow.system
            r.battery = r.battery ?? flow.battery
        }
        return r
    }
}

enum PowerDetailsReader {
    /// AppleSmartBattery's properties (≈0.5 ms); nil on a Mac without a battery.
    static func read() -> PowerDetails? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return PowerDetails.parse(d)
    }
}

/// The Power details' graph: the last couple of minutes, oldest first. Parts are NaN where they
/// weren't measured (the menu bar didn't need them and the details weren't open).
struct PowerHistory {
    static let capacity = 120
    var system: [Double] = []
    var input: [Double] = []
    /// Into the battery (charging only).
    var charge: [Double] = []
    var parts: [PowerComponent: [Double]] = [:]

    mutating func append(_ r: PowerReading) {
        func push(_ list: inout [Double], _ v: Double?) {
            list.append(v ?? .nan)
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        }
        push(&system, r.system)
        push(&input, r.onAC ? r.adapter : nil)
        push(&charge, r.battery.map { max($0, 0) })
        let measured = !r.components.isEmpty && r.components.keys.contains { $0 != .display }
        for c in PowerComponent.allCases {
            var list = parts[c] ?? []
            push(&list, measured ? r.watts(c) ?? 0 : nil)
            parts[c] = list
        }
    }

    mutating func reset() { self = PowerHistory() }
}
