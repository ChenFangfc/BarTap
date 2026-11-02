import Foundation
import CoreAudio
import AudioToolbox
import BarTapCore

struct AudioDevice: Equatable {
    var id: AudioObjectID
    var name: String
    var transport: UInt32
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
}

/// The default output and input devices as the Volume and 3-in-1 items show them.
struct AudioState: Equatable {
    var output: AudioDevice?
    /// 0…1; nil when the device has no volume control (most HDMI / DisplayPort outputs).
    var volume: Double?
    var muted = false
    var canMute = false
    var input: AudioDevice?
    var inputVolume: Double?
    var outputs: [AudioDevice] = []
    var inputs: [AudioDevice] = []

    /// Level the glyphs show: a device without a volume control plays at full level.
    var level: Double { volume ?? 1 }
}

/// CoreAudio property listeners through the C API (function + client data). A Swift closure
/// passed as a listener block is bridged to a new block on every call, so removing it silently
/// fails and it keeps firing (verified); this removes exactly what it added. The client data is
/// a plain token, never a pointer to an object, and handlers run on the main thread.
final class AudioListeners {
    private final class Box { weak var target: AudioListeners? }
    private static var live: [UInt: Box] = [:]   // main thread only
    private static var nextToken: UInt = 1
    private let token: UInt
    private var added: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private let handler: ([AudioObjectPropertySelector]) -> Void

    /// - Parameter handler: called on the main thread with the selectors that changed.
    init(_ handler: @escaping ([AudioObjectPropertySelector]) -> Void) {
        token = Self.nextToken
        Self.nextToken += 1
        self.handler = handler
        let box = Box()
        box.target = self
        Self.live[token] = box
    }

    deinit {
        removeAll()
        Self.live[token] = nil
    }

    private static let proc: AudioObjectPropertyListenerProc = { _, count, addresses, data in
        let token = UInt(bitPattern: data)
        let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
        DispatchQueue.main.async { AudioListeners.live[token]?.target?.handler(selectors) }
        return noErr
    }

    @discardableResult
    func add(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        guard id != 0, AudioObjectHasProperty(id, &a),
              AudioObjectAddPropertyListener(id, &a, Self.proc, UnsafeMutableRawPointer(bitPattern: token)) == noErr else { return false }
        added.append((id, address))
        return true
    }

    /// Removes the listeners on one object, or all of them.
    func remove(_ only: AudioObjectID? = nil) {
        added.removeAll { id, address in
            guard only == nil || only == id else { return false }
            var a = address
            AudioObjectRemovePropertyListener(id, &a, Self.proc, UnsafeMutableRawPointer(bitPattern: token))
            return true
        }
    }

    func removeAll() { remove(nil) }
    var count: Int { added.count }
}

/// CoreAudio, event-driven: property listeners on the system object (default devices, device
/// list) and on the two default devices (volume, mute). Nothing is polled; a change costs a
/// handful of property reads (~1 ms). Runs on the main thread, only while the Volume or 3-in-1
/// item is on. (The first CoreAudio call in a process loads the HAL client once, ~0.1–0.25 s.)
final class AudioMonitor {
    var onChange: ((AudioState) -> Void)?
    private(set) var state: AudioState?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var running = false
    private var boundOutput: AudioObjectID = 0
    private var boundInput: AudioObjectID = 0
    private var devicesDirty = true
    private var refreshQueued = false
    private var outputs: [AudioDevice] = []
    private var inputs: [AudioDevice] = []
    // The default devices' names and capabilities, read when they change (each read is an IPC).
    private var outputDevice: AudioDevice?
    private var inputDevice: AudioDevice?
    private var outputCanMute = false
    /// The system object (default devices, device list) and the two default devices.
    private lazy var systemListeners = AudioListeners { [weak self] selectors in self?.changed(selectors) }
    private lazy var deviceListeners = AudioListeners { [weak self] selectors in self?.changed(selectors) }

    deinit { stop() }

    /// Listeners currently installed, and change notifications received (debug).
    var listenerCount: Int { running ? systemListeners.count + deviceListeners.count : 0 }
    private(set) var events = 0

    func start() {
        guard !running else { return }
        running = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            systemListeners.add(system, Self.address(selector))
        }
        devicesDirty = true
        refresh()
    }

    func stop() {
        guard running else { return }
        running = false
        systemListeners.removeAll()
        deviceListeners.removeAll()
        boundOutput = 0
        boundInput = 0
        state = nil
    }

    private func changed(_ selectors: [AudioObjectPropertySelector]) {
        guard running else { return }
        events += 1
        if selectors.contains(kAudioHardwarePropertyDevices) { devicesDirty = true }
        scheduleRefresh()
    }

    /// Several properties change together (volume on each channel, then the virtual volume);
    /// read them once.
    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    /// A volume change costs ~6 property reads; a device change also re-reads names and lists.
    func refresh() {
        guard running else { return }
        let out = Self.defaultDevice(output: true), inp = Self.defaultDevice(output: false)
        let devicesChanged = devicesDirty
        if devicesDirty {
            devicesDirty = false
            let all = Self.deviceIDs()
            outputs = all.compactMap { Self.device($0, output: true) }
            inputs = all.compactMap { Self.device($0, output: false) }
        }
        if out != boundOutput || inp != boundInput || devicesChanged {
            if out != boundOutput || inp != boundInput { bind(output: out, input: inp) }
            outputDevice = out == 0 ? nil : outputs.first { $0.id == out } ?? Self.device(out, output: true, requireSelectable: false)
                ?? AudioDevice(id: out, name: Self.name(out) ?? "", transport: 0)
            inputDevice = inp == 0 ? nil : inputs.first { $0.id == inp } ?? Self.device(inp, output: false, requireSelectable: false)
                ?? AudioDevice(id: inp, name: Self.name(inp) ?? "", transport: 0)
            var mute = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
            outputCanMute = out != 0 && AudioObjectHasProperty(out, &mute)
        }
        var s = AudioState(output: outputDevice, canMute: outputCanMute, input: inputDevice, outputs: outputs, inputs: inputs)
        if out != 0 {
            s.volume = Self.volume(out, scope: kAudioObjectPropertyScopeOutput)
            if outputCanMute { s.muted = (Self.get(out, Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0) != 0 }
        }
        if inp != 0 { s.inputVolume = Self.volume(inp, scope: kAudioObjectPropertyScopeInput) }
        guard s != state else { return }
        state = s
        onChange?(s)
    }

    // MARK: Actions

    /// Sets the output volume (unmuting, like the volume keys, when raised above zero).
    func setVolume(_ v: Double) {
        guard let out = state?.output?.id else { return }
        let value = Float32(min(max(v, 0), 1))
        if !Self.setVolume(out, scope: kAudioObjectPropertyScopeOutput, value) { return }
        if value > 0, state?.muted == true { setMuted(false) }
        refresh()
    }

    /// A scroll step over the item (see VolumeMath.scrolled).
    func adjustVolume(by delta: Double) {
        guard let s = state, s.volume != nil, let next = VolumeMath.scrolled(volume: s.level, muted: s.muted, by: delta) else { return }
        setVolume(next.volume)   // unmutes too
    }

    func setMuted(_ on: Bool) {
        guard let out = state?.output?.id else { return }
        var value: UInt32 = on ? 1 : 0
        var a = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(out, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        refresh()
    }

    func toggleMute() { setMuted(!(state?.muted ?? false)) }

    func setInputVolume(_ v: Double) {
        guard let inp = state?.input?.id else { return }
        _ = Self.setVolume(inp, scope: kAudioObjectPropertyScopeInput, Float32(min(max(v, 0), 1)))
        refresh()
    }

    func setDefault(_ id: AudioObjectID, output: Bool) {
        var value = id
        var a = Self.address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        refresh()
    }

    // MARK: Listeners on the default devices

    private func bind(output: AudioObjectID, input: AudioObjectID) {
        deviceListeners.removeAll()
        boundOutput = output
        boundInput = input
        let out = kAudioObjectPropertyScopeOutput, inp = kAudioObjectPropertyScopeInput
        deviceListeners.add(output, Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out))
        deviceListeners.add(output, Self.address(kAudioDevicePropertyMute, out))
        // Devices that only have per-channel volumes report changes there.
        for channel: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            deviceListeners.add(output, Self.address(kAudioDevicePropertyVolumeScalar, out, channel))
        }
        deviceListeners.add(input, Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, inp))
        deviceListeners.add(input, Self.address(kAudioDevicePropertyVolumeScalar, inp))
    }

    // MARK: Property access

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// One property read; a property the object lacks simply fails (no separate HasProperty call).
    static func get<T: Numeric>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = address, value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? value : nil
    }

    static func defaultDevice(output: Bool) -> AudioObjectID {
        get(AudioObjectID(kAudioObjectSystemObject),
            address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice), AudioObjectID(0)) ?? 0
    }

    static func deviceIDs() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ id: AudioObjectID) -> String? {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A device that can play (or record) and that macOS lets people pick as the default.
    static func device(_ id: AudioObjectID, output: Bool, requireSelectable: Bool = true) -> AudioDevice? {
        let scope = output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        guard channels(id, scope) > 0, (get(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) ?? 0) == 0 else { return nil }
        if requireSelectable, (get(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope), UInt32(1)) ?? 1) == 0 { return nil }
        return AudioDevice(id: id, name: name(id) ?? "", transport: get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0)
    }

    /// The virtual main volume (what the volume keys change); devices without one fall back to
    /// their main or first stereo channels.
    static func volume(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Double? {
        if let v = get(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope), Float32(0)) { return Double(v) }
        if let v = get(id, address(kAudioDevicePropertyVolumeScalar, scope), Float32(0)) { return Double(v) }
        let channels = [1, 2].compactMap { get(id, address(kAudioDevicePropertyVolumeScalar, scope, AudioObjectPropertyElement($0)), Float32(0)) }
        return channels.isEmpty ? nil : Double(channels.max() ?? 0)
    }

    @discardableResult
    static func setVolume(_ id: AudioObjectID, scope: AudioObjectPropertyScope, _ value: Float32) -> Bool {
        func set(_ a: AudioObjectPropertyAddress) -> Bool {
            var a = a, v = value
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { return false }
            return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        }
        if set(address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)) { return true }
        if set(address(kAudioDevicePropertyVolumeScalar, scope)) { return true }
        let left = set(address(kAudioDevicePropertyVolumeScalar, scope, 1))
        let right = set(address(kAudioDevicePropertyVolumeScalar, scope, 2))
        return left || right
    }
}
