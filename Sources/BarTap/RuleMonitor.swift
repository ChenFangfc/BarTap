import AppKit
import IOKit.ps
import Network
import BarTapCore

/// Collects the facts auto-reveal rules depend on. Entirely notification-driven: app activation,
/// Space changes, display changes, IOKit power-source callbacks and NWPathMonitor. Sources are
/// attached only while a rule that needs them is enabled.
final class RuleMonitor {
    var onChange: ((RevealLevel, [RuleReason]) -> Void)?

    private var settings = RuleSettings()
    private(set) var facts = RuleFacts()
    private(set) var lastResult: (level: RevealLevel, reasons: [RuleReason]) = (.collapsed, [])
    private var workspaceTokens: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var pathMonitor: NWPathMonitor?
    private var debounce: DispatchWorkItem?

    func configure(_ s: RuleSettings) {
        settings = s
        let ws = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { ws.removeObserver($0) }
        workspaceTokens.removeAll()
        if s.largeScreen || s.apps {
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
                workspaceTokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleUpdate() })
            }
        }
        if s.lowBattery { attachPower() } else { detachPower() }
        if s.offline { attachNetwork() } else { detachNetwork() }
        update()
    }

    func screensChanged() { scheduleUpdate() }

    private func scheduleUpdate() {
        // Activation and Space notifications arrive in bursts; one evaluation is enough.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func update() {
        if settings.largeScreen { facts.activeScreenWidth = activeScreenWidth() }
        if settings.apps { facts.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        if settings.lowBattery { readPower() }
        let result = RuleEngine.evaluate(facts, settings)
        let changed = result.level != lastResult.level || result.reasons != lastResult.reasons
        lastResult = result
        if changed { onChange?(result.level, result.reasons) }
    }

    /// The display the user is working on: where the frontmost app's frontmost window is,
    /// falling back to the pointer's display.
    private func activeScreenWidth() -> CGFloat? {
        let screens = SystemQueries.screens()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let windows = SystemQueries.windows(onScreenOnly: true)
            if let w = windows.first(where: { $0.pid == pid && $0.layer == 0 && $0.bounds.width > 100 && $0.bounds.height > 100 }) {
                let center = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
                if let s = screens.first(where: { $0.frame.contains(center) }) { return s.frame.width }
            }
        }
        return SystemQueries.screen(containingCG: SystemQueries.pointerCG, in: screens)?.frame.width
    }

    // MARK: Power

    private func attachPower() {
        guard powerSource == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<RuleMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.update() }
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        powerSource = src
    }

    private func detachPower() {
        if let src = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        powerSource = nil
    }

    private func readPower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                facts.batteryPercent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            facts.onBatteryPower = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return
        }
        facts.batteryPercent = nil
        facts.onBatteryPower = false
    }

    // MARK: Network

    private func attachNetwork() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let online = path.status == .satisfied
                if self.facts.networkOnline != online {
                    self.facts.networkOnline = online
                    self.update()
                }
            }
        }
        m.start(queue: DispatchQueue(label: "bartap.path", qos: .utility))
        pathMonitor = m
    }

    private func detachNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
        facts.networkOnline = true
    }
}
