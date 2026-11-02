import AppKit
import ScreenCaptureKit
import BarTapCore

/// Real images of menu bar icons for the shelf, captured from the window server. This needs
/// Screen Recording; without it the shelf shows app icons. Nothing is captured except when the
/// shelf opens, and only the icons it lists.
enum ItemImages {
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    /// The system prompt appears only once; after that, the switch lives in System Settings.
    static func request() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The last real image of each icon (by `BarItem.slotKey`). Hidden icons are drawn nowhere, so
    /// the shelf shows what was captured while they were visible (the Layout pane reveals them all).
    /// Only icons of the latest capture are kept: a few KB each.
    private(set) static var cache: [String: NSImage] = [:]
    /// What happened to each icon in the last capture (debug).
    private(set) static var lastLog: [String: String] = [:]

    /// Captures each icon on whichever display draws it. Every display lays the bar out the same way
    /// from its right edge, so its window is found by where its centre is from that edge (the window
    /// adds macOS's padding around the button Accessibility reports, so widths differ). The display
    /// is captured with only that window in it, cropped to the button: a window captured on its own
    /// comes back blank for template icons (most of them), which the menu bar tints as it composites.
    /// Hidden icons are drawn nowhere and are simply missing. Completion runs on the main thread.
    static func capture(_ items: [BarItem], completion: @escaping ([String: NSImage]) -> Void) {
        guard #available(macOS 14.0, *), permitted, !items.isEmpty else { completion([:]); return }
        let screens = SystemQueries.screens()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content else { DispatchQueue.main.async { completion([:]) }; return }
            let drawn: [(window: SCWindow, rd: CGFloat, display: SCDisplay)] = content.windows.compactMap { w in
                guard w.windowLayer == WindowLevel.status, w.isOnScreen,
                      let s = screens.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }),
                      MenuBarSections.inMenuBar(w.frame, of: s),
                      let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }) else { return nil }
                return (w, MenuBarGeometry.rightDistance(of: w.frame, on: s), d)
            }
            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [String: NSImage] = [:]
            var log: [String: String] = [:]
            for item in items {
                let centre = item.order + item.frame.width / 2
                // Its window on each display, widest bar first: a narrow bar may not draw it (an
                // icon that doesn't fit is still listed but comes back blank).
                let candidates = drawn.filter { d in
                    let w = d.window.frame.width
                    // Measured: centres agree within 2 pt; most windows are the button plus 14–16 pt of
                    // padding, a few apps' (Electron, Catalyst) 2 pt narrower than their button.
                    return abs(d.rd + w / 2 - centre) <= 4 && w >= item.frame.width - 4 && w - item.frame.width <= 28
                }.sorted { $0.display.frame.width > $1.display.frame.width }
                guard !candidates.isEmpty else { log[item.slotKey] = "no window"; continue }
                group.enter()
                // Each display's copy, first alone (a clean icon), then as composited on screen: some
                // icons only come out there (with a sliver of menu bar behind them).
                let tries = candidates.flatMap { c in [(c, true), (c, false)] }
                func attempt(_ i: Int) {
                    guard i < tries.count else {
                        lock.lock(); log[item.slotKey] = "empty"; lock.unlock()
                        group.leave()
                        return
                    }
                    let ((window, _, display), alone) = tries[i]
                    let frame = window.frame
                    let size = CGSize(width: min(item.frame.width, frame.width), height: min(item.frame.height, frame.height))
                    let config = SCStreamConfiguration()
                    config.sourceRect = CGRect(x: frame.minX - display.frame.minX + (frame.width - size.width) / 2,
                                               y: frame.minY - display.frame.minY + (frame.height - size.height) / 2,
                                               width: size.width, height: size.height)
                    config.width = max(1, Int(size.width * scale))
                    config.height = max(1, Int(size.height * scale))
                    config.showsCursor = false
                    let filter = alone ? SCContentFilter(display: display, including: [window]) : SCContentFilter(display: display, excludingWindows: [])
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                        guard let image, hasContent(image) else { attempt(i + 1); return }
                        lock.lock()
                        let clean = alone ? detached(image) : withoutBackground(image)
                        images[item.slotKey] = NSImage(cgImage: clean ?? image, size: size)
                        log[item.slotKey] = alone ? "ok" : "ok (screen)"
                        lock.unlock()
                        group.leave()
                    }
                }
                attempt(0)
            }
            group.notify(queue: .main) {
                lastLog = log
                let current = Set(items.map(\.slotKey))
                cache = cache.filter { current.contains($0.key) }.merging(images) { $1 }
                completion(cache.filter { current.contains($0.key) })
            }
        }
    }

    /// A plain copy: a capture is backed by a GPU surface far larger than the icon, which the cache
    /// would otherwise keep alive.
    private static func detached(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// An icon captured from the screen sits on a patch of menu bar tinted by the wallpaper, and
    /// macOS draws template icons there as a lighter (or darker) shade of that tint. Rebuild it as a
    /// plain silhouette: white where it is lighter than the colour around its border (a dark bar),
    /// black where it is darker (a light bar), with that difference as its opacity.
    private static func withoutBackground(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 2, h > 2, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func lum(_ o: Int) -> Double { 0.299 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.114 * Double(p[o + 2]) }
        // The background: the median brightness along the border.
        var border: [Double] = []
        for x in 0..<w { for y in [0, h - 1] { border.append(lum((y * w + x) * 4)) } }
        for y in 0..<h { for x in [0, w - 1] { border.append(lum((y * w + x) * 4)) } }
        let bg = border.sorted()[border.count / 2]
        // Lighter or darker glyph: whichever way the pixels that differ most lean.
        var lean = 0.0
        for i in 0..<(w * h) { let d = lum(i * 4) - bg; if abs(d) > 30 { lean += d } }
        let lighter = lean >= 0
        // Scaled to the strongest pixel, so the glyph's core comes out fully opaque.
        var strongest = 0.0
        for i in 0..<(w * h) { strongest = max(strongest, lighter ? lum(i * 4) - bg : bg - lum(i * 4)) }
        let range = max(30, strongest - 8)
        let ink: UInt8 = lighter ? 255 : 0
        for i in 0..<(w * h) {
            let o = i * 4
            let a = min(max(((lighter ? lum(o) - bg : bg - lum(o)) - 8) / range, 0), 1)
            for c in 0..<3 { p[o + c] = UInt8(Double(ink) * a) }   // premultiplied
            p[o + 3] = UInt8(255 * a)
        }
        return ctx.makeImage()
    }

    /// A capture of an icon the window server didn't draw comes back fully transparent.
    private static func hasContent(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) where bytes[i] > 16 { return true }
        return false
    }
}
