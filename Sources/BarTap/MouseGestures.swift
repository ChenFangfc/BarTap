import AppKit
import BarTapCore

/// Optional reveal gestures (hover, scroll, click on empty bar space, ⌘-drag arranging).
///
/// Uses *passive* global monitors only: we observe a copy of each event after the system has
/// delivered it, so we can never block, delay, move or alter the pointer. Monitors are installed
/// only for the gestures the user enabled; with none enabled nothing is installed at all.
final class MouseGestures {
    struct Config: Equatable {
        var hover = false
        var hoverDelay: TimeInterval = 0.3
        var scroll = false
        var emptyClick = false
        var arrangeOnCommandDrag = false
        var dismissShelfOnOutsideClick = false
    }

    var onHoverReveal: (() -> Void)?
    var onPointerLeftBar: (() -> Void)?
    var onScrollToggle: ((_ reveal: Bool) -> Void)?
    var onEmptyClick: (() -> Void)?
    var onArranging: ((Bool) -> Void)?
    var onOutsideClick: ((CGPoint) -> Void)?
    /// Supplies x-ranges in a bar that are *not* empty (app menus) for the given screen.
    var occupiedProvider: ((ScreenInfo) -> [ClosedRange<CGFloat>]?)?

    private var config = Config()
    private var monitors: [Any] = []
    private var screens: [ScreenInfo] = []
    private var statusRowsCache: (time: Date, rows: [UInt32: ClosedRange<CGFloat>])?
    private var hoverWork: DispatchWorkItem?
    private var pointerInBar = false
    private var lastScrollToggle = Date.distantPast
    private var arranging = false
    private var arrangeEndWork: DispatchWorkItem?

    func configure(_ c: Config) {
        guard c != config || (monitors.isEmpty && needsMonitors(c)) else { return }
        config = c
        reinstall()
    }

    func screensChanged() {
        screens = SystemQueries.screens(windows: SystemQueries.windows(onScreenOnly: false))
        statusRowsCache = nil
    }

    private func needsMonitors(_ c: Config) -> Bool {
        c.hover || c.scroll || c.emptyClick || c.arrangeOnCommandDrag || c.dismissShelfOnOutsideClick
    }

    private func reinstall() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        hoverWork?.cancel()
        hoverWork = nil
        guard needsMonitors(config) else { return }
        if screens.isEmpty { screensChanged() }

        if config.hover {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in self?.moved(e) }) {
                monitors.append(m)
            }
        }
        if config.scroll {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] e in self?.scrolled(e) }) {
                monitors.append(m)
            }
        }
        if config.emptyClick || config.arrangeOnCommandDrag || config.dismissShelfOnOutsideClick {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in self?.down(e) }) {
                monitors.append(m)
            }
        }
        if config.arrangeOnCommandDrag {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in self?.up(e) }) {
                monitors.append(m)
            }
        }
    }

    // MARK: Geometry

    private func pointerCG() -> CGPoint { SystemQueries.pointerCG }

    private func barScreen(at p: CGPoint) -> ScreenInfo? {
        screens.first { $0.containsMenuBarPoint(p, slop: 1) }
    }

    /// x-range covered by drawn status icons on each display (refreshed at most once a second,
    /// and only while the pointer is actually inside a menu bar).
    private func statusRange(for screen: ScreenInfo) -> ClosedRange<CGFloat>? {
        if let c = statusRowsCache, Date().timeIntervalSince(c.time) < 1 { return c.rows[screen.id] }
        let windows = SystemQueries.windows(onScreenOnly: false)
        var rows: [UInt32: ClosedRange<CGFloat>] = [:]
        for s in screens {
            let drawn = MenuBarGeometry.row(on: s, windows: windows).filter { $0.isOnScreen }
            if let first = drawn.first, let last = drawn.last { rows[s.id] = first.bounds.minX...last.bounds.maxX }
        }
        statusRowsCache = (Date(), rows)
        return rows[screen.id]
    }

    /// Empty bar space: not over a status icon, not over the notch, and not over app menus.
    func isEmptyBarSpace(_ p: CGPoint, on screen: ScreenInfo) -> Bool {
        if let n = screen.notch, n.contains(p.x) { return false }
        if let r = statusRange(for: screen), p.x >= r.lowerBound - 2 { return false }
        if let occupied = occupiedProvider?(screen) {
            return !occupied.contains { $0.contains(p.x) }
        }
        // Without app-menu geometry, only the part right of the notch (or the right third of
        // the bar) is safely known to be empty.
        if let n = screen.notch { return p.x > n.upperBound }
        return p.x > screen.frame.minX + screen.frame.width * 2 / 3
    }

    // MARK: Handlers

    private func moved(_ e: NSEvent) {
        let p = pointerCG()
        guard let screen = barScreen(at: p) else {
            if pointerInBar {
                pointerInBar = false
                hoverWork?.cancel()
                hoverWork = nil
                onPointerLeftBar?()
            }
            return
        }
        pointerInBar = true
        guard isEmptyBarSpace(p, on: screen) else { hoverWork?.cancel(); hoverWork = nil; return }
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            let now = self.pointerCG()
            if let s = self.barScreen(at: now), self.isEmptyBarSpace(now, on: s) { self.onHoverReveal?() }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.hoverDelay, execute: work)
    }

    private func scrolled(_ e: NSEvent) {
        guard barScreen(at: pointerCG()) != nil else { return }
        // One toggle per gesture: ignore momentum and the rest of the same swipe.
        guard e.momentumPhase == [] else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScrollToggle) > 0.6 else { return }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        guard max(abs(dx), abs(dy)) > 0.5 else { return }
        lastScrollToggle = now
        // Down/left (in natural-scrolling terms, content moving right) reveals; up/right hides.
        let natural = e.isDirectionInvertedFromDevice
        let primary = abs(dy) >= abs(dx) ? dy : -dx
        let reveal = natural ? primary < 0 : primary > 0
        onScrollToggle?(reveal)
    }

    private func down(_ e: NSEvent) {
        let p = pointerCG()
        let screen = barScreen(at: p)
        if config.dismissShelfOnOutsideClick, screen == nil { onOutsideClick?(p) }
        guard e.type == .leftMouseDown, let screen else { return }
        if config.arrangeOnCommandDrag, e.modifierFlags.contains(.command) {
            arrangeEndWork?.cancel()
            arrangeEndWork = nil
            arranging = true
            onArranging?(true)
            return
        }
        if config.emptyClick, isEmptyBarSpace(p, on: screen) { onEmptyClick?() }
    }

    private func up(_ e: NSEvent) {
        guard arranging else { return }
        arranging = false
        // Give macOS a moment to settle the drop before we re-validate the order. A new ⌘-drag
        // starting meanwhile cancels this.
        let work = DispatchWorkItem { [weak self] in
            self?.arrangeEndWork = nil
            self?.onArranging?(false)
        }
        arrangeEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
