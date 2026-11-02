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
    let catalog = AXCatalog()
    /// Settings › Layout is capturing icons, or its Apply is running: every icon stays revealed meanwhile.
    private var layoutHolds: Set<String> = []
    private var levelBeforeLayoutPane: RevealLevel?
    private lazy var layoutApplier = LayoutApplier(catalog: catalog, mover: IconMover(), ownRun: { [weak self] in self?.catalog.ownRun?() })
    /// The last Apply's outcome, numbered (debug).
    private var lastLayoutApply = ""
    private var layoutApplyRuns = 0
    private(set) var stats: StatsController?
    private var searchPanel: SearchPanel?
    private var shelfPanel: ShelfPanel?
    private var settingsWC: SettingsWindowController?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var appMenuRanges: (pid: pid_t, rects: [CGRect])?
    private var screenWork: DispatchWorkItem?
    private var placementRetries = 0
    private var placementWaits = 0
    private var pendingPlacementCheck: DispatchWorkItem?
    /// A (re)placement is still being checked or corrected (tests wait for it).
    private(set) var placementSettling = false
    private var lastMeasuredToggle: CGRect?
    private var crowdHintShown = false
    private var trustWatch: Timer?
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
        VideoDownloads.shared.stopAll()
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
        catalog.ownRun = { [weak self] in
            guard let self, let t = self.bar.toggleItem?.button?.window?.frame.width, t > 0,
                  let h = self.bar.hiddenItem?.button?.window?.frame.width, h > 0 else { return nil }
            let seen = self.bar.ownFrames().toggle
            return OwnRun(hidden: h, toggle: t, stats: self.stats?.itemWindowWidths() ?? [],
                          always: self.bar.alwaysItem?.button?.window?.frame.width, toggleRD: seen.width > 0 ? -seen.maxX : nil)
        }
        reveal.ownPanelVisible = { [weak self] in
            (self?.searchPanel?.isVisible ?? false) || (self?.shelfPanel?.isVisible ?? false) || !(self?.layoutHolds.isEmpty ?? true)
        }
        keepAwake.onChange = { [weak self] in self?.stateChanged() }

        VideoDownloads.shared.settings = settings
        let firstRun = !settings.didPlaceItems
        if firstRun { seedInitialPositions(extraDrop: 0, firstRun: true) }
        bar.createItems(alwaysHidden: settings.alwaysHiddenEnabled)
        if !settings.startCollapsed { reveal.reveal(.revealed, source: .command) }
        reveal.refresh()

        let statsController = StatsController(settings: settings)
        statsController.toggleKeyProvider = {
            UserDefaults.standard.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) as? Double
        }
        statsController.toggleKeyEstimate = { [weak self] in self?.toggleOrderKey() }
        statsController.openSettings = { [weak self] in self?.showSettings() }
        stats = statsController
        statsController.apply()

        wireGestures()
        configureTogglePresenter()
        rules.onChange = { [weak self] level, _ in self?.reveal.setRuleLevel(level) }
        rules.configure(settings.rules)
        applyHotkeys()
        observeSystem()
        configureGestures()

        // Once laid out, record where our items actually are, so later launches and new stats
        // items have a stable anchor even when no position was seeded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.recordPositionsIfMissing() }
        if firstRun {
            placementSettling = true
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
            storeOwnSeeds(seeds)
        } else {
            StatusBarController.clearStoredPositions(.standard)
        }
        settings.didPlaceItems = true
    }

    /// After (re)placing our items: the toggle must be drawn on every bar that draws anything (a
    /// notch or the front app's menus can crowd it out). macOS orders items by stored keys, which on
    /// a multi-display Mac don't always match geometry, so a seed can land further left than
    /// measured. Correct the toggle's key by the measured overshoot and try again (3 times at most).
    private func verifyFirstPlacement() {
        pendingPlacementCheck?.cancel()   // one check at a time
        pendingPlacementCheck = nil
        guard placementRetries < 3 else { placementSettling = false; return }
        let storedKey = UserDefaults.standard.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) as? Double
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        let toggle = bar.ownFrames().toggle
        var bars: [(screen: ScreenInfo, row: [WindowInfo], drawn: Bool?)] = []
        for screen in screens {
            let row = MenuBarGeometry.row(on: screen, windows: windows)
            guard row.contains(where: \.isOnScreen) else { continue }   // that bar is not visible right now
            bars.append((screen, row, ToggleVisibility.isDrawn(toggle, row: row, on: screen)
                ?? ToggleVisibility.besideCollapsedDivider(toggle, row: row, windows: windows, on: screen)?.isOnScreen))
        }
        // Measure once our items have stored positions, the stats items (which sit right of the
        // toggle and push it left) are in, and the bar has stopped moving: the toggle sits where
        // it sat half a second ago and every visible bar shows it, drawn or not. Laying out a few
        // new items on three displays takes macOS a couple of seconds.
        let arriving = stats.map { $0.awaitingItems || Date().timeIntervalSince($0.itemsCreatedAt) < 0.8 } ?? false
        // A bar that doesn't list the toggle at all is usually still laying out; past two seconds it
        // is one that can't draw it (then measured below like any other).
        let moving = toggle != lastMeasuredToggle || bars.contains { $0.drawn == nil } && placementWaits < 4
        lastMeasuredToggle = toggle
        if storedKey == nil || toggle.width <= 0 || arriving || moving, placementWaits < 30 {
            placementWaits += 1
            let check = DispatchWorkItem { [weak self] in self?.verifyFirstPlacement() }
            pendingPlacementCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
            return
        }
        placementWaits = 0
        lastMeasuredToggle = nil
        guard toggle.width > 0, let key = storedKey else { placementSettling = false; return }
        var overshoot: CGFloat = 0
        for (screen, row, drawn) in bars {
            guard drawn == false, let leftmost = row.first(where: \.isOnScreen) else { continue }
            // Drawing stops at the leftmost drawn icon: the toggle's left edge has to come back to it.
            let limit = MenuBarGeometry.rightDistance(of: leftmost.bounds, on: screen) + leftmost.bounds.width
            overshoot = max(overshoot, -toggle.minX - limit + 4)
        }
        guard overshoot > 0 else { placementSettling = false; return }
        placementRetries += 1
        bar.removeAllItems()
        stats?.removeItemsForReplacement()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.storeOwnSeeds(Placement.Seeds(anchorRightDistance: max(0.5, key - Double(overshoot))))
            self.bar.createItems(alwaysHidden: self.settings.alwaysHiddenEnabled)
            self.reveal.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.stats?.apply()
                self?.verifyFirstPlacement()
            }
        }
    }

    /// Deferred first-run placement: the notched bar is visible now and our items still have no
    /// stored positions (the user has not arranged them yet), so place them properly once.
    @discardableResult
    private func runPendingPlacementIfPossible() -> Bool {
        let stored = UserDefaults.standard.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) as? Double
        // A toggle the user has ⌘-dragged since (its key no longer the provisional one) stays put.
        let untouched = stored == nil || settings.provisionalToggleKey.map { abs($0 - stored!) < 0.001 } == true
        guard settings.placementPending, untouched else {
            settings.placementPending = false
            settings.provisionalToggleKey = nil
            return false
        }
        let windows = SystemQueries.windows(onScreenOnly: false)
        guard !notchedBarHidden(SystemQueries.screens(windows: windows), windows) else { return false }
        settings.placementPending = false
        settings.provisionalToggleKey = nil
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
        Toast.show(L("The BarTap button doesn't fit beside the notch. In Settings › Layout, move a few icons (stats items too) to Hidden."),
                   symbol: "exclamationmark.triangle")
    }

    func resetPositions() {
        resetCount += 1
        reveal.setCleanMode(false)
        reveal.resetRecheckBudget()
        bar.removeAllItems()
        // Stats items start next to the toggle again, at its new position.
        stats?.removeItemsForReplacement()
        StatusBarController.clearStoredPositions(.standard)
        placementRetries = 0
        placementWaits = 0
        lastMeasuredToggle = nil
        pendingPlacementCheck?.cancel()
        placementSettling = true
        // Wait for macOS to re-lay out the bar without our items before measuring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.seedInitialPositions(extraDrop: 0)
            self.bar.createItems(alwaysHidden: self.settings.alwaysHiddenEnabled)
            self.reveal.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.recordPositionsIfMissing()
                self?.stats?.apply()   // recreate stats items next to the new toggle position
                self?.verifyFirstPlacement()
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

    /// Without stored keys macOS may re-add our items in any order (a Control Center restart
    /// does), so record them once laid out. While a first-run placement waits for the notched
    /// bar, they are provisional (see runPendingPlacementIfPossible).
    private func recordPositionsIfMissing(attempt: Int = 0) {
        let d = UserDefaults.standard
        guard d.object(forKey: StatusBarController.preferredPositionKey("tb_toggle")) == nil else { return }
        guard reveal.layoutProblem == nil, let key = toggleOrderKey() else {
            // Not laid out yet (or briefly misreported): look again shortly.
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.recordPositionsIfMissing(attempt: attempt + 1) }
            }
            return
        }
        storeOwnSeeds(Placement.Seeds(anchorRightDistance: key))
    }

    /// Stores our items' positions. Keys BarTap writes while a first-run placement waits are
    /// provisional: that placement still runs unless the user moves the toggle meanwhile.
    private func storeOwnSeeds(_ seeds: Placement.Seeds) {
        StatusBarController.seed(seeds, in: .standard)
        if settings.placementPending { settings.provisionalToggleKey = seeds.toggle }
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
        alert.informativeText = L("• Choose which icons to hide in Settings › Layout, or hold ⌘ and drag them left of the │ divider yourself.\n• Click the BarTap toggle (or press ⌃⌥⌘B) to show or hide them.\n• Icons that were hidden behind the notch now start in the Hidden section.\n• Optional: allow Accessibility access to arrange icons in Settings › Layout, search icons (⌃⌥⌘F) and use the shelf below the menu bar.\n\nHiding never moves your pointer or blocks your clicks. Icons move only when you click Apply in Settings › Layout.")
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
        case .toggle:
            if reveal.isCleanMode { reveal.setCleanMode(false); return }
            // Opened some other way (hotkey, scroll, a rule): a click closes it, as before.
            if togglePresenter.model.shown == nil && toggleOpen { primaryToggle(source: .click) } else { togglePresenter.itemClicked("toggle") }
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
        case "hoverReveal", "hoverDelay", "scrollReveal", "emptyClickReveal", "revealWhileDragging", "toggleHoverOpen":
            configureGestures()
            applyToggleHover()
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
        case .downloadVideo:
            VideoDownloads.shared.showPanel()
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
        // Closed some other way (hotkey, a menu command, the shelf's own dismissal): so are the
        // button's hover/click rules.
        if level == .collapsed, shelfPanel?.isVisible != true, togglePresenter.model.shown != nil { togglePresenter.dismiss() }
        if level != lastLevelForStats {
            lastLevelForStats = level
            // Once macOS has laid the bar out again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateDormantStats() }
        }
    }

    private var lastLevelForStats: RevealLevel?

    // MARK: BarTap button: hover and click

    /// The BarTap button opens like a stats item's details: rest the pointer on it (for the hover
    /// delay) and the hidden icons, or the shelf, show until the pointer leaves them; click it and
    /// they stay until a click elsewhere. Same rules and code as the stats (HoverClickPresenter).
    private let togglePresenter = HoverClickPresenter()
    private let toggleLocator = StatusItemLocator()
    /// The open area in each menu bar, from the leftmost drawn icon to the button (cached ~1 s).
    private var toggleArea: (at: Date, rects: [CGRect])?

    private func configureTogglePresenter() {
        toggleLocator.items = { [weak self] in
            guard let w = self?.bar.toggleItem?.button?.window else { return [] }
            return [StatusItemHitTest.Item(id: "toggle", windowName: "tb_toggle", proxyFrame: SystemQueries.cgRect(fromCocoa: w.frame))]
        }
        togglePresenter.inBar = { [weak self] p in self?.toggleLocator.inMenuBar(p) ?? false }
        togglePresenter.locate = { [weak self] p in self?.toggleLocator.hit(at: p) }
        togglePresenter.contains = { [weak self] p in self?.toggleOpenArea(contains: p) ?? false }
        togglePresenter.open = { [weak self] _, _, _ in self?.openFromButton() }
        togglePresenter.close = { [weak self] in self?.closeFromButton() }
        applyToggleHover()
    }

    private func applyToggleHover() {
        var c = togglePresenter.config
        c.hoverEnabled = settings.toggleHoverOpen
        c.dwell = settings.hoverDelay
        if c != togglePresenter.config { togglePresenter.config = c }
        togglePresenter.hoverActive = settings.toggleHoverOpen
    }

    private var toggleOpen: Bool { reveal.effectiveLevel > .collapsed || shelfPanel?.isVisible == true }

    private func openFromButton() {
        toggleArea = nil
        if settings.shelfMode == .always { openShelf(); return }
        closeShelf()
        reveal.reveal(.revealed, source: .button)
        if settings.shelfMode == .whenCrowded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openShelfIfCrowded() }
        }
    }

    private func closeFromButton() {
        closeShelf()
        guard reveal.effectiveLevel > .collapsed, !reveal.model.layoutBlocked else { return }
        // A menu opened from one of the revealed icons keeps them out until it closes.
        if let busy = reveal.currentBusyReason(), busy == .menuOpen || busy == .popoverOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.togglePresenter.model.shown == nil else { return }
                self.closeFromButton()
            }
            return
        }
        reveal.collapseByUser()
    }

    /// Whether a point (global Cocoa) is where the opened icons are: the shelf (and the gap above
    /// it), or the stretch of menu bar from the leftmost drawn icon to the button.
    private func toggleOpenArea(contains p: NSPoint) -> Bool {
        if let shelf = shelfPanel, shelf.isVisible {
            var f = shelf.frame.insetBy(dx: -6, dy: -6)
            if let top = NSScreen.screens.first(where: { $0.frame.contains(p) || $0.frame.contains(shelf.frame.origin) })?.frame.maxY {
                f.size.height = max(f.height, top - f.minY)   // up to the menu bar it hangs from
            }
            if f.contains(p) { return true }
        }
        guard reveal.effectiveLevel > .collapsed else { return false }
        if toggleArea.map({ Date().timeIntervalSince($0.at) > 1 }) ?? true {
            let windows = SystemQueries.windows(onScreenOnly: false)
            let screens = SystemQueries.screens(windows: windows)
            let run = catalog.ownRun?()
            toggleArea = (Date(), screens.compactMap { s in
                guard !s.asleep, let t = run?.locate(on: s, windows: windows)?.toggle,
                      let left = MenuBarGeometry.row(on: s, windows: windows).first(where: \.isOnScreen) else { return nil }
                return CGRect(x: left.bounds.minX, y: s.frame.minY, width: t.maxX - left.bounds.minX, height: s.menuBarHeight)
            })
        }
        let cg = CGPoint(x: p.x, y: SystemQueries.mainScreenHeight - p.y)
        return toggleArea?.rects.contains { $0.contains(cg) } ?? false
    }

    /// Stats items the user put in a hidden section don't need redrawing while it is hidden.
    /// Decided only when certain: icons hidden, window names visible (Screen Recording) and the
    /// item left of the divider on an awake display. Otherwise every item keeps updating.
    private func updateDormantStats() {
        guard let stats else { return }
        guard reveal.effectiveLevel == .collapsed, !reveal.isCleanMode else { stats.dormant = []; return }
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        func awake(_ w: WindowInfo) -> Bool {
            screens.first(where: { $0.frame.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) })?.asleep == false
        }
        guard let divider = windows.first(where: { $0.layer == WindowLevel.status && $0.name == "tb_hidden" }), awake(divider) else {
            stats.dormant = []
            return
        }
        var dormant: Set<StatsModule> = []
        for w in windows where w.layer == WindowLevel.status && abs(w.bounds.minY - divider.bounds.minY) <= 1 {
            guard let name = w.name, name.hasPrefix("tb_stats_"), w.bounds.maxX <= divider.bounds.minX + 1,
                  let m = StatsModule(rawValue: String(name.dropFirst("tb_stats_".count))) else { continue }
            dormant.insert(m)
        }
        stats.dormant = dormant
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
        panel.onRequestImages = { ItemImages.request() }
        panel.onClosed = { [weak self] in
            guard let self else { return }
            self.configureGestures()
            // Closed on its own (an icon opened from it, a click elsewhere): so is the button's open state.
            if self.reveal.effectiveLevel == .collapsed, self.togglePresenter.model.shown != nil { self.togglePresenter.dismiss() }
        }
        shelfPanel = panel
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        guard let screen = SystemQueries.screen(containingCG: SystemQueries.pointerCG, in: screens) else { return }
        let toggle = bar.ownFrames().toggle
        let anchorX = toggle.width > 0 ? ToggleVisibility.toggleMaxX(toggle, on: screen) : screen.frame.maxX - 8
        // Only on the notched display itself (Accessibility reports icons in its coordinates when
        // it is the main display); elsewhere those icons are visible.
        let notch = screen.frame.origin == .zero ? screen.notch : nil
        let show = { [weak self] (items: [BarItem]) in
            // Hidden icons, plus shown ones that sit behind the notch (macOS draws them nowhere).
            let listed = items.filter { item in
                item.section != .shown || notch.map { $0.overlaps(item.frame.minX...item.frame.maxX) } == true
            }
            panel.present(items: listed, trusted: AXCatalog.isTrusted, on: screen, anchorX: anchorX,
                          appearance: self?.bar.toggleItem?.button?.effectiveAppearance)
            self?.configureGestures()
            // BarTap's own stats items as BarTap draws them (a hidden one is drawn nowhere to capture);
            // the others as last captured, then as drawn right now.
            let own = { [weak self] () -> [String: NSImage] in
                var out: [String: NSImage] = [:]
                for item in listed {
                    if let id = item.identifier, id.hasPrefix("bartap.stats."), let img = self?.statsItemImage(id) { out[item.slotKey] = img }
                }
                return out
            }
            panel.updateImages(ItemImages.cache.merging(own()) { $1 })
            ItemImages.capture(listed) { images in if panel.isVisible { panel.updateImages(images.merging(own()) { $1 }) } }
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
        if settings.videoDownloadsEnabled {
            m.addItem(item(VideoDownloads.menuTitle + hint(.downloadVideo)) { VideoDownloads.shared.showPanel() })
        }
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
                Memory.returnFreedPages(after: 1.0)
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

    func revealForLayout(_ on: Bool) { holdLayout("capture", on) }

    func setStatsSlim(_ on: Bool) { if !layoutApplier.running { stats?.slim = on } }

    var barCollapsed: Bool { reveal.effectiveLevel == .collapsed }

    func statsItemImage(_ identifier: String) -> NSImage? { stats?.itemImage(identifier) }

    /// Reveals every icon while anything holds the layout (the pane, a running Apply), and puts the
    /// bar back as it was once nothing does.
    private func holdLayout(_ reason: String, _ on: Bool) {
        let wasHeld = !layoutHolds.isEmpty
        if on { layoutHolds.insert(reason) } else { layoutHolds.remove(reason) }
        guard wasHeld != !layoutHolds.isEmpty else { return }
        if !wasHeld {
            levelBeforeLayoutPane = reveal.effectiveLevel
            reveal.reveal(.revealedAll, source: .command)
        } else if levelBeforeLayoutPane == .collapsed {
            reveal.collapseByUser()
        }
    }

    var menuBarIsDark: Bool {
        bar.toggleItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Settings › Layout's Apply: moves icons until the bar matches `request` (see LayoutApplier).
    func applyLayout(_ request: LayoutApplier.Request, progress: @escaping (Int, Int) -> Void, completion: @escaping (LayoutApplier.Report) -> Void) {
        guard !layoutApplier.running else { return }
        holdLayout("apply", true)
        // BarTap's own stats items step aside meanwhile (see StatsController.slim): a bar too narrow
        // for every icon (beside the notch) then draws them all, dividers included.
        stats?.slim = true
        lastLayoutApply = "running"
        // A bar that was just revealed (or rearranged) needs a moment to draw every icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.layoutApplier.run(request, progress: { [weak self] k, n in
                self?.lastLayoutApply = "running \(k)/\(n)"
                progress(k, n)
            }, completion: { [weak self] report in
                guard let self else { return }
                self.layoutApplyRuns += 1
                self.lastLayoutApply = "#\(self.layoutApplyRuns) \(report.finish) moves=\(report.moves) stuck=\(report.stuck.count) notDrawn=\(report.notDrawn.count) left=\(report.left) ["
                    + self.layoutApplier.log.joined(separator: "; ") + "]"
                self.stats?.slim = false
                // The pane captures the new order before the bar goes back (no flash in between).
                completion(report)
                self.holdLayout("apply", false)
            })
        }
    }

    func cancelLayoutApply() { layoutApplier.cancel() }

    func requestAccessibility() {
        AXCatalog.requestTrust()
        AXCatalog.openAccessibilitySettings()
        watchForTrust()
    }

    func statsSnapshot() -> StatsSnapshot? { stats?.latest }

    func rereadAIHistory() { stats?.rereadAIHistory() }

    func resetAccessibility() {
        AXCatalog.resetTrust()
        requestAccessibility()
    }

    /// After a request, notice the grant as soon as it happens (no relaunch needed). Polls once a
    /// second for at most three minutes, and only after the user asked for access.
    private func watchForTrust() {
        trustWatch?.invalidate()
        let deadline = Date().addingTimeInterval(180)
        trustWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            if AXCatalog.isTrusted {
                timer.invalidate()
                self?.trustWatch = nil
                NotificationCenter.default.post(name: .barTapTrustChanged, object: nil)
                Toast.show(L("Accessibility is on: search and the shelf are ready"), symbol: "checkmark.circle")
            } else if Date() > deadline {
                timer.invalidate()
                self?.trustWatch = nil
            }
        }
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
            "lastPress": catalog.lastPress,
            "memoryMB": ProcessStats.memoryMB(),
            "cpuSeconds": ProcessStats.cpuSeconds(),
            "settingsOpen": settingsWC != nil,
            "settingsControllersAlive": SettingsWindowController.liveCount,
            "resetCount": resetCount,
            "placementSettling": placementSettling,
            "layoutApply": lastLayoutApply,
            "layoutApplying": layoutApplier.running,
            "layoutPaneOpen": layoutHolds.contains("capture"),
            "crowding": barCollapsed ? (LayoutPaneModel.crowdedDisplays() ?? "") : "",
            "button": togglePresenter.debugInfo.merging(["source": reveal.model.userSource?.rawValue ?? ""]) { a, _ in a },
            // Displays that draw BarTap's run (toggle, then every stats item) by exact window widths.
            "ownRunOn": { () -> [Int] in
                let windows = SystemQueries.windows(onScreenOnly: false)
                guard let run = catalog.ownRun?() else { return [] }
                return SystemQueries.screens(windows: windows).filter { run.locate(on: $0, windows: windows) != nil }.map { Int($0.id) }
            }(),
            "screenRecording": ItemImages.permitted,
            // macOS's padding around each of our items (window width = length + this).
            "itemSpacing": UserDefaults.standard.integer(forKey: "NSStatusItemSpacing"),
            "imageCache": ItemImages.cache.count,
            "captureLog": ItemImages.lastLog,
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

    func debugToggleClick() { handleClick(.toggle) }

    func debugOwnWindowNumbers() -> [String: Any] {
        func info(_ item: NSStatusItem?) -> [String: Any] {
            guard let w = item?.button?.window else { return [:] }
            return ["number": w.windowNumber, "x": Double(w.frame.minX), "w": Double(w.frame.width)]
        }
        var out: [String: Any] = ["toggle": info(bar.toggleItem), "hidden": info(bar.hiddenItem)]
        for (name, item) in stats?.debugItems() ?? [] { out[name] = info(item) }
        return out
    }

    /// What Accessibility sees in the menu bar, as JSON (debug; local only).
    func debugCatalog() {
        catalog.snapshot { items in
            let rows = items.map { ["app": $0.appName, "section": "\($0.section)", "rd": Int($0.order), "key": $0.slotKey, "id": $0.identifier ?? ""] as [String: Any] }
            let url = DebugRender.dir.deletingLastPathComponent().appendingPathComponent("catalog-classified.json")
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? data.write(to: url) }
        }
        catalog.rawDump { rows in
            let screens = SystemQueries.screens().map { ["x": Double($0.frame.minX), "y": Double($0.frame.minY), "w": Double($0.frame.width),
                                                         "h": Double($0.frame.height), "bar": Double($0.menuBarHeight)] }
            let url = DebugRender.dir.deletingLastPathComponent().appendingPathComponent("catalog.json")
            if let data = try? JSONSerialization.data(withJSONObject: ["items": rows, "screens": screens], options: [.prettyPrinted]) {
                try? data.write(to: url)
            }
        }
    }

    /// Opens the first icon whose app name matches, the way the shelf does (debug).
    func debugPress(_ appName: String) {
        catalog.snapshot { [weak self] items in
            let matches = items.filter { $0.appName.localizedCaseInsensitiveContains(appName) }
            guard let item = matches.first(where: { $0.section != .shown }) ?? matches.first else { return }
            self?.activate(item)
        }
    }

    /// Closes an open menu through Accessibility (AXCancel), never with synthetic keys (debug).
    func debugCloseMenu() {
        catalog.cancelOpenMenu()
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let start = focused, CFGetTypeID(start) == AXUIElementGetTypeID() else { return }
        var element = start as! AXUIElement
        for _ in 0..<6 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXMenuRole { AXUIElementPerformAction(element, kAXCancelAction as CFString); return }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let p = parent,
                  CFGetTypeID(p) == AXUIElementGetTypeID() else { return }
            element = p as! AXUIElement
        }
    }

    /// Renders the shelf's current content to PNG (debug).
    func debugRenderShelf() {
        guard let panel = shelfPanel, panel.isVisible, let content = panel.contentView else { return }
        // As shown, then in both appearances (the shelf follows the menu bar's).
        let shown = panel.appearance
        for (name, look) in [("shelf", shown), ("shelf_light", NSAppearance(named: .aqua)), ("shelf_dark", NSAppearance(named: .darkAqua))] {
            panel.appearance = look
            content.display()
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            if let rep { content.cacheDisplay(in: content.bounds, to: rep) }
            DebugRender.write(rep, name)
        }
        panel.appearance = shown
    }

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
        // The element editor sheet, for one module with a custom combination.
        let editor = StatsElementEditor(module: .memory, settings: settings, liveSnapshot: { [weak self] in self?.stats?.latest })
        if let content = editor.window?.contentView {
            for dark in [false, true] { DebugRender.view(content, "settings_editor_\(dark ? "dark" : "light")", dark: dark) }
        }
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
    private static var pane: LayoutPaneModel?

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
        case "catalog":
            app.debugCatalog()
        case "shelf-render":
            app.debugRenderShelf()
        case let w where w.hasPrefix("press-"):
            app.debugPress(String(w.dropFirst("press-".count)))
        case "close-menu":
            app.debugCloseMenu()
        case "layout-render":
            // The Settings › Layout editor as it would show now, rendered to a file (debug).
            let model = LayoutPaneModel(host: app)
            model.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                for dark in [false, true] { DebugRender.view(model.editor, "layout_editor_\(dark ? "dark" : "light")", dark: dark) }
                model.stop()
            }
        case "layout-page-open":
            // Settings › Layout's model as the pane runs it, without the window (debug).
            pane = LayoutPaneModel(host: app)
            pane?.start()
        case "layout-page-close":
            pane?.stop()
            pane = nil
        case "layout-open":
            app.revealForLayout(true)
        case "layout-close":
            app.revealForLayout(false)
        case "layout-apply":
            // Apply the rows in layout-request.json ({"shown": [keys], "hidden": [...], "always": [...], "pinned": [...]},
            // keys as in catalog-classified.json), as Settings › Layout's Apply does (debug).
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("layout-request.json")),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { break }
            let wanted = LayoutArrangement(shown: rows["shown"] ?? [], hidden: rows["hidden"] ?? [], always: rows["always"] ?? [], pinned: rows["pinned"] ?? [])
            let touched = Set(wanted.shown + wanted.hidden + wanted.always)
            app.applyLayout(.init(arrangement: wanted, alwaysSection: app.settings.alwaysHiddenEnabled, touched: touched), progress: { _, _ in }, completion: { _ in })
        case "layout-cancel":
            app.cancelLayoutApply()
        case let w where w.hasPrefix("stats-details-"):
            // A stats item's details, as a click opens them ("stats-details-close" closes them).
            app.stats?.debugShowDetails(String(w.dropFirst("stats-details-".count)))
        case "toggle-click":
            // The BarTap button's click, as from its button (debug).
            app.debugToggleClick()
        case "slim-on", "slim-off":
            app.stats?.slim = what == "slim-on"
        case "own-windows":
            // BarTap's in-process window numbers next to the window server's status windows (debug).
            let own = app.debugOwnWindowNumbers()
            let rows = SystemQueries.windows(onScreenOnly: false).filter { $0.layer == WindowLevel.status }.map {
                ["id": Int($0.id), "name": $0.name ?? "", "x": Double($0.bounds.minX), "y": Double($0.bounds.minY), "w": Double($0.bounds.width), "on": $0.isOnScreen] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["own": own, "windows": rows], options: [.prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("own-windows.json"))
            }
        default:
            break
        }
    }
}
