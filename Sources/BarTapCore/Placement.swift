import CoreGraphics

/// Chooses where our items first appear.
///
/// macOS orders status items by a per-item "NSStatusItem Preferred Position <autosaveName>" value:
/// the distance from the right edge of the menu bar (0 = rightmost slot next to Control Center).
/// Values for existing items track their geometry closely, so seeding ours with the midpoint of a
/// neighbour's span lands us right next to that neighbour.
public enum Placement {
    /// Only the toggle and the hidden divider are seeded. The always-hidden divider is never
    /// seeded: created without a stored position it lands at the far left, so enabling that
    /// section later starts it empty instead of swallowing the whole hidden section.
    public struct Seeds: Equatable {
        public var toggle: Double
        public var hidden: Double

        public init(anchorRightDistance v: Double) {
            toggle = v
            hidden = v + 0.25
        }
    }

    /// Extra room macOS keeps between the camera housing and the first drawable icon.
    public static let notchMargin: CGFloat = 16

    /// Do-no-harm seeding: icons that are visible on every display right now stay visible; icons
    /// macOS is already failing to draw (behind the notch, or crowded out) start in the Hidden
    /// section. Returns nil when nothing overflows: then our items go to the far left and nothing
    /// is hidden until the user ⌘-drags icons across the divider.
    ///
    /// - Parameter extraDrop: move this many additional icons into Hidden (used to retry when a
    ///   seeded toggle still landed somewhere undrawable).
    public static func initialSeeds(screens: [ScreenInfo], windows: [WindowInfo],
                                    toggleWidth: CGFloat, extraDrop: Int = 0) -> Seeds? {
        struct Candidate { var screen: ScreenInfo; var row: [WindowInfo]; var visible: [WindowInfo] }
        var constrained: [Candidate] = []
        for screen in screens {
            let row = MenuBarGeometry.row(on: screen, windows: windows)
            // A bar drawing nothing is asleep, covered by a full-screen app or auto-hidden: it says
            // nothing about overflow, so it must not drive placement.
            guard !row.isEmpty, row.contains(where: \.isOnScreen) else { continue }
            // Drawn icons form a contiguous run at the right end of the row.
            var visible: [WindowInfo] = []
            for w in row.reversed() {
                if w.isOnScreen { visible.insert(w, at: 0) } else { break }
            }
            if visible.count < row.count || extraDrop > 0 && screen.notch != nil {
                constrained.append(Candidate(screen: screen, row: row, visible: visible))
            }
        }
        guard let target = constrained.min(by: { $0.visible.count < $1.visible.count }) else { return nil }
        let screen = target.screen
        var keep = target.visible
        if keep.isEmpty { return Seeds(anchorRightDistance: 0) }

        // The left edge of the rightmost undrawn icon proves where drawing stops.
        let hiddenPart = target.row.prefix(target.row.count - keep.count)
        var boundary = screen.notch.map { $0.upperBound + notchMargin } ?? screen.frame.minX
        if let lastHidden = hiddenPart.last { boundary = max(boundary, lastHidden.bounds.minX + 1) }

        let need = toggleWidth + 4
        var slack = keep[0].bounds.minX - boundary
        while slack < need && keep.count > 1 {
            slack += keep.removeFirst().bounds.width
        }
        for _ in 0..<extraDrop where keep.count > 1 {
            keep.removeFirst()
        }
        let anchor = keep[0]
        let r = Double(MenuBarGeometry.rightDistance(of: anchor.bounds, on: screen))
        return Seeds(anchorRightDistance: r + Double(anchor.bounds.width) / 2)
    }
}
