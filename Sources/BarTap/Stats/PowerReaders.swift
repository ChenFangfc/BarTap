import Foundation
import IOKit
import Darwin
import CoreWLAN
import BarTapCore

// Readers for the battery power flow, energy by app and the 3-in-1 item's Wi-Fi signal. All run
// on the stats queue. Measured on an M2 Max: four SMC power keys ≈ 0.4 ms, PowerTelemetryData
// ≈ 0.01 ms, one energy pass over ~1,250 processes ≈ 2–3 ms (dropdown only), RSSI ≈ 0.05 ms of
// our CPU (2.4 ms wall, an XPC round trip to the Wi-Fi daemon).

extension BatteryReader {
    /// AppleSmartBattery's PowerTelemetryData (one property, ~0.01 ms): the power-flow fallback.
    /// The gauge publishes it only every few tens of seconds (it stayed frozen through a 15 s
    /// sample while the SMC's figures moved every second), so it is never the first choice.
    static func telemetry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}

enum PowerFlowReader {
    /// Reads since launch (debug).
    private(set) static var reads = 0
    /// SMC first (adapter in, system total, battery current × voltage, display): live every
    /// second. Verified on an M2 Max under a fluctuating load: B0AC goes negative (e.g. −204 mA)
    /// whenever the load briefly outruns the adapter, and B0AC × B0AV equals the SMC's own B0AP
    /// battery power (−2,566 mW). Then the battery's telemetry; the gauge's voltage × current last.
    /// - Parameter full: also read the display key (dropdown).
    static func sample(smc: SMC?, battery b: BatteryInfo?, full: Bool) -> PowerFlow? {
        reads += 1
        let onAC = b?.onAC ?? true, charging = b?.charging ?? false
        if let smc, smc.isAvailable,
           let flow = PowerFlowMath.fromSMC(adapterIn: smc.value("PDTR"), systemTotal: smc.value("PSTR"),
                                            batteryMilliamps: smc.integer("B0AC"), batteryMillivolts: smc.integer("B0AV"),
                                            display: full ? smc.value("PDBR") : nil, onAC: onAC, charging: charging),
           flow.battery != nil, flow.system != nil {
            return flow
        }
        if let t = BatteryReader.telemetry(), let flow = PowerFlowMath.fromTelemetry(t, onAC: onAC, charging: charging) {
            return flow
        }
        if let v = b?.voltage, let a = b?.amperage {
            return PowerFlow(adapter: nil, system: nil,
                             battery: PowerFlowMath.signed(v * a, onAC: onAC, charging: charging, adapter: nil, system: nil), source: .gauge)
        }
        return nil
    }
}

/// Energy per app from the kernel's per-process energy counters (rusage v6 `ri_energy_nj`),
/// sampled only while the battery dropdown is open. Helpers, XPC services and login items count
/// toward the app bundle that contains them; command-line tools toward the app that started
/// them (a terminal), like Activity Monitor's Energy tab. Processes of other users (and the
/// kernel) can't be read without root and are left out.
final class EnergyReader {
    private struct Owner { var start: UInt64; var key: String; var name: String }
    private var previous: [pid_t: (start: UInt64, energy: UInt64)] = [:]
    private var previousTime: UInt64 = 0
    private var owners: [pid_t: Owner] = [:]
    private var window = EnergyWindow(span: 5)
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    /// True until two samples exist.
    var measuring: Bool { window.isEmpty }

    /// - Parameter totals: also add up each app's energy since its processes started (the
    ///   first pass looks up every process's app once, a few ms; later passes reuse it).
    func sample(top n: Int = 5, totals: Bool = false) -> [EnergyUse] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = max(0, Int(bytes) / MemoryLayout<pid_t>.size)
        let now = mach_absolute_time()
        let seconds = previousTime > 0 ? Double((now - previousTime) * timebase.numer / timebase.denom) / 1e9 : 0
        var current: [pid_t: (start: UInt64, energy: UInt64)] = [:]
        current.reserveCapacity(count)
        var samples: [EnergySample] = []
        var total: [String: Double] = [:]
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }
            current[pid] = (ri.ri_proc_start_abstime, ri.ri_energy_nj)
            if totals, ri.ri_energy_nj > 0 {
                total[owner(pid, start: ri.ri_proc_start_abstime).key, default: 0] += Double(ri.ri_energy_nj) / 1e9
            }
            // Same process as last time (pids are reused), and its counter only grows.
            guard seconds > 0, let p = previous[pid], p.start == ri.ri_proc_start_abstime, ri.ri_energy_nj > p.energy else { continue }
            let owner = owner(pid, start: ri.ri_proc_start_abstime)
            samples.append(EnergySample(key: owner.key, name: owner.name, joules: Double(ri.ri_energy_nj - p.energy) / 1e9))
        }
        if seconds > 0 { window.add(seconds: seconds, samples: samples) }
        owners = owners.filter { current[$0.key]?.start == $0.value.start }
        previous = current
        previousTime = now
        var uses = window.top(n)
        if totals { for i in uses.indices { uses[i].joules = total[uses[i].key] ?? 0 } }
        return uses
    }

    func reset() {
        previous.removeAll()
        owners.removeAll()
        previousTime = 0
        window.reset()
    }

    /// The app a process counts toward (cached per process).
    private func owner(_ pid: pid_t, start: UInt64) -> Owner {
        if let o = owners[pid], o.start == start { return o }
        var o = Owner(start: start, key: "", name: "")
        var cursor = pid
        // Up to five ancestors: zsh → login → Terminal.
        for _ in 0..<6 {
            if let path = Self.path(cursor), let bundle = AppGrouping.appBundle(inPath: path) {
                o.key = bundle
                o.name = FileManager.default.displayName(atPath: bundle)
                if o.name.hasSuffix(".app") { o.name = AppGrouping.appName(bundlePath: bundle) }
                break
            }
            guard let parent = Self.parent(cursor), parent > 1 else { break }
            cursor = parent
        }
        if o.key.isEmpty {
            let name = AppGrouping.toolName(path: Self.path(pid), processName: Self.name(pid) ?? "pid \(pid)")
            o.key = "proc:" + name
            o.name = name
        }
        owners[pid] = o
        return o
    }

    private static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }
}

/// The 3-in-1 item's Wi-Fi signal: RSSI only (no network name without Location access; this
/// never asks for it).
struct WiFiLink: Equatable {
    var rssi: Int?      // nil: off or not connected
    var ssid: String?   // only if macOS reveals it without a prompt (it usually doesn't)
    var powered = true
    var bars: Int { WiFiMath.bars(rssi: rssi) }
}

enum WiFiLinkReader {
    /// Reads since launch (debug).
    private(set) static var reads = 0

    static func sample(detail: Bool) -> WiFiLink {
        reads += 1
        guard let i = CWWiFiClient.shared().interface() else { return WiFiLink(rssi: nil, ssid: nil, powered: false) }
        let rssi = i.rssiValue()
        var link = WiFiLink(rssi: rssi < 0 ? rssi : nil, ssid: nil)
        if detail {
            link.powered = i.powerOn()
            if link.rssi != nil { link.ssid = i.ssid() }
        }
        return link
    }
}
