import Foundation
import BarTapCore

// Volume, Bluetooth, 3-in-1 and battery power flow (pure logic). Called from main.swift.
func runTrioTests() {
    test("volume: level → speaker waves, meter bars, percentage") {
        expect(VolumeMath.waves(0, muted: false) == 0 && VolumeMath.waves(0.004, muted: false) == 0, "silent → slash")
        expect(VolumeMath.waves(0.01, muted: false) == 1 && VolumeMath.waves(1.0 / 3, muted: false) == 1)
        expect(VolumeMath.waves(0.34, muted: false) == 2 && VolumeMath.waves(2.0 / 3, muted: false) == 2)
        expect(VolumeMath.waves(0.67, muted: false) == 3 && VolumeMath.waves(1, muted: false) == 3)
        expect(VolumeMath.waves(0.8, muted: true) == 0, "muted → no waves whatever the level")
        expect(VolumeMath.waves(.nan, muted: false) == 0 && VolumeMath.waves(7, muted: false) == 3, "garbage is clamped")
        expect(VolumeMath.filledBars(0, muted: false) == 0 && VolumeMath.filledBars(0.01, muted: false) == 1, "any sound lights a bar")
        expect(VolumeMath.filledBars(0.5, muted: false) == 4 && VolumeMath.filledBars(1, muted: false) == VolumeMath.meterBars)
        expect(VolumeMath.filledBars(0.9, muted: true) == 0)
        expect(VolumeMath.percentText(0.456, muted: false) == "46%" && VolumeMath.percentText(0.456, muted: true) == "0%")
        expect(VolumeMath.effective(0.4, muted: false) == 0.4 && VolumeMath.effective(0.4, muted: true) == 0)
    }

    test("volume: scrolling over the item") {
        // A wheel notch away from you is one volume-key step up, with or without natural scrolling.
        expect(VolumeMath.scrollDelta(deltaY: 1, precise: false, inverted: false) == 1.0 / 16)
        expect(VolumeMath.scrollDelta(deltaY: -1, precise: false, inverted: true) == 1.0 / 16, "natural scrolling flips the delta back")
        expect(VolumeMath.scrollDelta(deltaY: -1, precise: false, inverted: false) == -1.0 / 16)
        expect(VolumeMath.scrollDelta(deltaY: 3, precise: false, inverted: false) == 3.0 / 16, "accelerated wheel")
        expect(VolumeMath.scrollDelta(deltaY: 40, precise: false, inverted: false) == 0.25, "capped per event")
        // Trackpad: 1% per 4 points; two fingers up (natural: negative delta) is louder.
        expect(abs(VolumeMath.scrollDelta(deltaY: -8, precise: true, inverted: true) - 0.02) < 1e-12)
        expect(VolumeMath.scrollDelta(deltaY: 0, precise: true, inverted: false) == 0)
        expect(VolumeMath.adjusted(0.98, by: 0.0625) == 1 && VolumeMath.adjusted(0.03, by: -0.0625) == 0)
        expect(VolumeMath.adjusted(0.5, by: 0.0625) == 0.5625 && VolumeMath.adjusted(0.002, by: 0) == 0, "tiny residue snaps to silent")
        expect(VolumeMath.scrolled(volume: 0.5, muted: true, by: -0.0625) == nil, "turning it down while muted changes nothing")
        let up = VolumeMath.scrolled(volume: 0.5, muted: true, by: 0.0625)
        expect(up?.volume == 0.5625 && up?.muted == false, "turning it up unmutes from the kept level")
        expect(VolumeMath.scrolled(volume: 0.5, muted: false, by: 0) == nil)
        expect(VolumeMath.scrolled(volume: 0.04, muted: false, by: -0.0625)?.volume == 0, "down to silent, not muted")
    }

    test("wi-fi: RSSI → signal arcs") {
        expect(WiFiMath.bars(rssi: nil) == 0 && WiFiMath.bars(rssi: 0) == 0, "off / not connected")
        expect(WiFiMath.bars(rssi: -45) == 3 && WiFiMath.bars(rssi: -62) == 3)
        expect(WiFiMath.bars(rssi: -63) == 2 && WiFiMath.bars(rssi: -74) == 2)
        expect(WiFiMath.bars(rssi: -75) == 1 && WiFiMath.bars(rssi: -92) == 1)
    }

    test("power flow: battery sign by state") {
        // On battery power the battery can only discharge, whatever the sensor's sign convention.
        expect(PowerFlowMath.signed(8.4, onAC: false, charging: false, adapter: nil, system: 8.4) == -8.4)
        expect(PowerFlowMath.signed(-8.4, onAC: false, charging: false, adapter: nil, system: 8.4) == -8.4)
        // Charging: power goes in.
        expect(PowerFlowMath.signed(-23, onAC: true, charging: true, adapter: 60, system: 35) == 23)
        // A 30 W adapter under a 60 W load: the battery tops up the difference.
        expect(PowerFlowMath.signed(30, onAC: true, charging: false, adapter: 30, system: 60) == -30)
        // Full on AC: a trickle keeps the sensor's own sign.
        expect(PowerFlowMath.signed(0.2, onAC: true, charging: false, adapter: 40, system: 37) == 0.2)
        expect(PowerFlowMath.signed(-0.2, onAC: true, charging: false, adapter: 40, system: 37) == -0.2)
    }

    test("power flow: SMC readings") {
        // Measured on an M2 Max at 100% on a 140 W adapter: PDTR 40.4, PSTR 36.9, B0AC 0, B0AV 12586.
        let full = PowerFlowMath.fromSMC(adapterIn: 40.4, systemTotal: 36.9, batteryMilliamps: 0, batteryMillivolts: 12586,
                                         display: 8.35, onAC: true, charging: false)
        expect(full?.adapter == 40.4 && full?.system == 36.9 && full?.battery == 0 && full?.display == 8.35 && full?.source == .smc)
        expect(full?.direction == .idle)
        // Discharging at 620 mA, 12.8 V → −7.94 W; no adapter while on battery even if PDTR reads noise.
        let draining = PowerFlowMath.fromSMC(adapterIn: 0.3, systemTotal: 8.1, batteryMilliamps: -620, batteryMillivolts: 12800,
                                             display: nil, onAC: false, charging: false)
        expect(draining?.adapter == nil && abs((draining?.battery ?? 0) + 7.936) < 1e-9 && draining?.direction == .discharging)
        // Charging at 1.8 A, 12.4 V → +22.3 W.
        let charging = PowerFlowMath.fromSMC(adapterIn: 61, systemTotal: 36, batteryMilliamps: 1800, batteryMillivolts: 12400,
                                             display: nil, onAC: true, charging: true)
        expect(abs((charging?.battery ?? 0) - 22.32) < 1e-9 && charging?.direction == .charging)
        // Measured under a fluctuating load on AC: the battery tops up a brief spike even though
        // PDTR (adapter) reads above PSTR (PSTR lags a second); the sensor's sign stands.
        let spike = PowerFlowMath.fromSMC(adapterIn: 114.8, systemTotal: 95.8, batteryMilliamps: -204, batteryMillivolts: 12578,
                                          display: nil, onAC: true, charging: false)
        expect(abs((spike?.battery ?? 0) + 2.565912) < 1e-9 && spike?.direction == .discharging, "\(String(describing: spike))")
        // Wrong byte order (an implausible voltage) drops the battery figure instead of inventing one.
        let bad = PowerFlowMath.fromSMC(adapterIn: nil, systemTotal: 10, batteryMilliamps: 500, batteryMillivolts: 61_000,
                                        display: nil, onAC: true, charging: true)
        expect(bad?.battery == nil && bad?.system == 10)
        expect(PowerFlowMath.fromSMC(adapterIn: nil, systemTotal: nil, batteryMilliamps: nil, batteryMillivolts: nil,
                                     display: nil, onAC: true, charging: false) == nil)
    }

    test("power flow: battery telemetry fallback") {
        // Real PowerTelemetryData shape (mW): full battery on AC.
        let idle: [String: Any] = ["SystemPowerIn": 34025, "SystemLoad": 34025, "BatteryPower": 0, "SystemVoltageIn": 27794]
        let f = PowerFlowMath.fromTelemetry(idle, onAC: true, charging: false)
        expect(f?.adapter == 34.025 && f?.system == 34.025 && f?.battery == 0 && f?.source == .telemetry, "\(String(describing: f))")
        // On battery: no adapter, the battery supplies the load (sign from state).
        let away: [String: Any] = ["SystemPowerIn": 0, "SystemLoad": 9100, "BatteryPower": 9100]
        let a = PowerFlowMath.fromTelemetry(away, onAC: false, charging: false)
        expect(a?.adapter == nil && a?.battery == -9.1 && a?.direction == .discharging)
        // Charging without a BatteryPower figure: the difference goes into the battery.
        let fill: [String: Any] = ["SystemPowerIn": 60000, "SystemLoad": 35000]
        expect(PowerFlowMath.fromTelemetry(fill, onAC: true, charging: true)?.battery == 25)
        expect(PowerFlowMath.fromTelemetry([:], onAC: true, charging: false) == nil)
    }

    test("power flow: menu bar text and smoothing") {
        // The bar shows whole watts; the dropdown one decimal below 10 W.
        expect(PowerFlowMath.barText(23.4) == "+23 W" && PowerFlowMath.barText(-8.44) == "−8 W" && PowerFlowMath.barText(-8.6) == "−9 W")
        expect(PowerFlowMath.barText(0.4) == "0 W" && PowerFlowMath.barText(-0.49) == "0 W" && PowerFlowMath.barText(nil) == "–")
        expect(PowerFlowMath.smoothed(previous: nil, current: -8) == -8)
        expect(abs(PowerFlowMath.smoothed(previous: -8, current: -10, alpha: 0.5) + 9) < 1e-12, "moves part of the way")
        expect(PowerFlowMath.smoothed(previous: -8, current: 20) == 20, "plugging in starts over")
        expect(PowerFlowMath.smoothed(previous: 5, current: 30) == 30, "a large jump starts over")
        expect(PowerFlowMath.wattsText(23.4) == "+23 W" && PowerFlowMath.wattsText(-8.44) == "−8.4 W")
        expect(PowerFlowMath.wattsText(0.01) == "0 W" && PowerFlowMath.wattsText(-0.04) == "0 W" && PowerFlowMath.wattsText(nil) == "–")
        expect(PowerFlowMath.wattsText(9.96) == "+10.0 W" || PowerFlowMath.wattsText(9.96) == "+10 W")
        expect(PowerFlowMath.plain(-37.42) == "37.4 W" && PowerFlowMath.plain(nil) == "–")
    }

    test("smc: integer keys in either byte order") {
        // B0AV on Apple silicon: bytes 2a 31 = 12586 mV little-endian (AppleSmartBattery Voltage = 12586).
        expect(SMCValue.integer(type: "ui16", bytes: [0x2A, 0x31], littleEndian: true) == 12586)
        expect(SMCValue.integer(type: "ui16", bytes: [0x2A, 0x31], littleEndian: false) == 10801)
        expect(SMCValue.integer(type: "si16", bytes: [0x9C, 0xFF], littleEndian: true) == -100, "discharge current is negative")
        expect(SMCValue.integer(type: "si16", bytes: [0xFF, 0x9C], littleEndian: false) == -100)
        expect(SMCValue.integer(type: "si32", bytes: [0x18, 0xFC, 0xFF, 0xFF], littleEndian: true) == -1000)
        expect(SMCValue.integer(type: "ui8 ", bytes: [7], littleEndian: true) == 7 && SMCValue.integer(type: "si8 ", bytes: [0xFF], littleEndian: false) == -1)
        expect(SMCValue.integer(type: "si16", bytes: [1], littleEndian: true) == nil, "short read")
        var f: Float = 40.5
        let bytes = withUnsafeBytes(of: &f) { Array($0) }
        expect(SMCValue.integer(type: "flt ", bytes: bytes, littleEndian: true) == 40.5, "other types decode as before")
    }

    test("bluetooth: system_profiler JSON") {
        // The layout of `system_profiler SPBluetoothDataType -json` on macOS 26 (names and addresses made up).
        let json = #"""
        {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on","controller_address":"00:00:00:00:00:01"},
          "device_connected":[
            {"Work Mouse":{"device_address":"AA:BB:CC:00:00:01","device_batteryLevelMain":"100%","device_minorType":"Mouse","device_services":"0x400000 < BLE >"}},
            {"Pods":{"device_address":"aa:bb:cc:00:00:02","device_batteryLevelLeft":"62%","device_batteryLevelRight":"58 %","device_batteryLevelCase":"90%","device_minorType":"Headphones","device_services":"0x980019 < HFP AVRCP A2DP AACP GATT ACL >"}}
          ],
          "device_not_connected":[
            {"Desk Keyboard":{"device_address":"AA:BB:CC:00:00:03","device_minorType":"Keyboard"}},
            {"Work Mouse":{"device_address":"AA:BB:CC:00:00:04","device_minorType":"Mouse"}},
            {"Big Speaker":{"device_address":"AA:BB:CC:00:00:05","device_minorType":"Speaker"}},
            {"Pods":{"device_address":"AA:BB:CC:00:00:02","device_minorType":"Headphones"}}
          ]}]}
        """#
        guard let s = BluetoothProfile.parse(Data(json.utf8)) else { expect(false, "parsed"); return }
        expect(s.powered)
        expect(s.devices.map(\.name) == ["Pods", "Work Mouse", "Big Speaker", "Desk Keyboard"], "\(s.devices.map(\.name))")
        expect(s.connected.count == 2)
        let pods = s.devices[0]
        expect(pods.kind == .earbuds && pods.left == 62 && pods.right == 58 && pods.caseBattery == 90 && pods.battery == nil)
        expect(pods.address == "AA:BB:CC:00:00:02" && !pods.lowEnergyOnly, "addresses normalized; a classic device")
        expect(pods.lowestBattery == 58, "the case doesn't count")
        let mouse = s.devices[1]
        expect(mouse.kind == .mouse && mouse.battery == 100 && mouse.lowEnergyOnly && mouse.connected)
        expect(s.lowest?.name == "Pods" && s.earbuds?.name == "Pods")
        expect(!s.devices.contains { !$0.connected && $0.name == "Work Mouse" }, "a disconnected twin of a connected device is hidden")
        expect(s.devices.first { $0.name == "Big Speaker" }?.kind == .speaker && s.devices.first { $0.name == "Desk Keyboard" }?.kind == .keyboard)

        let off = #"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_off"}}]}"#
        let o = BluetoothProfile.parse(Data(off.utf8))
        expect(o?.powered == false && o?.devices.isEmpty == true)
        expect(BluetoothProfile.parse(Data("not json".utf8)) == nil && BluetoothProfile.parse(Data("{}".utf8)) == nil)
        expect(BluetoothProfile.percent("85%") == 85 && BluetoothProfile.percent(NSNumber(value: 40)) == 40)
        expect(BluetoothProfile.percent("n/a") == nil && BluetoothProfile.percent(NSNumber(value: 140)) == nil)
        expect(BluetoothProfile.kind(minorType: "Headset", name: "x", hasEarbuds: false) == .headphones)
        expect(BluetoothProfile.kind(minorType: nil, name: "My AirPods Max", hasEarbuds: false) == .earbuds)
        expect(BluetoothProfile.kind(minorType: nil, name: "Somebody's iPad", hasEarbuds: false) == .tablet)
    }

    test("bluetooth: lowest battery and earbuds") {
        let devices = [BluetoothDevice(name: "Keys", address: "1", connected: true, kind: .keyboard, battery: 31),
                       BluetoothDevice(name: "Mouse", address: "2", connected: true, kind: .mouse, battery: 64),
                       BluetoothDevice(name: "Old", address: "3", connected: false, kind: .mouse, battery: 5)]
        let s = BluetoothState(powered: true, devices: devices)
        expect(s.lowest?.name == "Keys", "only connected devices count")
        expect(s.earbuds == nil)
        expect(BluetoothState(powered: true, devices: []).lowest == nil)
        let caseOnly = BluetoothDevice(name: "Pods", address: "4", connected: true, kind: .earbuds, caseBattery: 70)
        expect(caseOnly.lowestBattery == 70 && caseOnly.hasBattery, "only the case reports: use it")
    }

    test("energy: helpers grouped under their app") {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/153.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        expect(AppGrouping.appBundle(inPath: helper) == "/Applications/Google Chrome.app")
        expect(AppGrouping.appBundle(inPath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == "/System/Applications/Utilities/Terminal.app")
        expect(AppGrouping.appBundle(inPath: "/Applications/Foo.app/Contents/XPCServices/Bar.xpc/Contents/MacOS/Bar") == "/Applications/Foo.app")
        expect(AppGrouping.appBundle(inPath: "/usr/libexec/duetexpertd") == nil && AppGrouping.appBundle(inPath: "/opt/apps/tool") == nil)
        expect(AppGrouping.appName(bundlePath: "/Applications/Google Chrome.app") == "Google Chrome")
        expect(AppGrouping.toolName(path: "/Users/x/.local/share/claude/versions/2.1.316", processName: "2.1.316") == "claude",
               "a binary named after its version takes its folder's name")
        expect(AppGrouping.toolName(path: "/opt/homebrew/bin/gh", processName: "gh") == "gh")
        expect(AppGrouping.toolName(path: nil, processName: "1.0") == "1.0" && AppGrouping.toolName(path: "/1/2/3", processName: "3") == "3")

        var w = EnergyWindow(span: 3)
        expect(w.isEmpty && w.top(5).isEmpty)
        let chrome = "/Applications/Google Chrome.app"
        w.add(seconds: 2, samples: [EnergySample(key: chrome, name: "Google Chrome", joules: 1.0),
                                    EnergySample(key: chrome, name: "Google Chrome", joules: 3.0),   // a helper
                                    EnergySample(key: "proc:mds", name: "mds", joules: 0.5),
                                    EnergySample(key: "proc:idle", name: "idle", joules: 0.001)])
        let top = w.top(5)
        expect(top.map(\.name) == ["Google Chrome", "mds"], "\(top.map(\.name)); tiny users are dropped")
        expect(top.first?.watts == 2 && top.first?.processes == 2, "4 J over 2 s from two processes")
        w.add(seconds: 2, samples: [EnergySample(key: "proc:mds", name: "mds", joules: 7.5)])
        expect(w.top(1).first?.name == "mds" && w.top(5).first?.watts == 2, "averaged over the window: 8 J / 4 s")
        w.add(seconds: 1, samples: [])
        w.add(seconds: 1, samples: [])
        expect(w.top(5).map(\.name) == ["mds"], "the oldest interval left the window")
        w.add(seconds: 0, samples: [EnergySample(key: "x", name: "x", joules: 99)])
        expect(!w.top(5).contains { $0.name == "x" }, "a zero-length interval is ignored")
        w.reset()
        expect(w.isEmpty)
    }

    test("stats: new modules, elements and presets") {
        let (d, discard) = scratchDefaults()
        defer { discard() }
        let s = Settings(defaults: d)
        expect(s.statsModules.isEmpty, "new modules are off by default")
        expect(s.statsElements(.volume) == [.speaker, .percent] && s.statsElements(.bluetooth) == [.bluetoothIcon]
               && s.statsElements(.trio) == [.trio])
        expect(s.statsElements(.battery) == [.battery, .percent], "the battery default is unchanged")
        expect(StatsModule.battery.elements.contains(.batteryPower) && StatsModule.battery.presets.contains([.battery, .batteryPower]))
        for m in [StatsModule.volume, .bluetooth, .trio] {
            for p in m.presets { expect(m.sanitized(p) == p, "\(m) preset \(p)") }
        }
        s.setStatsElements(.volume, [.levelMeter, .bluetoothIcon, .speaker])
        expect(s.statsElements(.volume) == [.levelMeter, .speaker], "foreign elements dropped")
        s.statsModules = [.trio, .volume, .bluetooth]
        expect(Settings(defaults: d).statsModules == [.trio, .volume, .bluetooth])
    }
}
