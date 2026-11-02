import Foundation
import IOKit
import CoreAudio
import CoreBluetooth
import IOBluetooth
import BarTapCore

/// Paired Bluetooth devices, their connection state and batteries (AirPods left/right/case,
/// Magic and third-party mice and keyboards).
///
/// Source: `system_profiler SPBluetoothDataType -json`, the only read path on macOS 26 that
/// covers Low Energy devices and earbuds without a privacy prompt (IORegistry `BatteryPercent`
/// only exists for Apple HID devices; IOBluetooth needs Bluetooth permission for any read). One
/// read is ~0.2 s wall / ~40–60 ms CPU in a child process, so it runs only when the dropdown opens
/// (then every 10 s while it stays open), every 60 s while the item shows a battery level, and a
/// few seconds after a Bluetooth HID device or an audio device appears or disappears
/// (event-driven, IOKit and CoreAudio notifications), which keeps the connected count current.
final class BluetoothMonitor {
    var onChange: ((BluetoothState, Date) -> Void)?
    private(set) var state: BluetoothState?
    /// Re-read every 60 s (battery levels drift without any event).
    var periodic = true { didSet { if periodic != oldValue { reschedule() } } }
    private(set) var updated: Date?

    private let queue = DispatchQueue(label: "bartap.bluetooth", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var reading = false
    private var running = false
    private var detailOpen = false
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private lazy var audioDevices = AudioListeners { [weak self] _ in self?.refresh(after: 3) }

    deinit { stop() }

    func start() {
        guard !running else { return }
        running = true
        watchConnections()
        refresh(after: 0)
        reschedule()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        pending?.cancel()
        pending = nil
        for it in iterators { IOObjectRelease(it) }
        iterators.removeAll()
        if let p = notifyPort { IONotificationPortDestroy(p) }
        notifyPort = nil
        audioDevices.removeAll()
        state = nil
        updated = nil
    }

    /// The dropdown opened or closed.
    func setDetail(_ open: Bool) {
        guard running, open != detailOpen else { return }
        detailOpen = open
        if open { refresh(after: 0) }
        reschedule()
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard running, detailOpen || periodic else { return }
        let period: TimeInterval = detailOpen ? 10 : 60
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + period, repeating: period, leeway: .seconds(detailOpen ? 1 : 10))
        t.setEventHandler { [weak self] in self?.refresh(after: 0) }
        t.resume()
        timer = t
    }

    /// Reads again after `delay` (coalesced; system_profiler can lag a connection by a second).
    func refresh(after delay: TimeInterval) {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func read() {
        guard running, !reading else { return }
        reading = true
        queue.async { [weak self] in
            let parsed = Self.readProfile()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                guard self.running, let parsed else { return }
                let now = Date()
                self.state = parsed
                self.updated = now
                self.onChange?(parsed, now)
            }
        }
    }

    /// system_profiler runs since launch (debug).
    private(set) static var reads = 0

    /// Runs system_profiler (10 s timeout) and parses its JSON. Any thread.
    static func readProfile(timeout: TimeInterval = 10) -> BluetoothState? {
        reads += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return BluetoothProfile.parse(data)
    }

    // MARK: Connection events

    /// Bluetooth HID devices (mice, keyboards, trackpads) and audio devices (headphones,
    /// speakers) announce themselves to IOKit and CoreAudio; either triggers a read. Nothing is
    /// polled for this.
    private func watchConnections() {
        audioDevices.add(AudioObjectID(kAudioObjectSystemObject), AudioMonitor.address(kAudioHardwarePropertyDevices))
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        notifyPort = port
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator to re-arm the notification.
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<BluetoothMonitor>.fromOpaque(refcon).takeUnretainedValue().refresh(after: 3)
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for transport in ["Bluetooth", "Bluetooth Low Energy"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                let match = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
                match["IOPropertyMatch"] = ["Transport": transport]
                var it: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, type, match, callback, me, &it) == KERN_SUCCESS else { continue }
                while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
                iterators.append(it)
            }
        }
    }
}

/// Connect / Disconnect from the dropdown. IOBluetooth needs Bluetooth permission
/// (NSBluetoothAlwaysUsageDescription); macOS asks the first time someone clicks either button,
/// never earlier. Nothing else in BarTap touches IOBluetooth.
final class BluetoothControl: NSObject {
    static let shared = BluetoothControl()
    private var completions: [String: (Bool) -> Void] = [:]

    enum Access { case allowed, notAsked, denied }

    /// Reading the authorization status does not prompt.
    static var access: Access {
        switch CBManager.authorization {
        case .allowedAlways: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Opens or closes the classic connection to a paired device (main thread).
    func setConnected(_ on: Bool, address: String, completion: @escaping (Bool) -> Void) {
        guard Self.access != .denied, let device = IOBluetoothDevice(addressString: address) else { completion(false); return }
        if on {
            completions[address.uppercased()] = completion
            if device.openConnection(self) != kIOReturnSuccess {
                completions[address.uppercased()] = nil
                completion(false)
            }
        } else {
            completion(device.closeConnection() == kIOReturnSuccess)
        }
    }

    /// IOBluetooth's asynchronous openConnection(_:) reply.
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let address = device?.addressString?.replacingOccurrences(of: "-", with: ":").uppercased(),
              let done = completions.removeValue(forKey: address) else { return }
        done(status == kIOReturnSuccess)
    }
}
