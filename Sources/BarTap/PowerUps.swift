import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import BarTapCore

/// Keep the Mac (and optionally the display) awake via a power assertion — the same mechanism
/// `caffeinate` uses. Releasing the assertion is the only cleanup; it also dies with the process.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var until: Date?
    var onChange: (() -> Void)?

    var isActive: Bool { assertion != 0 }

    func start(minutes: Int?, allowDisplaySleep: Bool) {
        stop(notify: false)
        let type = allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "BarTap Keep Awake" as CFString, &id) == kIOReturnSuccess
        guard ok else { onChange?(); return }
        assertion = id
        if let minutes {
            until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            let t = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in self?.stop() }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            until = .distantFuture
        }
        onChange?()
    }

    func stop(notify: Bool = true) {
        timer?.invalidate()
        timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        until = nil
        if notify { onChange?() }
    }

    var statusText: String {
        guard isActive, let until else { return L("Off") }
        if until == .distantFuture { return L("On, indefinitely") }
        let f = DateFormatter()
        f.timeStyle = .short
        return L("On until %@", f.string(from: until))
    }
}

/// System colour sampler (the magnifier loupe); copies the picked colour to the clipboard.
enum ColorPicker {
    static func pick(format: String) {
        NSColorSampler().show { color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
            let text: String
            switch format {
            case "rgb": text = "rgb(\(r), \(g), \(b))"
            case "swiftui": text = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.redComponent, c.greenComponent, c.blueComponent)
            default: text = String(format: "#%02X%02X%02X", r, g, b)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show(L("Copied %@", text), symbol: "eyedropper")
        }
    }
}

/// Menu bar icon spacing (the `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` host
/// defaults that macOS reads when menu bar items are laid out).
enum Spacing {
    private static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]

    static func apply(_ preset: SpacingPreset) {
        let values: [Int]? = preset.values.map { [$0.spacing, $0.padding] }
        for (i, key) in keys.enumerated() {
            CFPreferencesSetValue(key as CFString, values.map { $0[i] as CFNumber }, kCFPreferencesAnyApplication,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    static func current() -> (spacing: Int?, padding: Int?) {
        func read(_ k: String) -> Int? {
            CFPreferencesCopyValue(k as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
        }
        return (read(keys[0]), read(keys[1]))
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}

/// Other menu bar managers fight over the same icons; running two at once causes exactly the
/// flicker we exist to avoid.
enum Conflicts {
    static let knownManagers: [(bundleID: String, name: String)] = [
        ("com.surteesstudios.Bartender", "Bartender"),
        ("com.jordanbaird.Ice", "Ice"),
        ("com.stonerl.Thaw", "Thaw"),
        ("com.dwarvesv.minimalbar", "Hidden Bar"),
        ("com.mortennn.Dozer", "Dozer"),
        ("net.matthewpalmer.Vanilla", "Vanilla"),
        ("com.HiddenBar.app", "Hidden Bar"),
        ("app.barbee.Barbee", "Barbee"),
    ]

    static func running() -> [NSRunningApplication] {
        knownManagers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID) }
    }
}

enum ProcessStats {
    /// Physical footprint in MB (what Activity Monitor shows as "Memory").
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Total CPU seconds used since launch.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
