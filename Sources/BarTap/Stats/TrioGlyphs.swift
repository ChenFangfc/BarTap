import AppKit
import BarTapCore

/// Menu bar glyphs for the Volume, Bluetooth and 3-in-1 items. Like the rest of StatsRenderer they
/// are black-on-clear template drawings with fixed geometry: a level only changes which parts are
/// solid and which are faint, never where anything sits.
enum TrioGlyphs {
    static let speakerWidth: CGFloat = 16
    static let meterWidth = CGFloat(VolumeMath.meterBars) * 3 - 1
    static let bluetoothWidth: CGFloat = 8
    static let miniBatteryWidth: CGFloat = 15
    static let trioWidth: CGFloat = 22

    /// Parts that are "off" (quieter waves, missing signal arcs) stay faintly visible.
    private static let faint: CGFloat = 0.25

    private static func solid(_ on: Bool) -> NSColor { NSColor.black.withAlphaComponent(on ? 1 : faint) }

    /// Clears a halo around a stroke, then draws it, so a slash stays readable over solid parts.
    private static func cutStroke(_ p: NSBezierPath, width: CGFloat) {
        p.lineCapStyle = .round
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        p.lineWidth = width + 2
        p.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setStroke()
        p.lineWidth = width
        p.stroke()
    }

    private static func arc(center c: NSPoint, radius: CGFloat, from a0: CGFloat, to a1: CGFloat, width: CGFloat, on: Bool) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: radius, startAngle: a0, endAngle: a1)
        p.lineWidth = width
        p.lineCapStyle = .round
        solid(on).setStroke()
        p.stroke()
    }

    // MARK: Volume

    /// A speaker: three waves, solid up to the level; muted or silent draws a slash instead.
    static func speaker(waves: Int, muted: Bool, x: CGFloat, midY: CGFloat) {
        let cone = NSBezierPath()
        cone.move(to: NSPoint(x: x + 0.8, y: midY - 2.3))
        cone.line(to: NSPoint(x: x + 3.4, y: midY - 2.3))
        cone.line(to: NSPoint(x: x + 6.8, y: midY - 5.5))
        cone.line(to: NSPoint(x: x + 6.8, y: midY + 5.5))
        cone.line(to: NSPoint(x: x + 3.4, y: midY + 2.3))
        cone.line(to: NSPoint(x: x + 0.8, y: midY + 2.3))
        cone.close()
        cone.lineJoinStyle = .round
        cone.lineWidth = 0.8
        NSColor.black.set()
        cone.fill()
        cone.stroke()
        let c = NSPoint(x: x + 4.6, y: midY)
        for (i, r) in [CGFloat(4.5), 7.3, 10.1].enumerated() {
            arc(center: c, radius: r, from: -42, to: 42, width: 1.45, on: !muted && waves > i)
        }
        if muted || waves == 0 {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: x + 1.2, y: midY + 6.6))
            slash.line(to: NSPoint(x: x + 14.6, y: midY - 6.6))
            cutStroke(slash, width: 1.5)
        }
    }

    /// Eight rising bars, solid up to the level (all faint when muted).
    static func levelMeter(filled: Int, x: CGFloat, bottom: CGFloat) {
        let n = VolumeMath.meterBars
        for i in 0..<n {
            let h = (4 + 11 * CGFloat(i) / CGFloat(n - 1)).rounded()
            solid(i < filled).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + CGFloat(i) * 3, y: bottom, width: 2, height: h), xRadius: 0.6, yRadius: 0.6).fill()
        }
    }

    // MARK: Bluetooth

    /// The Bluetooth rune, solid while devices are connected.
    static func bluetooth(x: CGFloat, midY: CGFloat, active: Bool) {
        let h: CGFloat = 13
        let bottom = midY - h / 2
        let left = x + 0.6, right = x + 7.0, spine = x + 3.6
        let p = NSBezierPath()
        p.move(to: NSPoint(x: left, y: bottom + 0.27 * h))
        p.line(to: NSPoint(x: right, y: bottom + 0.71 * h))
        p.line(to: NSPoint(x: spine, y: bottom + h))
        p.line(to: NSPoint(x: spine, y: bottom))
        p.line(to: NSPoint(x: right, y: bottom + 0.29 * h))
        p.line(to: NSPoint(x: left, y: bottom + 0.73 * h))
        p.lineWidth = 1.35
        p.lineCapStyle = .round
        p.lineJoinStyle = .miter
        p.miterLimit = 4
        NSColor.black.withAlphaComponent(active ? 1 : 0.45).setStroke()
        p.stroke()
    }

    /// A small battery filled to `level` (0…1); an empty outline when unknown.
    static func miniBattery(_ level: Double?, x: CGFloat, midY: CGFloat) {
        let body = NSRect(x: x + 0.5, y: midY - 3.5, width: 12, height: 7)
        let outline = NSBezierPath(roundedRect: body, xRadius: 1.8, yRadius: 1.8)
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outline.stroke()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.7, y: midY - 1.3, width: 1.3, height: 2.6), xRadius: 0.6, yRadius: 0.6).fill()
        guard let level else { return }
        let inner = body.insetBy(dx: 1.4, dy: 1.4)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(1, inner.width * CGFloat(min(max(level, 0), 1))), height: inner.height),
                     xRadius: 0.9, yRadius: 0.9).fill()
    }

    // MARK: 3-in-1

    /// One 22 × 22 pt glyph: Wi-Fi signal (top left) and volume (top right) sit on the battery
    /// gauge, which spans the whole width. `waves` < 0: volume not known yet (faint, no slash).
    static func trio(battery: Double?, charging: Bool, wifiBars: Int, waves: Int, muted: Bool, x: CGFloat, y: CGFloat) {
        // Battery: outline, nub, fill; a bolt with a cleared rim while charging.
        let body = NSRect(x: x + 0.75, y: y + 2.25, width: 18.2, height: 7.25)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.2, yRadius: 2.2)
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(battery == nil ? 0.3 : 0.55).setStroke()
        outline.stroke()
        NSColor.black.withAlphaComponent(battery == nil ? 0.3 : 0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.8, y: body.midY - 1.5, width: 1.5, height: 3), xRadius: 0.7, yRadius: 0.7).fill()
        let inner = body.insetBy(dx: 1.4, dy: 1.4)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(1, inner.width * CGFloat(min(max(battery ?? 0, 0), 1))), height: inner.height)
        if battery != nil {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.1, yRadius: 1.1).fill()
        }
        if charging {
            // The bolt is cut out of the fill and solid over the empty part, so it reads at any level.
            let cx = body.midX, cy = body.midY
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: cx + 1.3, y: cy + 3.5))
            bolt.line(to: NSPoint(x: cx - 2.4, y: cy - 0.45))
            bolt.line(to: NSPoint(x: cx - 0.2, y: cy - 0.45))
            bolt.line(to: NSPoint(x: cx - 1.3, y: cy - 3.5))
            bolt.line(to: NSPoint(x: cx + 2.4, y: cy + 0.65))
            bolt.line(to: NSPoint(x: cx + 0.2, y: cy + 0.65))
            bolt.close()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: fill).addClip()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            bolt.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: body.insetBy(dx: -2, dy: -2))
            outside.append(NSBezierPath(rect: fill))
            outside.windingRule = .evenOdd
            outside.addClip()
            NSColor.black.setFill()
            bolt.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Wi-Fi: a wedge and two arcs.
        let fan = NSPoint(x: x + 5.5, y: y + 11.6)
        let wedge = NSBezierPath()
        wedge.move(to: fan)
        wedge.appendArc(withCenter: fan, radius: 2.5, startAngle: 50, endAngle: 130)
        wedge.close()
        solid(wifiBars >= 1).setFill()
        wedge.fill()
        arc(center: fan, radius: 5.0, from: 50, to: 130, width: 1.4, on: wifiBars >= 2)
        arc(center: fan, radius: 7.6, from: 50, to: 130, width: 1.4, on: wifiBars >= 3)

        // Volume: a small speaker with two waves, or a slash when muted.
        let mid = y + 15.3
        let cone = NSBezierPath()
        cone.move(to: NSPoint(x: x + 12.3, y: mid - 1.5))
        cone.line(to: NSPoint(x: x + 13.9, y: mid - 1.5))
        cone.line(to: NSPoint(x: x + 16.2, y: mid - 3.7))
        cone.line(to: NSPoint(x: x + 16.2, y: mid + 3.7))
        cone.line(to: NSPoint(x: x + 13.9, y: mid + 1.5))
        cone.line(to: NSPoint(x: x + 12.3, y: mid + 1.5))
        cone.close()
        cone.lineJoinStyle = .round
        cone.lineWidth = 0.6
        NSColor.black.set()
        cone.fill()
        cone.stroke()
        let quiet = muted || waves == 0
        arc(center: NSPoint(x: x + 14.6, y: mid), radius: 3.6, from: -45, to: 45, width: 1.25, on: !quiet && waves >= 1)
        arc(center: NSPoint(x: x + 14.6, y: mid), radius: 6.0, from: -45, to: 45, width: 1.25, on: !quiet && waves >= 2)
        if quiet {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: x + 12.2, y: mid + 4.4))
            slash.line(to: NSPoint(x: x + 20.4, y: mid - 4.0))
            cutStroke(slash, width: 1.25)
        }
    }
}
