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

/// Stay awake with the lid closed (`pmset -a disablesleep 1`; see `LidAwakeScript`). Turning it on
/// asks for an administrator password once; turning it off just leaves a file for the watcher.
final class LidAwake {
    /// On battery at or below this, sleep comes back on its own.
    static let batteryMin = 10
    private static let stopFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BarTap/lid-awake.stop")

    /// `SleepDisabled` as macOS reports it (also when set some other way, e.g. in Terminal).
    private(set) var isOn = false
    var onChange: (() -> Void)?
    /// The watcher started by this BarTap (running as root, so only its existence can be checked).
    private var watcher: pid_t?
    private var poll: Timer?
    private var turningOff = false

    /// Reads the current state; while it's on, keeps an eye on it (the watcher may turn it off).
    func refresh(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let on = Self.readSleepDisabled()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let was = self.isOn
                if let on { self.isOn = on }
                if was && !self.isOn && !self.turningOff {
                    Toast.show(Self.onBatteryAtOrBelowMin() ? L("Battery below %d%%: the Mac sleeps normally again", Self.batteryMin)
                                                            : L("The Mac sleeps normally again"), symbol: "moon")
                }
                if !self.isOn { self.watcher = nil }
                self.watch()
                if was != self.isOn { self.onChange?() }
                completion?()
            }
        }
    }

    func turnOn() {
        guard !isOn else { return }
        try? FileManager.default.createDirectory(at: Self.stopFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.stopFile)
        guard let command = LidAwakeScript.command(watching: getpid(), stopFile: Self.stopFile.path, batteryMin: Self.batteryMin) else {
            Toast.show(L("Couldn't turn it on: %@", L("unusual folder name")), symbol: "exclamationmark.triangle")
            return
        }
        // macOS's own password dialog; it blocks this thread until answered, as any app's would.
        guard let out = Self.runAsAdministrator(command) else { refresh(); return }
        watcher = pid_t(out.trimmingCharacters(in: .whitespacesAndNewlines))
        refresh { [weak self] in
            if self?.isOn == true { Toast.show(L("Lid closed, the Mac stays awake"), symbol: "laptopcomputer") }
        }
    }

    func turnOff() {
        guard isOn else { return }
        turningOff = true
        if let w = watcher, kill(w, 0) == 0 || errno == EPERM {
            // The watcher (ours, running as root) puts sleep back within 2 s: no password.
            FileManager.default.createFile(atPath: Self.stopFile.path, contents: nil)
            confirmOff(tries: 12)
        } else {
            // Turned on some other way (Terminal, or before a restart): needs the password again.
            _ = Self.runAsAdministrator(LidAwakeScript.restoreCommand())
            confirmOff(tries: 4)
        }
    }

    private func confirmOff(tries: Int) {
        refresh { [weak self] in
            guard let self else { return }
            if self.isOn, tries > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.confirmOff(tries: tries - 1) }
                return
            }
            self.turningOff = false
            try? FileManager.default.removeItem(at: Self.stopFile)
            if !self.isOn { Toast.show(L("The Mac sleeps normally again"), symbol: "moon") }
        }
    }

    private func watch() {
        if isOn, poll == nil {
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
            t.tolerance = 3
            RunLoop.main.add(t, forMode: .common)
            poll = t
        } else if !isOn {
            poll?.invalidate()
            poll = nil
        }
    }

    /// Runs `shell` as an administrator; nil if the user cancelled or it failed.
    private static func runAsAdministrator(_ shell: String) -> String? {
        let source = LidAwakeScript.appleScript(running: shell,
                                                prompt: L("BarTap needs an administrator to keep the Mac awake with the lid closed."))
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
            if let code = error?[NSAppleScript.errorNumber] as? Int, code != -128 {   // -128: cancelled
                Toast.show(L("Couldn't turn it on: %@", (error?[NSAppleScript.errorMessage] as? String) ?? "\(code)"),
                           symbol: "exclamationmark.triangle")
            }
            return nil
        }
        return result.stringValue ?? ""
    }

    private static func readSleepDisabled() -> Bool? {
        run("/usr/bin/pmset", ["-g"]).flatMap(LidAwakeScript.sleepDisabled(fromPMSet:))
    }

    private static func onBatteryAtOrBelowMin() -> Bool {
        guard let out = run("/usr/bin/pmset", ["-g", "batt"]), out.contains("Battery Power"),
              let pct = out.split(separator: "\t").dropFirst().first?.split(separator: "%").first.flatMap({ Int($0) }) else { return false }
        return pct <= batteryMin
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
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

/// Freed memory stays with the process until malloc happens to reuse it. After a one-off burst
/// (the Settings window, the first read of the AI history) hand it back, so the footprint returns
/// to its steady size instead of keeping the peak.
enum Memory {
    static func returnFreedPages(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = malloc_zone_pressure_relief(nil, 0) }
    }
}
