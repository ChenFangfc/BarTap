import AppKit
import BarTapCore

final class AppDelegate: NSObject, NSApplicationDelegate, SettingsHost {
    let settings = Settings()
    let keepAwake = KeepAwake()
    private(set) var hotkeyFailures: Set<HotkeyAction> = []

    private var bar: StatusBarController!
    private var reveal: RevealController!
    private let hotkeys = HotkeyCenter()
    private let gestures = MouseGestures()
    private let rules = RuleMonitor()
    private let catalog = AXCatalog()
    private(set) var stats: StatsController?
    private var searchPanel: SearchPanel?
    private var shelfPanel: ShelfPanel?
    private var settingsWC: SettingsWindowController?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var appMenuRanges: (pid: pid_t, rects: [CGRect])?
    private var screenWork: DispatchWorkItem?
    private var placementRetries = 0
    private var crowdHintShown = false
    private var started = false

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch completes so a bartap:// URL that launched us is not lost.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Loc.language = settings.language
        resolveConflicts { [weak self] in self?.startUp() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if reveal?.isCleanMode == true { reveal.setCleanMode(false) } else { showSettings() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.stop(notify: false)
        stats?.flush()
    }

    private func startUp() {
        guard !started else { return }
        started = true
        bar = StatusBarController(settings: settings)
        reveal = RevealController(bar: bar, settings: settings)
        bar.onClick = { [weak self] click in self?.handleClick(click) }
        bar.onCleanExitClick = { [weak self] in self?.reveal.setCleanMode(false) }
        bar.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        reveal.onChange = { [weak self] in self?.stateChanged() }
        reveal.ownPanelVisible = { [weak self] in
            (self?.searchPanel?.isVisible ?? false) || (self?.shelfPanel?.isVisible ?? false)
        }
        keepAwake.onChange = { [weak self] in self?.stateChanged() }

        let firstRun = !settings.didPlaceItems
        if firstRun { seedInitialPositions(extraDrop: 0, firstRun: true) }
        bar.createItems(alwaysHidden: settings.alwaysHiddenEnabled)
        if !settings.startCollapsed { reveal.reveal(.revealed, source: .command) }
        reveal.refresh()

        let statsController = StatsController(settings: settings)
        statsController.toggleKeyProvider = { [weak self] in self?.toggleOrderKey() }
        statsController.toggleRightDistance = { [weak self] in
            guard let t = self?.bar?.ownFrames().toggle, t.width > 0 else { return nil }
            return -t.maxX
        }
        statsController.openSettings = { [weak self] in self?.showSettings() }
        stats = statsController
        statsController.apply()

        wireGestures()
        rules.onChange = { [weak self] level, _ in self?.reveal.setRuleLevel(level) }
        rules.configure(settings.rules)
        applyHotkeys()
        observeSystem()
        configureGestures()

        // Once laid out, record where our items actually are, so later launches and new stats
        // items have a stable anchor even when no position was seeded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.recordPositionsIfMissing() }
        if firstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.verifyFirstPlacement() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.showOnboarding() }
        }
    }

    // MARK: Placement

    /// Whether a notched display exists but its menu bar is not being drawn right now.
    private func notchedBarHidden(_ screens: [ScreenInfo], _ windows: [WindowInfo]) -> Bool {
        guard let notched = screens.first(where: { $0.notch != nil }) else { return false }
        return !MenuBarGeometry.row(on: notched, windows: windows).contains(where: \.isOnScreen)
    }

    /// - Parameter firstRun: only the very first launch may defer placement; re-placements never
    ///   re-arm it (a display cycling between awake and asleep must not cause repeated re-placement).
    private func seedInitialPositions(extraDrop: Int, firstRun: Bool = false) {
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        if firstRun { settings.placementPending = notchedBarHidden(screens, windows) }
        // Stats items sit right of the toggle, so leave room for them too.
        let statsWidth = stats?.shownWidth() ?? StatsController.estimatedWidth(settings)
        // The toggle (logo glyph, 21 pt + macOS padding) is ~37 pt wide.
        if let seeds = Placement.initialSeeds(screens: screens, windows: windows, toggleWidth: 38 + statsWidth, extraDrop: extraDrop) {
            StatusBarController.seed(seeds, in: .standard)
        } else {
            StatusBarController.clearStoredPositions(.standard)
        }
        settings.didPlaceItems = true
    }

    /// First run only: if the seeded toggle still ended up behind the notch, move one more icon
    /// into Hidden and try again (twice at most).
    private func verifyFirstPlacement() {
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        guard let notched = screens.first(where: { $0.notch != nil }) else { return }
        let row = MenuBarGeometry.row(on: notched, windows: windows)
        guard row.contains(where: \.isOnScreen) else { return }   // that bar is not visible right now
        let drawn = ToggleVisibility.isDrawn(bar.ownFrames().toggle, row: row, on: notched)
        guard drawn == false, placementRetries < 2 else { return }
        placementRetries += 1
        bar.removeAllItems()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.seedInitialPositions(extraDrop: self.placementRetries)
            self.bar.createItems(alwaysHidden: self.settings.alwaysHiddenEnabled)
            self.reveal.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.verifyFirstPlacement() }
        }
    }

    /// Deferred first-run placement: the notched bar is visible now and our items still have no
    /// stored positions (the user has not arranged them yet), so place them properly once.
    @discardableResult
    private func runPendingPlacementIfPossible() -> Bool {
        guard settings.placementPending,
              UserDefaults.standard.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) == nil else {
            settings.placementPending = false
            return false
        }
        let windows = SystemQueries.windows(onScreenOnly: false)
        guard !notchedBarHidden(SystemQueries.screens(windows: windows), windows) else { return false }
        settings.placementPending = false
        resetPositions()
        return true
    }

    private(set) var resetCount = 0

    /// Enabling stats items can push the toggle behind the notch on the built-in display. Moving
    /// things automatically would undo the user's arrangement, so only point at the fix.
    private func hintIfToggleBehindNotch() {
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        guard let notched = screens.first(where: { $0.notch != nil }) else { return }
        let row = MenuBarGeometry.row(on: notched, windows: windows)
        guard row.contains(where: \.isOnScreen),
              ToggleVisibility.isDrawn(bar.ownFrames().toggle, row: row, on: notched) == false else { return }
        Toast.show(L("The BarTap toggle no longer fits beside the notch. Use Settings › Layout › Reset BarTap Positions."),
                   symbol: "exclamationmark.triangle")
    }

    func resetPositions() {
        resetCount += 1
        reveal.setCleanMode(false)
        reveal.resetRecheckBudget()
        bar.removeAllItems()
        // Stats items are anchored next to the toggle; re-anchor them to its new position too.
        stats?.removeItemsForReplacement()
        StatusBarController.clearStoredPositions(.standard)
        placementRetries = 0
        // Wait for macOS to re-lay out the bar without our items before measuring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.seedInitialPositions(extraDrop: 0)
            self.bar.createItems(alwaysHidden: self.settings.alwaysHiddenEnabled)
            self.reveal.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.verifyFirstPlacement()
                self?.recordPositionsIfMissing()
                self?.stats?.apply()   // recreate stats items next to the new toggle position
            }
        }
    }

    /// The toggle's ordering key ("NSStatusItem Preferred Position"): stored value, or derived
    /// from where it currently sits (keys track the distance of an item's right edge from the bar's
    /// right edge, observed ≈ +7 for system items).
    func toggleOrderKey() -> Double? {
        if let stored = UserDefaults.standard.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) as? Double {
            return stored
        }
        let t = bar?.ownFrames().toggle ?? .zero
        return t.width > 0 ? Double(-t.maxX) + 7 : nil
    }

    private func recordPositionsIfMissing() {
        let d = UserDefaults.standard
        guard !settings.placementPending, d.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) == nil,
              reveal.layoutProblem == nil, let key = toggleOrderKey() else { return }
        StatusBarController.seed(Placement.Seeds(anchorRightDistance: key), in: d)
    }

    // MARK: Conflicts & onboarding

    private func resolveConflicts(then proceed: @escaping () -> Void) {
        let running = Conflicts.running()
        guard !running.isEmpty else { proceed(); return }
        let names = Set(running.compactMap(\.localizedName)).sorted().joined(separator: ", ")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("%@ is running", names)
        alert.informativeText = L("Two menu bar managers fighting over the same icons is what makes the menu bar jump. Quit %@ and let BarTap take over?", names)
        alert.addButton(withTitle: L("Quit %@", names))
        alert.addButton(withTitle: L("Keep Both"))
        if alert.runModal() == .alertFirstButtonReturn {
            running.forEach { $0.terminate() }
            waitForExit(running, deadline: Date().addingTimeInterval(8), then: proceed)
        } else {
            proceed()
        }
    }

    private func waitForExit(_ apps: [NSRunningApplication], deadline: Date, then proceed: @escaping () -> Void) {
        if apps.allSatisfy(\.isTerminated) || Date() > deadline {
            // Give macOS a moment to re-lay out the icons that manager was holding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: proceed)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.waitForExit(apps, deadline: deadline, then: proceed) }
    }

    private func showOnboarding() {
        guard !settings.onboardingShown else { return }
        settings.onboardingShown = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Welcome to BarTap")
        alert.informativeText = L("• Hold ⌘ and drag menu bar icons to the left of the │ divider to hide them.\n• Click the BarTap toggle (or press ⌃⌥⌘B) to show or hide them.\n• Icons that were hidden behind the notch now start in the Hidden section.\n• Optional: allow Accessibility access to search icons (⌃⌥⌘F) and to use the shelf below the menu bar.\n\nBarTap never moves your pointer or blocks your clicks.")
        alert.addButton(withTitle: L("Got It"))
        alert.addButton(withTitle: L("Allow Accessibility…"))
        alert.addButton(withTitle: L("Open Settings"))
        switch alert.runModal() {
        case .alertSecondButtonReturn: requestAccessibility()
        case .alertThirdButtonReturn: showSettings()
        default: break
        }
    }

    // MARK: Events

    private func handleClick(_ click: StatusBarController.Click) {
        switch click {
        case .toggle: primaryToggle(source: .click)
        case .toggleAll: reveal.toggleAll(source: .click)
        case .menu: bar.showMenu()
        }
    }

    private func primaryToggle(source: RevealSource) {
        if reveal.isCleanMode { reveal.setCleanMode(false); return }
        if settings.shelfMode == .always {
            if shelfPanel?.isVisible == true { closeShelf() } else { openShelf() }
            return
        }
        closeShelf()
        reveal.toggle(source: source)
        if settings.shelfMode == .whenCrowded, reveal.effectiveLevel > .collapsed {
            // Let macOS lay out the revealed icons, then check whether they actually fit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openShelfIfCrowded() }
        }
    }

    private func openShelfIfCrowded() {
        guard reveal.effectiveLevel > .collapsed else { return }
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        guard let screen = SystemQueries.screen(containingCG: SystemQueries.pointerCG, in: screens) else { return }
        let toggle = bar.ownFrames().toggle
        guard toggle.width > 0 else { return }
        let toggleX = ToggleVisibility.toggleMaxX(toggle, on: screen)
        let row = MenuBarGeometry.row(on: screen, windows: windows)
        guard MenuBarGeometry.overflowCount(on: screen, row: row, leftOf: toggleX - toggle.width) > 0 else { return }
        if AXCatalog.isTrusted {
            openShelf()
        } else if !crowdHintShown {
            crowdHintShown = true
            Toast.show(L("Some icons don't fit beside the notch — allow Accessibility to use the shelf"), symbol: "exclamationmark.triangle")
        }
    }

    private func wireGestures() {
        gestures.onHoverReveal = { [weak self] in self?.reveal.reveal(.revealed, source: .hover) }
        gestures.onPointerLeftBar = { [weak self] in self?.reveal.pointerLeftMenuBar() }
        gestures.onScrollToggle = { [weak self] show in
            guard let self else { return }
            if show { self.reveal.reveal(.revealed, source: .scroll) } else { self.reveal.collapseByUser() }
        }
        gestures.onEmptyClick = { [weak self] in self?.primaryToggle(source: .emptyClick) }
        gestures.onArranging = { [weak self] on in self?.reveal.setArranging(on) }
        gestures.onOutsideClick = { [weak self] p in
            guard let self, let shelf = self.shelfPanel, shelf.isVisible, !shelf.containsCG(p) else { return }
            self.closeShelf()
        }
        gestures.occupiedProvider = { [weak self] screen in
            // nil = "unknown": the caller then uses its conservative fallback. AX reports the menus
            // of the active display only, so other displays get nil as well.
            guard let self, let cache = self.appMenuRanges,
                  cache.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            let here = cache.rects.filter { screen.frame.intersects($0) }
            return here.isEmpty ? nil : here.map { $0.minX...$0.maxX }
        }
    }

    private func configureGestures() {
        var c = MouseGestures.Config()
        c.hover = settings.hoverReveal
        c.hoverDelay = settings.hoverDelay
        c.scroll = settings.scrollReveal
        c.emptyClick = settings.emptyClickReveal
        c.arrangeOnCommandDrag = settings.revealWhileDragging
        c.dismissShelfOnOutsideClick = shelfPanel?.isVisible ?? false
        gestures.configure(c)
        if c.hover || c.emptyClick { refreshAppMenuRanges() }
    }

    /// Frontmost app's menu titles (Accessibility), so "empty bar space" excludes them precisely.
    private func refreshAppMenuRanges() {
        guard AXCatalog.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { appMenuRanges = nil; return }
        let pid = app.processIdentifier
        catalog.appMenuRanges(pid: pid) { [weak self] rects in self?.appMenuRanges = (pid, rects) }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((nc, nc.addObserver(forName: .barTapSettingsChanged, object: nil, queue: .main) { [weak self] n in
            self?.settingsChanged(n.userInfo?["key"] as? String ?? "")
        }))
        observers.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }))
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                // Space changes (incl. entering/leaving full screen, which hides the bar) matter only
                // while a deferred placement waits or a layout problem is pending re-validation.
                if n.name == NSWorkspace.activeSpaceDidChangeNotification,
                   self?.settings.placementPending != true, self?.reveal.layoutProblem == nil { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.screensChanged() }
            }))
        }
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.hoverReveal || self.settings.emptyClickReveal else { return }
            self.refreshAppMenuRanges()
        }))
    }

    private(set) var screenChangeCount = 0

    private func screensChanged() {
        screenChangeCount += 1
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gestures.screensChanged()
            self.rules.screensChanged()
            self.closeShelf()
            if self.runPendingPlacementIfPossible() { return }
            self.reveal.refresh()
        }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func settingsChanged(_ key: String) {
        switch key {
        case "alwaysHiddenEnabled":
            bar.setAlwaysHiddenEnabled(settings.alwaysHiddenEnabled)
            reveal.refresh()
        case "showDivider", "iconStyle":
            reveal.refresh()
        case "hoverReveal", "hoverDelay", "scrollReveal", "emptyClickReveal", "revealWhileDragging":
            configureGestures()
        case "rules":
            rules.configure(settings.rules)
        case "stats", "alerts":
            stats?.apply()
            // New or removed items change the layout; re-verify the hidden state.
            reveal.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.hintIfToggleBehindNotch() }
        case "language":
            Loc.language = settings.language
            stateChanged()
        default:
            stateChanged()
        }
    }

    func applyHotkeys() {
        var bindings: [(HotkeyAction, KeyCombo, () -> Void)] = []
        for action in HotkeyAction.allCases {
            guard let combo = settings.hotkey(action) else { continue }
            bindings.append((action, combo, { [weak self] in self?.performHotkey(action) }))
        }
        hotkeyFailures = hotkeys.apply(bindings)
    }

    func setHotkeysSuspended(_ on: Bool) {
        hotkeys.setSuspended(on)
        if !on { hotkeyFailures = hotkeys.failed }
    }

    private func performHotkey(_ action: HotkeyAction) {
        switch action {
        case .toggle: primaryToggle(source: .hotkey)
        case .toggleAll: reveal.toggleAll(source: .hotkey)
        case .search: openSearch()
        case .shelf: shelfPanel?.isVisible == true ? closeShelf() : openShelf()
        case .clean: reveal.setCleanMode(!reveal.isCleanMode)
        case .keepAwake:
            if keepAwake.isActive { keepAwake.stop() } else { keepAwake.start(minutes: nil, allowDisplaySleep: settings.keepAwakeAllowDisplaySleep) }
            Toast.show(keepAwake.isActive ? L("Keep awake: on") : L("Keep awake: off"), symbol: "cup.and.saucer")
        }
    }

    private func stateChanged() {
        guard let bar, let reveal else { return }
        let level = reveal.effectiveLevel
        var badge: Icons.Badge?
        if reveal.layoutProblem != nil && reveal.layoutProblem != .notReady { badge = .warning } else if keepAwake.isActive { badge = .awake }
        let tip: String
        if let p = reveal.layoutProblem, p != .notReady {
            tip = L("BarTap can't hide icons: its dividers are out of order. Right-click for help.")
        } else {
            tip = level == .collapsed ? L("Click to show hidden icons (⌥-click: all)") : L("Click to hide icons")
        }
        bar.updateToggleIcon(expanded: level > .collapsed, badge: badge, tooltip: tip)
    }

    // MARK: Search & shelf

    func openSearch() {
        closeShelf()
        let panel = searchPanel ?? SearchPanel()
        panel.onActivate = { [weak self] item in self?.activate(item) }
        searchPanel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard AXCatalog.isTrusted else {
            panel.present(on: screen, items: [], trusted: false)
            return
        }
        catalog.snapshot { items in panel.present(on: screen, items: items, trusted: true) }
    }

    func openShelf() {
        let panel = shelfPanel ?? ShelfPanel()
        panel.onActivate = { [weak self] item in self?.activate(item) }
        panel.onOpenSettings = { [weak self] in self?.requestAccessibility() }
        panel.onClosed = { [weak self] in self?.configureGestures() }
        shelfPanel = panel
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        guard let screen = SystemQueries.screen(containingCG: SystemQueries.pointerCG, in: screens) else { return }
        let toggle = bar.ownFrames().toggle
        let anchorX = toggle.width > 0 ? ToggleVisibility.toggleMaxX(toggle, on: screen) : screen.frame.maxX - 8
        let show = { [weak self] (items: [BarItem]) in
            let hidden = items.filter { $0.section != .shown }
            panel.present(items: hidden, trusted: AXCatalog.isTrusted, on: screen, anchorX: anchorX)
            self?.configureGestures()
        }
        if AXCatalog.isTrusted { catalog.snapshot(completion: show) } else { show([]) }
    }

    private func closeShelf() {
        guard shelfPanel?.isVisible == true else { return }
        shelfPanel?.orderOut(nil)
        configureGestures()
    }

    /// Open a menu bar icon: reveal its section if needed, then AXPress it. No pointer movement.
    private func activate(_ item: BarItem) {
        configureGestures()
        let needed: RevealLevel
        switch item.section {
        case .shown: needed = .collapsed
        case .hidden: needed = .revealed
        case .alwaysHidden: needed = .revealedAll
        }
        var delay = 0.05
        if needed > .collapsed, reveal.effectiveLevel < needed {
            reveal.reveal(needed, source: .search)
            delay = 0.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.catalog.press(item) { ok in
                if !ok { Toast.show(L("Couldn't open %@", item.title), symbol: "exclamationmark.triangle") }
            }
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let level = reveal.effectiveLevel
        func item(_ title: String, _ key: String = "", action: @escaping () -> Void) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.fire(_:)), keyEquivalent: key)
            let t = ClosureMenuTarget(action)
            i.target = t
            i.representedObject = t
            return i
        }
        func hint(_ action: HotkeyAction) -> String { settings.hotkey(action).map { "   " + HotkeyCenter.display($0) } ?? "" }

        m.addItem(item((level == .collapsed ? L("Show Hidden Icons") : L("Hide Icons")) + hint(.toggle)) { [weak self] in
            self?.primaryToggle(source: .click)
        })
        if settings.alwaysHiddenEnabled {
            m.addItem(item((level == .revealedAll ? L("Hide All Icons") : L("Show All Icons")) + hint(.toggleAll)) { [weak self] in
                self?.reveal.toggleAll(source: .click)
            })
        }
        m.addItem(item(L("Search Menu Bar…") + hint(.search)) { [weak self] in self?.openSearch() })
        m.addItem(item(L("Open Shelf") + hint(.shelf)) { [weak self] in self?.openShelf() })
        m.addItem(.separator())

        let clean = item(L("Clean Menu Bar") + hint(.clean)) { [weak self] in
            guard let self else { return }
            self.reveal.setCleanMode(!self.reveal.isCleanMode)
        }
        clean.state = reveal.isCleanMode ? .on : .off
        m.addItem(clean)

        let awake = NSMenuItem(title: L("Keep Awake"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let status = NSMenuItem(title: keepAwake.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        sub.addItem(status)
        sub.addItem(.separator())
        for (title, minutes) in [(L("15 min"), 15), (L("1 hour"), 60), (L("2 hours"), 120), (L("4 hours"), 240)] as [(String, Int)] {
            sub.addItem(item(title) { [weak self] in
                guard let self else { return }
                self.keepAwake.start(minutes: minutes, allowDisplaySleep: self.settings.keepAwakeAllowDisplaySleep)
            })
        }
        sub.addItem(item(L("Indefinitely")) { [weak self] in
            guard let self else { return }
            self.keepAwake.start(minutes: nil, allowDisplaySleep: self.settings.keepAwakeAllowDisplaySleep)
        })
        if keepAwake.isActive {
            sub.addItem(.separator())
            sub.addItem(item(L("Turn Off")) { [weak self] in self?.keepAwake.stop() })
        }
        awake.submenu = sub
        awake.state = keepAwake.isActive ? .on : .off
        m.addItem(awake)
        m.addItem(item(L("Pick a Color…")) { [weak self] in self?.pickColor() })

        if let problem = reveal.layoutProblem, problem != .notReady {
            m.addItem(.separator())
            let info = NSMenuItem(title: problem == .alwaysRightOfHidden
                                  ? L("⚠︎ The ‖ divider is right of the │ divider")
                                  : L("⚠︎ The │ divider is right of the toggle"), action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
            m.addItem(item(L("Fix: Reset BarTap Positions")) { [weak self] in self?.resetPositions() })
        }
        let rivals = Conflicts.running()
        if !rivals.isEmpty {
            m.addItem(.separator())
            let names = Set(rivals.compactMap(\.localizedName)).sorted().joined(separator: ", ")
            m.addItem(item(L("Quit %@ (conflicts with BarTap)", names)) { rivals.forEach { $0.terminate() } })
        }
        m.addItem(.separator())
        m.addItem(item(L("Settings…"), ",") { [weak self] in self?.showSettings() })
        m.addItem(item(L("Quit BarTap"), "q") { NSApp.terminate(nil) })
        return m
    }

    // MARK: SettingsHost

    func showSettings() {
        if settingsWC == nil {
            let wc = SettingsWindowController(host: self)
            wc.onClose = { [weak self] in
                // Release the whole window hierarchy; it is rebuilt on demand.
                DispatchQueue.main.async { self?.settingsWC = nil }
            }
            settingsWC = wc
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    func reopenSettings() {
        settingsWC?.close()
        settingsWC = nil
        DispatchQueue.main.async { [weak self] in self?.showSettings() }
    }

    func revealEverything() { reveal.reveal(.revealedAll, source: .command) }

    func catalogSnapshot(_ completion: @escaping ([BarItem]) -> Void) { catalog.snapshot(completion: completion) }

    func requestAccessibility() {
        AXCatalog.requestTrust()
        AXCatalog.openAccessibilitySettings()
    }

    func pickColor() { ColorPicker.pick(format: settings.colorFormat) }

    /// Restarting Control Center re-applies icon spacing to the system icons it draws (Wi-Fi,
    /// battery, clock…). macOS relaunches it immediately and every icon comes back (verified).
    func restartMenuBarHost() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["ControlCenter"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.reveal.refresh() }
    }

    // MARK: URL commands

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        // The descriptor is only valid during this call: parse now, defer only the result.
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s),
              let command = URLCommand(url: url) else { return }
        perform(command)
    }

    private func perform(_ command: URLCommand, attempt: Int = 0) {
        guard started else {
            // Still starting up (e.g. the conflict alert is open); try again for up to 30 s.
            guard attempt < 60 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.perform(command, attempt: attempt + 1) }
            return
        }
        switch command {
        case .toggle: primaryToggle(source: .command)
        case .show: reveal.reveal(.revealed, source: .command)
        case .showAll: reveal.reveal(.revealedAll, source: .command)
        case .hide: reveal.collapseByUser()
        case .search: openSearch()
        case .shelf: openShelf()
        case .clean(let on): reveal.setCleanMode(on ?? !reveal.isCleanMode)
        case .keepAwake(let minutes): keepAwake.start(minutes: minutes, allowDisplaySleep: settings.keepAwakeAllowDisplaySleep)
        case .keepAwakeOff: keepAwake.stop()
        case .pickColor: pickColor()
        case .settings: showSettings()
        case .resetPositions: resetPositions()
        case .debug(let what): if settings.debugCommands { Debug.run(what, app: self) }
        }
    }

    // MARK: Debug introspection (only with `defaults write io.github.chenfangfc.BarTap debugCommands -bool true`)

    func debugState() -> [String: Any] {
        let f = bar.ownFrames()
        func r(_ rect: CGRect?) -> [Double] { rect.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [] }
        return [
            "effectiveLevel": reveal.effectiveLevel.description,
            "userLevel": reveal.model.userLevel.description,
            "userSource": reveal.model.userSource?.rawValue ?? "",
            "ruleLevel": reveal.model.ruleLevel.description,
            "arranging": reveal.model.arranging,
            "layoutProblem": reveal.layoutProblem.map { "\($0)" } ?? "",
            "toggleUndrawn": reveal.toggleUndrawn,
            "watchdogLog": reveal.watchdogLog,
            "clean": reveal.isCleanMode,
            // Normalized: x = −(distance from the bar's right edge).
            "frames": ["toggle": r(f.toggle), "hidden": r(f.hidden), "always": r(f.alwaysHidden)],
            "toggleRD": f.toggle.width > 0 ? Double(-f.toggle.maxX) : -1,
            "lengths": ["hidden": Double(bar.hiddenItem?.length ?? -1), "always": Double(bar.alwaysItem?.length ?? -1)],
            "keepAwake": keepAwake.isActive,
            "hotkeyFailures": hotkeyFailures.map(\.rawValue),
            "busy": reveal.currentBusyReason()?.rawValue ?? "",
            "lastBusy": reveal.lastBusyReason?.rawValue ?? "",
            "axTrusted": AXCatalog.isTrusted,
            "memoryMB": ProcessStats.memoryMB(),
            "cpuSeconds": ProcessStats.cpuSeconds(),
            "settingsOpen": settingsWC != nil,
            "settingsControllersAlive": SettingsWindowController.liveCount,
            "resetCount": resetCount,
            "jitter": jitterResults,
            "commits": reveal.commits,
            "watchdogRuns": reveal.watchdogRuns,
            "screenChanges": screenChangeCount,
            "placementPending": settings.placementPending,
            "stats": stats?.debugInfo ?? [:],
            "menuItems": lastMenuItemCount,
            "ruleLevel2": rules.lastResult.level.description,
            "ruleReasons": rules.lastResult.reasons.map(\.rawValue),
        ]
    }

    func debugSimulateScreenChange() { screensChanged() }

    func closeSettingsForTesting() { settingsWC?.close() }

    func debugSetHiddenLength(_ v: CGFloat) { bar.hiddenItem?.length = v }

    /// Renders each settings pane to PNG (debug).
    func renderSettingsForDebug() {
        let wc = SettingsWindowController(host: self)
        guard let tabs = wc.window?.contentViewController as? NSTabViewController else { return }
        for (i, item) in tabs.tabViewItems.enumerated() {
            guard let view = item.viewController?.view as? NSScrollView, let doc = view.documentView else { continue }
            doc.layoutSubtreeIfNeeded()
            let size = NSSize(width: 640, height: max(doc.fittingSize.height, 100))
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            doc.removeFromSuperview()
            doc.translatesAutoresizingMaskIntoConstraints = true
            doc.frame = NSRect(origin: .zero, size: size)
            container.addSubview(doc)
            for dark in [false, true] {
                DebugRender.view(container, "settings_\(i)_\(dark ? "dark" : "light")", dark: dark)
            }
        }
        wc.close()
    }

    var lastMenuItemCount = 0
    var jitterResults: [String: Bool] = [:]
    func buildMenuForTesting() -> NSMenu { buildMenu() }

    /// Re-applies every setting (for changes written with `defaults write` while running).
    func reloadAllSettings() {
        settings.defaults.synchronize()
        Loc.language = settings.language
        if (bar.alwaysItem != nil) != settings.alwaysHiddenEnabled { bar.setAlwaysHiddenEnabled(settings.alwaysHiddenEnabled) }
        rules.configure(settings.rules)
        configureGestures()
        applyHotkeys()
        stats?.apply()
        reveal.refresh()
    }
}

/// Retains a closure for an NSMenuItem (the item holds this via `representedObject`).
final class ClosureMenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action() }
}

enum Debug {
    static func run(_ what: String, app: AppDelegate) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BarTap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch what {
        case "timing":
            app.stats?.refreshTiming()
        case "dump":
            let data = try? JSONSerialization.data(withJSONObject: app.debugState(), options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: dir.appendingPathComponent("debug-state.json"), options: .atomic)
        case "screens", "wake":
            app.debugSimulateScreenChange()
        case "settings":
            app.showSettings()
        case "close-settings":
            app.closeSettingsForTesting()
        case "reload":
            app.reloadAllSettings()
        case "menu":
            app.lastMenuItemCount = app.buildMenuForTesting().items.count
        case "jitter":
            app.jitterResults = JitterCheck.run()
        case "render":
            app.stats?.debugRender()
            app.renderSettingsForDebug()
        case let w where w.hasPrefix("len-"):
            if let v = Double(w.dropFirst(4)) { app.debugSetHiddenLength(CGFloat(v)) }
        case let w where w.hasPrefix("stats-open-"):
            if let m = StatsModule(rawValue: String(w.dropFirst("stats-open-".count))) { app.stats?.debugOpen(m) }
        case "search":
            app.openSearch()
        case "shelf":
            app.openShelf()
        default:
            break
        }
    }
}
