import AppKit
import BarTapCore

/// Read-only views of window-server state. Nothing here needs a permission: window bounds,
/// layers and owners are public; we never ask for window titles or pixels.
enum SystemQueries {
    static func windows(onScreenOnly: Bool) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        out.reserveCapacity(list.count)
        for d in list {
            guard let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            out.append(WindowInfo(
                id: (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                pid: (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                name: d[kCGWindowName as String] as? String,
                layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: rect,
                isOnScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1))
        }
        return out
    }

    static var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Converts a Cocoa global rect (bottom-left origin) to CG global coordinates.
    static func cgRect(fromCocoa r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaPoint(fromCG p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: mainScreenHeight - p.y) }

    static var pointerCG: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: mainScreenHeight - p.y)
    }

    static func screens(windows: [WindowInfo]? = nil) -> [ScreenInfo] {
        let all = NSScreen.screens
        guard let mainH = all.first?.frame.height else { return [] }
        return all.map { s in
            let f = s.frame
            let cg = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
            var notch: ClosedRange<CGFloat>?
            if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                let lx = (l.maxX >= f.minX && l.maxX <= f.maxX) ? l.maxX : f.minX + l.maxX
                let rx = (r.minX >= f.minX && r.minX <= f.maxX) ? r.minX : f.minX + r.minX
                if rx > lx { notch = lx...rx }
            }
            var height: CGFloat = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top + 1 : max(f.maxY - s.visibleFrame.maxY, 24)
            if let ws = windows, let bar = ws.first(where: {
                $0.layer == WindowLevel.mainMenu && $0.ownerName == "Window Server"
                    && abs($0.bounds.minY - cg.minY) < 1 && abs($0.bounds.width - cg.width) < 1 && $0.bounds.height < 60
            }) {
                height = bar.bounds.height
            }
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return ScreenInfo(id: id, frame: cg, menuBarHeight: height, notch: notch, asleep: CGDisplayIsAsleep(id) != 0)
        }
    }

    static func screen(containingCG p: CGPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first { $0.frame.contains(p) } ?? screens.first
    }

    static func nsScreen(for info: ScreenInfo) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == info.id
        }
    }
}
