import AppKit
import BarTapCore

/// Finds BarTap's own status items under the pointer on any display (StatusItemHitTest), from a
/// cached list of on-screen windows (~0.6 ms to read, vs ~14 ms for every window): refreshed at
/// most once a second, only when asked about a point inside a menu bar, and at once after the
/// displays change. Nothing here needs a permission; window names (exact matches) need Screen
/// Recording, without it items are matched by their slot.
final class StatusItemLocator {
    /// Our items: id, window (autosave) name and in-process frame, asked for on each refresh.
    var items: () -> [StatusItemHitTest.Item] = { [] }
    private var screens: [ScreenInfo] = []
    private var windows: [WindowInfo] = []
    private var refreshedAt = -Double.infinity
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func invalidate() {
        screens = []
        refreshedAt = -Double.infinity
    }

    /// Forces the next hit test to read the window list again (debug, measurements).
    func expire() { refreshedAt = -Double.infinity }

    /// Whether a point (global CG) is in any display's menu bar (cheap; no window list).
    func inMenuBar(_ p: CGPoint) -> Bool {
        if screens.isEmpty { screens = SystemQueries.screens() }
        return screens.contains { $0.containsMenuBarPoint(p) }
    }

    /// Our item under a point (global CG) and its frame on that display.
    func hit(at p: CGPoint) -> StatusItemHitTest.Hit? {
        guard inMenuBar(p) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if now - refreshedAt >= 1 {
            // Only drawn icons can be under the pointer. (Displays are re-read on change only.)
            windows = SystemQueries.windows(onScreenOnly: true).filter { $0.layer == WindowLevel.status }
            refreshedAt = now
        }
        return StatusItemHitTest.hit(at: p, screens: screens, windows: windows, items: items())
    }
}

/// Opens one item's details on hover or click and closes them by the rules of HoverClickModel:
/// passive NSEvent monitors (never posting, blocking or moving anything) plus timers.
///
/// - The pointer monitors (global + local mouseMoved) run only while `hoverActive` is on. The
///   handler is a point-in-menu-bar test and, inside a bar, a hit test on a cached window list.
///   While the pointer is inside a menu bar it is also re-read every 0.1 s, so a rest is noticed
///   even where the window under it sends no move events.
/// - The outside-click monitors (global + local mouse-down) run only while details are open.
/// - Clicks on the items themselves come in through `itemClicked(_:)` (their button action).
///
/// The owner says where its items are (`locate`, `inBar`), whether a point is inside the open
/// details (`contains`), and performs `open`, `pin` and `close`.
final class HoverClickPresenter {
    typealias Model = HoverClickModel<String>

    /// Where the pointer is (global CG). Replaceable for headless checks.
    var pointer: () -> CGPoint = { SystemQueries.pointerCG }
    /// Our item under a global CG point, and its frame there (for placing the details).
    var locate: (CGPoint) -> StatusItemHitTest.Hit? = { _ in nil }
    /// Whether a global CG point is inside any display's menu bar (cheap).
    var inBar: (CGPoint) -> Bool = { _ in false }
    /// Whether a global Cocoa point is inside the open details, or the gap between them and their item.
    var contains: (NSPoint) -> Bool = { _ in false }
    /// Show an item's details, closing any others first. `frame`: the item on the display under
    /// the pointer (global CG), if known.
    var open: (_ id: String, _ mode: Model.Mode, _ frame: CGRect?) -> Void = { _, _, _ in }
    var pin: () -> Void = {}
    var close: () -> Void = {}

    private(set) var model = Model()
    private var pointerMonitors: [Any] = []
    private var clickMonitors: [Any] = []
    private var deadlineWork: DispatchWorkItem?
    private var scheduledFor: TimeInterval?
    private var barWatch: Timer?
    private var lastOutsideClose: (id: String, at: TimeInterval)?
    private var lastPoint: CGPoint?
    /// Where the pointer last found one of our items (for placing the details it opens).
    private var lastHit: StatusItemHitTest.Hit?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var config: Model.Config {
        get { model.config }
        set { model.config = newValue }
    }

    /// Hover tracking on or off (off: only clicks open details).
    var hoverActive = false {
        didSet {
            guard hoverActive != oldValue else { return }
            for m in pointerMonitors { NSEvent.removeMonitor(m) }
            pointerMonitors.removeAll()
            guard hoverActive else {
                watchBar(false)
                // Nothing would close hover-opened details any more.
                if model.shown?.mode == .hover { dismiss() }
                return
            }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in self?.sample() }) {
                pointerMonitors.append(m)
            }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in self?.sample(); return e }) {
                pointerMonitors.append(m)
            }
        }
    }

    /// Monitors and timers that are running (debug).
    var debugInfo: [String: Any] {
        ["hoverMonitors": pointerMonitors.count, "clickMonitors": clickMonitors.count, "barWatch": barWatch != nil,
         "shown": model.shown.map { "\($0.target):\($0.mode)" } ?? "-"]
    }

    deinit {
        for m in pointerMonitors + clickMonitors { NSEvent.removeMonitor(m) }
        barWatch?.invalidate()
        deadlineWork?.cancel()
    }

    // MARK: Inputs

    /// A click on one of the items (from its button's action).
    func itemClicked(_ id: String) {
        // The outside-click monitor may have seen this very click first (if it couldn't tell it
        // was on the item) and closed the details: then it was meant to close them.
        if let c = lastOutsideClose, c.id == id, now - c.at < 0.4 { lastOutsideClose = nil; return }
        let hit = locate(pointer())
        lastHit = hit?.id == id ? hit : nil
        perform(model.click(on: id, now: now))
    }

    /// Close the details for another reason (item removed, settings, an alert that needs the screen).
    func dismiss() { perform(model.dismiss()) }

    /// Reads the pointer: on every move, at deadlines, and every 0.1 s while it is in a menu bar
    /// (that one does nothing while the pointer stays put and nothing is pending).
    func sample() { sample(watching: false) }

    private func sample(watching: Bool) {
        let p = pointer()
        if watching, p == lastPoint, model.deadline == nil { return }
        lastPoint = p
        let bar = inBar(p)
        if hoverActive { watchBar(bar) }
        let hit = bar ? locate(p) : nil
        if let hit { lastHit = hit }
        let inside = model.shown != nil && contains(SystemQueries.cocoaPoint(fromCG: p))
        perform(model.pointer(.init(point: p, item: hit?.id, inPanel: inside), now: now))
    }

    // MARK: Effects

    private func perform(_ effects: [Model.Effect]) {
        for e in effects {
            switch e {
            case .open(let id, let mode):
                open(id, mode, lastHit?.id == id ? lastHit?.frame : nil)
                setClickMonitors(true)
                // Where is the pointer now that the details are there (starts the grace if it isn't
                // on either)? After this round of effects, not inside it.
                DispatchQueue.main.async { [weak self] in self?.sample() }
            case .pin:
                pin()
            case .close:
                close()
                setClickMonitors(false)
            }
        }
        schedule()
    }

    private func schedule() {
        let due = model.deadline
        guard due != scheduledFor else { return }
        deadlineWork?.cancel()
        deadlineWork = nil
        scheduledFor = due
        guard let due else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.deadlineWork = nil
            self?.scheduledFor = nil
            self?.sample()
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, due - now), execute: work)
    }

    private func watchBar(_ on: Bool) {
        if on, barWatch == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample(watching: true) }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            barWatch = t
        } else if !on, let t = barWatch {
            t.invalidate()
            barWatch = nil
        }
    }

    private func setClickMonitors(_ on: Bool) {
        if !on {
            for m in clickMonitors { NSEvent.removeMonitor(m) }
            clickMonitors.removeAll()
            return
        }
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseDown() }) {
            clickMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseDown(); return e }) {
            clickMonitors.append(m)
        }
    }

    /// A mouse-down anywhere while details are open: outside both them and our items closes them.
    private func mouseDown() {
        guard let open = model.shown else { return }
        let p = pointer()
        if contains(SystemQueries.cocoaPoint(fromCG: p)) || (inBar(p) && locate(p) != nil) { return }
        lastOutsideClose = (open.target, now)
        perform(model.clickOutside(now: now))
    }
}
