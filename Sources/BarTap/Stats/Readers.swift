import Foundation
import IOKit
import IOKit.ps
import Darwin
import CoreWLAN
import SystemConfiguration
import BarTapCore

// Thin wrappers over public system interfaces. Every call here was measured on an M2 Max at
// ≤ 0.07 ms except process enumeration (~1.5 ms) and battery details (~0.5 ms), which only run
// while the matching dropdown is open.

enum CPUReader {
    static func ticks() -> [CPUTicks] {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var out: [CPUTicks] = []
        out.reserveCapacity(Int(cpus))
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpus) {
            let base = i * stride
            func t(_ s: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(s)])) }
            out.append(CPUTicks(user: t(CPU_STATE_USER), system: t(CPU_STATE_SYSTEM), idle: t(CPU_STATE_IDLE), nice: t(CPU_STATE_NICE)))
        }
        return out
    }

    /// (performance, efficiency) core counts on Apple silicon; (n, 0) elsewhere.
    static func coreLayout() -> (performance: Int, efficiency: Int) {
        func int(_ name: String) -> Int? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        }
        if let p = int("hw.perflevel0.logicalcpu"), let e = int("hw.perflevel1.logicalcpu") { return (p, e) }
        return (int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount, 0)
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }

    static func uptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - (Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }
}

enum MemoryReader {
    private static let pageSize: UInt64 = UInt64(vm_kernel_page_size)
    static let total: UInt64 = ProcessInfo.processInfo.physicalMemory

    static func sample() -> (breakdown: MemoryBreakdown, pageIns: UInt64, pageOuts: UInt64)? {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let b = MemoryMath.breakdown(pageSize: pageSize, total: total,
                                     internalPages: UInt64(s.internal_page_count), purgeablePages: UInt64(s.purgeable_count),
                                     externalPages: UInt64(s.external_page_count), wiredPages: UInt64(s.wire_count),
                                     compressorPages: UInt64(s.compressor_page_count), freePages: UInt64(s.free_count),
                                     speculativePages: UInt64(s.speculative_count))
        return (b, s.pageins, s.pageouts)
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(kernelLevel: level)
    }

    static func swap() -> (used: UInt64, total: UInt64) {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return (0, 0) }
        return (x.xsu_used, x.xsu_total)
    }
}

struct InterfaceInfo: Equatable {
    var name: String
    var addresses: [String]
}

enum NetworkReader {
    /// 64-bit byte counters summed over physical interfaces (en*, pdp_ip*), from NET_RT_IFLIST2.
    /// (getifaddrs only exposes 32-bit counters, which wrap every 4 GB.)
    static func counters() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var offset = 0
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        if isPhysical(name) && (Int32(h2.ifm_flags) & IFF_LOOPBACK) == 0 {
                            rx &+= h2.ifm_data.ifi_ibytes
                            tx &+= h2.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += msgLen
            }
        }
        return (rx, tx)
    }

    static func isPhysical(_ name: String) -> Bool { name.hasPrefix("en") || name.hasPrefix("pdp_ip") }

    /// IPv4/IPv6 addresses of up interfaces (dropdown only).
    static func interfaces() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var map: [String: [String]] = [:]
        var order: [String] = []
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let a = cur {
            defer { cur = a.pointee.ifa_next }
            let name = String(cString: a.pointee.ifa_name)
            guard isPhysical(name), (Int32(a.pointee.ifa_flags) & IFF_UP) != 0, let sa = a.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, saLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            if addr.hasPrefix("fe80") { continue }   // link-local noise
            if map[name] == nil { order.append(name) }
            map[name, default: []].append(addr)
        }
        return order.map { InterfaceInfo(name: $0, addresses: map[$0] ?? []) }
    }
}

struct VolumeInfo: Equatable {
    var name: String
    var mountPoint: String
    var total: UInt64
    var free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum DiskReader {
    /// Cumulative bytes read/written across all block storage drivers.
    static func ioCounters() -> (read: UInt64, write: UInt64) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let service = IOIteratorNext(it), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    /// Local, user-visible volumes (statfs; ~1 µs each).
    static func volumes() -> [VolumeInfo] {
        var list: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&list, MNT_NOWAIT)
        guard n > 0, let list else { return [] }
        var out: [VolumeInfo] = []
        for i in 0..<Int(n) {
            let s = list[i]
            let flags = Int32(bitPattern: s.f_flags)
            guard flags & MNT_LOCAL != 0, flags & MNT_DONTBROWSE == 0 else { continue }
            let mount = withUnsafePointer(to: s.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            // The sealed system volume and its data volume share space; show the data volume as "/".
            if mount.hasPrefix("/System/Volumes/") && mount != "/System/Volumes/Data" { continue }
            let total = UInt64(s.f_blocks) * UInt64(s.f_bsize)
            let free = UInt64(s.f_bavail) * UInt64(s.f_bsize)
            guard total > 0 else { continue }
            let name = mount == "/" || mount == "/System/Volumes/Data" ? "Macintosh HD" : FileManager.default.displayName(atPath: mount)
            if out.contains(where: { $0.name == name && $0.total == total }) { continue }
            out.append(VolumeInfo(name: name, mountPoint: mount == "/System/Volumes/Data" ? "/" : mount, total: total, free: free))
        }
        return out
    }
}

struct GPUInfo: Equatable {
    var utilization: Double          // 0…1
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: UInt64?
    var memoryAllocated: UInt64?
}

enum GPUReader {
    /// The busiest accelerator's statistics, nil if unavailable.
    static func sample() -> GPUInfo? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: GPUInfo?
        while case let service = IOIteratorNext(it), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            func pct(_ k: String) -> Double? { (stats[k] as? NSNumber).map { $0.doubleValue / 100 } }
            func bytes(_ k: String) -> UInt64? { (stats[k] as? NSNumber)?.uint64Value }
            let info = GPUInfo(utilization: u / 100, renderer: pct("Renderer Utilization %"), tiler: pct("Tiler Utilization %"),
                               memoryInUse: bytes("In use system memory"), memoryAllocated: bytes("Alloc system memory"))
            if best == nil || info.utilization > best!.utilization { best = info }
        }
        return best
    }
}

struct WiFiInfo: Equatable {
    var ssid: String?        // nil without Location Services permission
    var rssi: Int
    var noise: Int
    var channel: Int?
    var rateMbps: Double
}

struct NetworkDetails: Equatable {
    var router: String?
    var dns: [String] = []
    var primaryInterface: String?
    var wifi: WiFiInfo?
}

/// Network details for the dropdown (router, DNS, Wi-Fi). Only read while it is open.
final class NetworkDetailsReader {
    private var store: SCDynamicStore?

    func sample() -> NetworkDetails {
        if store == nil { store = SCDynamicStoreCreate(nil, "BarTap" as CFString, nil, nil) }
        var d = NetworkDetails()
        if let store {
            let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            d.router = ipv4?["Router"] as? String
            d.primaryInterface = ipv4?["PrimaryInterface"] as? String
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
            d.dns = dns?["ServerAddresses"] as? [String] ?? []
        }
        if let i = CWWiFiClient.shared().interface(), i.powerOn(), i.rssiValue() != 0 {
            d.wifi = WiFiInfo(ssid: i.ssid(), rssi: i.rssiValue(), noise: i.noiseMeasurement(),
                              channel: i.wlanChannel()?.channelNumber, rateMbps: i.transmitRate())
        }
        return d
    }
}

struct DeviceBattery: Equatable {
    var name: String
    var percent: Int
}

enum PeripheralBatteryReader {
    /// Bluetooth keyboards, mice and trackpads that report a battery level.
    static func sample() -> [DeviceBattery] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [DeviceBattery] = []
        while case let service = IOIteratorNext(it), service != 0 {
            defer { IOObjectRelease(service) }
            guard let pct = (IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue else { continue }
            let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            out.append(DeviceBattery(name: name ?? "Bluetooth device", percent: min(max(pct, 0), 100)))
        }
        return out
    }
}

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var charged: Bool
    var minutesRemaining: Int?   // to empty (discharging) or to full (charging)
    // Details (dropdown only)
    var cycles: Int?
    var healthPercent: Int?
    var temperature: Double?
    var voltage: Double?
    var amperage: Double?
    var adapterWatts: Int?
    var condition: String?
}

enum BatteryReader {
    static func quick() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = charging ? d[kIOPSTimeToFullChargeKey] as? Int : d[kIOPSTimeToEmptyKey] as? Int
            return BatteryInfo(percent: max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur,
                               charging: charging, onAC: onAC, charged: d[kIOPSIsChargedKey] as? Bool ?? false,
                               minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil,
                               condition: d["BatteryHealth"] as? String)
        }
        return nil
    }

    static func details(into b: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        b.cycles = int("CycleCount")
        if let design = int("DesignCapacity"), design > 0, let maxCap = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") {
            b.healthPercent = min(100, Int((Double(maxCap) / Double(design) * 100).rounded()))
        }
        if let t = int("Temperature") { b.temperature = Double(t) / 100 }
        if let v = int("Voltage") { b.voltage = Double(v) / 1000 }
        if let a = int("InstantAmperage") ?? int("Amperage") { b.amperage = Double(Int32(truncatingIfNeeded: a)) / 1000 }
        if let adapter = d["AdapterDetails"] as? [String: Any], let w = (adapter["Watts"] as? NSNumber)?.intValue, w > 0 { b.adapterWatts = w }
    }
}

struct ProcessUsage: Equatable {
    var pid: pid_t
    var name: String
    var cpu: Double        // fraction of one core
    var memory: UInt64     // physical footprint
    var diskRate: Double = 0   // bytes read + written per second
}

/// Top processes by CPU and memory. CPU% needs two samples, so it keeps the previous CPU times.
final class ProcessReader {
    private var previous: [pid_t: UInt64] = [:]
    private var previousDisk: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    func sample() -> [ProcessUsage] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let n = Int(bytes) / MemoryLayout<pid_t>.size
        let now = mach_absolute_time()
        let elapsedNs = previousTime > 0 ? Double((now - previousTime) * timebase.numer / timebase.denom) : 0
        var current: [pid_t: UInt64] = [:]
        current.reserveCapacity(n)
        var currentDisk: [pid_t: UInt64] = [:]
        currentDisk.reserveCapacity(n)
        var out: [ProcessUsage] = []
        out.reserveCapacity(n)
        var nameBuf = [CChar](repeating: 0, count: 256)
        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = (ri.ri_user_time + ri.ri_system_time) * timebase.numer / timebase.denom
            current[pid] = cpuTime
            var cpu = 0.0
            if elapsedNs > 0, let prev = previous[pid], cpuTime >= prev { cpu = Double(cpuTime - prev) / elapsedNs }
            let disk = ri.ri_diskio_bytesread &+ ri.ri_diskio_byteswritten
            currentDisk[pid] = disk
            var diskRate = 0.0
            if elapsedNs > 0, let prev = previousDisk[pid], disk >= prev { diskRate = Double(disk - prev) / (elapsedNs / 1e9) }
            let len = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = len > 0 ? String(cString: nameBuf) : "pid \(pid)"
            out.append(ProcessUsage(pid: pid, name: name, cpu: cpu, memory: ri.ri_phys_footprint, diskRate: diskRate))
        }
        previous = current
        previousDisk = currentDisk
        previousTime = now
        return out
    }

    func reset() {
        previous.removeAll()
        previousDisk.removeAll()
        previousTime = 0
    }
}
