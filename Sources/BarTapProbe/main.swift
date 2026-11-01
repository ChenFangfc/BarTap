import AppKit
import BarTapCore

// Prints what each display's menu bar is actually drawing, as JSON (used by scripts/live_test.py).
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var windows: [WindowInfo] = []
for d in list {
    guard let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
    windows.append(WindowInfo(id: (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                              pid: (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                              ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                              layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: r,
                              isOnScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false))
}
let mainH = NSScreen.screens.first?.frame.height ?? 0
var screensOut: [[String: Any]] = []
for s in NSScreen.screens {
    let f = s.frame
    let cg = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
    var notch: ClosedRange<CGFloat>?
    if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { notch = l.maxX...r.minX }
    let bar = windows.first { $0.layer == 24 && $0.ownerName == "Window Server" && abs($0.bounds.minY - cg.minY) < 1 && abs($0.bounds.width - cg.width) < 1 }
    let info = ScreenInfo(id: 0, frame: cg, menuBarHeight: bar?.bounds.height ?? 24, notch: notch)
    let row = MenuBarGeometry.row(on: info, windows: windows)
    let wide = windows.filter { $0.layer == 25 && abs($0.bounds.minY - cg.minY) <= 1 && $0.bounds.width >= separatorWidthThreshold }
    screensOut.append([
        "name": s.localizedName, "x": cg.minX, "y": cg.minY, "width": cg.width, "notch": notch.map { [$0.lowerBound, $0.upperBound] } ?? [],
        "row": row.map { ["x": $0.bounds.minX, "w": $0.bounds.width, "rd": cg.maxX - $0.bounds.maxX, "on": $0.isOnScreen] },
        "drawn": row.filter(\.isOnScreen).count, "separators": wide.count,
        "drawnSeparators": wide.filter(\.isOnScreen).count,
    ])
}
let data = try! JSONSerialization.data(withJSONObject: ["screens": screensOut], options: [.sortedKeys])
FileHandle.standardOutput.write(data)
