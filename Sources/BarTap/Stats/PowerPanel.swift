import AppKit
import BarTapCore

// The Power item's details: where the power comes from and where it goes (a flow diagram whose
// dots move along the flows), the last two minutes, battery and adapter figures, and apps by
// energy. Built when the details open, updated once a second while they're open, dropped when
// they close. The diagram and graph are drawn once per update; only the dots move in between,
// and Core Animation moves those (no redraws, no timers in BarTap).

/// One color per part, source and sink: the first five slots of the categorical palette in
/// their order (checked for color-vision deficiency, with their own dark steps), a neutral
/// "other", green for the adapter, violet for the battery and a neutral hub for the Mac.
enum PowerColors {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    static let cpu = dynamic(0x2A78D6, 0x3987E5)
    static let gpu = dynamic(0xEB6834, 0xD95926)
    static let memory = dynamic(0x1BAF7A, 0x199E70)
    static let display = dynamic(0xEDA100, 0xC98500)
    static let ane = dynamic(0xE87BA4, 0xD55181)
    static let other = dynamic(0x898781, 0x898781)
    static let adapter = dynamic(0x008300, 0x008300)
    static let battery = dynamic(0x6250D6, 0x9085E9)
    static let mac = dynamic(0x52514E, 0xC3C2B7)

    static func of(_ c: PowerComponent) -> NSColor {
        switch c {
        case .cpu: return cpu
        case .gpu: return gpu
        case .memory: return memory
        case .display: return display
        case .ane: return ane
        case .other: return other
        }
    }

    static func of(_ n: PowerDiagram.Node) -> NSColor {
        if let c = n.component { return of(c) }
        switch n {
        case .adapter: return adapter
        case .batteryOut, .batteryIn: return battery
        default: return mac
        }
    }
}

enum PowerNames {
    /// Short names for the diagram and the legend.
    static func short(_ c: PowerComponent) -> String {
        switch c {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return L("Memory")
        case .display: return L("Display")
        case .ane: return L("ANE")
        case .other: return L("Other")
        }
    }

    static func node(_ n: PowerDiagram.Node, hasBattery: Bool) -> String {
        if let c = n.component { return short(c) }
        switch n {
        case .adapter: return hasBattery ? L("Adapter") : L("Power supply")
        case .batteryOut, .batteryIn: return L("Battery")
        default: return L("This Mac")
        }
    }

    /// What a part covers, for the caption under the diagram.
    static func about(_ n: PowerDiagram.Node) -> String? {
        switch n {
        case .cpu: return L("processor cores")
        case .gpu: return L("graphics")
        case .memory: return L("DRAM and its controllers")
        case .display: return L("the built-in display's backlight")
        case .ane: return L("the Neural Engine (machine learning)")
        case .other: return L("SSD, Wi-Fi, fans, USB devices, media engines, power conversion")
        case .batteryIn: return L("charging the battery")
        case .batteryOut: return L("from the battery")
        case .adapter: return L("from the power adapter")
        case .mac: return L("everything the Mac uses")
        }
    }
}

// MARK: - Flow diagram

final class PowerFlowDiagramView: NSView {
    var reading: PowerReading? { didSet { if reading != oldValue { rebuild() } } }
    /// Promo and debug renders: draw the dots in place (moving layers don't show in a still).
    var staticParticles = false

    private var diagram = PowerDiagram(columns: [], links: [])
    private var geo = PowerDiagramLayout(boxes: [], bands: [])
    private enum Hover: Equatable { case band(Int), node(PowerDiagram.Node) }
    private var hover: Hover? {
        didSet {
            guard hover != oldValue else { return }
            needsDisplay = true
            for (i, b) in geo.bands.enumerated() {
                tracks[Self.key(b.link)]?.container.opacity = lit(i) ? 1 : 0.2
            }
        }
    }

    private static func key(_ l: PowerDiagram.Link) -> String { "\(l.from.rawValue)>\(l.to.rawValue)" }

    private static let nodeWidth: CGFloat = 8
    private static let leftLabels: CGFloat = 66
    private static let rightLabels: CGFloat = 96
    private static let captionHeight: CGFloat = 15
    private var diagramRect: CGRect { CGRect(x: 0, y: 18, width: bounds.width, height: bounds.height - 18 - 18 - Self.captionHeight) }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    private var hasBattery: Bool { reading?.hasBattery ?? true }

    private func rebuild() {
        diagram = reading.map { PowerDiagram.make($0) } ?? PowerDiagram(columns: [], links: [])
        let r = diagramRect
        let x0 = Self.leftLabels, xLast = r.width - Self.rightLabels - Self.nodeWidth
        let xs: [CGFloat] = diagram.columns.count >= 3 ? [x0, (x0 + xLast) / 2, xLast] : [x0, xLast]
        // Gaps wide enough that one-line labels sit beside their boxes.
        geo = PowerDiagramLayout.make(diagram, in: r, columnX: xs, nodeWidth: Self.nodeWidth, gap: 12, minHeight: 2)
        if case .band(let i) = hover, i >= geo.bands.count { hover = nil }
        needsDisplay = true
        updateParticles()
        setAccessibilityLabel(summary())
    }

    // MARK: Drawing

    private func ribbon(_ b: PowerDiagramLayout.Band) -> CGPath {
        let p = CGMutablePath()
        let xm = (b.x0 + b.x1) / 2
        p.move(to: CGPoint(x: b.x0, y: b.top0))
        p.addCurve(to: CGPoint(x: b.x1, y: b.top1), control1: CGPoint(x: xm, y: b.top0), control2: CGPoint(x: xm, y: b.top1))
        p.addLine(to: CGPoint(x: b.x1, y: b.bottom1))
        p.addCurve(to: CGPoint(x: b.x0, y: b.bottom0), control1: CGPoint(x: xm, y: b.bottom1), control2: CGPoint(x: xm, y: b.bottom0))
        p.closeSubpath()
        return p
    }

    private func centerline(_ b: PowerDiagramLayout.Band) -> CGPath {
        let p = CGMutablePath()
        let m0 = (b.top0 + b.bottom0) / 2, m1 = (b.top1 + b.bottom1) / 2, xm = (b.x0 + b.x1) / 2
        p.move(to: CGPoint(x: b.x0, y: m0))
        p.addCurve(to: CGPoint(x: b.x1, y: m1), control1: CGPoint(x: xm, y: m0), control2: CGPoint(x: xm, y: m1))
        return p
    }

    /// Is this band or node part of what the pointer is on?
    private func lit(_ i: Int) -> Bool {
        switch hover {
        case nil: return true
        case .band(let j): return i == j
        case .node(let n): return geo.bands[i].link.from == n || geo.bands[i].link.to == n
        }
    }

    private func lit(_ n: PowerDiagram.Node) -> Bool {
        switch hover {
        case nil: return true
        case .node(let m): return m == n || geo.bands.contains { ($0.link.from == m && $0.link.to == n) || ($0.link.to == m && $0.link.from == n) }
        case .band(let j): return j < geo.bands.count && (geo.bands[j].link.from == n || geo.bands[j].link.to == n)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard !geo.boxes.isEmpty, let r = reading else {
            let text = L("Measuring…") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: diagramRect.midY - size.height / 2), withAttributes: attrs)
            return
        }
        // Flows: a wash from the source's color to the target's.
        for (i, b) in geo.bands.enumerated() {
            let alpha: CGFloat = hover == nil ? 0.36 : lit(i) ? 0.56 : 0.10
            let from = PowerColors.of(b.link.from).withAlphaComponent(alpha).cgColor
            let to = PowerColors.of(b.link.to).withAlphaComponent(alpha).cgColor
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from, to] as CFArray, locations: [0, 1]) else { continue }
            ctx.saveGState()
            ctx.addPath(ribbon(b))
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: b.x0, y: 0), end: CGPoint(x: b.x1, y: 0), options: [])
            ctx.restoreGState()
            if staticParticles { drawStill(b) }
        }
        // Nodes.
        for box in geo.boxes {
            let color = PowerColors.of(box.node).withAlphaComponent(lit(box.node) ? 1 : 0.3)
            color.setFill()
            NSBezierPath(roundedRect: box.rect, xRadius: 2.5, yRadius: 2.5).fill()
        }
        drawLabels(r)
        drawCaption(r)
    }

    private func drawStill(_ b: PowerDiagramLayout.Band) {
        let thickness = b.bottom0 - b.top0
        guard thickness >= 0.8 else { return }
        let radius = Self.dotRadius(thickness)
        PowerColors.of(particleNode(b.link)).setFill()
        for t in stride(from: 0.12, through: 0.9, by: 0.26) {
            let p = Self.point(on: b, at: CGFloat(t))
            NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)).fill()
        }
    }

    private static func point(on b: PowerDiagramLayout.Band, at t: CGFloat) -> CGPoint {
        let m0 = (b.top0 + b.bottom0) / 2, m1 = (b.top1 + b.bottom1) / 2, xm = (b.x0 + b.x1) / 2
        let p0 = CGPoint(x: b.x0, y: m0), c1 = CGPoint(x: xm, y: m0), c2 = CGPoint(x: xm, y: m1), p3 = CGPoint(x: b.x1, y: m1)
        let u = 1 - t
        let a = u * u * u, bb = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + bb * c1.x + c * c2.x + d * p3.x, y: a * p0.y + bb * c1.y + c * c2.y + d * p3.y)
    }

    private func value(_ n: PowerDiagram.Node, _ r: PowerReading) -> String {
        switch n {
        case .adapter: return PowerMath.watts(r.adapter ?? r.system)
        case .batteryOut: return PowerMath.watts(r.battery.map(abs))
        case .batteryIn: return PowerMath.signedWatts(r.battery)
        case .mac: return PowerMath.watts(r.system)
        default: return PowerMath.watts(n.component.flatMap { r.watts($0) })
        }
    }

    private static let nameFont = NSFont.systemFont(ofSize: 10.5)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    private func drawLabels(_ r: PowerReading) {
        let columns = diagram.columns
        let bounds = diagramRect
        func attrs(_ font: NSFont, _ color: NSColor, _ on: Bool) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: on ? color : NSColor.tertiaryLabelColor]
        }
        for (ci, col) in columns.enumerated() {
            let boxes = col.compactMap { geo.box($0) }
            let first = ci == 0, last = ci == columns.count - 1
            if first || last {
                // Beside the boxes: names and values on one line (right column) or two (left).
                let lineH: CGFloat = first ? 28 : 14
                let centres = PowerDiagramLayout.spread(boxes.map { $0.rect.midY }, spacing: lineH,
                                                        lower: bounds.minY - 10 + lineH / 2, upper: bounds.maxY + 10 - lineH / 2)
                for (box, y) in zip(boxes, centres) {
                    let on = lit(box.node)
                    let name = PowerNames.node(box.node, hasBattery: hasBattery) as NSString
                    let val = value(box.node, r) as NSString
                    if first {
                        let na = attrs(Self.nameFont, .secondaryLabelColor, on), va = attrs(NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .labelColor, on)
                        let ns = name.size(withAttributes: na), vs = val.size(withAttributes: va)
                        let right = box.rect.minX - 6
                        name.draw(at: NSPoint(x: right - ns.width, y: y - ns.height - 0.5), withAttributes: na)
                        val.draw(at: NSPoint(x: right - vs.width, y: y - 1), withAttributes: va)
                    } else {
                        let na = attrs(Self.nameFont, .secondaryLabelColor, on), va = attrs(Self.valueFont, .labelColor, on)
                        let ns = name.size(withAttributes: na), vs = val.size(withAttributes: va)
                        name.draw(at: NSPoint(x: box.rect.maxX + 6, y: y - ns.height / 2), withAttributes: na)
                        val.draw(at: NSPoint(x: bounds.maxX - vs.width, y: y - vs.height / 2), withAttributes: va)
                    }
                    // A hairline when the label had to move off its box.
                    if abs(y - box.rect.midY) > 3 {
                        let line = NSBezierPath()
                        let x = first ? box.rect.minX - 1 : box.rect.maxX + 1
                        line.move(to: NSPoint(x: x, y: box.rect.midY))
                        line.line(to: NSPoint(x: first ? x - 4 : x + 4, y: y))
                        line.lineWidth = 0.75
                        NSColor.tertiaryLabelColor.setStroke()
                        line.stroke()
                    }
                }
            } else {
                // The middle column: the Mac above its box, the charging battery below its own.
                for box in boxes {
                    let on = lit(box.node)
                    let text = NSMutableAttributedString(string: PowerNames.node(box.node, hasBattery: hasBattery) + " ",
                                                         attributes: attrs(Self.nameFont, .secondaryLabelColor, on))
                    text.append(NSAttributedString(string: value(box.node, r), attributes: attrs(Self.valueFont, .labelColor, on)))
                    let size = text.size()
                    let x = min(max(box.rect.midX - size.width / 2, 0), self.bounds.width - size.width)
                    let y = box.node == .mac ? box.rect.minY - size.height - 2 : box.rect.maxY + 2
                    text.draw(at: NSPoint(x: x, y: y))
                }
            }
        }
    }

    /// Under the diagram: what the pointer is on, or a hint.
    private func drawCaption(_ r: PowerReading) {
        var text = L("Point at a flow or a part for its share.")
        var strong = false
        switch hover {
        case .band(let i) where i < geo.bands.count:
            let l = geo.bands[i].link
            let total = l.from == .mac ? (r.system ?? 0) : diagram.watts(l.from)
            let share = total > 0 ? " · \(Int((l.watts / total * 100).rounded()))%" : ""
            text = "\(PowerNames.node(l.from, hasBattery: hasBattery)) → \(PowerNames.node(l.to, hasBattery: hasBattery)) · "
                + PowerMath.watts(l.watts) + share
            strong = true
        case .node(let n):
            let share: String
            if n.component != nil, let s = r.system, s > 0, let w = n.component.flatMap({ r.watts($0) }) {
                share = " · " + L("%d%% of the Mac", Int((w / s * 100).rounded()))
            } else {
                share = ""
            }
            text = PowerNames.node(n, hasBattery: hasBattery) + " " + value(n, r) + share + (PowerNames.about(n).map { " · " + $0 } ?? "")
            strong = true
        default:
            break
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5),
                                                    .foregroundColor: strong ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor]
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        var a = attrs
        a[.paragraphStyle] = p
        (text as NSString).draw(in: NSRect(x: 0, y: bounds.height - Self.captionHeight, width: bounds.width, height: Self.captionHeight), withAttributes: a)
    }

    private func summary() -> String {
        guard let r = reading, !diagram.isEmpty else { return L("Power flow") }
        let parts = diagram.links.map { "\(PowerNames.node($0.from, hasBattery: hasBattery)) → \(PowerNames.node($0.to, hasBattery: hasBattery)) \(PowerMath.watts($0.watts))" }
        return L("Power flow") + ": " + L("This Mac") + " " + PowerMath.watts(r.system) + "; " + parts.joined(separator: ", ")
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let box = geo.boxes.first(where: { $0.rect.insetBy(dx: -4, dy: -2).contains(p) }) {
            hover = .node(box.node)
        } else if let i = geo.bands.indices.reversed().first(where: { ribbon(geo.bands[$0]).contains(p) }) {
            hover = .band(i)
        } else {
            hover = nil
        }
    }

    override func mouseExited(with event: NSEvent) { hover = nil }

    // MARK: Moving dots

    /// Dots along each flow, moved by Core Animation (in the render server: BarTap doesn't wake
    /// up for them). Rebuilt only when a flow really moves; small changes leave them running.
    private struct Track {
        /// Holds the dots, so a flow the pointer isn't on can fade as a whole.
        var container: CALayer
        var count: Int
        var mid0: CGFloat, mid1: CGFloat, x0: CGFloat, x1: CGFloat
        var tier: Int
        var radius: CGFloat
    }
    private var tracks: [String: Track] = [:]

    static func dotRadius(_ thickness: CGFloat) -> CGFloat { min(max(thickness * 0.16, 1.1), 2.3) }

    /// Faster for more watts (a few steps, so a small change keeps the dots going).
    static func speedTier(_ w: Double) -> Int { w < 1 ? 0 : w < 5 ? 1 : w < 15 ? 2 : w < 40 ? 3 : 4 }
    private static let speeds: [CGFloat] = [14, 22, 30, 40, 52]

    /// Dots take the source's color into the Mac or the battery, the part's color out of the Mac.
    private func particleNode(_ l: PowerDiagram.Link) -> PowerDiagram.Node { l.from == .mac ? l.to : l.from }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clearTracks()
        updateParticles()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearTracks() } else { updateParticles() }
    }

    private func clearTracks() {
        for t in tracks.values { t.container.removeFromSuperlayer() }
        tracks.removeAll()
    }

    private func updateParticles() {
        guard let root = layer, window != nil, !staticParticles, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clearTracks()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var seen = Set<String>()
        for (i, b) in geo.bands.enumerated() {
            let thickness = b.bottom0 - b.top0
            guard thickness >= 0.8 else { continue }
            let key = Self.key(b.link)
            seen.insert(key)
            let mid0 = (b.top0 + b.bottom0) / 2, mid1 = (b.top1 + b.bottom1) / 2
            let tier = Self.speedTier(b.link.watts), radius = Self.dotRadius(thickness)
            if let t = tracks[key], abs(t.mid0 - mid0) < 2.5, abs(t.mid1 - mid1) < 2.5, t.x0 == b.x0, t.x1 == b.x1,
               t.tier == tier, abs(t.radius - radius) < 0.4 { continue }
            tracks[key]?.container.removeFromSuperlayer()
            let t = makeTrack(b, tier: tier, radius: radius)
            t.container.opacity = lit(i) ? 1 : 0.2
            root.addSublayer(t.container)
            tracks[key] = t
        }
        for (key, t) in tracks where !seen.contains(key) {
            t.container.removeFromSuperlayer()
            tracks[key] = nil
        }
    }

    private func makeTrack(_ b: PowerDiagramLayout.Band, tier: Int, radius: CGFloat) -> Track {
        let path = centerline(b)
        var length: CGFloat = 0
        var last = Self.point(on: b, at: 0)
        for i in 1...16 {
            let p = Self.point(on: b, at: CGFloat(i) / 16)
            length += hypot(p.x - last.x, p.y - last.y)
            last = p
        }
        let duration = Double(max(length, 1) / Self.speeds[tier])
        let count = max(2, Int(length / 26))
        var color = NSColor.gray.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = PowerColors.of(particleNode(b.link)).cgColor }
        // Same coordinates as the view (a sublayer keeps its parent's flipped geometry).
        let container = CALayer()
        container.frame = bounds
        for k in 0..<count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
            dot.cornerRadius = radius
            dot.backgroundColor = color
            dot.position = CGPoint(x: b.x0, y: (b.top0 + b.bottom0) / 2)
            dot.opacity = 0
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.duration = duration
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.14, 0.86, 1]
            fade.duration = duration
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.repeatCount = .infinity
            group.timeOffset = duration * Double(k) / Double(count)
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            dot.add(group, forKey: "flow")
            container.addSublayer(dot)
        }
        let mid0 = (b.top0 + b.bottom0) / 2, mid1 = (b.top1 + b.bottom1) / 2
        return Track(container: container, count: count, mid0: mid0, mid1: mid1, x0: b.x0, x1: b.x1, tier: tier, radius: radius)
    }

    /// Debug: how many dots are moving.
    var movingDots: Int { tracks.values.reduce(0) { $0 + $1.count } }

    // MARK: Promo film

    /// Points at the flow from `from` to `to`, as the pointer would (the film's close-up).
    func promoHover(from: String, to: String) {
        hover = geo.bands.firstIndex { $0.link.from.rawValue == from && $0.link.to.rawValue == to }.map { .band($0) }
    }

    /// The flows as drawn (view coordinates, y down) with their dots' color, size and speed, so
    /// the film can move the dots the way Core Animation does here.
    func promoBands(dark: Bool) -> [[String: Any]] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        return geo.bands.map { b in
            var hex = "#808080"
            appearance.performAsCurrentDrawingAppearance {
                if let c = PowerColors.of(particleNode(b.link)).usingColorSpace(.sRGB) {
                    hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                }
            }
            let thickness = b.bottom0 - b.top0
            return ["from": b.link.from.rawValue, "to": b.link.to.rawValue, "x0": b.x0, "top0": b.top0, "bottom0": b.bottom0,
                    "x1": b.x1, "top1": b.top1, "bottom1": b.bottom1, "color": hex, "radius": Self.dotRadius(thickness),
                    "speed": Self.speeds[Self.speedTier(b.link.watts)], "watts": b.link.watts]
        }
    }
}

// MARK: - The last two minutes

final class PowerHistoryView: NSView {
    var history = PowerHistory() { didSet { needsDisplay = true } }
    /// Seconds between readings (the stats interval), for the time labels.
    var interval: Double = 1
    /// Laptops get a second legend row: the battery's charge and the adapter's line.
    var hasBattery = true
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    var legendHeight: CGFloat { hasBattery ? 30 : 15 }

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Power over the last two minutes"))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var plot: NSRect { NSRect(x: 0, y: legendHeight + 3, width: bounds.width, height: bounds.height - legendHeight - 3) }

    private static func niceCeil(_ v: Double) -> Double {
        let steps: [Double] = [5, 10, 15, 20, 30, 40, 60, 80, 100, 120, 150, 200, 250, 300]
        return steps.first { $0 >= v } ?? (v / 50).rounded(.up) * 50
    }

    private static func value(_ list: [Double], _ i: Int) -> Double { i < list.count && !list[i].isNaN ? list[i] : 0 }

    override func draw(_ dirtyRect: NSRect) {
        let r = plot.insetBy(dx: 0.5, dy: 0.5)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        let h = history
        let n = h.system.count
        let usable = r.height - 17
        var peak = 0.0
        for i in 0..<n { peak = max(peak, Self.value(h.system, i) + Self.value(h.charge, i), Self.value(h.input, i)) }
        peak = Self.niceCeil(max(peak * 1.05, 5))
        let step = r.width / CGFloat(PowerHistory.capacity - 1)
        func x(_ i: Int) -> CGFloat { r.maxX - CGFloat(n - 1 - i) * step }
        func y(_ w: Double) -> CGFloat { r.minY + usable * CGFloat(min(max(w / peak, 0), 1)) }

        if n >= 2 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            // The Mac's parts where they were measured, the whole Mac (neutral) elsewhere, the
            // battery's charge on top: the same story as the diagram, over time.
            let measured = (0..<n).map { i in !(h.parts[.cpu].map { i < $0.count && $0[i].isNaN } ?? true) }
            var below = [Double](repeating: 0, count: n)
            var first = true
            for c in PowerComponent.allCases {
                let values = h.parts[c] ?? []
                let top = (0..<n).map { below[$0] + (measured[$0] ? Self.value(values, $0) : 0) }
                fillBand(lower: below, upper: top, include: measured, gap: !first, x: x, y: y, color: PowerColors.of(c).withAlphaComponent(0.55))
                below = top
                first = false
            }
            let unmeasured = measured.map { !$0 }
            for i in 0..<n where unmeasured[i] { below[i] = Self.value(h.system, i) }
            fillBand(lower: [Double](repeating: 0, count: n), upper: below, include: unmeasured, gap: false, x: x, y: y,
                     color: PowerColors.other.withAlphaComponent(0.35))
            let charging = (0..<n).map { Self.value(h.charge, $0) > 0.3 }
            fillBand(lower: below, upper: (0..<n).map { below[$0] + Self.value(h.charge, $0) }, include: charging, gap: true, x: x, y: y,
                     color: PowerColors.battery.withAlphaComponent(0.4))
            // What the adapter delivered: a line over the stack.
            let line = NSBezierPath()
            var drawing = false
            for i in 0..<n {
                let v = i < h.input.count ? h.input[i] : .nan
                if v.isNaN { drawing = false; continue }
                let p = NSPoint(x: x(i), y: y(v))
                if drawing { line.line(to: p) } else { line.move(to: p); drawing = true }
            }
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            PowerColors.adapter.setStroke()
            line.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]
        let minutes = max(1, Int((Double(PowerHistory.capacity) * interval / 60).rounded()))
        var caption = L("Last %d min", minutes)
        if let k = hoverIndex, k < n {
            let ago = Int((Double(n - 1 - k) * interval).rounded())
            var parts = [ago == 0 ? L("now") : L("%d s ago", ago), L("This Mac") + " " + PowerMath.watts(h.system[k].isNaN ? nil : h.system[k])]
            if Self.value(h.charge, k) > 0.3 { parts.append(L("Battery") + " " + PowerMath.signedWatts(h.charge[k])) }
            if k < h.input.count, !h.input[k].isNaN { parts.append(L("Adapter") + " " + PowerMath.watts(h.input[k])) }
            caption = parts.joined(separator: " · ")
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: x(k), y: r.minY))
            guide.line(to: NSPoint(x: x(k), y: r.minY + usable))
            guide.lineWidth = 1
            NSColor.secondaryLabelColor.setStroke()
            guide.stroke()
        }
        (caption as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 14), withAttributes: hoverIndex == nil ? small
            : [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        if hoverIndex == nil {
            let peakText = PowerMath.watts(peak) as NSString
            let ps = peakText.size(withAttributes: small)
            peakText.draw(at: NSPoint(x: r.maxX - ps.width - 6, y: r.maxY - 14), withAttributes: small)
        }
        drawLegend()
    }

    /// The parts in stack order; laptops add the battery's charge and the adapter's line below.
    private func drawLegend() {
        let legend: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        var lx: CGFloat = 0
        let rowY: CGFloat = hasBattery ? 15 : 0
        func item(_ name: String, _ draw: (CGFloat, CGFloat) -> Void, y: CGFloat) {
            draw(lx, y)
            (name as NSString).draw(at: NSPoint(x: lx + 11, y: y + 1), withAttributes: legend)
            lx += 11 + (name as NSString).size(withAttributes: legend).width + 10
        }
        for c in PowerComponent.allCases {
            item(PowerNames.short(c), { x, y in
                PowerColors.of(c).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y + 4, width: 7, height: 7)).fill()
            }, y: rowY)
        }
        guard hasBattery else { return }
        lx = 0
        item(L("Battery charging"), { x, y in
            PowerColors.battery.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 3.5, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
        }, y: 0)
        item(L("Adapter input"), { x, y in
            PowerColors.adapter.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: y + 6.5, width: 10, height: 2), xRadius: 1, yRadius: 1).fill()
        }, y: 0)
    }

    /// One band of the stack between `lower` and `upper`, only where `include` holds. With `gap`
    /// its bottom edge sits a point above the band below, so neighbouring bands read apart.
    private func fillBand(lower: [Double], upper: [Double], include: [Bool], gap: Bool,
                          x: (Int) -> CGFloat, y: (Double) -> CGFloat, color: NSColor) {
        var i = 0
        let n = upper.count
        color.setFill()
        while i < n {
            guard include[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && include[j + 1] { j += 1 }
            if j > i {
                let path = NSBezierPath()
                func bottom(_ k: Int) -> CGFloat { min(y(lower[k]) + (gap ? 1 : 0), y(upper[k])) }
                path.move(to: NSPoint(x: x(i), y: bottom(i)))
                for k in i...j { path.line(to: NSPoint(x: x(k), y: y(upper[k]))) }
                for k in stride(from: j, through: i, by: -1) { path.line(to: NSPoint(x: x(k), y: bottom(k))) }
                path.close()
                path.fill()
            }
            i = j + 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let n = history.system.count
        guard n > 0, plot.contains(p) else { hoverIndex = nil; return }
        let step = plot.width / CGFloat(PowerHistory.capacity - 1)
        let i = n - 1 - Int(((plot.maxX - p.x) / step).rounded())
        hoverIndex = i >= 0 && i < n ? i : nil
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
}

// MARK: - Figures

/// Small tiles: a label above a value.
final class PowerTilesView: NSView {
    struct Tile: Equatable {
        var label: String
        var value: String
    }
    var tiles: [Tile] = [] {
        didSet {
            guard tiles != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(tiles.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        }
    }
    var columns = 4
    static let tileHeight: CGFloat = 34
    static let gap: CGFloat = 6

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = (bounds.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        for (i, t) in tiles.enumerated() {
            let r = NSRect(x: CGFloat(i % columns) * (w + Self.gap), y: CGFloat(i / columns) * (Self.tileHeight + Self.gap), width: w, height: Self.tileHeight)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            (t.label as NSString).draw(in: NSRect(x: r.minX + 7, y: r.minY + 4, width: r.width - 10, height: 13), withAttributes: label)
            // The value shrinks to fit its tile rather than being cut off.
            var size: CGFloat = 13
            var attrs: [NSAttributedString.Key: Any] = [:]
            repeat {
                attrs = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor]
                if (t.value as NSString).size(withAttributes: attrs).width <= r.width - 12 { break }
                size -= 0.5
            } while size > 9
            (t.value as NSString).draw(at: NSPoint(x: r.minX + 7, y: r.minY + 16 + (13 - size) / 2), withAttributes: attrs)
        }
    }
}

/// Apps by power right now, with what each used since it started.
final class PowerAppsView: NSView {
    var apps: [EnergyUse]? { didSet { if apps != oldValue { needsDisplay = true; updateAccessibility() } } }
    var measuring = true
    static let rows = 5
    static let rowHeight: CGFloat = 21
    static let headerHeight: CGFloat = 13
    private var icons: [String: NSImage] = [:]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func icon(_ key: String) -> NSImage {
        if let i = icons[key] { return i }
        let img = key.hasPrefix("/") ? NSWorkspace.shared.icon(forFile: key) : NSWorkspace.shared.icon(for: .unixExecutable)
        img.size = NSSize(width: 16, height: 16)
        icons[key] = img
        return img
    }

    private func updateAccessibility() {
        let list = (apps ?? []).map { "\($0.name) \(PowerMath.watts($0.watts))" }
        setAccessibilityLabel(L("Apps") + ": " + (list.isEmpty ? L("Measuring…") : list.joined(separator: ", ")))
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor]
        let valueW: CGFloat = 50, usedW: CGFloat = 58, barW: CGFloat = 56
        func right(_ s: String, _ attrs: [NSAttributedString.Key: Any], _ maxX: CGFloat, _ y: CGFloat) {
            let size = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: NSPoint(x: maxX - size.width, y: y), withAttributes: attrs)
        }
        right(L("Now"), head, w - usedW - 6, 0)
        right(L("Used"), head, w, 0)
        let list = apps ?? []
        guard !list.isEmpty else {
            let text = measuring || apps == nil ? L("Measuring…") : L("Nothing measurable")
            (text as NSString).draw(at: NSPoint(x: 0, y: Self.headerHeight + 3),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let top = max(list.map(\.watts).max() ?? 1, 0.01)
        let name: [NSAttributedString.Key: Any] = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
        }()
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.labelColor]
        let used: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for (i, app) in list.prefix(Self.rows).enumerated() {
            let y = Self.headerHeight + CGFloat(i) * Self.rowHeight
            icon(app.key).draw(in: NSRect(x: 0, y: y + 2, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let barX = w - usedW - 6 - valueW - 6 - barW
            let title = app.processes > 1 ? "\(app.name) (\(app.processes))" : app.name
            (title as NSString).draw(in: NSRect(x: 22, y: y + 2, width: barX - 28, height: 16), withAttributes: name)
            // Processor energy, so the bar takes the CPU's color.
            let track = NSRect(x: barX, y: y + 7.5, width: barW, height: 5)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            PowerColors.cpu.setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: y + 7.5, width: max(3, barW * CGFloat(app.watts / top)), height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            right(app.watts < 0.1 ? String(format: "%.2f W", app.watts) : PowerMath.watts(app.watts), value, w - usedW - 6, y + 2.5)
            right(app.joules > 0 ? PowerMath.wattHours(app.joules) : "–", used, w, y + 2.5)
        }
    }
}

// MARK: - Panel

final class PowerPanel: StatsPanel {
    override class var width: CGFloat { 392 }
    private var big: NSTextField!
    private let status = NSTextField(labelWithString: "")
    private let diagram = PowerFlowDiagramView()
    private let history = PowerHistoryView()
    private let tiles = PowerTilesView()
    private let adapterLine = NSTextField(labelWithString: "")
    private let batteryLine = NSTextField(labelWithString: "")
    private let apps = PowerAppsView()
    private let hasBattery: Bool

    /// - Parameters:
    ///   - hasBattery: a laptop (battery and adapter figures), checked when the details open.
    ///   - interval: seconds between readings, for the graph's time labels.
    init(hasBattery: Bool = true, interval: Double = 1) {
        self.hasBattery = hasBattery
        super.init()
        big = header(L("Power"))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)
        add(diagram, height: 184)
        history.interval = interval
        history.hasBattery = hasBattery
        add(history, height: 64 + history.legendHeight + 3)
        if hasBattery {
            section(L("Battery & adapter"))
            add(tiles, height: PowerTilesView.tileHeight * 3 + PowerTilesView.gap * 2)
            for line in [adapterLine, batteryLine] {
                line.font = .systemFont(ofSize: 10.5)
                line.textColor = .secondaryLabelColor
                line.lineBreakMode = .byTruncatingTail
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
            }
        }
        section(L("Apps"))
        add(apps, height: PowerAppsView.headerHeight + PowerAppsView.rowHeight * CGFloat(PowerAppsView.rows))
        let note = NSTextField(wrappingLabelWithString: L("Processor energy by app; graphics and display power aren't split by app. Used: since each app started."))
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = Self.width - 28
        stack.addArrangedSubview(note)
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ v: NSView, height: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    /// For renders (promo, debug): dots drawn in place.
    func drawStill() { diagram.staticParticles = true }

    /// The film's close-up: one flow pointed at.
    func promoHover(from: String, to: String) { diagram.promoHover(from: from, to: to) }

    /// Where things are, for the film (points, y down from the panel's top): the panel, the diagram
    /// and its flows, and each section the film points at.
    func promoLayout(dark: Bool) -> [String: Any] {
        layoutSubtreeIfNeeded()
        func top(_ v: NSView) -> [String: CGFloat] {
            let f = v.convert(v.bounds, to: self)
            return ["x": f.minX, "y": bounds.height - f.maxY, "w": f.width, "h": f.height]
        }
        let tileRow = PowerTilesView.tileHeight + PowerTilesView.gap
        var tilesRows: [[String: CGFloat]] = []
        if hasBattery {
            let t = top(tiles)
            for r in 0..<3 { tilesRows.append(["x": t["x"]!, "y": t["y"]! + CGFloat(r) * tileRow, "w": t["w"]!, "h": PowerTilesView.tileHeight]) }
        }
        return ["size": ["w": bounds.width, "h": bounds.height], "diagram": top(diagram), "history": top(history),
                "tiles": tilesRows, "apps": top(apps), "bands": diagram.promoBands(dark: dark)]
    }

    /// Debug: how many dots are moving in the diagram.
    var movingDots: Int { diagram.movingDots }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        let r = s.powerReading
        big.stringValue = PowerMath.watts(r?.system)
        status.stringValue = Self.statusText(r, s.battery)
        diagram.reading = r
        if let h = s.powerHistory { history.history = h }
        if hasBattery { updateFigures(r, s.powerDetails, fahrenheit: o.fahrenheit) }
        if let list = s.powerApps {
            apps.measuring = s.energyMeasuring
            apps.apps = list
        }
    }

    static func statusText(_ r: PowerReading?, _ b: BatteryInfo?) -> String {
        guard let r else { return L("Measuring…") }
        guard r.hasBattery, let b else { return L("Powered by the power supply") }
        let time = b.minutesRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        if b.charging {
            return [L("Charging"), "\(b.percent)%", time.map { L("%@ until full", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
        if b.onAC {
            return [L("Plugged in"), "\(b.percent)%", b.charged ? L("fully charged") : L("not charging")].joined(separator: " · ")
        }
        return [L("On battery"), "\(b.percent)%", time.map { L("%@ left", $0) }].compactMap { $0 }.joined(separator: " · ")
    }

    private func updateFigures(_ r: PowerReading?, _ d: PowerDetails?, fahrenheit: Bool) {
        let onAC = r?.onAC == true
        let temp = d?.temperature.map { StatFormat.temperature($0, fahrenheit: fahrenheit) + (fahrenheit ? "F" : "C") } ?? "–"
        let input: String
        if onAC, let v = r?.inputVolts, let a = r?.inputAmps {
            input = String(format: "%.1f V · %.2f A", v, a)
        } else {
            input = onAC ? PowerMath.watts(r?.adapter) : "–"
        }
        let negotiated = onAC ? d.flatMap { d in d.adapterVolts.flatMap { v in d.adapterAmps.map { String(format: "%.0f V × %.2f A", v, $0) } } } : nil
        tiles.tiles = [
            // The battery now.
            .init(label: L("Voltage"), value: PowerMath.volts(r?.batteryVolts ?? d?.voltage)),
            .init(label: L("Current"), value: PowerMath.amps((r?.batteryAmps ?? d?.amperage).map { abs($0) < 0.02 ? 0 : $0 }, signed: true)),
            .init(label: L("Battery power"), value: PowerMath.signedWatts(r?.battery.map { abs($0) < 0.3 ? 0 : $0 })),
            .init(label: L("Temperature"), value: temp),
            // Its health.
            .init(label: L("Charge"), value: d?.currentCharge.map { "\($0.formatted()) mAh" } ?? "–"),
            .init(label: L("Full charge"), value: d?.fullChargeCapacity.map { "\($0.formatted()) mAh" } ?? "–"),
            .init(label: L("Health"), value: d?.healthPercent.map { "\($0)%" } ?? "–"),
            .init(label: L("Cycle count"), value: d?.cycleCount.map { c in d?.designCycleCount.map { "\(c) / \($0)" } ?? "\(c)" } ?? "–"),
            // The adapter.
            .init(label: L("Adapter rating"), value: onAC ? d?.adapterWatts.map { "\($0) W" } ?? "–" : "–"),
            .init(label: L("Negotiated"), value: negotiated ?? "–"),
            .init(label: L("Input now"), value: input),
            .init(label: L("Adapter heat"), value: onAC ? d?.adapterLoss.map { PowerMath.watts($0) } ?? "–" : "–"),
        ]
        if onAC {
            adapterLine.stringValue = d?.adapterName ?? (d?.wireless == true ? L("Wireless charger") : L("Power adapter"))
        } else {
            adapterLine.stringValue = L("No adapter connected")
        }
        var battery: [String] = []
        if let design = d?.designCapacity { battery.append(L("Design %@ mAh", design.formatted())) }
        if let cells = d?.cellVoltages, !cells.isEmpty {
            battery.append(L("Cells %@ V", cells.map { String(format: "%.2f", $0) }.joined(separator: " / ")))
        }
        if let lo = d?.dailyMinPercent, let hi = d?.dailyMaxPercent { battery.append(L("Today %d–%d%%", lo, hi)) }
        batteryLine.stringValue = battery.joined(separator: " · ")
    }
}
