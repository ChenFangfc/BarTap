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

    public init(id: UInt32, frame: CGRect, menuBarHeight: CGFloat, notch: ClosedRange<CGFloat>? = nil) {
        self.id = id
        self.frame = frame
        self.menuBarHeight = menuBarHeight
        self.notch = notch
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
    public static func classify(_ frames: [CGRect], toggle: CGRect, hidden: CGRect, always: CGRect?,
                                screens: [ScreenInfo]) -> [(rd: CGFloat, section: ExtraSection)?] {
        guard let ref = screens.first(where: { inMenuBar(toggle, of: $0) && $0.frame.minX <= toggle.midX && toggle.midX <= $0.frame.maxX })
        else { return frames.map { _ in nil } }
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
