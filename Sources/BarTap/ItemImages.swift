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

    /// Captures each item's window, found by its Accessibility frame. Completion runs on the main
    /// thread, keyed by `BarItem.key`; items that couldn't be captured are simply missing.
    static func capture(_ items: [BarItem], completion: @escaping ([String: NSImage]) -> Void) {
        guard #available(macOS 14.0, *), permitted, !items.isEmpty else { completion([:]); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            guard let content else { DispatchQueue.main.async { completion([:]) }; return }
            let status = content.windows.filter { $0.windowLayer == WindowLevel.status }
            // Every icon has a window on each display; take the one at the icon's own frame (AX
            // reports the button a few points into the bar; the window spans the bar's height).
            let pairs: [(key: String, window: SCWindow)] = items.compactMap { item in
                status.first {
                    abs($0.frame.minX - item.frame.minX) <= 3 && abs($0.frame.width - item.frame.width) <= 4
                        && $0.frame.minY - 1 <= item.frame.midY && item.frame.midY <= $0.frame.maxY + 1
                }.map { (item.key, $0) }
            }
            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [String: NSImage] = [:]
            for pair in pairs {
                group.enter()
                let config = SCStreamConfiguration()
                config.width = max(1, Int(pair.window.frame.width * scale))
                config.height = max(1, Int(pair.window.frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: pair.window),
                                                 configuration: config) { image, _ in
                    if let image, hasContent(image) {
                        lock.lock()
                        images[pair.key] = NSImage(cgImage: image, size: pair.window.frame.size)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(images) }
        }
    }

    /// A capture of a window the window server didn't render comes back fully transparent.
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
