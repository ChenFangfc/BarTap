import AppKit
import BarTapCore

// The window that shows a stats item's details instead of a menu: the same panels, on menu
// material with rounded corners and a shadow, opened on hover or click (HoverClickPresenter).
// It never activates BarTap, so the frontmost app keeps focus; its controls still work.

/// One action in the details' bottom row.
struct DetailAction {
    var title: String
    /// An icon-only button (the title becomes its tooltip and accessibility label).
    var symbol: String?
    var help: String?
    var enabled = true
    var handler: () -> Void
}

/// What a details panel's actions do (the menu's footer items of BarTap 1.3).
enum DetailCommand: Equatable {
    case eject(Int), diskUtility, activityMonitor, soundSettings, bluetoothSettings, wifiSettings, batterySettings, toggleMute, statsSettings
}

enum DetailActions {
    /// A module's actions, settings last. `volumes`: ejectable volumes by name (disk).
    static func list(for module: StatsModule, muted: Bool, canMute: Bool, volumes: [String], run: @escaping (DetailCommand) -> Void) -> [DetailAction] {
        var out: [DetailAction] = []
        func add(_ title: String, help: String? = nil, enabled: Bool = true, _ c: DetailCommand) {
            out.append(DetailAction(title: title, help: help, enabled: enabled) { run(c) })
        }
        switch module {
        case .disk:
            for (i, name) in volumes.enumerated() { add(L("Eject %@", name), .eject(i)) }
            add(L("Disk Utility"), .diskUtility)
            add(L("Activity Monitor"), .activityMonitor)
        case .volume:
            add(L("Sound Settings…"), .soundSettings)
        case .bluetooth:
            add(L("Bluetooth Settings…"), .bluetoothSettings)
        case .trio:
            // Quick actions.
            add(muted ? L("Unmute") : L("Mute"), enabled: canMute, .toggleMute)
            add(L("Wi-Fi…"), help: L("Wi-Fi Settings…"), .wifiSettings)
            add(L("Sound…"), help: L("Sound Settings…"), .soundSettings)
            add(L("Battery…"), help: L("Battery Settings…"), .batterySettings)
        case .battery:
            add(L("Activity Monitor"), .activityMonitor)
            add(L("Battery Settings…"), .batterySettings)
        default:
            add(L("Activity Monitor"), .activityMonitor)
        }
        out.append(DetailAction(title: L("Stats Settings…"), symbol: "gearshape") { run(.statsSettings) })
        return out
    }
}

/// A compact pill button for the actions row: readable in a window that is never active (the
/// system's inline style dims its title there), slightly stronger under the pointer.
final class PillButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    convenience init(title: String, symbol: String?) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = Icons.symbol(symbol, config: .init(pointSize: 12, weight: .regular)) }
        isBordered = false
        setButtonType(.momentaryChange)
        let text = symbol == nil ? ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) : 14
        setFrameSize(NSSize(width: text + (symbol == nil ? 18 : 10), height: 22))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        let alpha: CGFloat = !isEnabled ? 0.04 : pressed ? 0.2 : hovering ? 0.14 : 0.08
        // withAlphaComponent replaces a system color's alpha, so this is labelColor at `alpha`.
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let color: NSColor = isEnabled ? .labelColor : .tertiaryLabelColor
        if let image {
            let tinted = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height))
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

/// The bottom row: compact buttons, wrapping onto a second line if they don't fit, the settings
/// gear last.
final class DetailFooter: NSView {
    private(set) var buttons: [NSButton] = []
    private var targets: [ClosureTarget] = []
    private var height: CGFloat = 0
    private static let inset = NSEdgeInsets(top: 9, left: 12, bottom: 10, right: 12)
    private static let spacing: CGFloat = 6

    init(actions: [DetailAction]) {
        super.init(frame: NSRect(x: 0, y: 0, width: StatsPanel.width, height: 30))
        for a in actions {
            let b = PillButton(title: a.title, symbol: a.symbol)
            b.toolTip = a.symbol != nil ? (a.help ?? a.title) : a.help
            b.setAccessibilityLabel(a.title)
            b.isEnabled = a.enabled
            let t = ClosureTarget { _ in a.handler() }
            targets.append(t)
            b.target = t
            b.action = #selector(ClosureTarget.fire(_:))
            addSubview(b)
            buttons.append(b)
        }
        layoutButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A hairline between the details and the actions, like a menu separator.
        NSColor.separatorColor.setFill()
        NSRect(x: 10, y: 0, width: bounds.width - 20, height: 1).fill()
    }

    private func layoutButtons() {
        let inset = Self.inset
        let available = StatsPanel.width - inset.left - inset.right
        let widths = buttons.map { ceil($0.frame.width) }
        let rowHeight = buttons.map(\.frame.height).max() ?? 20
        var y = inset.top
        for (r, range) in DetailPlacement.rows(widths, width: available, spacing: Self.spacing).enumerated() {
            if r > 0 { y += rowHeight + 5 }
            var x = inset.left
            for i in range {
                buttons[i].setFrameOrigin(NSPoint(x: x, y: y))
                x += widths[i] + Self.spacing
            }
            // The last button of the last row (the settings gear) sits at the right end.
            if range.upperBound == buttons.count, let last = buttons.last {
                last.setFrameOrigin(NSPoint(x: StatsPanel.width - inset.right - widths[buttons.count - 1], y: y))
            }
        }
        height = buttons.isEmpty ? 1 : y + rowHeight + inset.bottom
        setFrameSize(NSSize(width: StatsPanel.width, height: height))
    }

    override var intrinsicContentSize: NSSize { NSSize(width: StatsPanel.width, height: height) }
}

/// Tabs for the combined item: one per module, an icon each.
final class DetailTabs: NSView {
    let control: NSSegmentedControl
    static let height: CGFloat = 38

    init(modules: [StatsModule], selected: StatsModule, onSelect: @escaping (StatsModule) -> Void) {
        let images = modules.map(DetailTabs.icon)
        control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: StatsPanel.width, height: Self.height))
        for (i, m) in modules.enumerated() { control.setToolTip(StatsNames.module(m), forSegment: i) }
        control.segmentDistribution = .fillEqually
        control.selectedSegment = modules.firstIndex(of: selected) ?? 0
        control.frame = NSRect(x: 12, y: 10, width: StatsPanel.width - 24, height: 24)
        control.setAccessibilityLabel(L("Stats"))
        let t = ClosureTarget { [weak control] _ in
            guard let c = control, c.selectedSegment >= 0, c.selectedSegment < modules.count else { return }
            onSelect(modules[c.selectedSegment])
        }
        target = t
        control.target = t
        control.action = #selector(ClosureTarget.fire(_:))
        addSubview(control)
    }

    private var target: ClosureTarget?

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A template icon per module (the Bluetooth rune and the 3-in-1 glyph are BarTap's own).
    static func icon(_ m: StatsModule) -> NSImage {
        let symbol: String
        switch m {
        case .cpu: symbol = "cpu"
        case .gpu: symbol = "display"
        case .memory: symbol = "memorychip"
        case .disk: symbol = "internaldrive"
        case .network: symbol = "network"
        case .sensors: symbol = "thermometer.medium"
        case .battery: symbol = "battery.75"
        case .time: symbol = "clock"
        case .ai: symbol = "sparkles"
        case .volume: symbol = "speaker.wave.2"
        case .bluetooth, .trio:
            let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { r in
                NSColor.black.set()
                if m == .bluetooth {
                    TrioGlyphs.bluetooth(x: r.midX - 4, midY: r.midY, active: true)
                } else {
                    // The 22 pt glyph, scaled to the other icons' size.
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform()
                    t.translateX(by: r.midX - 11 * 0.78, yBy: r.midY - 11 * 0.78)
                    t.scale(by: 0.78)
                    t.concat()
                    TrioGlyphs.trio(battery: 0.8, charging: false, wifiBars: 3, waves: 2, muted: false, x: 0, y: 0)
                    NSGraphicsContext.restoreGraphicsState()
                }
                return true
            }
            img.isTemplate = true
            img.accessibilityDescription = StatsNames.module(m)
            return img
        }
        let img = Icons.symbol(symbol, config: .init(pointSize: 12, weight: .regular))
        img.accessibilityDescription = StatsNames.module(m)
        return img
    }
}

/// Tabs (combined item), the module's panel and the actions, top to bottom, 300 pt wide.
final class DetailContent: NSView {
    private(set) var panel: StatsPanel
    private(set) var footer: DetailFooter
    let tabs: DetailTabs?

    init(panel: StatsPanel, footer: DetailFooter, tabs: DetailTabs?) {
        self.panel = panel
        self.footer = footer
        self.tabs = tabs
        super.init(frame: .zero)
        if let tabs { addSubview(tabs) }
        addSubview(panel)
        addSubview(footer)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Swaps in another module's panel and actions (combined item tabs).
    func replace(panel: StatsPanel, footer: DetailFooter) {
        self.panel.removeFromSuperview()
        self.footer.removeFromSuperview()
        self.panel = panel
        self.footer = footer
        addSubview(panel)
        addSubview(footer)
        relayout()
    }

    private func relayout() {
        var y: CGFloat = 0
        if let tabs {
            tabs.frame.origin = NSPoint(x: 0, y: 0)
            y = DetailTabs.height
        }
        panel.setFrameOrigin(NSPoint(x: 0, y: y))
        y += panel.frame.height
        footer.setFrameOrigin(NSPoint(x: 0, y: y))
        y += footer.frame.height
        setFrameSize(NSSize(width: StatsPanel.width, height: y))
    }
}

/// Menu material with rounded corners behind the content (the window's shadow follows the mask).
final class DetailChrome: NSView {
    static let radius: CGFloat = 10
    let effect = NSVisualEffectView()
    private(set) var content: DetailContent

    init(content: DetailContent) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        // Always the active look: the window belongs to an app that is never active.
        effect.state = .active
        effect.maskImage = Self.mask
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        addSubview(content)
        border.frame = bounds
        border.autoresizingMask = [.width, .height]
        addSubview(border)
    }

    private let border = Border()

    /// A hairline around the edge, as menus have (stronger in dark mode).
    private final class Border: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)).setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: DetailChrome.radius, yRadius: DetailChrome.radius)
            p.lineWidth = 0.5
            p.stroke()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func fit() {
        setFrameSize(content.frame.size)
        content.setFrameOrigin(.zero)
        border.needsDisplay = true
    }

    static var mask: NSImage {
        let r = radius
        let img = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// The details window: non-activating, above the menu bar. Opened by a click it takes the
/// keyboard like a menu (without activating BarTap; Esc closes it); opened by hover it doesn't,
/// so typing keeps going to the frontmost app.
final class DetailWindow: NSPanel {
    let chrome: DetailChrome
    /// Esc while it is key.
    var onCancel: (() -> Void)?

    init(content: DetailContent) {
        chrome = DetailChrome(content: content)
        super.init(contentRect: NSRect(origin: .zero, size: content.frame.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = chrome
    }

    // A click on a control makes the panel key without activating BarTap, so sliders, buttons
    // and pop-ups respond to the first click. It only becomes key on such a click, never when it
    // appears (typing keeps going to the frontmost app).
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Resizes to the content, keeping the top edge where it is (tab switches).
    func fitContent() {
        chrome.fit()
        let size = chrome.frame.size
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }

    /// Shows the window below `item` (global Cocoa coordinates) on `screen`.
    func show(below item: NSRect, on screen: NSScreen?) {
        chrome.fit()
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? item
        setFrame(DetailPlacement.frame(below: item, size: chrome.frame.size, visible: visible), display: true)
        invalidateShadow()
        orderFrontRegardless()
    }
}
