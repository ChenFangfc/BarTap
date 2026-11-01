import CoreGraphics

/// Decides whether re-hiding now would yank something out from under the user.
/// Pure: the app passes a fresh on-screen window list and the pointer location.
public enum InteractionDetector {
    public struct Context {
        public var windows: [WindowInfo]
        public var screens: [ScreenInfo]
        public var pointer: CGPoint          // CG global coordinates
        public var ownPID: Int32
        public var ownPanelVisible: Bool     // our search/shelf panel is up

        public init(windows: [WindowInfo], screens: [ScreenInfo], pointer: CGPoint, ownPID: Int32, ownPanelVisible: Bool) {
            self.windows = windows
            self.screens = screens
            self.pointer = pointer
            self.ownPID = ownPID
            self.ownPanelVisible = ownPanelVisible
        }
    }

    public enum Reason: String, Equatable {
        case pointerInMenuBar, menuOpen, popoverOpen, ownPanel
    }

    public static func busyReason(_ c: Context) -> Reason? {
        if c.ownPanelVisible { return .ownPanel }
        if c.screens.contains(where: { $0.containsMenuBarPoint(c.pointer, slop: 2) }) { return .pointerInMenuBar }
        for w in c.windows where w.isOnScreen && w.alpha > 0.01 && w.pid != c.ownPID {
            if w.layer == WindowLevel.popUpMenu && w.bounds.width > 4 && w.bounds.height > 4 { return .menuOpen }
            if isMenuBarPopover(w, screens: c.screens) { return .popoverOpen }
        }
        return nil
    }

    /// A panel hanging from the menu bar: above normal windows, taller than the bar itself, and
    /// starting right below it. Status icons (bar height) and the bar itself are excluded.
    static func isMenuBarPopover(_ w: WindowInfo, screens: [ScreenInfo]) -> Bool {
        guard w.layer >= 3 && w.layer <= 30 else { return false }
        guard w.ownerName != "Window Server" && w.ownerName != "Dock" else { return false }
        guard let s = screens.first(where: { $0.frame.intersects(w.bounds) }) else { return false }
        let barBottom = s.frame.minY + s.menuBarHeight
        guard w.bounds.height > s.menuBarHeight + 8, w.bounds.width > 40 else { return false }
        // Full-screen overlays (Notification Center keeps an invisible one up permanently) are
        // never dropdowns.
        if w.bounds.width >= s.frame.width * 0.9 && w.bounds.height >= s.frame.height * 0.9 { return false }
        return w.bounds.minY >= s.frame.minY - 1 && w.bounds.minY <= barBottom + 24
    }
}
