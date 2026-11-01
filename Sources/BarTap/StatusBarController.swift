import AppKit
import BarTapCore

/// Owns our status items. Hiding works purely by resizing separator items: a separator that is
/// wider than any screen pushes every icon to its left out of the drawable area. No events are
/// synthesized and no other app's item is ever touched.
///
/// Layout, left to right:
///   [always-hidden icons] ‖ [hidden icons] │ (toggle) [shown icons] [Control Center] [Clock]
final class StatusBarController: NSObject {
    enum Click { case toggle, toggleAll, menu }

    static let collapsedLength: CGFloat = 10_000
    /// Collapsed dividers are always wider than this, so window geometry can tell them apart
    /// from real icons (see `separatorWidthThreshold`).
    static let minimumCollapsedLength: CGFloat = 1600
    static let dividerLength: CGFloat = 8
    /// Open divider without the drawn line. Not 0: a zero-length item may report no frame.
    static let gapLength: CGFloat = 1

    private enum Name {
        static let toggle = "tb_toggle"
        static let hidden = "tb_hidden"
        static let always = "tb_always"
        static let clean = "tb_clean"
        static let cleanExit = "tb_clean_exit"
    }

    private(set) var toggleItem: NSStatusItem?
    private(set) var hiddenItem: NSStatusItem?
    private(set) var alwaysItem: NSStatusItem?
    private var cleanSeparator: NSStatusItem?
    private var cleanExit: NSStatusItem?

    var onClick: ((Click) -> Void)?
    var onCleanExitClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let settings: Settings
    private(set) var appliedLevel: RevealLevel?
    private var showDividers = true

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: Creation

    static func preferredPositionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    static func hasStoredPositions(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: preferredPositionKey(Name.toggle)) != nil
    }

    static func seed(_ seeds: Placement.Seeds, in defaults: UserDefaults) {
        defaults.set(seeds.toggle, forKey: preferredPositionKey(Name.toggle))
        defaults.set(seeds.hidden, forKey: preferredPositionKey(Name.hidden))
    }

    static func clearStoredPositions(_ defaults: UserDefaults) {
        for n in [Name.toggle, Name.hidden, Name.always] { defaults.removeObject(forKey: preferredPositionKey(n)) }
    }

    /// Creation order matters when no positions are stored: each new item lands at the far left,
    /// so toggle → hidden → always yields `‖ │ (toggle)` with nothing hidden yet.
    func createItems(alwaysHidden: Bool) {
        guard toggleItem == nil else { return }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = Name.toggle
        toggle.behavior = []
        configureButton(toggle, identifier: "bartap.toggle", label: L("BarTap: show or hide menu bar icons"))
        toggleItem = toggle

        let hidden = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        hidden.autosaveName = Name.hidden
        hidden.behavior = []
        configureButton(hidden, identifier: "bartap.hidden", label: L("BarTap divider: icons to the left are hidden"))
        hiddenItem = hidden

        if alwaysHidden { createAlwaysItem() }
        appliedLevel = nil
    }

    private func createAlwaysItem() {
        guard alwaysItem == nil else { return }
        // Start open: the reveal controller collapses it only after validating the order.
        let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        item.autosaveName = Name.always
        item.behavior = []
        configureButton(item, identifier: "bartap.always", label: L("BarTap divider: icons to the left are always hidden"))
        alwaysItem = item
    }

    func setAlwaysHiddenEnabled(_ on: Bool) {
        if on {
            createAlwaysItem()
        } else if let item = alwaysItem {
            NSStatusBar.system.removeStatusItem(item)
            alwaysItem = nil
        }
        appliedLevel = nil
    }

    func removeAllItems() {
        for item in [toggleItem, hiddenItem, alwaysItem, cleanSeparator, cleanExit].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        toggleItem = nil
        hiddenItem = nil
        alwaysItem = nil
        cleanSeparator = nil
        cleanExit = nil
        appliedLevel = nil
    }

    private func configureButton(_ item: NSStatusItem, identifier: String, label: String) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.imagePosition = .imageOnly
    }

    // MARK: State

    /// Collapsed dividers use a fixed, very large length (macOS clamps it to ~5,000 pt).
    /// Shorter "just wide enough" lengths save ~10 MB of backing store but were measured to
    /// trigger a macOS 26 layout state where one display draws the divider and hides every other
    /// icon (clock included); the long length never did.
    func collapsedLength() -> CGFloat { Self.collapsedLength }

    func apply(level: RevealLevel, showDividers: Bool) {
        self.showDividers = showDividers
        guard let hidden = hiddenItem else { return }
        let open = showDividers ? Self.dividerLength : Self.gapLength
        // Measure before changing anything: once collapsed, the divider's own right edge stays put,
        // so a measurement taken in any state is valid.
        let closed = collapsedLength()
        let hiddenLength = level >= .revealed ? open : closed
        // The always-hidden divider only has to be wide while the hidden section is shown. When
        // everything is collapsed it sits behind the hidden divider anyway, so it stays narrow and
        // does not hold a second full-width backing surface.
        let alwaysLength = level == .revealed ? closed : open
        // Change the outer separator while it is still covered by the inner one, so the
        // always-hidden icons never flash on screen.
        if level == .collapsed {
            setLength(hidden, hiddenLength)
            if let a = alwaysItem { setLength(a, alwaysLength) }
        } else {
            if let a = alwaysItem { setLength(a, alwaysLength) }
            setLength(hidden, hiddenLength)
        }
        hidden.button?.image = (showDividers && level >= .revealed) ? Icons.divider(double: false) : nil
        alwaysItem?.button?.image = (showDividers && level >= .revealedAll) ? Icons.divider(double: true) : nil
        appliedLevel = level
    }

    private func setLength(_ item: NSStatusItem, _ length: CGFloat) {
        if abs(item.length - length) > 0.5 { item.length = length }
    }

    /// Re-sends the collapsed length with a 1 pt nudge so macOS lays the bar out again
    /// (used once when a display ended up drawing a collapsed divider).
    func nudgeCollapsed() {
        for item in [hiddenItem, alwaysItem].compactMap({ $0 }) where item.length >= Self.minimumCollapsedLength {
            item.length = item.length == Self.collapsedLength ? Self.collapsedLength - 1 : Self.collapsedLength
        }
    }

    func updateToggleIcon(expanded: Bool, badge: Icons.Badge?, tooltip: String) {
        guard let button = toggleItem?.button else { return }
        let image = Icons.toggle(style: settings.iconStyle, expanded: expanded, badge: badge)
        if button.image !== image { button.image = image }
        if button.toolTip != tooltip { button.toolTip = tooltip }
    }

    /// The display hosting our status-item proxy windows. AppKit picks one per process and it is
    /// often *not* the main display, so all geometry is expressed relative to it.
    private func referenceScreen() -> NSScreen? {
        guard let f = toggleItem?.button?.window?.frame, f.width > 0 else { return nil }
        let p = NSPoint(x: f.maxX - 0.5, y: f.maxY - 0.5)
        return NSScreen.screens.first { NSPointInRect(p, $0.frame) }
    }

    /// Our items' positions as distance-from-the-right-edge, encoded as rects whose x axis is
    /// `-(distance from the bar's right edge)`. That distance is identical on every display (the
    /// same icons are laid out right-aligned on each bar), so it can be compared with any display's
    /// window list. On macOS 26 the real windows live in Control Center; AppKit keeps these proxies
    /// in sync with the actual layout.
    func ownFrames() -> OwnItemFrames {
        guard let screen = referenceScreen() else {
            return OwnItemFrames(toggle: .zero, hidden: .zero, alwaysHidden: alwaysItem == nil ? nil : .zero)
        }
        func normalized(_ item: NSStatusItem?) -> CGRect {
            guard let f = item?.button?.window?.frame, f.width > 0 else { return .zero }
            let rightDistance = screen.frame.maxX - f.maxX
            return CGRect(x: -rightDistance - f.width, y: 0, width: f.width, height: f.height)
        }
        return OwnItemFrames(toggle: normalized(toggleItem), hidden: normalized(hiddenItem),
                             alwaysHidden: alwaysItem.map { normalized($0) })
    }

    // MARK: Clean mode

    var isCleanModeOn: Bool { cleanSeparator != nil }

    /// Pushes *every* third-party icon (ours included) off the bar, leaving only the system's pinned
    /// Control Center and clock. An optional exit button sits right of the separator.
    func setCleanMode(_ on: Bool, showExit: Bool) {
        if on == isCleanModeOn { return }
        let d = UserDefaults.standard
        if on {
            d.set(0.0, forKey: Self.preferredPositionKey(Name.cleanExit))
            d.set(0.5, forKey: Self.preferredPositionKey(Name.clean))
            if showExit {
                let exit = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                exit.autosaveName = Name.cleanExit
                exit.behavior = []
                if let b = exit.button {
                    b.image = Icons.symbol("eye.slash")
                    b.target = self
                    b.action = #selector(cleanExitClicked)
                    b.toolTip = L("Clean menu bar is on. Click to restore your icons.")
                    b.setAccessibilityLabel(L("Restore menu bar icons"))
                }
                cleanExit = exit
            }
            // Created narrow so macOS honours the seeded slot, then widened once it is placed.
            let sep = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
            sep.autosaveName = Name.clean
            sep.behavior = []
            cleanSeparator = sep
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak sep] in
                guard let sep, self?.cleanSeparator === sep else { return }
                sep.length = Self.collapsedLength
            }
        } else {
            if let s = cleanSeparator { NSStatusBar.system.removeStatusItem(s) }
            if let e = cleanExit { NSStatusBar.system.removeStatusItem(e) }
            cleanSeparator = nil
            cleanExit = nil
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            let item = [toggleItem, hiddenItem, alwaysItem].compactMap { $0 }.first { $0.button === sender } ?? toggleItem
            if let item { showMenu(from: item) }
            return
        }
        if sender === alwaysItem?.button || event.modifierFlags.contains(.option) {
            onClick?(.toggleAll)
        } else {
            onClick?(.toggle)
        }
    }

    @objc private func cleanExitClicked() { onCleanExitClick?() }

    func showMenu(from item: NSStatusItem? = nil) {
        guard let menu = menuProvider?(), let item = item ?? toggleItem else { return }
        // Attaching the menu for a single click is the standard way to get native placement.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
