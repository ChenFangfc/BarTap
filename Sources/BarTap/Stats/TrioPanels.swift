import AppKit
import CoreAudio
import BarTapCore

// Dropdowns of the Volume, Bluetooth and 3-in-1 items, and the battery dropdown's power flow.
// Like the other panels they are built when the menu opens and updated in place while it is
// open. Lists (devices) are fixed at open, so the menu never changes size under the pointer.

/// Adapter → Mac ← battery, with watts. Arrows follow the direction power moves.
final class PowerFlowView: NSView {
    var flow: PowerFlow? { didSet { if flow != oldValue { needsDisplay = true } } }
    var batteryPercent: Int? { didSet { if batteryPercent != oldValue { needsDisplay = true } } }
    var charging = false { didSet { if charging != oldValue { needsDisplay = true } } }
    var hasBattery = true

    override var isFlipped: Bool { true }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func batterySymbol() -> String {
        guard let p = batteryPercent else { return "battery.0" }
        if charging { return "battery.100.bolt" }
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let centers = [w / 6, w / 2, w * 5 / 6]
        let iconY: CGFloat = 4, iconH: CGFloat = 24
        let adapterOn = flow?.adapter != nil
        let direction = flow?.direction ?? .idle
        let nodes: [(String, NSColor, String, String)] = [
            ("powerplug", adapterOn ? .labelColor : .tertiaryLabelColor,
             adapterOn ? PowerFlowMath.plain(flow?.adapter) : "–", adapterOn ? L("Adapter") : L("No adapter")),
            ("laptopcomputer", .labelColor, PowerFlowMath.plain(flow?.system), L("This Mac")),
            (batterySymbol(), hasBattery ? .labelColor : .tertiaryLabelColor,
             flow?.battery.map { direction == .idle ? "0 W" : PowerFlowMath.wattsText($0) } ?? "–", L("Battery")),
        ]
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let caption: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        var iconRects: [NSRect] = []
        for (i, node) in nodes.enumerated() {
            if let img = symbol(node.0, node.1) {
                let s = img.size, scale = min(1, iconH / max(s.height, 1))
                let r = NSRect(x: centers[i] - s.width * scale / 2, y: iconY + (iconH - s.height * scale) / 2, width: s.width * scale, height: s.height * scale)
                img.draw(in: r)
                iconRects.append(r)
            } else {
                iconRects.append(NSRect(x: centers[i] - 10, y: iconY, width: 20, height: iconH))
            }
            for (text, attrs, y) in [(node.2, value, CGFloat(32)), (node.3, caption, CGFloat(49))] {
                let size = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: centers[i] - size.width / 2, y: y), withAttributes: attrs)
            }
        }
        // Adapter → Mac.
        let midY = iconY + iconH / 2
        arrow(from: iconRects[0].maxX + 8, to: iconRects[1].minX - 8, y: midY, active: adapterOn, color: .systemGreen)
        // Battery → Mac (discharging) or Mac → battery (charging).
        switch direction {
        case .discharging: arrow(from: iconRects[2].minX - 8, to: iconRects[1].maxX + 8, y: midY, active: true, color: .systemOrange)
        case .charging: arrow(from: iconRects[1].maxX + 8, to: iconRects[2].minX - 8, y: midY, active: true, color: .systemGreen)
        case .idle: arrow(from: iconRects[1].maxX + 8, to: iconRects[2].minX - 8, y: midY, active: false, color: .systemGreen)
        }
    }

    /// A line from `x0` to `x1` with a head at `x1`; inactive is a faint dashed line without one.
    private func arrow(from x0: CGFloat, to x1: CGFloat, y: CGFloat, active: Bool, color: NSColor) {
        guard abs(x1 - x0) > 12 else { return }
        let dir: CGFloat = x1 > x0 ? 1 : -1
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x0, y: y))
        line.line(to: NSPoint(x: x1 - dir * (active ? 5 : 0), y: y))
        line.lineWidth = active ? 2 : 1.2
        line.lineCapStyle = .round
        if !active {
            line.setLineDash([2, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            line.stroke()
            return
        }
        color.setStroke()
        line.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x1, y: y))
        head.line(to: NSPoint(x: x1 - dir * 7, y: y - 4.5))
        head.line(to: NSPoint(x: x1 - dir * 7, y: y + 4.5))
        head.close()
        color.setFill()
        head.fill()
    }
}

/// Small helpers shared by the panels below.
private extension StatsPanel {
    func fullWidth(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
    }

    func caption(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 10)
        f.textColor = .tertiaryLabelColor
        f.preferredMaxLayoutWidth = Self.width - 28
        return f
    }
}

// MARK: - Volume

final class VolumePanel: StatsPanel {
    private weak var audio: AudioMonitor?
    private var big: NSTextField!
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteButton = NSButton(image: Icons.symbol("speaker.wave.2.fill"), target: nil, action: nil)
    private let inputSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let inputValue = NSTextField(labelWithString: "–")
    private var outputs: [(AudioObjectID, NSButton)] = []
    private var inputs: [(AudioObjectID, NSButton)] = []
    private var targets: [ClosureTarget] = []
    private static let maxDevices = 8

    init(audio: AudioMonitor?, state: AudioState?) {
        self.audio = audio
        super.init()
        big = header(L("Volume"))

        muteButton.bezelStyle = .inline
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.contentTintColor = .labelColor
        muteButton.toolTip = L("Mute")
        muteButton.target = target { [weak self] _ in self?.audio?.toggleMute() }
        muteButton.action = #selector(ClosureTarget.fire(_:))
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        slider.isContinuous = true
        slider.target = target { [weak self] _ in self?.audio?.setVolume(self?.slider.doubleValue ?? 0) }
        slider.action = #selector(ClosureTarget.fire(_:))
        slider.setAccessibilityLabel(L("Output volume"))
        let volumeRow = NSStackView(views: [muteButton, slider])
        volumeRow.spacing = 6
        fullWidth(volumeRow)

        section(L("Output"))
        outputs = radios(state?.outputs ?? [], selected: state?.output?.id, output: true)

        section(L("Input"))
        let inputLabel = NSTextField(labelWithString: L("Input volume"))
        inputLabel.font = .systemFont(ofSize: 12)
        inputLabel.setContentHuggingPriority(.required, for: .horizontal)
        inputSlider.isContinuous = true
        inputSlider.controlSize = .small
        inputSlider.target = target { [weak self] _ in self?.audio?.setInputVolume(self?.inputSlider.doubleValue ?? 0) }
        inputSlider.action = #selector(ClosureTarget.fire(_:))
        inputSlider.setAccessibilityLabel(L("Input volume"))
        inputValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        inputValue.alignment = .right
        inputValue.translatesAutoresizingMaskIntoConstraints = false
        inputValue.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let inputRow = NSStackView(views: [inputLabel, inputSlider, inputValue])
        inputRow.spacing = 8
        fullWidth(inputRow)
        inputs = radios(state?.inputs ?? [], selected: state?.input?.id, output: false)
        finishLayout()
        var s = StatsSnapshot()
        s.audio = state
        update(s, StatsRenderer.Options())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func target(_ h: @escaping (Any?) -> Void) -> ClosureTarget {
        let t = ClosureTarget(h)
        targets.append(t)
        return t
    }

    /// One radio button per device. Each list has its own container: AppKit groups radio
    /// buttons that share a superview and an action.
    private func radios(_ devices: [AudioDevice], selected: AudioObjectID?, output: Bool) -> [(AudioObjectID, NSButton)] {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 3
        var out: [(AudioObjectID, NSButton)] = []
        for d in devices.prefix(Self.maxDevices) {
            let b = NSButton(radioButtonWithTitle: d.name.isEmpty ? L("Unnamed device") : d.name, target: nil, action: nil)
            b.target = target { [weak self] _ in self?.audio?.setDefault(d.id, output: output) }
            b.action = #selector(ClosureTarget.fire(_:))
            b.state = d.id == selected ? .on : .off
            b.font = .systemFont(ofSize: 12)
            b.lineBreakMode = .byTruncatingTail
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 28).isActive = true
            group.addArrangedSubview(b)
            out.append((d.id, b))
        }
        if devices.isEmpty {
            let none = NSTextField(labelWithString: output ? L("No output devices") : L("No input devices"))
            none.font = .systemFont(ofSize: 12)
            none.textColor = .secondaryLabelColor
            group.addArrangedSubview(none)
        }
        fullWidth(group)
        return out
    }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        guard let a = s.audio else { big.stringValue = "–"; return }
        big.stringValue = a.volume == nil ? "–" : a.muted ? L("Muted") : VolumeMath.percentText(a.level, muted: false)
        slider.isEnabled = a.volume != nil
        // Don't fight the pointer while the slider is being dragged.
        if let v = a.volume, abs(slider.doubleValue - v) > 0.001 { slider.doubleValue = v }
        let waves = VolumeMath.waves(a.level, muted: a.muted)
        let symbol = a.muted || waves == 0 ? "speaker.slash.fill" : "speaker.wave.\(max(1, min(3, waves))).fill"
        muteButton.image = Icons.symbol(symbol, config: .init(pointSize: 14, weight: .regular))
        muteButton.isEnabled = a.canMute
        muteButton.toolTip = a.muted ? L("Unmute") : L("Mute")
        muteButton.setAccessibilityLabel(muteButton.toolTip)
        inputSlider.isEnabled = a.inputVolume != nil
        if let v = a.inputVolume, abs(inputSlider.doubleValue - v) > 0.001 { inputSlider.doubleValue = v }
        inputValue.stringValue = a.inputVolume.map { StatFormat.percent($0) } ?? "–"
        for (id, b) in outputs { b.state = id == a.output?.id ? .on : .off }
        for (id, b) in inputs { b.state = id == a.input?.id ? .on : .off }
    }
}

// MARK: - Bluetooth

final class BluetoothPanel: StatsPanel {
    private var big: NSTextField!
    private var rows: [String: (detail: NSTextField, button: NSButton?)] = [:]
    private var busy: Set<String> = []
    private var connectedNow: [String: Bool] = [:]
    /// A failed connect / disconnect stays in the note until the dropdown closes.
    private var failure: String?
    private let note: NSTextField
    private var targets: [ClosureTarget] = []
    private let access: BluetoothControl.Access
    private var updated: Date?
    /// Connect (true) or disconnect a device; the completion reports success (nil: cancelled).
    var onSetConnected: ((BluetoothDevice, Bool, @escaping (Bool?) -> Void) -> Void)?
    private static let maxDevices = 10

    init(state: BluetoothState?, updated: Date?, access: BluetoothControl.Access) {
        self.access = access
        self.updated = updated
        note = NSTextField(wrappingLabelWithString: "")
        super.init()
        big = header(L("Bluetooth"))
        let devices = Array((state?.devices ?? []).prefix(Self.maxDevices))
        if state == nil {
            stack.addArrangedSubview(caption(L("Reading Bluetooth devices…")))
        } else if state?.powered == false {
            stack.addArrangedSubview(caption(L("Bluetooth is off.")))
        } else {
            let connected = devices.filter(\.connected), paired = devices.filter { !$0.connected }
            if !connected.isEmpty {
                section(L("Connected"))
                for d in connected { addRow(d) }
            }
            if !paired.isEmpty {
                section(L("Paired"))
                for d in paired { addRow(d) }
            }
            if devices.isEmpty { stack.addArrangedSubview(caption(L("No paired devices."))) }
        }
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = Self.width - 28
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? note)
        stack.addArrangedSubview(note)
        var s = StatsSnapshot()
        s.bluetooth = state
        s.bluetoothUpdated = updated
        update(s, StatsRenderer.Options())
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func symbol(_ k: BluetoothDevice.Kind) -> String {
        switch k {
        case .earbuds: return "airpods"
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gamepad: return "gamecontroller"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .watch: return "applewatch"
        case .computer: return "desktopcomputer"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// "L 80% · R 75% · Case 60%", or "85%".
    static func batteryText(_ d: BluetoothDevice) -> String {
        var parts: [String] = []
        if let l = d.left { parts.append(L("L %d%%", l)) }
        if let r = d.right { parts.append(L("R %d%%", r)) }
        if let c = d.caseBattery { parts.append(L("Case %d%%", c)) }
        if parts.isEmpty, let b = d.battery { parts.append("\(b)%") }
        return parts.joined(separator: " · ")
    }

    private func addRow(_ d: BluetoothDevice) {
        let icon = NSImageView(image: Icons.symbol(Self.symbol(d.kind), config: .init(pointSize: 13, weight: .regular)))
        icon.contentTintColor = d.connected ? .labelColor : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let name = NSTextField(labelWithString: d.name)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The battery line exists only for devices that reported one at open (fixed size).
        let detail = NSTextField(labelWithString: Self.batteryText(d))
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = detail.stringValue.isEmpty
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        var views: [NSView] = [icon, text, NSView()]
        var button: NSButton?
        // Low Energy-only devices (many mice, keyboards) have no classic connection to toggle, and
        // a link to a phone, tablet, watch or computer does nothing useful from here.
        let togglable = !d.lowEnergyOnly && ![.phone, .tablet, .watch, .computer].contains(d.kind)
        if togglable && access != .denied {
            let b = NSButton(title: d.connected ? L("Disconnect") : L("Connect"), target: nil, action: nil)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            let t = ClosureTarget { [weak self] _ in self?.toggle(d) }
            targets.append(t)
            b.target = t
            b.action = #selector(ClosureTarget.fire(_:))
            views.append(b)
            button = b
        }
        let row = NSStackView(views: views)
        row.spacing = 6
        row.alignment = .centerY
        fullWidth(row)
        rows[d.address] = (detail, button)
        connectedNow[d.address] = d.connected
    }

    private func toggle(_ d: BluetoothDevice) {
        guard let row = rows[d.address], !busy.contains(d.address) else { return }
        busy.insert(d.address)
        let connect = !(connectedNow[d.address] ?? d.connected)
        row.button?.title = connect ? L("Connecting…") : L("Disconnecting…")
        row.button?.isEnabled = false
        onSetConnected?(d, connect) { [weak self] ok in
            guard let self else { return }
            self.busy.remove(d.address)
            row.button?.isEnabled = true
            guard let ok else {
                row.button?.title = connect ? L("Connect") : L("Disconnect")
                return
            }
            if ok {
                // The next read (a couple of seconds later) confirms it.
                self.connectedNow[d.address] = connect
                row.button?.title = connect ? L("Disconnect") : L("Connect")
            } else {
                row.button?.title = connect ? L("Connect") : L("Disconnect")
                self.failure = connect ? L("Couldn't connect %@.", d.name) : L("Couldn't disconnect %@.", d.name)
                self.note.stringValue = self.failure ?? ""
            }
        }
    }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        guard let state = s.bluetooth else { big.stringValue = "–"; return }
        updated = s.bluetoothUpdated
        big.stringValue = state.powered ? L("%d connected", state.connected.count) : L("Off")
        for d in state.devices {
            guard let row = rows[d.address] else { continue }
            connectedNow[d.address] = d.connected
            let battery = Self.batteryText(d)
            if !row.detail.isHidden, row.detail.stringValue != battery { row.detail.stringValue = battery.isEmpty ? "–" : battery }
            if let b = row.button, !busy.contains(d.address) {
                let title = d.connected ? L("Disconnect") : L("Connect")
                if b.title != title { b.title = title }
            }
        }
        var lines: [String] = []
        switch access {
        case .notAsked: lines.append(L("Connect and Disconnect ask for Bluetooth access the first time."))
        case .denied: lines.append(L("To connect and disconnect from here, allow BarTap in System Settings › Privacy & Security › Bluetooth."))
        case .allowed: break
        }
        if let u = updated {
            let age = Int(Date().timeIntervalSince(u))
            if age >= 10 { lines.append(L("Battery levels as of %d s ago.", age)) }
        }
        let text = (failure.map { [$0] } ?? lines).joined(separator: "\n")
        if note.stringValue != text { note.stringValue = text }
    }
}

// MARK: - 3-in-1

final class TrioPanel: StatsPanel {
    private let glyph = NSImageView()

    override init() {
        super.init()
        let title = NSTextField(labelWithString: L("Battery · Wi-Fi · Volume"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .labelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: TrioGlyphs.trioWidth * 1.6).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: StatsRenderer.height * 1.6).isActive = true
        let h = NSStackView(views: [title, NSView(), glyph])
        h.alignment = .centerY
        fullWidth(h)
        section(L("Battery"))
        row(L("Level"), key: "level")
        row(L("Time remaining"), key: "time")
        row(L("Power"), key: "power")
        section(L("Wi-Fi"))
        row(L("Network"), key: "ssid")
        row(L("Signal"), key: "signal")
        section(L("Volume"))
        row(L("Output"), key: "output")
        row(L("Volume"), key: "volume")
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func signalWord(_ bars: Int) -> String {
        switch bars {
        case 3: return L("Strong")
        case 2: return L("Good")
        case 1: return L("Weak")
        default: return L("None")
        }
    }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        glyph.image = StatsRenderer.image(.trio, [.trio], s, o)
        if let b = s.battery {
            let state = b.charged ? L("Charged") : b.charging ? L("Charging") : b.onAC ? L("Not charging") : L("On battery")
            set("level", "\(b.percent)% · \(state)")
            set("time", b.minutesRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "–")
            set("power", s.power?.battery.map { PowerFlowMath.wattsText($0) } ?? "–")
        } else {
            set("level", L("No battery"))
        }
        if let w = s.wifi {
            // macOS only reveals the network name to apps with Location access; BarTap never asks.
            set("ssid", w.rssi == nil ? (w.powered ? L("Not connected") : L("Off")) : (w.ssid ?? L("Connected")))
            set("signal", w.rssi.map { "\($0) dBm · " + Self.signalWord(w.bars) } ?? "–")
        }
        if let a = s.audio {
            set("output", a.output?.name ?? "–")
            set("volume", a.volume == nil ? "–" : a.muted ? L("Muted") : VolumeMath.percentText(a.level, muted: false))
        }
    }
}
