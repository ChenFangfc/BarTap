import AppKit
import BarTapCore

/// Minimal declarative helpers for the settings panes (plain AppKit, no SwiftUI runtime).
final class ClosureTarget: NSObject {
    let handler: (Any?) -> Void
    init(_ handler: @escaping (Any?) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

final class Form {
    let stack = NSStackView()
    private var targets: [ClosureTarget] = []
    /// Refreshers run when the pane appears so controls reflect external changes.
    private var refreshers: [() -> Void] = []
    private var appearHandlers: [() -> Void] = []
    private var disappearHandlers: [() -> Void] = []
    /// Helper objects that live as long as the pane.
    private var kept: [AnyObject] = []

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
    }

    func refresh() { refreshers.forEach { $0() } }
    /// For views built outside these helpers.
    func onRefresh(_ h: @escaping () -> Void) { refreshers.append(h) }

    func onAppear(_ h: @escaping () -> Void) { appearHandlers.append(h) }
    func onDisappear(_ h: @escaping () -> Void) { disappearHandlers.append(h) }
    func keep(_ object: AnyObject) { kept.append(object) }
    func appeared() { appearHandlers.forEach { $0() } }
    func disappeared() { disappearHandlers.forEach { $0() } }

    private func target(_ h: @escaping (Any?) -> Void) -> ClosureTarget {
        let t = ClosureTarget(h)
        targets.append(t)
        return t
    }

    func section(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
            stack.addArrangedSubview(spacer)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)
    }

    @discardableResult
    func toggle(_ title: String, help: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        let t = target { sender in set((sender as? NSButton)?.state == .on) }
        b.target = t
        b.action = #selector(ClosureTarget.fire(_:))
        refreshers.append { b.state = get() ? .on : .off }
        b.state = get() ? .on : .off
        add(b, help: help)
        return b
    }

    @discardableResult
    func popup(_ title: String, options: [(value: String, label: String)], help: String? = nil,
               get: @escaping () -> String, set: @escaping (String) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for o in options { p.addItem(withTitle: o.label) }
        let t = target { sender in
            guard let p = sender as? NSPopUpButton, p.indexOfSelectedItem >= 0 else { return }
            set(options[p.indexOfSelectedItem].value)
        }
        p.target = t
        p.action = #selector(ClosureTarget.fire(_:))
        let sync = { p.selectItem(at: options.firstIndex { $0.value == get() } ?? 0) }
        refreshers.append(sync)
        sync()
        row(title, p, help: help)
        return p
    }

    @discardableResult
    func slider(_ title: String, min: Double, max: Double, step: Double? = nil, help: String? = nil,
                format: @escaping (Double) -> String, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> NSSlider {
        let s = NSSlider(value: get(), minValue: min, maxValue: max, target: nil, action: nil)
        s.isContinuous = true
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let value = NSTextField(labelWithString: format(get()))
        value.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let t = target { sender in
            guard let s = sender as? NSSlider else { return }
            var v = s.doubleValue
            if let step { v = (v / step).rounded() * step }
            value.stringValue = format(v)
            set(v)
        }
        s.target = t
        s.action = #selector(ClosureTarget.fire(_:))
        refreshers.append { s.doubleValue = get(); value.stringValue = format(get()) }
        let h = NSStackView(views: [s, value])
        h.spacing = 8
        row(title, h, help: help)
        return s
    }

    @discardableResult
    func button(_ title: String, help: String? = nil, action: @escaping () -> Void) -> NSButton {
        let t = target { _ in action() }
        let b = NSButton(title: title, target: t, action: #selector(ClosureTarget.fire(_:)))
        b.bezelStyle = .rounded
        add(b, help: help)
        return b
    }

    func buttons(_ list: [(String, () -> Void)]) {
        let views: [NSView] = list.map { title, action in
            let t = target { _ in action() }
            let b = NSButton(title: title, target: t, action: #selector(ClosureTarget.fire(_:)))
            b.bezelStyle = .rounded
            return b
        }
        let h = NSStackView(views: views)
        h.spacing = 8
        stack.addArrangedSubview(h)
    }

    @discardableResult
    func note(_ text: String, color: NSColor = .secondaryLabelColor, refresh: (() -> String)? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = color
        l.font = .systemFont(ofSize: 11)
        l.preferredMaxLayoutWidth = 520
        if let refresh { refreshers.append { l.stringValue = refresh() } }
        stack.addArrangedSubview(l)
        return l
    }

    func custom(_ title: String?, _ view: NSView, help: String? = nil) {
        if let title { row(title, view, help: help) } else { add(view, help: help) }
    }

    private func row(_ title: String, _ control: NSView, help: String?) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 215).isActive = true
        let h = NSStackView(views: [label, control])
        h.spacing = 10
        h.alignment = .centerY
        add(h, help: help)
    }

    private func add(_ view: NSView, help: String?) {
        stack.addArrangedSubview(view)
        if let help {
            let l = NSTextField(wrappingLabelWithString: help)
            l.textColor = .secondaryLabelColor
            l.font = .systemFont(ofSize: 11)
            l.preferredMaxLayoutWidth = 500
            let indent = NSStackView(views: [l])
            indent.edgeInsets = NSEdgeInsets(top: -6, left: 20, bottom: 0, right: 0)
            stack.addArrangedSubview(indent)
        }
    }

    /// Wraps the form in a scroll view sized for the settings window.
    func makeView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 520)
        return scroll
    }
}

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Click, then type a shortcut. ⎋ cancels, ⌫ clears.
final class ShortcutRecorder: NSButton {
    var combo: KeyCombo? { didSet { updateTitle() } }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?
    private var recording = false { didSet { updateTitle(); onRecordingChange?(recording) } }

    init(combo: KeyCombo?) {
        self.combo = combo
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        if recording { title = L("Type shortcut…"); return }
        title = combo.map(HotkeyCenter.display) ?? L("Record Shortcut")
    }

    @objc private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self, self.recording else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 0x35 && mods.isEmpty { self.stop(); return nil }
            if (e.keyCode == 0x33 || e.keyCode == 0x75) && mods.isEmpty {
                self.combo = nil
                self.onChange?(nil)
                self.stop()
                return nil
            }
            var carbon: UInt32 = 0
            if mods.contains(.command) { carbon |= KeyCombo.cmd }
            if mods.contains(.option) { carbon |= KeyCombo.option }
            if mods.contains(.control) { carbon |= KeyCombo.control }
            if mods.contains(.shift) { carbon |= KeyCombo.shift }
            let c = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: carbon)
            if c.isValid {
                self.combo = c
                self.onChange?(c)
                self.stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}
