import AppKit
import BarTapCore

/// Names shown in Settings › Stats.
enum StatsNames {
    static func module(_ m: StatsModule) -> String {
        switch m {
        case .cpu: return L("CPU")
        case .gpu: return "GPU"
        case .memory: return L("Memory")
        case .disk: return L("Disk")
        case .network: return L("Network")
        case .sensors: return L("Sensors")
        case .battery: return L("Battery")
        case .power: return L("Power")
        case .time: return L("Time")
        case .ai: return L("AI usage")
        case .volume: return L("Volume")
        case .bluetooth: return L("Bluetooth")
        case .trio: return L("3-in-1 status")
        }
    }

    /// Full name, for the editor's lists.
    static func element(_ e: StatsElement, _ m: StatsModule) -> String {
        switch e {
        case .label: return L("Label")
        case .graph: return m == .network ? L("Upload / download graph") : m == .disk ? L("Read / write graph") : L("History graph")
        case .bar: return L("Bar")
        case .pie: return L("Pie")
        case .ring: return L("Ring")
        case .percent: return m == .trio ? L("Battery percentage") : L("Percentage")
        case .cores: return L("Per-core bars")
        case .usedFree: return L("Used / free (U: F:)")
        case .used: return L("Used amount")
        case .free: return L("Free amount")
        case .readWrite: return L("Read / write speed (R: W:)")
        case .rates: return L("Upload / download speed (↑ ↓)")
        case .temperature: return L("CPU temperature")
        case .fan: return L("Fan speed")
        case .tempFan: return L("Temperature + fan")
        case .power: return L("Power (W)")
        case .battery: return L("Battery icon")
        case .timeLeft: return L("Time remaining")
        case .clock: return L("Clock")
        case .aiTokens: return L("Tokens")
        case .aiCost: return L("Cost at API prices")
        case .aiTokensCost: return L("Tokens / cost (two lines)")
        case .aiPlan: return L("Plan usage ring")
        case .aiPlanPercent: return L("Plan usage %")
        case .aiPlanTwo: return L("Plan windows (5h / 7d)")
        case .aiCredits: return L("Usage credits (ring + amount)")
        case .batteryPower: return L("Charge / discharge rate (±W)")
        case .speaker: return L("Speaker icon (shows the level)")
        case .levelMeter: return L("Level meter")
        case .bluetoothIcon: return L("Bluetooth icon + connected count")
        case .lowestBattery: return L("Lowest battery of connected devices")
        case .airPods: return L("AirPods left / right (two lines)")
        case .trio: return L("Battery, Wi-Fi and volume in one icon")
        case .powerIcon: return L("Power icon (filled on the adapter)")
        case .powerIn: return L("Adapter input (IN, W)")
        case .powerBattery: return L("Into / out of the battery (BAT, ±W)")
        case .powerSystem: return L("Whole Mac (SYS, W)")
        case .powerTwo: return L("Input / whole Mac (two lines)")
        case .powerCPU: return L("CPU power (W)")
        case .powerGPU: return L("GPU power (W)")
        case .powerMemory: return L("Memory power (W)")
        case .powerDisplay: return L("Display backlight (W)")
        case .powerANE: return L("Neural Engine power (W)")
        case .batteryVolts: return L("Battery voltage (V)")
        case .batteryAmps: return L("Battery current (±A)")
        case .adapterRated: return L("Adapter rating (W)")
        case .cycleCount: return L("Battery cycle count")
        }
    }

    /// Short name, for preset titles such as "Pie + U/F".
    static func short(_ e: StatsElement) -> String {
        switch e {
        case .label: return L("Label")
        case .graph: return L("Graph")
        case .bar: return L("Bar")
        case .pie: return L("Pie")
        case .ring: return L("Ring")
        case .percent: return "%"
        case .cores: return L("Cores")
        case .usedFree: return "U/F"
        case .used: return L("Used")
        case .free: return L("Free")
        case .readWrite: return "R/W"
        case .rates: return "↑↓"
        case .temperature: return L("Temp")
        case .fan: return L("Fan")
        case .tempFan: return L("Temp/Fan")
        case .power: return "W"
        case .battery: return L("Icon")
        case .timeLeft: return L("Time left")
        case .clock: return L("Clock")
        case .aiTokens: return L("Tokens")
        case .aiCost: return "$"
        case .aiTokensCost: return L("Tokens/$")
        case .aiPlan: return L("Plan ring")
        case .aiPlanPercent: return L("Plan %")
        case .aiPlanTwo: return "5h/7d"
        case .aiCredits: return L("Credits")
        case .batteryPower: return "±W"
        case .speaker, .bluetoothIcon, .trio: return L("Icon")
        case .levelMeter: return L("Meter")
        case .lowestBattery: return L("Lowest")
        case .airPods: return "L/R"
        case .powerIcon: return L("Icon")
        case .powerIn: return L("IN")
        case .powerBattery: return L("BAT")
        case .powerSystem: return L("SYS")
        case .powerTwo: return L("IN/SYS")
        case .powerCPU: return "CPU"
        case .powerGPU: return "GPU"
        case .powerMemory: return L("MEM")
        case .powerDisplay: return L("DISP")
        case .powerANE: return "ANE"
        case .batteryVolts: return "V"
        case .batteryAmps: return "A"
        case .adapterRated: return L("ADP")
        case .cycleCount: return L("CYC")
        }
    }

    static func title(_ elements: [StatsElement]) -> String { elements.map(short).joined(separator: " + ") }
}

/// Settings › Stats module list: enable a module, pick a layout, see it, and order the items.
/// Top to bottom here is left to right inside the combined item; separate items are arranged in
/// Settings › Layout.
final class StatsModulesView: NSStackView {
    private let settings: Settings
    private let liveSnapshot: () -> StatsSnapshot?
    private let openEditor: (StatsModule) -> Void
    private var targets: [ClosureTarget] = []
    private var observer: NSObjectProtocol?
    private var rebuildQueued = false

    init(settings: Settings, liveSnapshot: @escaping () -> StatsSnapshot?, openEditor: @escaping (StatsModule) -> Void) {
        self.settings = settings
        self.liveSnapshot = liveSnapshot
        self.openEditor = openEditor
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        observer = NotificationCenter.default.addObserver(forName: .barTapSettingsChanged, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?["key"] as? String) == "stats" else { return }
            self?.queueRebuild()
        }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Controls are replaced after their own action finishes, never during it.
    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildQueued = false
            self?.rebuild()
        }
    }

    static func options(_ s: Settings) -> StatsRenderer.Options {
        StatsRenderer.Options(fahrenheit: s.statsFahrenheit, bits: s.statsNetworkBits, clockFormat: s.clockFormat)
    }

    /// Live values for a running module, sample values otherwise (a disabled module isn't sampled).
    static func snapshot(for m: StatsModule, settings: Settings, live: StatsSnapshot?) -> StatsSnapshot {
        if settings.statsModules.contains(m), let live { return live }
        return PromoAssets.sampleSnapshot(step: 3)
    }

    func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll()
        let enabled = settings.statsModules
        let live = liveSnapshot()
        for m in enabled + StatsModule.allCases.filter({ !enabled.contains($0) }) {
            addArrangedSubview(row(m, index: enabled.firstIndex(of: m), count: enabled.count, live: live))
        }
    }

    private func target(_ h: @escaping (Any?) -> Void) -> ClosureTarget {
        let t = ClosureTarget(h)
        targets.append(t)
        return t
    }

    private func row(_ m: StatsModule, index: Int?, count: Int, live: StatsSnapshot?) -> NSView {
        let s = settings
        let on = index != nil
        let check = NSButton(checkboxWithTitle: StatsNames.module(m), target: nil, action: nil)
        check.state = on ? .on : .off
        check.target = target { _ in
            var list = s.statsModules
            if check.state == .on { if !list.contains(m) { list.append(m) } } else { list.removeAll { $0 == m } }
            s.statsModules = list
        }
        check.action = #selector(ClosureTarget.fire(_:))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.widthAnchor.constraint(equalToConstant: 104).isActive = true

        let current = s.statsElements(m)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for p in m.presets { popup.addItem(withTitle: StatsNames.title(p)) }
        let presetIndex = m.presets.firstIndex(of: current)
        if presetIndex == nil { popup.addItem(withTitle: L("Custom: %@", StatsNames.title(current))) }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: L("Customize…"))
        let customizeIndex = popup.numberOfItems - 1
        let currentIndex = presetIndex ?? m.presets.count
        popup.selectItem(at: currentIndex)
        popup.target = target { [weak self] _ in
            let i = popup.indexOfSelectedItem
            if i == customizeIndex {
                popup.selectItem(at: currentIndex)
                self?.openEditor(m)
            } else if i >= 0 && i < m.presets.count {
                s.setStatsElements(m, m.presets[i])
            }
        }
        popup.action = #selector(ClosureTarget.fire(_:))
        popup.isEnabled = on
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 186).isActive = true

        func move(_ delta: Int, symbol: String, tip: String) -> NSButton {
            let b = NSButton(image: Icons.symbol(symbol, config: .init(pointSize: 11, weight: .semibold)), target: nil, action: nil)
            b.bezelStyle = .inline
            b.isBordered = false
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.target = target { _ in
                guard let i = index else { return }
                var list = s.statsModules
                let j = i + delta
                guard list.indices.contains(i), list.indices.contains(j) else { return }
                list.swapAt(i, j)
                s.statsModules = list
            }
            b.action = #selector(ClosureTarget.fire(_:))
            b.isEnabled = on && index.map { $0 + delta >= 0 && $0 + delta < count } == true
            return b
        }
        // The order inside the combined item; separate items are arranged in Settings › Layout.
        let left = move(-1, symbol: "chevron.up", tip: L("Move left in the combined item"))
        let right = move(1, symbol: "chevron.down", tip: L("Move right in the combined item"))
        left.isHidden = !s.statsCombined
        right.isHidden = !s.statsCombined

        let preview = NSImageView(image: StatsRenderer.image(m, current, Self.snapshot(for: m, settings: s, live: live), Self.options(s)))
        preview.contentTintColor = on ? .labelColor : .tertiaryLabelColor
        preview.imageScaling = .scaleNone
        preview.setAccessibilityLabel(L("Preview"))

        let row = NSStackView(views: [check, popup, left, right, preview])
        row.spacing = 8
        row.alignment = .centerY
        return row
    }
}

/// Builds one module's menu bar item from elements, like iStat Menus' "items to show in
/// menubar": shown elements left to right, plus the ones still available.
final class StatsElementEditor: NSWindowController {
    private let module: StatsModule
    private let settings: Settings
    private let liveSnapshot: () -> StatsSnapshot?
    private let stack = NSStackView()
    private var targets: [ClosureTarget] = []
    var onClose: (() -> Void)?
    private static let width: CGFloat = 420

    init(module: StatsModule, settings: Settings, liveSnapshot: @escaping () -> StatsSnapshot?) {
        self.module = module
        self.settings = settings
        self.liveSnapshot = liveSnapshot
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = L("%@ menu bar item", StatsNames.module(module))
        super.init(window: panel)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        panel.contentView = stack
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func target(_ h: @escaping (Any?) -> Void) -> ClosureTarget {
        let t = ClosureTarget(h)
        targets.append(t)
        return t
    }

    private func button(_ title: String, symbol: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) -> NSButton {
        let b: NSButton
        if let symbol {
            b = NSButton(image: Icons.symbol(symbol, config: .init(pointSize: 11, weight: .semibold)), target: nil, action: nil)
            b.bezelStyle = .inline
            b.isBordered = false
            b.toolTip = title
            b.setAccessibilityLabel(title)
        } else {
            b = NSButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded
        }
        b.target = target { _ in action() }
        b.action = #selector(ClosureTarget.fire(_:))
        b.isEnabled = enabled
        return b
    }

    private func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func name(_ e: StatsElement) -> NSTextField {
        let l = NSTextField(labelWithString: StatsNames.element(e, module))
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 270).isActive = true
        return l
    }

    private func set(_ list: [StatsElement]) {
        settings.setStatsElements(module, list)
        // After this action returns; the clicked button is part of what gets rebuilt.
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll()
        let current = settings.statsElements(module)

        // Preview at twice the menu bar size, on a menu-bar-like strip.
        let shot = StatsModulesView.snapshot(for: module, settings: settings, live: liveSnapshot())
        let img = StatsRenderer.image(module, current, shot, StatsModulesView.options(settings))
        let preview = NSImageView(image: img)
        preview.contentTintColor = .labelColor
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        let strip = PreviewStrip()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: img.size.width * 2),
            preview.heightAnchor.constraint(equalToConstant: img.size.height * 2),
            preview.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 14),
            preview.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -14),
            preview.topAnchor.constraint(equalTo: strip.topAnchor, constant: 8),
            preview.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -8),
        ])
        stack.addArrangedSubview(strip)

        stack.addArrangedSubview(heading(L("Shown, left to right")))
        for (i, e) in current.enumerated() {
            let up = button(L("Move left"), symbol: "chevron.up", enabled: i > 0) { [weak self] in
                var list = current
                list.swapAt(i, i - 1)
                self?.set(list)
            }
            let down = button(L("Move right"), symbol: "chevron.down", enabled: i < current.count - 1) { [weak self] in
                var list = current
                list.swapAt(i, i + 1)
                self?.set(list)
            }
            let remove = button(L("Remove"), symbol: "minus.circle", enabled: current.count > 1) { [weak self] in
                self?.set(current.filter { $0 != e })
            }
            let row = NSStackView(views: [name(e), up, down, remove])
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        let available = module.elements.filter { !current.contains($0) }
        if !available.isEmpty {
            stack.addArrangedSubview(heading(L("Available")))
            for e in available {
                let add = button(L("Add"), symbol: "plus.circle") { [weak self] in self?.set(current + [e]) }
                let row = NSStackView(views: [name(e), add])
                row.spacing = 8
                stack.addArrangedSubview(row)
            }
        }

        let reset = button(L("Reset to Default")) { [weak self] in
            guard let self else { return }
            self.set(self.module.presets[0])
        }
        let done = button(L("Done")) { [weak self] in self?.close() }
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [reset, done])
        footer.spacing = 10
        stack.addArrangedSubview(footer)
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    override func close() {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) } else { super.close() }
        onClose?()
    }
}

/// A faint rounded strip behind a preview (colors resolve at draw time, so it follows light/dark).
private final class PreviewStrip: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
