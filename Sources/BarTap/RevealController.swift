import AppKit
import BarTapCore

/// Drives `RevealModel` and applies it to the status items, enforcing the safety rules:
///   * never collapse unless our dividers are verifiably in the right order (fail open);
///   * after collapsing, confirm the toggle is still drawn somewhere, else re-open;
///   * never re-hide while a menu/popover from the menu bar is open or the pointer is in the bar.
/// All timers are one-shot and only exist while something is revealed; idle cost is zero.
final class RevealController {
    private(set) var model = RevealModel()
    private let bar: StatusBarController
    private let settings: Settings

    private(set) var appliedLevel: RevealLevel?
    private(set) var layoutProblem: LayoutProblem?
    private(set) var toggleUndrawn = false
    private var blockedUntil = Date.distantPast
    /// macOS drew a collapsed divider on a display (seen once in testing on macOS 26).
    private(set) var dividerTakeover = false
    private var rehideTimer: Timer?
    private var busyStreak = false
    private var recheckCount = 0
    private var retryWork: DispatchWorkItem?
    private var watchdogWork: DispatchWorkItem?
    private(set) var lastBusyReason: InteractionDetector.Reason?
    /// Recent watchdog findings (debug dump), newest last.
    private(set) var watchdogLog: [String] = []
    private func log(_ s: String) {
        watchdogLog.append(String(format: "%.1f ", ProcessInfo.processInfo.systemUptime) + s)
        if watchdogLog.count > 30 { watchdogLog.removeFirst() }
    }

    /// Called after every applied change (icons, menus, shelf follow from here).
    var onChange: (() -> Void)?
    /// True while one of our own panels (search, shelf) is on screen.
    var ownPanelVisible: () -> Bool = { false }

    init(bar: StatusBarController, settings: Settings) {
        self.bar = bar
        self.settings = settings
    }

    var effectiveLevel: RevealLevel { appliedLevel ?? .revealedAll }
    var isCleanMode: Bool { bar.isCleanModeOn }

    // MARK: Events

    func toggle(source: RevealSource) { clearCooldownOnUserIntent(source); model.toggle(source: source); commit() }
    func toggleAll(source: RevealSource) { clearCooldownOnUserIntent(source); model.toggleAll(source: source); commit() }
    func reveal(_ level: RevealLevel, source: RevealSource) { model.reveal(level, source: source); commit() }
    func collapseByUser() { clearCooldownOnUserIntent(.command); model.collapseByUser(); commit() }

    /// An explicit request to hide overrides a watchdog cooldown (the user can see the result).
    private func clearCooldownOnUserIntent(_ source: RevealSource) {
        guard toggleUndrawn, [.click, .hotkey, .command, .button].contains(source) else { return }
        toggleUndrawn = false
        blockedUntil = .distantPast
    }
    func setRuleLevel(_ level: RevealLevel) { model.setRuleLevel(level); commit() }
    func setArranging(_ on: Bool) {
        guard model.arranging != on else { return }
        model.setArranging(on)
        // The user just rearranged icons: whatever made the toggle undrawn may be fixed.
        if !on { toggleUndrawn = false; recheckCount = 0 }
        commit()
    }

    /// Re-validate and re-apply (settings changed, displays changed, woke from sleep, …).
    func refresh() {
        appliedLevel = nil
        recheckCount = 0
        toggleUndrawn = false
        dividerTakeover = false
        commit()
    }

    func setCleanMode(_ on: Bool) {
        bar.setCleanMode(on, showExit: settings.cleanShowsExitButton)
        onChange?()
    }

    /// Hover-revealed icons go away shortly after the pointer leaves the bar.
    func pointerLeftMenuBar() {
        guard model.userSource == .hover, model.userLevel > .collapsed else { return }
        scheduleRehide(after: 0.45)
    }

    // MARK: Commit

    private(set) var commits = 0
    private(set) var watchdogRuns = 0

    private func commit() {
        commits += 1
        let frames = bar.ownFrames()
        let wantsCollapse = model.effectiveLevel < .revealedAll || (model.layoutBlocked && !model.arranging)
        if wantsCollapse || model.layoutBlocked {
            // The watchdog saw the toggle vanish after collapsing: stay open (no collapse/expand
            // cycle) until a refresh or a rearrangement clears it.
            if toggleUndrawn && Date() >= blockedUntil { toggleUndrawn = false }   // cooldown over: try again
            let problem = toggleUndrawn ? .hiddenRightOfToggle : LayoutValidator.check(frames, keys: bar.ownKeys())
            layoutProblem = problem
            model.layoutBlocked = problem != nil
            // Frames can be mid-layout right after items are created or displays change; look
            // again a few times before believing a problem (and stay open meanwhile).
            if problem != nil && !toggleUndrawn { scheduleRecheck() } else if problem == nil { recheckCount = 0 }
        }
        let target = model.effectiveLevel
        let previous = appliedLevel
        if target != previous {
            bar.apply(level: target, showDividers: settings.showDivider || model.arranging)
            appliedLevel = target
            // Verify after every collapse and after every re-apply (refresh) that leaves icons hidden.
            if target < .revealedAll && (previous == nil || target < previous!) { scheduleWatchdog() }
        }
        scheduleRehideForCurrentReveal()
        onChange?()
    }

    private func scheduleRecheck() {
        let notReady = layoutProblem == .notReady
        // Fast at first. If the bar is still not laid out (a busy login can take longer than 10 s),
        // keep looking every 2 s for a few more minutes instead of staying open for good.
        let fast = notReady ? 40 : 8
        let limit = notReady ? fast + 90 : fast
        guard recheckCount < limit else { return }
        recheckCount += 1
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit() }
        retryWork = work
        let delay = recheckCount > fast ? 2.0 : (notReady ? 0.25 : 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Clears the recheck budget, e.g. after the user repaired the layout.
    func resetRecheckBudget() { recheckCount = 0 }

    // MARK: Re-hide

    private func scheduleRehideForCurrentReveal() {
        guard model.userLevel > .collapsed,
              let delay = RehidePolicy.delay(for: model.userSource, autoRehide: settings.autoRehide, delay: settings.rehideDelay)
        else {
            rehideTimer?.invalidate()
            rehideTimer = nil
            return
        }
        // Keep a running timer: re-clicking or repeated hover events must not keep pushing it out.
        if rehideTimer == nil { scheduleRehide(after: delay) }
    }

    private func scheduleRehide(after delay: TimeInterval) {
        rehideTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.rehideFired() }
        t.tolerance = min(0.25, delay * 0.1)
        RunLoop.main.add(t, forMode: .common)
        rehideTimer = t
    }

    private func rehideFired() {
        rehideTimer = nil
        guard model.userLevel > .collapsed else { return }
        if let reason = currentBusyReason() {
            lastBusyReason = reason
            busyStreak = true
            scheduleRehide(after: RehidePolicy.busyRecheck)
            return
        }
        lastBusyReason = nil
        if busyStreak {
            busyStreak = false
            scheduleRehide(after: RehidePolicy.afterMenuGrace)
            return
        }
        model.autoRehide()
        commit()
    }

    func currentBusyReason() -> InteractionDetector.Reason? {
        let windows = SystemQueries.windows(onScreenOnly: true)
        let context = InteractionDetector.Context(
            windows: windows,
            screens: SystemQueries.screens(windows: windows),
            pointer: SystemQueries.pointerCG,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            ownPanelVisible: ownPanelVisible())
        return InteractionDetector.busyReason(context)
    }

    // MARK: Watchdog

    /// After hiding, make sure the toggle itself is still drawn on at least one display whose
    /// menu bar is visible. If not (icons were ⌘-dragged into a bad order), re-open everything.
    private func scheduleWatchdog(attempt: Int = 0) {
        watchdogWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runWatchdog(attempt: attempt) }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.35 : 0.7), execute: work)
    }

    /// Three consecutive bad readings (~1.75 s) are required before acting: other apps re-laying
    /// out the bar (iStat-style items change width every second) can make a single snapshot of
    /// window positions inconsistent.
    private func runWatchdog(attempt: Int) {
        watchdogRuns += 1
        guard !bar.isCleanModeOn, (appliedLevel ?? .revealedAll) < .revealedAll else { return }
        let confirmations = 3
        if let where_ = ToggleVisibility.collapsedDividerDrawnDescription() {
            log("divider drawn (#\(attempt + 1)): \(where_)")
            // macOS drew a collapsed divider (and hid the icons beside it) on some display.
            // Nudge the layout once; if it persists, open everything up for a while.
            if attempt == 0 { bar.nudgeCollapsed() }
            if attempt + 1 < confirmations { scheduleWatchdog(attempt: attempt + 1); return }
            dividerTakeover = true
            failOpen(for: 60)
            return
        }
        switch ToggleVisibility.check(bar.ownFrames().toggle) {
        case .drawn, .inconclusive:
            break
        case .undrawnEverywhere:
            log("toggle undrawn everywhere (#\(attempt + 1)) rd=\(Int(-bar.ownFrames().toggle.maxX))")
            if attempt + 1 < confirmations { scheduleWatchdog(attempt: attempt + 1); return }
            failOpen(for: 60)
        }
    }

    /// Show everything and refuse to collapse for `seconds` (or until the user explicitly asks
    /// again, or something changes the layout).
    private func failOpen(for seconds: TimeInterval) {
        toggleUndrawn = true
        blockedUntil = Date().addingTimeInterval(seconds)
        layoutProblem = .hiddenRightOfToggle
        model.layoutBlocked = true
        bar.apply(level: .revealedAll, showDividers: true)
        appliedLevel = .revealedAll
        onChange?()
    }
}

/// Is our toggle actually drawn? Uses public window geometry only. `toggle` is a normalized
/// frame from `StatusBarController.ownFrames()` (x = −distance from the bar's right edge).
enum ToggleVisibility {
    enum Result { case drawn, undrawnEverywhere, inconclusive }

    static func check(_ toggle: CGRect) -> Result {
        // A just-created item reports the rightmost slot until macOS lays it out; that slot is
        // always Control Center's, so it says nothing about the toggle.
        guard toggle.width > 0, -toggle.maxX >= 1 else { return .inconclusive }
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        var conclusiveUndrawn = 0
        for s in screens {
            let row = MenuBarGeometry.row(on: s, windows: windows)
            guard row.contains(where: { $0.isOnScreen }) else { continue }   // bar hidden (full screen, auto-hide)
            switch isDrawn(toggle, row: row, on: s) ?? besideCollapsedDivider(toggle, row: row, windows: windows, on: s)?.isOnScreen {
            case true?: return .drawn
            case false?: conclusiveUndrawn += 1
            case nil:
                // No window at the toggle's slot. Conclusive only if the row was read past it
                // (otherwise the walk stopped early on a mid-layout gap).
                let rd = -toggle.maxX
                if let leftmost = row.first, MenuBarGeometry.rightDistance(of: leftmost.bounds, on: s) > rd + toggle.width + 2 {
                    conclusiveUndrawn += 1
                } else {
                    return .inconclusive
                }
            }
        }
        return conclusiveUndrawn > 0 ? .undrawnEverywhere : .inconclusive
    }

    /// Is the toggle drawn on this display? (nil = no window found at its slot)
    static func isDrawn(_ toggle: CGRect, row: [WindowInfo], on screen: ScreenInfo) -> Bool? {
        guard toggle.width > 0 else { return nil }
        return MenuBarGeometry.window(atRightDistance: -toggle.maxX, width: toggle.width, on: screen, in: row, tolerance: 5)?.isOnScreen
    }

    /// The toggle when its proxy frame is stale (seen on macOS 26 after a relaunch, off by ~20 pt):
    /// while collapsed it is the item touching the right edge of our collapsed divider, where the
    /// row walk stops. Width must match closely and the slot must be near the proxy's.
    static func besideCollapsedDivider(_ toggle: CGRect, row: [WindowInfo], windows: [WindowInfo], on screen: ScreenInfo) -> WindowInfo? {
        guard toggle.width > 0, let first = row.first, abs(first.bounds.width - toggle.width) <= 1.5,
              abs(MenuBarGeometry.rightDistance(of: first.bounds, on: screen) - (-toggle.maxX)) <= 48 else { return nil }
        let touchesDivider = windows.contains {
            $0.layer == WindowLevel.status && $0.bounds.width >= separatorWidthThreshold
                && abs($0.bounds.minY - screen.frame.minY) <= 1 && abs($0.bounds.maxX - first.bounds.minX) <= 2.5
        }
        return touchesDivider ? first : nil
    }

    /// A collapsed divider can never fit, so it must never be drawn. If one is drawn, macOS chose
    /// to show it instead of the icons around it.
    static func collapsedDividerDrawn() -> Bool { collapsedDividerDrawnDescription() != nil }

    static func collapsedDividerDrawnDescription() -> String? {
        let windows = SystemQueries.windows(onScreenOnly: false)
        let screens = SystemQueries.screens(windows: windows)
        for w in windows where w.layer == WindowLevel.status && w.isOnScreen && w.bounds.width >= separatorWidthThreshold {
            if let s = screens.first(where: { abs($0.frame.minY - w.bounds.minY) <= 1 }) {
                return "screen x=\(Int(s.frame.minX)) w=\(Int(s.frame.width)): window x=\(Int(w.bounds.minX)) w=\(Int(w.bounds.width))"
            }
        }
        return nil
    }

    /// The toggle's x (CG) on a given display.
    static func toggleMaxX(_ toggle: CGRect, on screen: ScreenInfo) -> CGFloat {
        screen.frame.maxX + toggle.maxX
    }
}
