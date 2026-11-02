import Foundation
import IOKit
import BarTapCore

/// Read-only access to the System Management Controller (temperatures, fans, power). Uses the
/// public IOKit user-client interface; no root helper, and no writes ever (so no fan control).
/// All calls happen on the stats queue.
final class SMC {
    // Mirrors the kernel's SMCKeyData_t (80 bytes). Swift packs fields into a nested struct's tail
    // padding, so KeyInfo carries explicit padding to keep C's layout.
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var limit = PowerLimit()
        var info = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Command: UInt8 { case read = 5, keyAtIndex = 8, keyInfo = 9 }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]
    private(set) var isAvailable = false

    init() {
        guard MemoryLayout<Param>.stride == 80 else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        isAvailable = IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout Param) -> Param? {
        guard isAvailable else { return nil }
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private func info(_ key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var p = Param()
        p.key = key
        p.command = Command.keyInfo.rawValue
        guard let out = call(&p) else { return nil }
        infoCache[key] = out.info
        return out.info
    }

    /// Numeric value of a key (°C for temperatures, rpm for fans, W for power), or nil.
    func value(_ key: String) -> Double? {
        guard let r = raw(key) else { return nil }
        return SMCValue.decode(type: r.type, bytes: r.bytes)
    }

    /// Signed or unsigned integer key (battery current in mA, voltage in mV…). The battery
    /// gauge's keys are little-endian on Apple silicon (B0AV matches AppleSmartBattery's Voltage
    /// only that way) and big-endian on Intel.
    func integer(_ key: String) -> Double? {
        guard let r = raw(key) else { return nil }
        return SMCValue.integer(type: r.type, bytes: r.bytes, littleEndian: Self.isAppleSilicon)
    }

    /// True on Apple silicon, also for an Intel build running under Rosetta.
    static let isAppleSilicon: Bool = {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }()

    private func raw(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = Self.code(key)
        guard let ki = info(k), ki.size > 0, ki.size <= 32 else { return nil }
        var p = Param()
        p.key = k
        p.info.size = ki.size
        p.command = Command.read.rawValue
        guard let out = call(&p) else { return nil }
        return (Self.name(ki.type), withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(ki.size))) })
    }

    /// Every temperature key with a plausible reading, grouped. Enumerating ~2,400 keys takes
    /// ~0.5 s, so the result is cached per Mac model in UserDefaults.
    func discoverTemperatureKeys() -> [SensorGroup: [String]] {
        let model = Self.modelIdentifier()
        let cacheKey = "smc.temperatureKeys.v1.\(model)"
        if let cached = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String]] {
            var out: [SensorGroup: [String]] = [:]
            for (g, keys) in cached { if let group = SensorGroup(rawValue: g) { out[group] = keys } }
            if !out.isEmpty { return out }
        }
        guard let count = value("#KEY"), count > 0, count < 10_000 else { return [:] }
        var out: [SensorGroup: [String]] = [:]
        for i in 0..<Int(count) {
            var p = Param()
            p.command = Command.keyAtIndex.rawValue
            p.data32 = UInt32(i)
            guard let o = call(&p) else { continue }
            let key = Self.name(o.key)
            guard let group = SensorClassifier.group(for: key), let v = value(key), SensorClassifier.plausible(v) else { continue }
            out[group, default: []].append(key)
        }
        if !out.isEmpty {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: out.map { ($0.key.rawValue, $0.value) }), forKey: cacheKey)
        }
        return out
    }

    static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
