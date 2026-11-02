import CoreGraphics

/// One on-screen window as reported by CGWindowListCopyWindowInfo.
/// All rects are in global CoreGraphics coordinates (origin at the top-left of the main display).
public struct WindowInfo: Equatable {
    public var id: UInt32
    public var pid: Int32
    public var ownerName: String
    public var name: String?
    public var layer: Int
    public var bounds: CGRect
    public var isOnScreen: Bool
    public var alpha: Double

    public init(id: UInt32, pid: Int32, ownerName: String, name: String? = nil, layer: Int,
                bounds: CGRect, isOnScreen: Bool, alpha: Double = 1) {
        self.id = id
        self.pid = pid
        self.ownerName = ownerName
        self.name = name
        self.layer = layer
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.alpha = alpha
    }
}

/// A display, in global CoreGraphics coordinates.
public struct ScreenInfo: Equatable {
    public var id: UInt32
    public var frame: CGRect
    public var menuBarHeight: CGFloat
    /// Horizontal span hidden by the camera housing, if the display has one.
    public var notch: ClosedRange<CGFloat>?
    /// Asleep (a closed lid with other displays attached): its window positions are stale.
    public var asleep: Bool

    public init(id: UInt32, frame: CGRect, menuBarHeight: CGFloat, notch: ClosedRange<CGFloat>? = nil, asleep: Bool = false) {
        self.id = id
        self.frame = frame
        self.menuBarHeight = menuBarHeight
        self.notch = notch
        self.asleep = asleep
    }

    public var menuBarRect: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: menuBarHeight)
    }

    /// Leftmost x that status items can occupy without being swallowed by the notch.
    public var statusAreaMinX: CGFloat { notch?.upperBound ?? frame.minX }

    public func containsMenuBarPoint(_ p: CGPoint, slop: CGFloat = 1) -> Bool {
        p.x >= frame.minX && p.x < frame.maxX && p.y >= frame.minY - slop && p.y <= frame.minY + menuBarHeight + slop
    }
}

public enum WindowLevel {
    public static let mainMenu = 24
    public static let status = 25
    public static let popUpMenu = 101
}

/// Anything wider than this in the status layer is a collapsed separator, never a real icon.
public let separatorWidthThreshold: CGFloat = 1500

public enum MenuBarGeometry {
    /// The status-item row of one display, left to right, *excluding* anything pushed off by a
    /// collapsed separator. We start at the item touching the display's right edge and walk left
    /// while items stay contiguous, stopping at a gap or at a separator-sized window.
    public static func row(on screen: ScreenInfo, windows: [WindowInfo]) -> [WindowInfo] {
        let candidates = windows.filter {
            $0.layer == WindowLevel.status
                && abs($0.bounds.minY - screen.frame.minY) <= 1
                && $0.bounds.height > 0
                && $0.bounds.height <= max(screen.menuBarHeight, 22) + 8
        }.sorted { $0.bounds.maxX > $1.bounds.maxX }
        guard let first = candidates.first(where: { abs($0.bounds.maxX - screen.frame.maxX) <= 6 }) else { return [] }
        var result = [first]
        var edge = first.bounds.minX
        for w in candidates where w.bounds.maxX < first.bounds.maxX - 0.5 {
            if w.bounds.width >= separatorWidthThreshold { break }
            if abs(w.bounds.maxX - edge) > 2.5 { break }
            result.append(w)
            edge = w.bounds.minX
        }
        return result.reversed()
    }

    /// Distance from a display's right edge to a window's right edge. This is the same on every
    /// display because macOS lays out the identical icon set right-aligned on each menu bar.
    public static func rightDistance(of rect: CGRect, on screen: ScreenInfo) -> CGFloat {
        screen.frame.maxX - rect.maxX
    }

    /// Finds the window in `row` that occupies the slot `rightDistance`/`width`, if any.
    public static func window(atRightDistance rd: CGFloat, width: CGFloat, on screen: ScreenInfo,
                              in row: [WindowInfo], tolerance: CGFloat = 3) -> WindowInfo? {
        row.first {
            abs(rightDistance(of: $0.bounds, on: screen) - rd) <= tolerance && abs($0.bounds.width - width) <= tolerance
        }
    }

    /// Icons that macOS laid out on this display but could not draw (typically behind the notch).
    public static func overflowCount(on screen: ScreenInfo, row: [WindowInfo], leftOf maxRightEdge: CGFloat) -> Int {
        row.filter { !$0.isOnScreen && $0.bounds.maxX <= maxRightEdge + 0.5 && $0.bounds.width < separatorWidthThreshold }.count
    }
}

public enum ExtraSection: Equatable { case shown, hidden, alwaysHidden }

/// Sorting other apps' menu bar icons into BarTap's sections, from Accessibility frames.
public enum MenuBarSections {
    /// Whether a frame sits in a display's menu bar. macOS 26 reports extras a few points into the
    /// bar (y ≈ 3…6 on a 33 pt bar), so test the frame's vertical middle, not its top edge.
    public static func inMenuBar(_ f: CGRect, of s: ScreenInfo) -> Bool {
        f.midY >= s.frame.minY - 2 && f.midY <= s.frame.minY + s.menuBarHeight + 2
    }

    /// For each frame, its distance from the right edge of the bar that holds our toggle and its
    /// section; nil for icons in no menu bar (macOS 26 parks icons it doesn't show at the bottom of
    /// the screen) and for zero-width ones. macOS reports every app's extras on one display, hidden
    /// ones far off its left edge, so one reference bar measures them all.
    /// The display whose bar Accessibility reports our toggle (and every other icon) in.
    public static func referenceScreen(toggle: CGRect, screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first { inMenuBar(toggle, of: $0) && $0.frame.minX <= toggle.midX && toggle.midX <= $0.frame.maxX }
    }

    public static func classify(_ frames: [CGRect], toggle: CGRect, hidden: CGRect, always: CGRect?,
                                screens: [ScreenInfo]) -> [(rd: CGFloat, section: ExtraSection)?] {
        guard let ref = referenceScreen(toggle: toggle, screens: screens) else { return frames.map { _ in nil } }
        func rd(_ f: CGRect) -> CGFloat? { f.width > 0 && inMenuBar(f, of: ref) ? ref.frame.maxX - f.maxX : nil }
        guard let hiddenRD = rd(hidden) else { return frames.map { _ in nil } }
        // Dividers grow leftwards from a fixed right edge, so an icon is hidden when its right edge
        // is at or beyond the divider's left edge (measured from the right).
        let hiddenLeft = hiddenRD + hidden.width
        let alwaysLeft = always.flatMap { a in rd(a).map { $0 + a.width } }
        return frames.map { f in
            guard let d = rd(f) else { return nil }
            if let a = alwaysLeft, d >= a - 1 { return (d, .alwaysHidden) }
            return (d, d >= hiddenLeft - 1 ? .hidden : .shown)
        }
    }
}

/// BarTap's own items where the window server really drew them. Our in-process frames (and
/// Accessibility, which reads them) can lag for seconds after the items are re-created, and even
/// flip back and forth; the window list can't. macOS draws ours as one run, │ then the toggle then
/// the stats items, whose window widths we know exactly, so that run is found by its widths in a
/// bar that is visible. ‖ is the nearest window of its own width further left (an open divider is
/// far narrower than any icon).
public struct OwnRun: Equatable {
    public var hidden: CGFloat
    public var toggle: CGFloat
    /// The stats items' window widths, in the order new ones are placed right of the toggle. They
    /// can sit anywhere (Settings › Layout moves them); when several windows look like the toggle,
    /// the one most of them follow wins.
    public var stats: [CGFloat]
    public var always: CGFloat?
    /// The toggle's distance from its display's right edge as BarTap last saw it (can lag), to
    /// pick between look-alikes.
    public var toggleRD: CGFloat?

    public init(hidden: CGFloat, toggle: CGFloat, stats: [CGFloat], always: CGFloat?, toggleRD: CGFloat? = nil) {
        self.hidden = hidden
        self.toggle = toggle
        self.stats = stats
        self.always = always
        self.toggleRD = toggleRD
    }

    /// Where the dividers and the toggle are drawn on one display.
    public struct Located: Equatable {
        public var screen: ScreenInfo
        public var toggle: CGRect
        public var hidden: CGRect
        public var always: CGRect?
    }

    /// The run's windows as frames on the first display that draws it, or nil.
    public func locate(screens: [ScreenInfo], windows: [WindowInfo]) -> (screen: ScreenInfo, toggle: CGRect, hidden: CGRect, always: CGRect?)? {
        for screen in screens {
            if let f = locate(on: screen, windows: windows) { return (f.screen, f.toggle, f.hidden, f.always) }
        }
        return nil
    }

    /// The dividers and the toggle on one display, or nil if that bar doesn't draw them.
    public func locate(on screen: ScreenInfo, windows: [WindowInfo]) -> Located? {
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.75 }
        let row = MenuBarGeometry.row(on: screen, windows: windows)
        guard row.contains(where: \.isOnScreen) else { return nil }
        let bar = windows.filter { $0.layer == WindowLevel.status && abs($0.bounds.minY - screen.frame.minY) <= 1 }
        // The window server names a status item's window after its autosave name, on the display
        // that hosts it (window names need Screen Recording): exact, wherever the items sit, unless
        // that display is asleep (its positions are then stale).
        if !screen.asleep, let t = bar.first(where: { $0.name == "tb_toggle" }), let h = bar.first(where: { $0.name == "tb_hidden" }) {
            return Located(screen: screen, toggle: t.bounds, hidden: h.bounds, always: bar.first(where: { $0.name == "tb_always" })?.bounds)
        }
        // Elsewhere by widths: │ (open, in the row; or collapsed, the long window the row stopped
        // at) right before a toggle-wide window.
        var best: (score: Int, distance: CGFloat, located: Located)?
        for j in row.indices where same(row[j].bounds.width, toggle) {
            let divider: CGRect
            if j > 0, same(row[j - 1].bounds.width, hidden) {
                divider = row[j - 1].bounds
            } else if j == 0, let wide = bar.first(where: {
                $0.bounds.width >= separatorWidthThreshold && abs($0.bounds.maxX - row[0].bounds.minX) <= 2.5
            }) {
                divider = wide.bounds
            } else {
                continue
            }
            var alwaysFrame: CGRect?
            if let always {
                alwaysFrame = row[..<max(0, j - 1)].last(where: { same($0.bounds.width, always) })?.bounds
                    ?? bar.first(where: {   // collapsed: the long window left of the hidden section
                        $0.bounds.width >= separatorWidthThreshold && $0.bounds.maxX <= divider.minX + 2.5 && $0.bounds != divider
                    })?.bounds
            }
            // Look-alikes: prefer the one followed by the stats items, then the one nearest where
            // BarTap last saw its toggle.
            var score = 0
            while score < stats.count, j + 1 + score < row.count, same(row[j + 1 + score].bounds.width, stats[score]) { score += 1 }
            let distance = toggleRD.map { abs(MenuBarGeometry.rightDistance(of: row[j].bounds, on: screen) - $0) } ?? 0
            let located = Located(screen: screen, toggle: row[j].bounds, hidden: divider, always: alwaysFrame)
            if let b = best, score < b.score || (score == b.score && distance >= b.distance) { continue }
            best = (score, distance, located)
        }
        return best?.located
    }
}

/// Positions of our own three status items, from their in-process proxy windows, expressed in the
/// main display's Cocoa x coordinates. `nil` means the item does not exist (feature disabled).
public struct OwnItemFrames: Equatable {
    public var toggle: CGRect
    public var hidden: CGRect
    public var alwaysHidden: CGRect?

    public init(toggle: CGRect, hidden: CGRect, alwaysHidden: CGRect?) {
        self.toggle = toggle
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

/// Our items' stored order keys ("NSStatusItem Preferred Position"): a larger value is further
/// left. macOS orders the real items by these keys. The in-process proxy frames can fall out of
/// sync with that order (seen on macOS 26 with three displays: after a relaunch the proxies showed
/// the toggle and the divider swapped for minutes while the bar itself was correct).
public struct OwnItemKeys: Equatable {
    public var toggle: Double
    public var hidden: Double
    public var alwaysHidden: Double?

    public init(toggle: Double, hidden: Double, alwaysHidden: Double?) {
        self.toggle = toggle
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

public enum LayoutProblem: Equatable {
    case notReady              // frames not reported yet
    case hiddenRightOfToggle   // collapsing would push the toggle off-screen
    case alwaysRightOfHidden   // always-hidden divider sits inside the hidden section
}

public enum LayoutValidator {
    /// Separators grow leftwards from a fixed right edge, so comparing right edges stays valid in
    /// every collapse state.
    public static func check(_ f: OwnItemFrames) -> LayoutProblem? {
        let tol: CGFloat = 1.5
        if f.toggle.width <= 0 || f.hidden.width <= 0 { return .notReady }
        if f.toggle == .zero || f.hidden == .zero { return .notReady }
        if f.hidden.maxX > f.toggle.minX + tol { return .hiddenRightOfToggle }
        if let a = f.alwaysHidden {
            if a.width <= 0 { return .notReady }
            // The always-hidden divider must end where (or before) the hidden divider begins.
            // This holds whether `hidden` is collapsed or not, because both grow leftwards.
            if a.maxX > f.hidden.minX + tol { return .alwaysRightOfHidden }
        }
        return nil
    }

    /// Readiness from the frames, order from the stored keys when we have them (macOS lays the
    /// bar out by those keys; the proxies only mirror it, and not always in time).
    public static func check(_ f: OwnItemFrames, keys: OwnItemKeys?) -> LayoutProblem? {
        if f.toggle.width <= 0 || f.hidden.width <= 0 || f.toggle == .zero || f.hidden == .zero { return .notReady }
        if let a = f.alwaysHidden, a.width <= 0 { return .notReady }
        guard let k = keys else { return check(f) }
        if k.hidden <= k.toggle { return .hiddenRightOfToggle }
        if let a = k.alwaysHidden, a <= k.hidden { return .alwaysRightOfHidden }
        return nil
    }
}

/// Turns the menu bar's order into a wanted one with ⌘-drags, working from the right: each step
/// drops one icon immediately left of its wanted right-hand neighbour, so icons already in place
/// are never moved again. Anchors (BarTap's own items, the Control Center and clock that macOS
/// keeps at the right end) never move.
public enum LayoutPlan {
    public struct Step: Equatable {
        public let item: String
        /// Drop immediately left of this one.
        public let leftOf: String
        public init(item: String, leftOf: String) {
            self.item = item
            self.leftOf = leftOf
        }
    }

    /// The next drag, or nil once `current` (left to right) has `wanted`'s order. The icons already
    /// in order (the longest such run; anchors always count among them) stay put, every other one
    /// moves once, right to left, each next to the icon that follows it. Keys in `current` that
    /// `wanted` doesn't mention stay where they are; keys missing from `current` are skipped.
    public static func nextStep(current: [String], wanted: [String], anchors: Set<String>) -> Step? {
        // Icons the plan doesn't know (one that appeared since) don't count as being in the way.
        let known = Set(wanted)
        var position: [String: Int] = [:]
        for (i, key) in current.filter(known.contains).enumerated() where position[key] == nil { position[key] = i }
        let present = wanted.filter { position[$0] != nil }
        guard present.count >= 2 else { return nil }
        let staying = inOrder(present.sorted { position[$0]! < position[$1]! }, rank: Dictionary(uniqueKeysWithValues: present.enumerated().map { ($1, $0) }),
                              anchors: anchors)
        for i in stride(from: present.count - 2, through: 0, by: -1) {
            let item = present[i], right = present[i + 1]
            guard !staying.contains(item), !anchors.contains(item) else { continue }
            if position[item]! + 1 != position[right]! || !staying.contains(right) { return Step(item: item, leftOf: right) }
        }
        return nil
    }

    /// The longest run of `order` already in `rank` order, anchors weighing more than anything else
    /// (they can't move).
    static func inOrder(_ order: [String], rank: [String: Int], anchors: Set<String>) -> Set<String> {
        let n = order.count
        let weight = order.map { anchors.contains($0) ? 1000 : 1 }
        var best = weight, previous = [Int](repeating: -1, count: n)
        for i in 0..<n {
            for j in 0..<i where rank[order[j]]! < rank[order[i]]! && best[j] + weight[i] > best[i] {
                best[i] = best[j] + weight[i]
                previous[i] = j
            }
        }
        guard var i = best.indices.max(by: { best[$0] < best[$1] }) else { return [] }
        var out: Set<String> = []
        while i >= 0 {
            out.insert(order[i])
            i = previous[i]
        }
        return out
    }

    /// Every step, by applying each one to a copy of `current` (for progress and tests).
    public static func steps(current: [String], wanted: [String], anchors: Set<String>) -> [Step] {
        var order = current
        var out: [Step] = []
        while let step = nextStep(current: order, wanted: wanted, anchors: anchors), out.count <= order.count * 2 {
            out.append(step)
            order.removeAll { $0 == step.item }
            if let r = order.firstIndex(of: step.leftOf) { order.insert(step.item, at: r) }
        }
        return out
    }
}

/// Settings › Layout's rows: the icons that are shown, hidden or always hidden, each left to right
/// as in the menu bar. Pinned icons (Control Center and the clock, which macOS keeps at the right
/// end) follow Shown and never move.
public struct LayoutArrangement: Equatable {
    public enum Row: Int, CaseIterable {
        // Right to left in the menu bar.
        case shown, hidden, always
    }

    public var shown: [String]
    public var hidden: [String]
    public var always: [String]
    public var pinned: [String]

    public init(shown: [String] = [], hidden: [String] = [], always: [String] = [], pinned: [String] = []) {
        self.shown = shown
        self.hidden = hidden
        self.always = always
        self.pinned = pinned
    }

    public subscript(row: Row) -> [String] {
        get {
            switch row {
            case .shown: return shown
            case .hidden: return hidden
            case .always: return always
            }
        }
        set {
            switch row {
            case .shown: shown = newValue
            case .hidden: hidden = newValue
            case .always: always = newValue
            }
        }
    }

    public func row(of key: String) -> Row? { Row.allCases.first { self[$0].contains(key) } }

    /// Puts `key` at `index` of `row` (an index among that row's icons before the move).
    public mutating func move(_ key: String, to row: Row, at index: Int) {
        guard let from = self.row(of: key), let i = self[from].firstIndex(of: key) else { return }
        self[from].remove(at: i)
        var j = index
        if from == row && i < index { j -= 1 }
        self[row].insert(key, at: max(0, min(j, self[row].count)))
    }

    /// Moves `key` to the end of `row` nearest the row it leaves, which is where a divider move
    /// would have put it.
    public mutating func send(_ key: String, to row: Row) {
        guard let from = self.row(of: key), from != row else { return }
        // Further right (a lower row) → its left end; further left → its right end.
        move(key, to: row, at: row.rawValue < from.rawValue ? 0 : self[row].count)
    }

    /// The whole bar left to right, with BarTap's dividers as "‖" and "│" (the toggle and stats
    /// items follow "│"). Without the always-hidden section its icons count as hidden.
    public func order(alwaysSection: Bool) -> [String] {
        (alwaysSection ? always + ["‖"] + hidden : always + hidden) + ["│"] + shown + pinned
    }

    /// What Apply aims for: icons the user moved (`touched`) go where these rows put them, each
    /// before the icon that follows it here (or last in its row); every other icon keeps its row
    /// and order from `fresh`, the bar as it is now. So Apply never moves an icon the user didn't.
    public func rebased(onto fresh: LayoutArrangement, touched: Set<String>) -> LayoutArrangement {
        var out = fresh
        let present = Set(Row.allCases.flatMap { fresh[$0] })
        let moving = touched.intersection(present).intersection(Row.allCases.flatMap { self[$0] })
        for row in Row.allCases { out[row].removeAll { moving.contains($0) } }
        for row in Row.allCases {
            let mine = self[row]
            // Right to left, so a moved icon can follow another moved one.
            for i in mine.indices.reversed() where moving.contains(mine[i]) {
                let next = mine[(i + 1)...].first { out[row].contains($0) }
                out[row].insert(mine[i], at: next.flatMap { out[row].firstIndex(of: $0) } ?? out[row].count)
            }
        }
        return out
    }

    /// These edits on top of the bar as it is now: icons that went away are dropped, new ones
    /// join the row they appeared in, next to the icon they appeared after.
    public func merged(into live: LayoutArrangement) -> LayoutArrangement {
        let present = Set(Row.allCases.flatMap { live[$0] })
        var out = self
        out.pinned = live.pinned
        for row in Row.allCases { out[row] = out[row].filter(present.contains) }
        let known = Set(Row.allCases.flatMap { out[$0] })
        for row in Row.allCases {
            for (i, key) in live[row].enumerated() where !known.contains(key) {
                let after = live[row][..<i].last(where: { out[row].contains($0) })
                let at = after.flatMap { out[row].firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                out[row].insert(key, at: at)
            }
        }
        return out
    }
}

extension MenuBarGeometry {
    /// With hidden icons hidden, each display draws the same run of icons from its right edge to
    /// BarTap's divider, except one too narrow for all of them: macOS leaves out what doesn't fit.
    /// Returns those displays with how many icons they leave out. Displays whose bar isn't drawn
    /// (full screen, lid closed) don't count.
    public static func shortRows(screens: [ScreenInfo], windows: [WindowInfo]) -> [(screen: ScreenInfo, missing: Int)] {
        let drawn = screens.compactMap { s -> (ScreenInfo, Int)? in
            let n = row(on: s, windows: windows).filter(\.isOnScreen).count
            return n == 0 ? nil : (s, n)
        }
        guard let most = drawn.map(\.1).max() else { return [] }
        return drawn.filter { $0.1 < most }.map { ($0.0, most - $0.1) }
    }
}
