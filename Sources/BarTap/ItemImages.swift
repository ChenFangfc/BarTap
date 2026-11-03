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
    /// Only icons of the latest capture are kept: a few KB each, on disk too, so a restart doesn't
    /// leave the shelf with app icons until every icon is out again.
    private(set) static var cache: [String: NSImage] = loadStore()
    /// v3: icons matched by their windows' names, trimmed to the glyph, and only real glyphs. The
    /// earlier stores could hold one app's icon under another's name, or an icon's empty window.
    private static let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BarTap/icon-images-v3.plist")
    private static let oldStores = ["icon-images.plist", "icon-images-v2.plist"].map { store.deletingLastPathComponent().appendingPathComponent($0) }
    private static var saveScheduled = false
    /// What happened to each icon in the last capture (debug).
    private(set) static var lastLog: [String: String] = [:]

    /// Captures each icon on whichever display draws it. Every display lays the bar out the same way
    /// from its right edge, so its window is found by where its centre is from that edge (the window
    /// adds macOS's padding around the button Accessibility reports, so widths differ). The display
    /// is captured with only that window in it, cropped to the button: a window captured on its own
    /// comes back blank for template icons (most of them), which the menu bar tints as it composites.
    /// Hidden icons are drawn nowhere and are simply missing. Completion runs on the main thread.
    ///
    /// - Parameter all: every icon in the bar (when `items` are some of them), to tell which of an
    ///   app's windows is which.
    static func capture(_ items: [BarItem], all: [BarItem]? = nil, completion: @escaping ([String: NSImage]) -> Void) {
        guard #available(macOS 14.0, *), permitted, !items.isEmpty else { completion([:]); return }
        // Each app's icons, left to right (the k-th of an app's windows is its k-th icon).
        let byApp = Dictionary(grouping: all ?? items, by: \.bundleID).mapValues { $0.sorted { $0.order > $1.order }.map(\.slotKey) }
        let screens = SystemQueries.screens()
        let scales = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, CGFloat)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, s.backingScaleFactor)
        }, uniquingKeysWith: { first, _ in first })
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content else { DispatchQueue.main.async { completion([:]) }; return }
            // macOS 26 names a status item's window after its app's bundle ID on each display but the
            // one hosting the bar (with Screen Recording, which capturing needs anyway). Places from
            // Accessibility can be stale for icons that were hidden, and matching by place alone once
            // filed one app's icon under another; a name can't be wrong.
            let names = Dictionary(SystemQueries.windows(onScreenOnly: true).compactMap { w -> (CGWindowID, String)? in
                guard w.layer == WindowLevel.status, let n = w.name, !n.isEmpty else { return nil }
                return (CGWindowID(w.id), n)
            }, uniquingKeysWith: { first, _ in first })
            let drawn: [(window: SCWindow, rd: CGFloat, display: SCDisplay)] = content.windows.compactMap { w in
                guard w.windowLayer == WindowLevel.status, w.isOnScreen,
                      let s = screens.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }),
                      MenuBarSections.inMenuBar(w.frame, of: s),
                      let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }) else { return nil }
                return (w, MenuBarGeometry.rightDistance(of: w.frame, on: s), d)
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [String: NSImage] = [:]
            var log: [String: String] = [:]
            for item in items {
                let centre = item.order + item.frame.width / 2
                func scale(_ d: SCDisplay) -> CGFloat { scales[d.displayID] ?? 2 }
                // By name: on a display that draws all of the app's icons, its k-th window.
                let siblings = byApp[item.bundleID] ?? [item.slotKey]
                let k = siblings.firstIndex(of: item.slotKey) ?? 0
                var named: [(window: SCWindow, rd: CGFloat, display: SCDisplay)] = []
                for display in content.displays {
                    let mine = drawn.filter { $0.display.displayID == display.displayID && names[$0.window.windowID] == item.bundleID }
                        .sorted { $0.window.frame.minX < $1.window.frame.minX }
                    if mine.count == siblings.count, k < mine.count { named.append(mine[k]) }
                }
                // Otherwise by place (Control Center's icons are unnamed; the hosting display uses
                // autosave names). Measured: centres agree within 2 pt; most windows are the button
                // plus 14–16 pt of padding, a few apps' (Electron, Catalyst) 2 pt narrower.
                let placed = drawn.filter { d in
                    let w = d.window.frame.width
                    return abs(d.rd + w / 2 - centre) <= 4 && w >= item.frame.width - 4 && w - item.frame.width <= 28
                        && (names[d.window.windowID].map { n in Self.mayBelong(n, to: item.bundleID) } ?? true)
                }
                // Sharpest bar first (a 1x display's copy comes out soft on a Retina one), then widest:
                // a narrow bar may not draw it (an icon that doesn't fit is still listed but blank).
                let candidates = (named.isEmpty ? placed : named)
                    .sorted { (scale($0.display), $0.display.frame.width) > (scale($1.display), $1.display.frame.width) }
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
                    config.width = max(1, Int(size.width * scale(display)))
                    config.height = max(1, Int(size.height * scale(display)))
                    config.showsCursor = false
                    let filter = alone ? SCContentFilter(display: display, including: [window]) : SCContentFilter(display: display, excludingWindows: [])
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                        guard let image, hasContent(image) else { attempt(i + 1); return }
                        let clean = alone ? detached(image) : withoutBackground(image)
                        let template = templated(clean ?? image)
                        // Just the glyph: shown at its own size, never shrunk to fit a row.
                        let glyph = template ?? clean ?? image
                        let final = trimmed(glyph) ?? glyph
                        // An app that hasn't drawn its icon yet (it was off screen) leaves its window
                        // empty but for a faint backdrop or an edge: not an icon, try elsewhere/later.
                        guard isGlyph(final) else { attempt(i + 1); return }
                        lock.lock()
                        let px = scale(display)
                        let result = NSImage(cgImage: final, size: NSSize(width: CGFloat(final.width) / px, height: CGFloat(final.height) / px))
                        result.isTemplate = template != nil
                        images[item.slotKey] = result
                        log[item.slotKey] = (alone ? "ok" : "ok (screen)") + (template != nil ? ", template" : "")
                        lock.unlock()
                        group.leave()
                    }
                }
                attempt(0)
            }
            group.notify(queue: .main) {
                lastLog = log
                // Icons still in the bar keep their images (the shelf captures only hidden ones).
                let current = Set((all ?? items).map(\.slotKey))
                let kept = cache.filter { current.contains($0.key) }
                if !images.isEmpty || kept.count != cache.count { scheduleSave() }
                cache = kept.merging(images) { $1 }
                completion(cache.filter { current.contains($0.key) })
            }
        }
    }

    // MARK: On disk

    private static func loadStore() -> [String: NSImage] {
        for old in oldStores { try? FileManager.default.removeItem(at: old) }
        guard let data = try? Data(contentsOf: store),
              let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return [:] }
        var out: [String: NSImage] = [:]
        for (key, row) in rows {
            guard let png = row["png"] as? Data, let w = row["w"] as? Double, let h = row["h"] as? Double,
                  let rep = NSBitmapImageRep(data: png) else { continue }
            let image = NSImage(size: NSSize(width: w, height: h))
            rep.size = image.size
            image.addRepresentation(rep)
            image.isTemplate = row["template"] as? Bool ?? false
            if let cg = rep.cgImage, !isGlyph(cg) { continue }
            out[key] = image
        }
        return out
    }

    /// Captures come in bursts (the Layout pane retries slow icons): write once they're done.
    private static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveScheduled = false
            var rows: [String: [String: Any]] = [:]
            for (key, image) in cache where !key.contains("|bartap.stats.") {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                rows[key] = ["png": png, "w": Double(image.size.width), "h": Double(image.size.height), "template": image.isTemplate]
            }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0) else { return }
            try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: store, options: .atomic)
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

    /// Most menu bar icons are template images: one colour plus transparency, which the menu bar
    /// tints to suit what's behind it. A capture keeps whichever colour it was drawn in (often the
    /// plain black template, even on a dark bar), so it turns illegible on a dark shelf. One without
    /// colour comes back as a template again (black, its strength as opacity), to be drawn in the
    /// colour of wherever it's shown; nil keeps an icon with colour as it is.
    private static func templated(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // An icon on a backing of its own: there's no telling its glyph from the backing.
        var edge: [Int] = []
        for x in 0..<w { edge += [x, (h - 1) * w + x] }
        for y in 0..<h { edge += [y * w, y * w + w - 1] }
        guard edge.filter({ p[$0 * 4 + 3] > 200 }).count * 2 < edge.count else { return nil }
        // Premultiplied: a pixel's colour over its alpha is the colour itself (0…1).
        func lum(_ o: Int) -> Double { (0.299 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.114 * Double(p[o + 2])) / Double(p[o + 3]) }
        var ink = 0.0, coloured = 0.0, light = 0.0
        for i in 0..<(w * h) {
            let o = i * 4, a = Double(p[o + 3])
            guard a > 8 else { continue }
            let c = [p[o], p[o + 1], p[o + 2]].map { Double($0) / a }
            ink += a
            if c.max()! - c.min()! > 0.12 { coloured += a }
            light += a * lum(o)
        }
        guard ink > 0, coloured / ink < 0.02 else { return nil }
        // A white icon (drawn for a dark bar) is as strong as it is light, a black one as it is dark.
        let white = light / ink >= 0.5
        var alpha = [Double](repeating: 0, count: w * h)
        var strongest = 0.0
        for i in 0..<(w * h) {
            let o = i * 4
            guard p[o + 3] > 0 else { continue }
            alpha[i] = Double(p[o + 3]) * (white ? lum(o) : 1 - lum(o))
            strongest = max(strongest, alpha[i])
        }
        // The glyph's core fully opaque, as the menu bar draws it: a capture through the bar's
        // vibrancy comes out a shade or two weaker, which read as grey and soft on the shelf. Faint
        // specks of what was behind the bar go.
        // (Only a glyph that is already strong: a faint backdrop must stay faint.)
        let gain = strongest >= 140 ? 255 / strongest : 1
        for i in 0..<(w * h) {
            let o = i * 4
            let a = min(alpha[i] * gain, 255)
            p[o] = 0; p[o + 1] = 0; p[o + 2] = 0
            p[o + 3] = a < 20 ? 0 : UInt8(a)
        }
        return ctx.makeImage()
    }

    /// A window's name rules out a match when it names another app (a bundle ID) or is one of
    /// BarTap's own (its autosave names start "tb_").
    static func mayBelong(_ name: String, to bundleID: String) -> Bool {
        if name.hasPrefix("tb_") { return bundleID == Bundle.main.bundleIdentifier }
        return name.contains(".") ? name == bundleID : true
    }

    /// Without the empty bar around the glyph (one pixel of it kept; faint specks of what was
    /// behind the bar don't count). Rows of memory run top down, as `cropping(to:)` counts them.
    static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 2, h > 2, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let a = data.bindMemory(to: UInt8.self, capacity: w * h)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where a[y * w + x] > 48 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let x0 = max(0, minX - 1), y0 = max(0, minY - 1)
        return image.cropping(to: CGRect(x: x0, y: y0, width: min(w, maxX + 2) - x0, height: min(h, maxY + 2) - y0))
    }

    /// An icon for a row of icons (the shelf): trimmed, then on a canvas of whole points (an even
    /// number high) drawn pixel for pixel and centred on whole pixels. A menu bar glyph shrunk by
    /// a fraction or shifted half a pixel is what looked blurry.
    static func crisp(_ image: NSImage, maxHeight: CGFloat) -> NSImage {
        guard image.size.width > 0, image.size.height > 0,
              var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let scale = max(1, (CGFloat(cg.width) / image.size.width).rounded())
        cg = trimmed(cg) ?? cg
        var w = CGFloat(cg.width) / scale, h = CGFloat(cg.height) / scale
        let shrink = h > maxHeight
        if shrink { w *= maxHeight / h; h = maxHeight }
        let canvas = NSSize(width: ceil(w), height: ceil(h / 2) * 2)
        let pw = Int(canvas.width * scale), ph = Int(canvas.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = shrink ? .high : .none
        let dw = shrink ? Int((w * scale).rounded()) : cg.width, dh = shrink ? Int((h * scale).rounded()) : cg.height
        ctx.draw(cg, in: CGRect(x: (pw - dw) / 2, y: (ph - dh) / 2, width: dw, height: dh))
        guard let out = ctx.makeImage() else { return image }
        let result = NSImage(cgImage: out, size: canvas)
        result.isTemplate = image.isTemplate
        return result
    }

    /// Real ink: a few dozen strong pixels over at least 4 × 4 px (an empty window's backdrop is
    /// faint everywhere; an edge is a line).
    static func isGlyph(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        guard w >= 4, h >= 4, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let a = data.bindMemory(to: UInt8.self, capacity: w * h)
        var strong = 0, minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where a[y * w + x] >= 128 {
                strong += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return strong >= 12 && maxX - minX >= 3 && maxY - minY >= 3
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
