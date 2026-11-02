import Foundation
import CoreGraphics

// Opening a menu bar item's details on hover or click, and finding BarTap's items under the
// pointer on any display. Pure: the app feeds pointer samples, clicks, timer ticks and window
// lists in, and performs what comes out. Used by the stats items; written for the BarTap toggle
// too (hover reveals, leaving hides, a click keeps it open until a click outside).

/// The rules for one set of menu bar items that open details (only one at a time):
///
/// - Hover: the pointer rests on an item for `dwell` (moving more than `restRadius` restarts the
///   wait, so passing over never counts) → open, in hover mode. It closes once the pointer has
///   been away from both the item and the details for `grace` (time to cross the gap).
/// - Click: opens at once, pinned; leaving doesn't close it, a click outside both or another click
///   on the item does. A click on an item whose details are hover-open pins them.
/// - While hover-open, resting on another item switches to it; while pinned, hovering others does
///   nothing and clicking another item switches (pinned).
/// - After a click closes an item's details, resting on it again doesn't reopen them until the
///   pointer has left it.
public struct HoverClickModel<Target: Hashable>: Equatable {
    public struct Config: Equatable {
        public var hoverEnabled: Bool
        /// How long the pointer must rest on an item before its details open.
        public var dwell: TimeInterval
        /// Moving further than this (points) from where the rest began starts it over.
        public var restRadius: CGFloat
        /// How long the pointer may be away from both the item and its hover-opened details.
        public var grace: TimeInterval

        public init(hoverEnabled: Bool = true, dwell: TimeInterval = 0.5, restRadius: CGFloat = 6, grace: TimeInterval = 0.3) {
            self.hoverEnabled = hoverEnabled
            self.dwell = dwell
            self.restRadius = restRadius
            self.grace = grace
        }
    }

    public enum Mode: Equatable { case hover, pinned }

    public enum Effect: Equatable {
        /// Show `target`'s details (replacing any that are open).
        case open(Target, Mode)
        /// The open details stay until a click outside (their item was clicked).
        case pin
        case close
    }

    /// Where the pointer is: a point (any consistent coordinates), the item under it (nil: none
    /// of ours) and whether it is over the open details (including the gap above them).
    public struct Sample: Equatable {
        public var point: CGPoint
        public var item: Target?
        public var inPanel: Bool
        public init(point: CGPoint, item: Target?, inPanel: Bool) {
            self.point = point
            self.item = item
            self.inPanel = inPanel
        }
    }

    public struct Shown: Equatable {
        public var target: Target
        public var mode: Mode
        public init(target: Target, mode: Mode) {
            self.target = target
            self.mode = mode
        }
    }

    private struct Rest: Equatable {
        var item: Target
        var anchor: CGPoint
        var since: TimeInterval
    }

    public var config: Config
    /// Timers can fire a hair early: a deadline counts as reached within this.
    private static var slack: TimeInterval { 0.001 }
    /// The details that are open, if any.
    public private(set) var shown: Shown?
    private var rest: Rest?
    private var leftAt: TimeInterval?
    /// An item whose details a click just closed: no hover reopen until the pointer leaves it.
    private var suppressed: Target?

    public init(config: Config = Config()) { self.config = config }

    /// When to call `pointer(_:now:)` again with a fresh sample even if the pointer doesn't move
    /// (a rest completing, or the grace after leaving running out). nil: nothing pending.
    public var deadline: TimeInterval? {
        [rest.map { $0.since + config.dwell }, leftAt.map { $0 + config.grace }].compactMap { $0 }.min()
    }

    /// A pointer move, or a deadline: the current sample.
    public mutating func pointer(_ s: Sample, now: TimeInterval) -> [Effect] {
        if let x = suppressed, s.item != x { suppressed = nil }
        if shown?.mode == .pinned {
            rest = nil
            leftAt = nil
            return []
        }
        var effects: [Effect] = []
        if let open = shown {
            if s.inPanel || s.item == open.target {
                leftAt = nil
            } else {
                let since = leftAt ?? now
                leftAt = since
                if now - since >= config.grace - Self.slack {
                    shown = nil
                    leftAt = nil
                    effects.append(.close)
                }
            }
        }
        guard config.hoverEnabled, let item = s.item, item != shown?.target, item != suppressed else {
            rest = nil
            return effects
        }
        if let r = rest, r.item == item, hypot(s.point.x - r.anchor.x, s.point.y - r.anchor.y) <= config.restRadius {
            // Still resting.
        } else {
            rest = Rest(item: item, anchor: s.point, since: now)
        }
        guard let r = rest, now - r.since >= config.dwell - Self.slack else { return effects }
        rest = nil
        leftAt = nil
        shown = Shown(target: item, mode: .hover)
        // Opening replaces whatever was open.
        return effects.filter { $0 != .close } + [.open(item, .hover)]
    }

    /// A click on one of the items.
    public mutating func click(on item: Target, now: TimeInterval) -> [Effect] {
        rest = nil
        leftAt = nil
        if let open = shown, open.target == item {
            if open.mode == .pinned {
                shown = nil
                suppressed = item
                return [.close]
            }
            shown?.mode = .pinned
            return [.pin]
        }
        suppressed = nil
        shown = Shown(target: item, mode: .pinned)
        return [.open(item, .pinned)]
    }

    /// A click outside both the items and the open details.
    public mutating func clickOutside(now: TimeInterval) -> [Effect] {
        rest = nil
        leftAt = nil
        guard shown != nil else { return [] }
        shown = nil
        return [.close]
    }

    /// The details went away for another reason (their item was removed, the displays changed):
    /// forget them; resting on the same item doesn't reopen them until the pointer leaves it.
    public mutating func dismiss() -> [Effect] {
        rest = nil
        leftAt = nil
        guard let open = shown else { return [] }
        suppressed = open.target
        shown = nil
        return [.close]
    }
}

// MARK: - Finding BarTap's items under the pointer

/// Which of BarTap's status items is under a point, on any display.
///
/// macOS 26 draws every status item on every display. The window server names an item's window
/// after its autosave name ("tb_stats_cpu", "tb_toggle") only on the display that hosts it, and
/// only for apps with Screen Recording; other displays' copies are unnamed but laid out the same
/// way, right-aligned, except that a display too narrow for every icon leaves some out (not
/// necessarily the leftmost). So: the status window under the point on its display; ours by its
/// name, or else by its slot (distance from the right edge and width) matched against the host
/// display's; on a display that leaves icons out, by aligning its row with the host's from the
/// right edge.
public enum StatusItemHitTest {
    public struct Item: Equatable {
        /// The caller's identifier ("cpu", "combined", "toggle").
        public var id: String
        /// The name the window server gives its window: its autosave name.
        public var windowName: String
        /// BarTap's own (proxy) frame for it on the display that hosts it, in global CoreGraphics
        /// coordinates: the fallback without Screen Recording (it can lag after re-creation).
        public var proxyFrame: CGRect?

        public init(id: String, windowName: String, proxyFrame: CGRect?) {
            self.id = id
            self.windowName = windowName
            self.proxyFrame = proxyFrame
        }
    }

    public struct Hit: Equatable {
        public var id: String
        /// The item's window on the display under the point (where to put its details).
        public var frame: CGRect
        public var screenID: UInt32
        public init(id: String, frame: CGRect, screenID: UInt32) {
            self.id = id
            self.frame = frame
            self.screenID = screenID
        }
    }

    public static func hit(at p: CGPoint, screens: [ScreenInfo], windows: [WindowInfo], items: [Item]) -> Hit? {
        guard !items.isEmpty, let screen = screens.first(where: { !$0.asleep && $0.containsMenuBarPoint(p) }) else { return nil }
        let row = MenuBarGeometry.row(on: screen, windows: windows)
        guard let w = row.first(where: { $0.isOnScreen && $0.bounds.minX <= p.x && p.x < $0.bounds.maxX }) else { return nil }
        func hit(_ id: String) -> Hit { Hit(id: id, frame: w.bounds, screenID: screen.id) }
        if let name = w.name, !name.isEmpty {
            return items.first { $0.windowName == name }.map { hit($0.id) }
        }
        let awake = screens.filter { !$0.asleep }
        func display(of r: CGRect) -> ScreenInfo? { awake.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } }
        // The host display: where our items' windows carry their names.
        let named = items.compactMap { item in
            windows.first { $0.layer == WindowLevel.status && $0.name == item.windowName }.flatMap { win in display(of: win.bounds).map { (item, win, $0) } }
        }
        if let host = named.first?.2, host.id != screen.id {
            let hostRow = MenuBarGeometry.row(on: host, windows: windows)
            guard let j = row.firstIndex(of: w) else { return nil }
            let k: Int? = hostRow.count == row.count ? j : MenuBarGeometry.alignFromRight(row, hostRow)[j]
            guard let k, let name = hostRow[k].name else { return nil }
            return items.first { $0.windowName == name }.map { hit($0.id) }
        }
        // No names (no Screen Recording), or the host display itself: by slot.
        let rd = MenuBarGeometry.rightDistance(of: w.bounds, on: screen)
        for item in items {
            let frame = named.first { $0.0 == item }?.1.bounds ?? item.proxyFrame
            guard let f = frame, let s = display(of: f) else { continue }
            if abs(MenuBarGeometry.rightDistance(of: f, on: s) - rd) <= 2.5 && abs(f.width - w.bounds.width) <= 2.5 { return hit(item.id) }
        }
        return nil
    }
}

public extension MenuBarGeometry {
    /// Pairs two displays' rows of the same icons from their right edges, where one leaves some
    /// out: walking left, equal widths pair up; otherwise the longer row's icon is the one missing
    /// from the other. Returns, for each index of `a`, the index of its partner in `b`.
    static func alignFromRight(_ a: [WindowInfo], _ b: [WindowInfo], tolerance: CGFloat = 1) -> [Int: Int] {
        var i = a.count - 1, j = b.count - 1
        var out: [Int: Int] = [:]
        while i >= 0 && j >= 0 {
            if abs(a[i].bounds.width - b[j].bounds.width) <= tolerance {
                out[i] = j
                i -= 1
                j -= 1
            } else if i < j {
                j -= 1   // b has more left to place: its icon is missing from a
            } else if j < i {
                i -= 1
            } else {
                i -= 1   // same count left but different icons: neither pairs
                j -= 1
            }
        }
        return out
    }
}

// MARK: - Placement

public enum DetailPlacement {
    /// Where details open (global Cocoa coordinates, origin bottom-left): just below the item,
    /// their left edge a little left of the item's, kept `margin` inside the display's visible area.
    public static func frame(below item: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 3, inset: CGFloat = 6, margin: CGFloat = 6) -> CGRect {
        var x = item.minX - inset
        x = min(x, visible.maxX - margin - size.width)
        x = max(x, visible.minX + margin)
        let top = min(item.minY - gap, visible.maxY)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// Buttons of the given widths in rows no wider than `width` (spacing between them), left to
    /// right: each row is a range of indices. A button wider than a row gets a row of its own. The
    /// last button (the settings gear) is never left alone on a row: the one before it joins it.
    public static func rows(_ widths: [CGFloat], width: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0, used: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let need = i == start ? w : used + spacing + w
            if i > start && need > width {
                out.append(start..<i)
                start = i
                used = w
            } else {
                used = need
            }
        }
        if start < widths.count { out.append(start..<widths.count) }
        if out.count >= 2, let last = out.last, last.count == 1, let previous = out.dropLast().last, previous.count >= 2,
           widths[previous.upperBound - 1] + spacing + widths[last.lowerBound] <= width {
            out[out.count - 2] = previous.lowerBound..<(previous.upperBound - 1)
            out[out.count - 1] = (last.lowerBound - 1)..<last.upperBound
        }
        return out
    }
}

// MARK: - Settings

public extension Settings {
    /// Open a stats item's details when the pointer rests on it (on by default).
    var statsHoverOpen: Bool {
        get { defaults.object(forKey: "stats.hoverOpen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stats.hoverOpen"); post("stats") }
    }

    /// How long the pointer rests on an item before its details open: the one hover delay
    /// (Settings › Reveal), shared with the BarTap button.
    var statsHoverDelay: Double {
        get { hoverDelay }
        set { hoverDelay = newValue }
    }
}
