// README images, composed from promo/assets (real BarTap renderings of sample data):
//
//   swiftc -O promo/shots.swift -o .build/shots && .build/shots <repo>
//
// Writes docs/media/{bar,panels}-{light,dark}.png.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let out = root.appendingPathComponent("docs/media")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func asset(_ path: String) -> NSImage {
    guard let img = NSImage(contentsOf: root.appendingPathComponent("promo/assets/" + path)) else { fatalError("missing \(path)") }
    return img
}

func render(_ size: NSSize, scale: CGFloat, _ name: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote docs/media/\(name)")
}

func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: img.size, flipped: false) { r in
        img.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
}

func card(_ r: NSRect, radius: CGFloat, dark: Bool, fill: NSColor, shadowBlur: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.14)
    shadow.shadowBlurRadius = shadowBlur
    shadow.shadowOffset = NSSize(width: 0, height: -shadowBlur / 3)
    shadow.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    return path
}

// 1. A menu bar strip: the toggle and every stats module, as BarTap draws them.
let items = ["toggle_collapsed", "cpu_3", "gpu_3", "memory_3", "disk_3", "network_3", "sensors_3", "battery_3", "time_3"]
    .map { asset("items/\($0).png") }
let gap: CGFloat = 12, pad: CGFloat = 14, barH: CGFloat = 30, margin: CGFloat = 18
let contentW = items.reduce(0) { $0 + $1.size.width } + gap * CGFloat(items.count - 1)
for dark in [false, true] {
    render(NSSize(width: contentW + 2 * (pad + margin), height: barH + 2 * margin), scale: 3, "bar-\(dark ? "dark" : "light").png") {
        let bar = NSRect(x: margin, y: margin, width: contentW + 2 * pad, height: barH)
        _ = card(bar, radius: 9, dark: dark, fill: dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.975, alpha: 1), shadowBlur: 12)
        var x = bar.minX + pad
        for img in items {
            tinted(img, dark ? .white : NSColor(white: 0.08, alpha: 1))
                .draw(in: NSRect(x: x, y: bar.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            x += img.size.width + gap
        }
    }
}

// 2. Three dropdowns side by side.
for dark in [false, true] {
    let panels = ["cpu", "network", "sensors"].map { asset("panel_\($0)_\(dark ? "dark" : "light").png") }
    let pg: CGFloat = 28, m: CGFloat = 36
    let w = panels.reduce(0) { $0 + $1.size.width } + pg * CGFloat(panels.count - 1) + 2 * m
    let h = (panels.map(\.size.height).max() ?? 0) + 2 * m
    render(NSSize(width: w, height: h), scale: 2, "panels-\(dark ? "dark" : "light").png") {
        var x = m
        for p in panels {
            let r = NSRect(x: x, y: h - m - p.size.height, width: p.size.width, height: p.size.height)
            let path = card(r, radius: 12, dark: dark, fill: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.985, alpha: 1), shadowBlur: 24)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            p.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)).setStroke()
            path.lineWidth = 1
            path.stroke()
            x += p.size.width + pg
        }
    }
}
