import AppKit
import BarTapCore

/// Draws stats into menu bar images in the classic iStat Menus layouts: a history bar graph with
/// a percentage for CPU/GPU, a pie with a percentage for memory and disk, two lines with fixed
/// arrows for network, a battery glyph with a percentage, and plain values for sensors and time.
///
/// Every element has a FIXED position and every item a FIXED width; only right-aligned numbers
/// change. Nothing to the left of a changing number moves (no jumping arrows), and the item never
/// resizes (no shifting of the icons beside it). Images are monochrome templates, so they follow
/// the menu bar's light/dark/tinted appearance on every display.
enum StatsRenderer {
    static let height: CGFloat = 22
    private static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let tinyFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)

    struct Options {
        var fahrenheit = false
        var bits = false
        var clockFormat = "EEE HH:mm"
    }

    // MARK: Fixed geometry

    static let graphBars = 10
    static let graphWidth = CGFloat(graphBars) * 3 - 1          // 2 pt bars, 1 pt gaps
    static let pieSize: CGFloat = 13
    static let arrowWidth: CGFloat = 6
    static let batteryWidth: CGFloat = 21

    private static func textWidth(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
    private static var percentBox: CGFloat { textWidth("100%", valueFont) }
    private static func rateBox(_ o: Options) -> CGFloat { textWidth(o.bits ? "888 Kb/s" : "888 KB/s", lineFont) }

    private static var clockWidthCache: [String: CGFloat] = [:]

    /// Widest rendering of a clock format: every weekday, every month, both halves of the day.
    static func clockWidth(_ format: String) -> CGFloat {
        if let w = clockWidthCache[format] { return w }
        let f = DateFormatter()
        f.dateFormat = format
        var widest: CGFloat = 0
        var c = DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 58, second: 58)
        let cal = Calendar(identifier: .gregorian)
        for month in 1...12 {
            for day in [1, 22, 28] {
                for hour in [0, 10, 12, 22, 23] {
                    c.month = month; c.day = day; c.hour = hour
                    if let d = cal.date(from: c) { widest = max(widest, textWidth(f.string(from: d), valueFont)) }
                }
            }
        }
        for day in 1...7 {   // every weekday
            c.month = 3; c.day = day; c.hour = 22
            if let d = cal.date(from: c) { widest = max(widest, textWidth(f.string(from: d), valueFont)) }
        }
        let w = widest + 4
        clockWidthCache[format] = w
        return w
    }

    static func width(_ module: StatsModule, _ mode: StatsMode, _ o: Options) -> CGFloat {
        switch mode {
        case .graphPercent: return 1 + graphWidth + 4 + percentBox + 1
        case .graph: return module == .network ? 30 : graphWidth + 2
        case .percent: return percentBox + 2
        case .cores:
            let l = CPUReader.coreLayout()
            return CGFloat(max(1, l.performance + l.efficiency)) * 3 + 1
        case .pie: return pieSize + 2
        case .piePercent: return 1 + pieSize + 4 + percentBox + 1
        case .usedAmount, .freeAmount: return textWidth("888.8 GB", valueFont) + 2
        case .activity: return 1 + textWidth("W", lineFont) + 3 + rateBox(o) + 1
        case .rates: return 1 + arrowWidth + 3 + rateBox(o) + 1
        case .cpuTemperature: return textWidth("188°", valueFont) + 2
        case .temperatureAndFan: return max(textWidth("188°", lineFont), textWidth("8888 rpm", lineFont)) + 2
        case .power: return textWidth("188.8 W", valueFont) + 2
        case .iconPercent: return 1 + batteryWidth + 4 + percentBox + 1
        case .timeRemaining: return textWidth("88:88", valueFont) + 2
        case .clock: return clockWidth(o.clockFormat)
        }
    }

    // MARK: Images

    /// Pre-rendered 2x bitmap (cheaper for AppKit to ship to the menu bar host than a lazily
    /// drawn image).
    static func image(_ module: StatsModule, _ mode: StatsMode, _ s: StatsSnapshot?, _ o: Options, now: Date = Date()) -> NSImage {
        let w = width(module, mode, o)
        return bitmap(width: w) { rect in draw(module, mode, s, o, rect, now) }
    }

    static func bitmap(width w: CGFloat, scale: CGFloat = 2, _ draw: (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: w, height: height)
        let img = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(w * scale)), pixelsHigh: Int(height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.set()
            draw(NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            img.addRepresentation(rep)
        }
        img.isTemplate = true
        return img
    }

    static func drawContent(_ m: StatsModule, _ mode: StatsMode, _ s: StatsSnapshot?, _ o: Options, _ r: NSRect, now: Date = Date()) {
        NSColor.black.set()
        draw(m, mode, s, o, r, now)
    }

    // MARK: Content

    private static func draw(_ m: StatsModule, _ mode: StatsMode, _ s: StatsSnapshot?, _ o: Options, _ r: NSRect, _ now: Date) {
        switch mode {
        case .graphPercent:
            bars(history(m, s), x: 1)
            single(percentText(m, s), box: NSRect(x: 1 + graphWidth + 4, y: 0, width: percentBox, height: r.height))
        case .graph:
            if m == .network {
                let peak = max(s?.netDownHistory.suffix(14).max() ?? 0, s?.netUpHistory.suffix(14).max() ?? 0, 1024)
                area((s?.netUpHistory ?? []).suffix(14).map { $0 / peak }, NSRect(x: 1, y: 12, width: r.width - 2, height: 8))
                area((s?.netDownHistory ?? []).suffix(14).map { $0 / peak }, NSRect(x: 1, y: 2.5, width: r.width - 2, height: 8))
            } else {
                bars(history(m, s), x: 1)
            }
        case .percent:
            single(percentText(m, s), box: NSRect(x: 1, y: 0, width: percentBox, height: r.height))
        case .cores:
            let cores = s?.cpu?.perCore ?? []
            for (i, v) in cores.enumerated() {
                let x = 1 + CGFloat(i) * 3
                NSColor.black.withAlphaComponent(0.22).setFill()
                NSRect(x: x, y: 3, width: 2, height: 16).fill()
                NSColor.black.setFill()
                NSRect(x: x, y: 3, width: 2, height: max(1, 16 * CGFloat(min(1, v)))).fill()
            }
        case .pie:
            pie(fraction(m, s), center: NSPoint(x: 1 + pieSize / 2, y: r.midY))
        case .piePercent:
            pie(fraction(m, s), center: NSPoint(x: 1 + pieSize / 2, y: r.midY))
            single(percentText(m, s), box: NSRect(x: 1 + pieSize + 4, y: 0, width: percentBox, height: r.height))
        case .usedAmount:
            single(s?.memory.map { gigs($0.used) } ?? "–", box: NSRect(x: 1, y: 0, width: r.width - 2, height: r.height))
        case .freeAmount:
            single(s.flatMap { bootVolume($0) }.map { gigs($0.free) } ?? "–", box: NSRect(x: 1, y: 0, width: r.width - 2, height: r.height))
        case .activity:
            let labelW = textWidth("W", lineFont)
            label("R", x: 1, top: true)
            label("W", x: 1, top: false)
            twoLines(rateText(s?.diskRead, o, short: false), rateText(s?.diskWrite, o, short: false),
                     box: NSRect(x: 1 + labelW + 3, y: 0, width: rateBox(o), height: r.height))
        case .rates:
            arrow(up: true, x: 1)
            arrow(up: false, x: 1)
            twoLines(rateText(s?.netUp, o, short: false), rateText(s?.netDown, o, short: false),
                     box: NSRect(x: 1 + arrowWidth + 3, y: 0, width: rateBox(o), height: r.height))
        case .cpuTemperature:
            single(s?.sensors?.cpu.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "–",
                   box: NSRect(x: 1, y: 0, width: r.width - 2, height: r.height))
        case .temperatureAndFan:
            let t = s?.sensors?.cpu.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "–"
            let fan = s?.sensors?.fans.first.map { "\(Int($0.rpm)) rpm" } ?? "–"
            twoLines(t, fan, box: NSRect(x: 1, y: 0, width: r.width - 2, height: r.height))
        case .power:
            single(s?.sensors?.systemPower.map { String(format: "%.1f W", $0) } ?? "–",
                   box: NSRect(x: 1, y: 0, width: r.width - 2, height: r.height))
        case .iconPercent:
            battery(s?.battery, x: 1, midY: r.midY)
            single(s?.battery.map { "\($0.percent)%" } ?? "–", box: NSRect(x: 1 + batteryWidth + 4, y: 0, width: percentBox, height: r.height))
        case .timeRemaining:
            let b = s?.battery
            let value: String
            if let mins = b?.minutesRemaining { value = String(format: "%d:%02d", mins / 60, mins % 60) }
            else if b?.charged == true || (b?.onAC == true && b?.charging == false) { value = "AC" }
            else { value = "–" }
            single(value, box: NSRect(x: 1, y: 0, width: r.width - 2, height: r.height))
        case .clock:
            single(clockText(o.clockFormat, now), box: NSRect(x: 0, y: 0, width: r.width, height: r.height), align: .center)
        }
    }

    // MARK: Values

    static func history(_ m: StatsModule, _ s: StatsSnapshot?) -> [Double] {
        Array(((m == .gpu ? s?.gpuHistory : s?.cpuHistory) ?? []).suffix(graphBars))
    }

    static func fraction(_ m: StatsModule, _ s: StatsSnapshot?) -> Double {
        guard let s else { return 0 }
        switch m {
        case .memory: return s.memory?.usedFraction ?? 0
        case .disk: return bootVolume(s)?.usedFraction ?? 0
        default: return 0
        }
    }

    static func percentText(_ m: StatsModule, _ s: StatsSnapshot?) -> String {
        guard let s else { return "–" }
        switch m {
        case .cpu: return s.cpu.map { StatFormat.percent($0.total) } ?? "–"
        case .gpu: return s.gpu.map { StatFormat.percent($0) } ?? "–"
        case .memory: return s.memory.map { StatFormat.percent($0.usedFraction) } ?? "–"
        case .disk: return bootVolume(s).map { StatFormat.percent($0.usedFraction) } ?? "–"
        case .battery: return s.battery.map { "\($0.percent)%" } ?? "–"
        case .network, .sensors, .time: return "–"
        }
    }

    static func bootVolume(_ s: StatsSnapshot) -> VolumeInfo? {
        s.volumes.first { $0.mountPoint == "/" } ?? s.volumes.first
    }

    private static func gigs(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 100 ? "\(Int(g)) GB" : String(format: "%.1f GB", g)
    }

    private static func rateText(_ v: Double?, _ o: Options, short: Bool) -> String {
        guard let v else { return "–" }
        return short ? StatFormat.rate(v, compact: true, bits: o.bits) : StatFormat.rate(v, bits: o.bits)
    }

    private static var clockFormatters: [String: DateFormatter] = [:]
    static func clockText(_ format: String, _ now: Date) -> String {
        let f = clockFormatters[format] ?? {
            let f = DateFormatter()
            f.dateFormat = format
            clockFormatters[format] = f
            return f
        }()
        return f.string(from: now)
    }

    // MARK: Primitives

    private static func single(_ s: String, box: NSRect, align: NSTextAlignment = .right) {
        let lineHeight = ceil(valueFont.ascender - valueFont.descender)
        text(s, valueFont, NSRect(x: box.minX, y: box.minY + (box.height - lineHeight) / 2 - 0.5, width: box.width, height: lineHeight), align: align)
    }

    private static func twoLines(_ top: String, _ bottom: String, box: NSRect) {
        text(top, lineFont, NSRect(x: box.minX, y: 10.5, width: box.width, height: 11), align: .right)
        text(bottom, lineFont, NSRect(x: box.minX, y: 0.5, width: box.width, height: 11), align: .right)
    }

    private static func label(_ s: String, x: CGFloat, top: Bool) {
        text(s, lineFont, NSRect(x: x, y: top ? 10.5 : 0.5, width: 12, height: 11), align: .left)
    }

    private static func text(_ s: String, _ font: NSFont, _ r: NSRect, align: NSTextAlignment) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byClipping
        (s as NSString).draw(in: r, withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: p])
    }

    /// History as vertical bars, newest on the right, with a faint baseline.
    private static func bars(_ values: [Double], x: CGFloat) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSRect(x: x, y: 3, width: graphWidth, height: 1).fill()
        NSColor.black.setFill()
        let start = x + CGFloat(graphBars - values.count) * 3
        for (i, v) in values.enumerated() {
            let h = (16 * CGFloat(min(max(v, 0), 1))).rounded()
            guard h >= 1 else { continue }   // idle: only the baseline
            NSRect(x: start + CGFloat(i) * 3, y: 4, width: 2, height: h).fill()
        }
    }

    private static func area(_ values: [Double], _ r: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width, height: 0.75).fill()
        guard values.count >= 2 else { return }
        let step = r.width / CGFloat(max(values.count - 1, 1))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        for (i, v) in values.enumerated() {
            path.line(to: NSPoint(x: r.minX + CGFloat(i) * step, y: r.minY + r.height * CGFloat(min(max(v, 0), 1))))
        }
        path.line(to: NSPoint(x: r.maxX, y: r.minY))
        path.close()
        NSColor.black.withAlphaComponent(0.85).setFill()
        path.fill()
    }

    /// A disc whose filled wedge (clockwise from 12 o'clock) shows `fraction`.
    private static func pie(_ fraction: Double, center c: NSPoint) {
        let radius = pieSize / 2
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: pieSize, height: pieSize)).fill()
        let f = min(max(fraction, 0), 1)
        guard f > 0.005 else { return }
        NSColor.black.setFill()
        if f >= 0.995 {
            NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: pieSize, height: pieSize)).fill()
            return
        }
        let wedge = NSBezierPath()
        wedge.move(to: c)
        wedge.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(f), clockwise: true)
        wedge.close()
        wedge.fill()
    }

    /// Bold arrow at a fixed spot: up on the top line, down on the bottom line.
    private static func arrow(up: Bool, x: CGFloat) {
        let midY: CGFloat = up ? 15.5 : 5.5
        let w = arrowWidth, half: CGFloat = 3.6
        let p = NSBezierPath()
        let tip = up ? midY + half : midY - half
        let base = up ? midY - half : midY + half
        let headBase = up ? tip - 3.2 : tip + 3.2
        p.move(to: NSPoint(x: x + w / 2, y: tip))
        p.line(to: NSPoint(x: x + w, y: headBase))
        p.line(to: NSPoint(x: x + w / 2 + 0.95, y: headBase))
        p.line(to: NSPoint(x: x + w / 2 + 0.95, y: base))
        p.line(to: NSPoint(x: x + w / 2 - 0.95, y: base))
        p.line(to: NSPoint(x: x + w / 2 - 0.95, y: headBase))
        p.line(to: NSPoint(x: x, y: headBase))
        p.close()
        NSColor.black.setFill()
        p.fill()
    }

    private static func battery(_ b: BatteryInfo?, x: CGFloat, midY: CGFloat) {
        let body = NSRect(x: x + 0.5, y: midY - 4.5, width: batteryWidth - 3, height: 9)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.2, yRadius: 2.2)
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outline.stroke()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.8, y: midY - 1.6, width: 1.5, height: 3.2), xRadius: 0.7, yRadius: 0.7).fill()
        let level = CGFloat(min(max(b?.percent ?? 0, 0), 100)) / 100
        NSColor.black.setFill()
        let inner = body.insetBy(dx: 1.5, dy: 1.5)
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(1, inner.width * level), height: inner.height),
                     xRadius: 1.2, yRadius: 1.2).fill()
        if b?.charging == true {
            // Lightning bolt cut out of the fill.
            let bolt = NSBezierPath()
            let cx = body.midX, cy = body.midY
            bolt.move(to: NSPoint(x: cx + 1.2, y: cy + 3.6))
            bolt.line(to: NSPoint(x: cx - 2.2, y: cy - 0.4))
            bolt.line(to: NSPoint(x: cx - 0.1, y: cy - 0.4))
            bolt.line(to: NSPoint(x: cx - 1.2, y: cy - 3.6))
            bolt.line(to: NSPoint(x: cx + 2.2, y: cy + 0.6))
            bolt.line(to: NSPoint(x: cx + 0.1, y: cy + 0.6))
            bolt.close()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            bolt.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }

    // MARK: Change detection

    /// Everything that determines the pixels of an item, so unchanged content is never re-sent to
    /// the menu bar (each update costs a few ms in the menu bar host across displays on macOS 26).
    static func signature(_ m: StatsModule, _ mode: StatsMode, _ s: StatsSnapshot?, _ o: Options, now: Date = Date()) -> String {
        if mode == .clock { return "clock|\(o.clockFormat)|\(clockText(o.clockFormat, now))" }
        guard let s else { return "\(m.rawValue)|\(mode.rawValue)|nil" }
        func q(_ values: [Double], scale: Double = 1, steps: Double = 16) -> String {
            values.map { String(Int((min(max($0 / scale, 0), 1) * steps).rounded())) }.joined(separator: ",")
        }
        let t: String
        switch mode {
        case .graphPercent: t = q(history(m, s)) + "|" + percentText(m, s)
        case .graph:
            if m == .network {
                let peak = max(s.netDownHistory.suffix(14).max() ?? 0, s.netUpHistory.suffix(14).max() ?? 0, 1024)
                t = q(Array(s.netUpHistory.suffix(14)), scale: peak, steps: 16) + "/" + q(Array(s.netDownHistory.suffix(14)), scale: peak, steps: 16)
            } else {
                t = q(history(m, s))
            }
        case .percent: t = percentText(m, s)
        case .cores: t = q(s.cpu?.perCore ?? [])
        case .pie: t = String(Int((fraction(m, s) * 52).rounded()))
        case .piePercent: t = String(Int((fraction(m, s) * 52).rounded())) + "|" + percentText(m, s)
        case .usedAmount: t = s.memory.map { gigs($0.used) } ?? "-"
        case .freeAmount: t = bootVolume(s).map { gigs($0.free) } ?? "-"
        case .activity: t = rateText(s.diskRead, o, short: false) + "/" + rateText(s.diskWrite, o, short: false)
        case .rates: t = rateText(s.netUp, o, short: false) + "/" + rateText(s.netDown, o, short: false)
        case .cpuTemperature: t = s.sensors?.cpu.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "-"
        case .temperatureAndFan:
            t = (s.sensors?.cpu.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "-") + "/" + (s.sensors?.fans.first.map { "\(Int($0.rpm))" } ?? "-")
        case .power: t = s.sensors?.systemPower.map { String(format: "%.1f", $0) } ?? "-"
        case .iconPercent: t = "\(s.battery?.percent ?? -1)|\(s.battery?.charging ?? false)"
        case .timeRemaining: t = "\(s.battery?.minutesRemaining ?? -1)|\(s.battery?.charged ?? false)|\(s.battery?.onAC ?? false)"
        case .clock: t = ""
        }
        return "\(m.rawValue)|\(mode.rawValue)|\(t)"
    }

    static func accessibilityText(_ m: StatsModule, _ s: StatsSnapshot?, _ o: Options, now: Date = Date()) -> String {
        if m == .time { return clockText(o.clockFormat, now) }
        guard let s else { return m.rawValue }
        switch m {
        case .cpu: return "CPU \(s.cpu.map { StatFormat.percent($0.total) } ?? "")"
        case .gpu: return "GPU \(s.gpu.map { StatFormat.percent($0) } ?? "")"
        case .memory: return "Memory \(s.memory.map { StatFormat.percent($0.usedFraction) } ?? "")"
        case .disk: return "Disk \(bootVolume(s).map { StatFormat.percent($0.usedFraction) } ?? "")"
        case .network: return "Network up \(StatFormat.rate(s.netUp, bits: o.bits)), down \(StatFormat.rate(s.netDown, bits: o.bits))"
        case .sensors: return "CPU temperature \(s.sensors?.cpu.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "")"
        case .battery: return "Battery \(s.battery.map { "\($0.percent)%" } ?? "")"
        case .time: return ""
        }
    }
}
