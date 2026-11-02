import AppKit
import BarTapCore

/// Settings › Layout's Apply: rearranges the menu bar to match the rows, one ⌘-drag at a time
/// (IconMover), reading the real bar again after every move. It works on one display, where each
/// icon is told apart by its window: an app's icons can share every other trait. Using the mouse
/// or keyboard stops it for good; nothing resumes on its own.
final class LayoutApplier {
    struct Request {
        var arrangement: LayoutArrangement
        var alwaysSection: Bool
        /// Icons the user dragged: the report names them if they couldn't be reached.
        var touched: Set<String>
    }

    struct Report {
        enum Finish: Equatable { case done, interrupted, failed(String) }
        var finish: Finish
        var moves = 0
        /// Icons macOS wouldn't move, by name.
        var stuck: [String] = []
        /// Icons the user moved that no display draws right now (the bar is full).
        var notDrawn: [String] = []
        /// Moves still planned when it stopped.
        var left = 0
    }

    private let catalog: AXCatalog
    private let mover: IconMover
    private let ownRun: () -> OwnRun?
    private(set) var running = false
    private var cancelled = false
    /// The last run, for the debug dump.
    private(set) var log: [String] = []

    init(catalog: AXCatalog, mover: IconMover, ownRun: @escaping () -> OwnRun?) {
        self.catalog = catalog
        self.mover = mover
        self.ownRun = ownRun
    }

    /// Stops after the move under way (the pane closed, or the app needs the bar back).
    func cancel() { cancelled = true }

    func run(_ request: Request, progress: @escaping (Int, Int) -> Void, completion: @escaping (Report) -> Void) {
        guard !running else { return }
        running = true
        cancelled = false
        log = []
        start(request, tries: 0, progress: progress, completion: completion)
    }

    /// Accessibility can report an icon's place a moment late (every icon just revealed, an app
    /// re-creating its icon): look again rather than plan around icons it couldn't place.
    private func start(_ request: Request, tries: Int, progress: @escaping (Int, Int) -> Void, completion: @escaping (Report) -> Void) {
        catalog.snapshot { [weak self] items in
            guard let self else { return }
            guard !self.cancelled, let plan = self.plan(request, items: items) else {
                self.finish(Report(finish: self.cancelled ? .interrupted
                    : .failed(L("The menu bar isn't fully shown on any display right now, so its icons can't be moved. Try again in a moment."))), completion)
                return
            }
            if !plan.unplaced.isEmpty, tries < 4 {
                self.log.append("unplaced \(plan.unplaced.joined(separator: ",")), looking again")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.start(request, tries: tries + 1, progress: progress, completion: completion)
                }
                return
            }
            self.log.append("display \(plan.screen.id): \(plan.wanted.count) slots, not drawn \(plan.notDrawn.count)")
            self.step(plan, Progress(notDrawn: plan.notDrawn), progress: progress, completion: completion)
        }
    }

    // MARK: Planning

    private struct Plan {
        let screen: ScreenInfo
        let wanted: [String]
        let anchors: Set<String>
        let alwaysSection: Bool
        let names: [String: String]
        let notDrawn: [String]
        /// Icons of the request with no window found for them, by name (debug, and to look again).
        let unplaced: [String]
    }

    private struct Progress {
        var moves = 0
        var total: Int?
        var attempts: [String: Int] = [:]
        var stuck: Set<String> = []
        var notDrawn: [String]
    }

    /// Picks the display that draws the most icons (and BarTap's dividers), and names every icon by
    /// its window there. "‖" and "│" stand for BarTap's dividers; the toggle always follows "│".
    /// BarTap's stats items are icons like any other.
    private func plan(_ request: Request, items: [BarItem]) -> Plan? {
        guard let run = ownRun() else { return nil }
        let windows = SystemQueries.windows(onScreenOnly: false)
        var best: (screen: ScreenInfo, ids: [String: UInt32])?
        for screen in SystemQueries.screens(windows: windows) {
            guard let found = run.locate(on: screen, windows: windows), !request.alwaysSection || found.always != nil else { continue }
            let row = MenuBarGeometry.row(on: screen, windows: windows).filter {
                $0.isOnScreen && $0.bounds != found.toggle && $0.bounds != found.hidden && $0.bounds != found.always
            }
            var ids: [String: UInt32] = [:]
            var used = Set<UInt32>()
            for item in items {
                // Accessibility and the window list agree on each icon's centre (their widths differ by padding).
                let centre = item.order + item.frame.width / 2
                if let w = row.first(where: { !used.contains($0.id) && abs(MenuBarGeometry.rightDistance(of: $0.bounds, on: screen) + $0.bounds.width / 2 - centre) <= 4 }) {
                    ids[item.slotKey] = w.id
                    used.insert(w.id)
                }
            }
            // One icon and one window left over can only be each other.
            let leftItems = items.filter { ids[$0.slotKey] == nil }, leftWindows = row.filter { !used.contains($0.id) }
            if leftItems.count == 1, leftWindows.count == 1 { ids[leftItems[0].slotKey] = leftWindows[0].id }
            if let b = best, ids.count < b.ids.count || (ids.count == b.ids.count && screen.frame.width <= b.screen.frame.width) { continue }
            best = (screen, ids)
        }
        guard let best, !best.ids.isEmpty else { return nil }
        // Only the icons the user moved move: the rest stay as the bar has them now.
        let a = request.arrangement.rebased(onto: LayoutPaneModel.arrangement(of: items), touched: request.touched)
        func tokens(_ keys: [String]) -> [String] { keys.compactMap { best.ids[$0].map { "w\($0)" } } }
        let pinned = tokens(a.pinned)
        let wanted = (request.alwaysSection ? tokens(a.always) + ["‖"] + tokens(a.hidden) : tokens(a.always) + tokens(a.hidden))
            + ["│"] + tokens(a.shown) + pinned
        var names: [String: String] = [:]
        for item in items { if let id = best.ids[item.slotKey] { names["w\(id)"] = item.appName } }
        let moved = (a.always + a.hidden + a.shown).filter { request.touched.contains($0) && best.ids[$0] == nil }
        let byKey = Dictionary(items.map { ($0.slotKey, $0.appName) }, uniquingKeysWith: { first, _ in first })
        let unplaced = (a.always + a.hidden + a.shown + a.pinned).filter { byKey[$0] != nil && best.ids[$0] == nil }
        return Plan(screen: best.screen, wanted: wanted, anchors: Set(["‖", "│"] + pinned), alwaysSection: request.alwaysSection,
                    names: names, notDrawn: moved.compactMap { byKey[$0] }, unplaced: unplaced.compactMap { byKey[$0] })
    }

    /// The bar on the plan's display, left to right, as tokens, with where each one is drawn.
    private func current(_ plan: Plan) -> (order: [String], spots: [String: IconMover.Spot])? {
        let windows = SystemQueries.windows(onScreenOnly: false)
        guard let screen = SystemQueries.screens(windows: windows).first(where: { $0.id == plan.screen.id }),
              let found = ownRun()?.locate(on: screen, windows: windows) else { return nil }
        var order: [String] = []
        var spots: [String: IconMover.Spot] = [:]
        for w in MenuBarGeometry.row(on: screen, windows: windows) where w.isOnScreen {
            let token: String
            if w.bounds == found.hidden { token = "│" } else if let a = found.always, w.bounds == a { token = "‖" } else if w.bounds == found.toggle { continue } else { token = "w\(w.id)" }
            order.append(token)
            spots[token] = IconMover.Spot(window: w.id, frame: w.bounds)
        }
        guard order.contains("│"), !plan.alwaysSection || order.contains("‖") else { return nil }
        return (order, spots)
    }

    // MARK: Moving

    private func step(_ plan: Plan, _ state: Progress, progress: @escaping (Int, Int) -> Void, completion: @escaping (Report) -> Void) {
        var s = state
        func report(_ finish: Report.Finish, left: Int = 0) -> Report {
            Report(finish: finish, moves: s.moves, stuck: s.stuck.compactMap { plan.names[$0] }.sorted(), notDrawn: s.notDrawn, left: left)
        }
        guard !cancelled else { finish(report(.interrupted), completion); return }
        guard let bar = current(plan) else {
            finish(report(.failed(L("BarTap's divider isn't drawn on that display any more (a display changed?). Nothing else was moved."))), completion)
            return
        }
        let fixed = plan.anchors.union(s.stuck)
        if s.total == nil { s.total = LayoutPlan.steps(current: bar.order, wanted: plan.wanted, anchors: fixed).count }
        guard let next = LayoutPlan.nextStep(current: bar.order, wanted: plan.wanted, anchors: fixed) else {
            log.append("done after \(s.moves) moves")
            finish(report(.done), completion)
            return
        }
        // Twice is enough: an icon that is still out of place is one macOS (or its app) keeps where it is.
        if s.attempts[next.item, default: 0] >= 2 || s.moves >= 2 * plan.wanted.count + 2 {
            log.append("stuck \(next.item)")
            s.stuck.insert(next.item)
            catalog.cancelOpenMenu()
            DispatchQueue.main.async { [weak self, s] in self?.step(plan, s, progress: progress, completion: completion) }
            return
        }
        guard let from = bar.spots[next.item], let to = bar.spots[next.leftOf] else {
            s.stuck.insert(next.item)
            DispatchQueue.main.async { [weak self, s] in self?.step(plan, s, progress: progress, completion: completion) }
            return
        }
        s.attempts[next.item, default: 0] += 1
        progress(s.moves + 1, max(s.total ?? 0, s.moves + 1))
        log.append("\(next.item) → left of \(next.leftOf)")
        mover.drag(from: from, to: CGPoint(x: to.frame.minX + 3, y: to.frame.midY)) { [weak self, s] outcome in
            var s = s
            guard let self else { return }
            guard outcome == .moved else {
                let left = LayoutPlan.steps(current: bar.order, wanted: plan.wanted, anchors: fixed).count
                self.log.append("interrupted")
                self.finish(report(.interrupted, left: left), completion)
                return
            }
            s.moves += 1
            // macOS animates the drop; the window list settles within half a second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, s] in self?.step(plan, s, progress: progress, completion: completion) }
        }
    }

    private func finish(_ report: Report, _ completion: (Report) -> Void) {
        running = false
        cancelled = false
        completion(report)
    }
}
