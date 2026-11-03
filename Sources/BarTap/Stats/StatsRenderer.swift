import AppKit
import BarTapCore

/// Draws stats into menu bar images. An item is a row of elements (graph, pie, percentage,
/// two-line values…) in the order the user chose, like iStat Menus' menubar items.
///
/// Every element has a FIXED width that never depends on the values, and inside it every label,
/// arrow and graph has a FIXED position; only right-aligned numbers change. Nothing to the left of a
/// changing number moves (no jumping arrows), and the item never resizes (no shifting of the icons
/// beside it). Images are monochrome templates, so they follow the menu bar's light/dark/tinted
/// appearance on every display.
enum StatsRenderer {
    static let height: CGFloat = 22
    private static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let labelFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    struct Options {
        var fahrenheit = false
        var bits = false
        var clockFormat = "EEE HH:mm"
        /// AI item: one segment per tag (agent) instead of the total.
        var aiTags: [String] = []
        /// AI item: plan limits as what is left.
        var aiPlanLeft = false
    }

    // MARK: Fixed geometry

    static let graphBars = 10
    static let graphWidth = CGFloat(graphBars) * 3 - 1          // 2 pt bars, 1 pt gaps
    static let areaWidth: CGFloat = 28                          // two-series graph (network, disk)
    static let pieSize: CGFloat = 13
    static let meterWidth: CGFloat = 5
    static let arrowWidth: CGFloat = 6
    static let batteryWidth: CGFloat = 21
    /// Space between two elements, and at each end of an item.
    static let gap: CGFloat = 4
    /// The Power item's figures each start with a tag, so they get more air between them (the tag
    /// should read with its own value, not the one before it).
    static func gap(_ m: StatsModule) -> CGFloat { m == .power ? 8 : gap }
    static let inset: CGFloat = 1

    private static func textWidth(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
    private static var percentBox: CGFloat { textWidth("100%", valueFont) }
    private static func rateBox(_ o: Options) -> CGFloat { textWidth(o.bits ? "888 Kb/s" : "888 KB/s", lineFont) }
    private static var amountBox: CGFloat { textWidth("888.8G", lineFont) }
    private static var shortLabelWidth: CGFloat { max(textWidth("U:", lineFont), textWidth("F:", lineFont)) }

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

    /// Short module name for the label element.
    static func label(_ m: StatsModule) -> String {
        switch m {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return L("MEM")
        case .disk: return L("DISK")
        case .network: return L("NET")
        case .sensors: return L("TEMP")
        case .battery: return L("BAT")
        case .power: return L("PWR")
        case .time: return ""
        case .ai: return "AI"
        case .volume: return L("VOL")
        case .bluetooth: return "BT"
        case .trio: return ""
        }
    }

    static func elementWidth(_ e: StatsElement, _ m: StatsModule, _ o: Options) -> CGFloat {
        switch e {
        case .label: return textWidth(label(m), labelFont)
        case .graph: return m == .network || m == .disk ? areaWidth : graphWidth
        case .bar: return meterWidth
        case .pie, .ring: return pieSize
        case .percent: return percentBox
        case .cores:
            let l = CPUReader.coreLayout()
            return CGFloat(max(1, l.performance + l.efficiency)) * 3 - 1
        case .usedFree: return shortLabelWidth + 2 + amountBox
        case .used, .free: return textWidth("888.8 GB", valueFont)
        case .readWrite: return textWidth("W", lineFont) + 3 + rateBox(o)
        case .rates: return arrowWidth + 3 + rateBox(o)
        case .temperature: return textWidth("188°", valueFont)
        case .fan: return textWidth("8888 rpm", valueFont)
        case .tempFan: return max(textWidth("188°", lineFont), textWidth("8888 rpm", lineFont))
        case .power: return textWidth("188.8 W", valueFont)
        case .battery: return batteryWidth
        case .timeLeft: return textWidth("88:88", valueFont)
        case .clock: return clockWidth(o.clockFormat)
        case .aiTokens: return textWidth("888.8M", valueFont)
        case .aiCost: return textWidth("$88.88", valueFont)
        case .aiTokensCost: return max(textWidth("888.8M", lineFont), textWidth("$88.88", lineFont))
        case .aiPlan: return pieSize
        case .aiPlanPercent: return percentBox
        case .aiPlanTwo: return planLabelWidth + 2 + textWidth("100%", lineFont)
        case .aiCredits: return pieSize + 3 + creditsBox
        case .batteryPower: return max(textWidth("−188 W", valueFont), textWidth("+188 W", valueFont))
        case .speaker: return TrioGlyphs.speakerWidth
        case .levelMeter: return TrioGlyphs.meterWidth
        case .bluetoothIcon: return TrioGlyphs.bluetoothWidth + 1 + countBox
        case .lowestBattery: return TrioGlyphs.miniBatteryWidth + 2 + percentBox
        case .airPods: return earLabelWidth + 2 + textWidth("100%", lineFont)
        case .trio: return TrioGlyphs.trioWidth
        case .powerIcon: return boltWidth
        case .powerTwo: return powerTwoLabelWidth + 2 + max(textWidth("888 W", lineFont), textWidth("−88.8 W", lineFont))
        case .powerIn, .powerBattery, .powerSystem, .powerCPU, .powerGPU, .powerMemory, .powerDisplay, .powerANE,
             .batteryVolts, .batteryAmps, .adapterRated, .cycleCount:
            let tag = powerTag(e).map { textWidth($0, tagFont) + 3 } ?? 0
            return tag + (powerValueSamples(e).map { textWidth($0, valueFont) }.max() ?? 30)
        }
    }

    // MARK: Power

    static let boltWidth: CGFloat = 8
    private static var powerTwoLabelWidth: CGFloat { [L("IN"), L("BAT"), L("SYS")].map { textWidth($0, lineFont) }.max() ?? 14 }

    /// The Power item's figures: a short fixed tag, then a right-aligned value.
    private static func powerTag(_ e: StatsElement) -> String? {
        switch e {
        case .powerIn: return L("IN")
        case .powerBattery: return L("BAT")
        case .powerSystem: return L("SYS")
        case .powerCPU: return "CPU"
        case .powerGPU: return "GPU"
        case .powerMemory: return L("MEM")
        case .powerDisplay: return L("DISP")
        case .powerANE: return "ANE"
        case .adapterRated: return L("ADP")
        case .cycleCount: return L("CYC")
        default: return nil
        }
    }

    /// The widest values each figure can show (its box never changes size).
    private static func powerValueSamples(_ e: StatsElement) -> [String] {
        switch e {
        case .powerBattery: return ["−88.8 W", "+188 W"]
        case .batteryVolts: return ["88.88 V"]
        case .batteryAmps: return ["−8.88 A", "+8.88 A"]
        case .cycleCount: return ["8888"]
        case .adapterRated: return ["888 W"]
        default: return ["888 W", "88.8 W"]
        }
    }

    static func powerText(_ e: StatsElement, _ v: Double?) -> String {
        guard let v else { return "–" }
        switch e {
        case .powerBattery: return PowerMath.signedWatts(v)
        case .batteryVolts: return PowerMath.volts(v)
        case .batteryAmps: return PowerMath.amps(v, signed: true)
        case .cycleCount: return "\(Int(v))"
        case .adapterRated: return "\(Int(v)) W"
        default: return PowerMath.watts(v)
        }
    }

    /// A lightning bolt: filled while the adapter powers the Mac, outlined on battery.
    private static func bolt(x: CGFloat, midY: CGFloat, filled: Bool) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x + 5.3, y: midY + 6.5))
        p.line(to: NSPoint(x: x + 0.8, y: midY - 0.7))
        p.line(to: NSPoint(x: x + 3.7, y: midY - 0.7))
        p.line(to: NSPoint(x: x + 2.7, y: midY - 6.5))
        p.line(to: NSPoint(x: x + 7.2, y: midY + 1.1))
        p.line(to: NSPoint(x: x + 4.3, y: midY + 1.1))
        p.close()
        NSColor.black.set()
        if filled {
            p.fill()
        } else {
            p.lineWidth = 1.1
            p.lineJoinStyle = .round
            p.stroke()
        }
    }

    private static var countBox: CGFloat { textWidth("9+", lineFont) }
    private static var earLabelWidth: CGFloat { max(textWidth("L", lineFont), textWidth("R", lineFont)) }

    private static var planLabelWidth: CGFloat { max(textWidth("5h", lineFont), textWidth("7d", lineFont)) }
    private static var creditsBox: CGFloat { max(textWidth("$88.88", valueFont), textWidth("$88.8K", valueFont)) }
    private static var tagWidth: CGFloat { ["CC", "CX", "GM", "OC"].map { textWidth($0, tagFont) }.max() ?? 14 }
    private static let tagFont = NSFont.systemFont(ofSize: 8.5, weight: .heavy)

    private static func elementsWidth(_ m: StatsModule, _ elements: [StatsElement], _ o: Options) -> CGFloat {
        elements.reduce(0) { $0 + elementWidth($1, m, o) } + gap(m) * CGFloat(max(elements.count - 1, 0))
    }

    static func width(_ m: StatsModule, _ elements: [StatsElement], _ o: Options) -> CGFloat {
        guard !elements.isEmpty else { return 2 * inset }
        if m == .ai, !o.aiTags.isEmpty {
            // One segment per agent: its tag, then the chosen elements.
            let segment = tagWidth + 3 + elementsWidth(m, elements, o)
            return 2 * inset + segment * CGFloat(o.aiTags.count) + (gap + 2) * CGFloat(o.aiTags.count - 1)
        }
        return 2 * inset + elementsWidth(m, elements, o)
    }

    // MARK: Images

    /// Pre-rendered 2x bitmap (cheaper for AppKit to ship to the menu bar host than a lazily
    /// drawn image).
    static func image(_ m: StatsModule, _ elements: [StatsElement], _ s: StatsSnapshot?, _ o: Options, now: Date = Date()) -> NSImage {
        bitmap(width: width(m, elements, o)) { rect in draw(m, elements, s, o, rect, now) }
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

    static func drawContent(_ m: StatsModule, _ elements: [StatsElement], _ s: StatsSnapshot?, _ o: Options, _ r: NSRect, now: Date = Date()) {
        NSColor.black.set()
        draw(m, elements, s, o, r, now)
    }

    // MARK: Content

    private static func draw(_ m: StatsModule, _ elements: [StatsElement], _ s: StatsSnapshot?, _ o: Options, _ r: NSRect, _ now: Date) {
        var x = r.minX + inset
        if m == .ai, !o.aiTags.isEmpty {
            for (i, tag) in o.aiTags.enumerated() {
                single(tag, box: NSRect(x: x, y: r.minY, width: tagWidth, height: r.height), font: tagFont, align: .left)
                x += tagWidth + 3
                let figure = s?.ai?.perAgent.first { $0.agent.tag == tag }?.figure
                for e in elements {
                    let w = elementWidth(e, m, o)
                    drawAI(e, figure, o, NSRect(x: x, y: r.minY, width: w, height: r.height))
                    x += w + gap
                }
                if i < o.aiTags.count - 1 { x += 2 }
            }
            return
        }
        for e in elements {
            let w = elementWidth(e, m, o)
            draw(e, m, s, o, NSRect(x: x, y: r.minY, width: w, height: r.height), now)
            x += w + gap(m)
        }
    }

    /// AI elements for one figure (the total, or one agent's).
    private static func drawAI(_ e: StatsElement, _ f: AIFigure?, _ o: Options, _ r: NSRect) {
        switch e {
        case .label: single("AI", box: r, font: labelFont, align: .left)
        case .aiTokens: single(f.map { AIFormat.tokens($0.tokens) } ?? "–", box: r)
        case .aiCost: single(f.map { AIFormat.cost($0.cost) } ?? "–", box: r)
        case .aiTokensCost:
            twoLines(f.map { AIFormat.tokens($0.tokens) } ?? "–", f.map { AIFormat.cost($0.cost) } ?? "–", box: r)
        case .aiPlan: ring((f?.windows.first?.percent(left: o.aiPlanLeft) ?? 0) / 100, center: NSPoint(x: r.minX + pieSize / 2, y: r.midY))
        case .aiPlanPercent: single(f?.windows.first.map { "\(Int($0.percent(left: o.aiPlanLeft).rounded()))%" } ?? "–", box: r)
        case .aiPlanTwo:
            // The two windows by length (5h above 7d). Labels and the numbers' left edges are fixed;
            // left-aligned numbers keep the gap after the label small whatever their length.
            let byLength = (f?.windows ?? []).sorted { $0.minutes < $1.minutes }.prefix(2)
            let rows = Array(byLength) + Array(repeating: nil as AIPlanWindow?, count: 2 - byLength.count).compactMap { $0 }
            for (i, top) in [true, false].enumerated() {
                let w = i < rows.count ? rows[i] : nil
                label(w?.shortName ?? "", x: r.minX, top: top)
                text(w.map { "\(Int($0.percent(left: o.aiPlanLeft).rounded()))%" } ?? (i == 0 ? "–" : ""), lineFont,
                     NSRect(x: r.minX + planLabelWidth + 2, y: top ? 10.5 : 0.5, width: r.width - planLabelWidth - 2, height: 11), align: .left)
            }
        case .aiCredits:
            // Usage credits: a ring for the share of the monthly limit, then the amount (used or left).
            let spend = f?.spend
            if let fraction = spend?.fraction(left: o.aiPlanLeft) {
                ring(fraction, center: NSPoint(x: r.minX + pieSize / 2, y: r.midY))
            }
            let amount = spend.flatMap { s in s.amount(left: o.aiPlanLeft).map { AIFormat.compactMoney($0, currency: s.currency) } }
            // Left-aligned: amounts vary in length ($0.83, $1.2K), and a right-aligned one leaves an odd gap.
            single(amount ?? "–", box: NSRect(x: r.minX + pieSize + 3, y: r.minY, width: r.width - pieSize - 3, height: r.height), align: .left)
        default: break
        }
    }

    private static func draw(_ e: StatsElement, _ m: StatsModule, _ s: StatsSnapshot?, _ o: Options, _ r: NSRect, _ now: Date) {
        if m == .ai { drawAI(e, s?.ai?.total, o, r); return }
        switch e {
        case .label:
            single(label(m), box: r, font: labelFont, align: .left)
        case .graph:
            if let (top, bottom) = series(m, s) {
                let peak = max(top.max() ?? 0, bottom.max() ?? 0, 1024)
                area(top.map { $0 / peak }, NSRect(x: r.minX, y: 12, width: r.width, height: 8))
                area(bottom.map { $0 / peak }, NSRect(x: r.minX, y: 2.5, width: r.width, height: 8))
            } else {
                bars(history(m, s), x: r.minX)
            }
        case .bar:
            meter(fraction(m, s), x: r.minX)
        case .pie:
            pie(fraction(m, s), center: NSPoint(x: r.minX + pieSize / 2, y: r.midY))
        case .ring:
            ring(fraction(m, s), center: NSPoint(x: r.minX + pieSize / 2, y: r.midY))
        case .percent:
            single(percentText(m, s), box: r)
        case .cores:
            for (i, v) in (s?.cpu?.perCore ?? []).enumerated() {
                let bx = r.minX + CGFloat(i) * 3
                NSColor.black.withAlphaComponent(0.22).setFill()
                NSRect(x: bx, y: 3, width: 2, height: 16).fill()
                NSColor.black.setFill()
                NSRect(x: bx, y: 3, width: 2, height: max(1, 16 * CGFloat(min(1, v)))).fill()
            }
        case .usedFree:
            label("U:", x: r.minX, top: true)
            label("F:", x: r.minX, top: false)
            let a = amounts(m, s)
            twoLines(a.map { StatFormat.compactAmount($0.used) } ?? "–", a.map { StatFormat.compactAmount($0.free) } ?? "–",
                     box: NSRect(x: r.minX + shortLabelWidth + 2, y: 0, width: amountBox, height: r.height))
        case .used:
            single(amounts(m, s).map { gigs($0.used) } ?? "–", box: r)
        case .free:
            single(amounts(m, s).map { gigs($0.free) } ?? "–", box: r)
        case .readWrite:
            let labelW = textWidth("W", lineFont)
            label("R", x: r.minX, top: true)
            label("W", x: r.minX, top: false)
            twoLines(rateText(s?.diskRead, o), rateText(s?.diskWrite, o),
                     box: NSRect(x: r.minX + labelW + 3, y: 0, width: rateBox(o), height: r.height))
        case .rates:
            arrow(up: true, x: r.minX)
            arrow(up: false, x: r.minX)
            twoLines(rateText(s?.netUp, o), rateText(s?.netDown, o),
                     box: NSRect(x: r.minX + arrowWidth + 3, y: 0, width: rateBox(o), height: r.height))
        case .temperature:
            single(temperatureText(s, o), box: r)
        case .fan:
            single(fanText(s), box: r)
        case .tempFan:
            twoLines(temperatureText(s, o), fanText(s), box: r)
        case .power:
            single(s?.sensors?.systemPower.map { String(format: "%.1f W", $0) } ?? "–", box: r)
        case .battery:
            battery(s?.battery, x: r.minX, midY: r.midY)
        case .timeLeft:
            single(timeLeftText(s), box: r)
        case .clock:
            single(clockText(o.clockFormat, now), box: r, align: .center)
        case .aiTokens, .aiCost, .aiTokensCost, .aiPlan, .aiPlanPercent, .aiPlanTwo, .aiCredits:
            break
        case .batteryPower:
            single(PowerFlowMath.barText(s?.barWatts), box: r)
        case .speaker:
            let a = s?.audio
            TrioGlyphs.speaker(waves: a.map { VolumeMath.waves($0.level, muted: $0.muted) } ?? -1, muted: a?.muted ?? false, x: r.minX, midY: r.midY)
        case .levelMeter:
            TrioGlyphs.levelMeter(filled: s?.audio.map { VolumeMath.filledBars($0.level, muted: $0.muted) } ?? 0, x: r.minX, bottom: r.midY - 7.5)
        case .bluetoothIcon:
            // The count sits low beside the rune, like a subscript; none while nothing is connected.
            let n = s?.bluetooth?.connected.count ?? 0
            TrioGlyphs.bluetooth(x: r.minX, midY: r.midY, active: s?.bluetooth?.powered == true && n > 0)
            if n > 0 {
                text(n > 9 ? "9+" : "\(n)", lineFont, NSRect(x: r.minX + TrioGlyphs.bluetoothWidth + 1, y: 0.5, width: countBox, height: 11), align: .left)
            }
        case .lowestBattery:
            let level = s?.bluetooth?.lowest?.lowestBattery
            TrioGlyphs.miniBattery(level.map { Double($0) / 100 }, x: r.minX, midY: r.midY)
            single(level.map { "\($0)%" } ?? "–", box: NSRect(x: r.minX + TrioGlyphs.miniBatteryWidth + 2, y: r.minY, width: percentBox, height: r.height))
        case .airPods:
            let e = s?.bluetooth?.earbuds
            label("L", x: r.minX, top: true)
            label("R", x: r.minX, top: false)
            twoLines(e?.left.map { "\($0)%" } ?? "–", e?.right.map { "\($0)%" } ?? "–",
                     box: NSRect(x: r.minX + earLabelWidth + 2, y: 0, width: r.width - earLabelWidth - 2, height: r.height))
        case .trio:
            let b = s?.battery, a = s?.audio
            TrioGlyphs.trio(battery: b.map { Double($0.percent) / 100 }, charging: b?.charging ?? false, wifiBars: s?.wifi?.bars ?? 0,
                            waves: a.map { VolumeMath.waves($0.level, muted: $0.muted) } ?? -1, muted: a?.muted ?? false, x: r.minX, y: r.minY)
        case .powerIcon:
            bolt(x: r.minX, midY: r.midY, filled: s?.powerReading?.onAC ?? true)
        case .powerTwo:
            // Adapter in (or the battery, on battery power) above what the Mac uses; tags fixed.
            let onAC = s?.powerReading?.onAC ?? true
            let tagW = powerTwoLabelWidth
            text(onAC ? L("IN") : L("BAT"), lineFont, NSRect(x: r.minX, y: 10.5, width: tagW, height: 11), align: .left)
            text(L("SYS"), lineFont, NSRect(x: r.minX, y: 0.5, width: tagW, height: 11), align: .left)
            let top = onAC ? powerText(.powerIn, s?.powerBar[.powerIn]) : powerText(.powerBattery, s?.powerBar[.powerBattery])
            twoLines(top, powerText(.powerSystem, s?.powerBar[.powerSystem]),
                     box: NSRect(x: r.minX + tagW + 2, y: 0, width: r.width - tagW - 2, height: r.height))
        case .powerIn, .powerBattery, .powerSystem, .powerCPU, .powerGPU, .powerMemory, .powerDisplay, .powerANE,
             .batteryVolts, .batteryAmps, .adapterRated, .cycleCount:
            var x = r.minX
            if let tag = powerTag(e) {
                let w = textWidth(tag, tagFont)
                single(tag, box: NSRect(x: x, y: r.minY, width: w, height: r.height), font: tagFont, align: .left)
                x += w + 3
            }
            single(powerText(e, s?.powerBar[e]), box: NSRect(x: x, y: r.minY, width: r.maxX - x, height: r.height))
        }
    }

    // MARK: Values

    static func history(_ m: StatsModule, _ s: StatsSnapshot?) -> [Double] {
        let all: [Double]
        switch m {
        case .gpu: all = s?.gpuHistory ?? []
        case .memory: all = s?.memoryHistory ?? []
        default: all = s?.cpuHistory ?? []
        }
        return Array(all.suffix(graphBars))
    }

    /// Two-series graphs: up/down for network, read/write for disk (top/bottom line order matches
    /// the rates and R/W elements).
    private static func series(_ m: StatsModule, _ s: StatsSnapshot?) -> ([Double], [Double])? {
        switch m {
        case .network: return (Array((s?.netUpHistory ?? []).suffix(14)), Array((s?.netDownHistory ?? []).suffix(14)))
        case .disk: return (Array((s?.diskReadHistory ?? []).suffix(14)), Array((s?.diskWriteHistory ?? []).suffix(14)))
        default: return nil
        }
    }

    static func fraction(_ m: StatsModule, _ s: StatsSnapshot?) -> Double {
        guard let s else { return 0 }
        switch m {
        case .cpu: return s.cpu?.total ?? 0
        case .gpu: return s.gpu ?? 0
        case .memory: return s.memory?.usedFraction ?? 0
        case .disk: return bootVolume(s)?.usedFraction ?? 0
        case .battery, .trio: return Double(s.battery?.percent ?? 0) / 100
        case .volume: return s.audio.map { VolumeMath.effective($0.level, muted: $0.muted) } ?? 0
        case .bluetooth: return Double(s.bluetooth?.lowest?.lowestBattery ?? 0) / 100
        case .network, .sensors, .time, .ai, .power: return 0
        }
    }

    static func percentText(_ m: StatsModule, _ s: StatsSnapshot?) -> String {
        guard let s else { return "–" }
        switch m {
        case .cpu: return s.cpu.map { StatFormat.percent($0.total) } ?? "–"
        case .gpu: return s.gpu.map { StatFormat.percent($0) } ?? "–"
        case .memory: return s.memory.map { StatFormat.percent($0.usedFraction) } ?? "–"
        case .disk: return bootVolume(s).map { StatFormat.percent($0.usedFraction) } ?? "–"
        case .battery, .trio: return s.battery.map { "\($0.percent)%" } ?? "–"
        case .volume: return s.audio.map { $0.volume == nil ? "–" : VolumeMath.percentText($0.level, muted: $0.muted) } ?? "–"
        case .bluetooth: return s.bluetooth?.lowest?.lowestBattery.map { "\($0)%" } ?? "–"
        case .network, .sensors, .time, .ai, .power: return "–"
        }
    }

    /// Used and free bytes: memory (free = what apps can still get) or the startup disk.
    private static func amounts(_ m: StatsModule, _ s: StatsSnapshot?) -> (used: UInt64, free: UInt64)? {
        guard let s else { return nil }
        switch m {
        case .memory: return s.memory.map { ($0.used, $0.total > $0.used ? $0.total - $0.used : 0) }
        case .disk: return bootVolume(s).map { ($0.used, $0.free) }
        default: return nil
        }
    }

    static func bootVolume(_ s: StatsSnapshot) -> VolumeInfo? {
        s.volumes.first { $0.mountPoint == "/" } ?? s.volumes.first
    }

    private static func gigs(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 100 ? "\(Int(g)) GB" : String(format: "%.1f GB", g)
    }

    private static func rateText(_ v: Double?, _ o: Options) -> String {
        guard let v else { return "–" }
        return StatFormat.rate(v, bits: o.bits)
    }

    private static func temperatureText(_ s: StatsSnapshot?, _ o: Options) -> String {
        s?.sensors?.cpu.map { StatFormat.temperature($0, fahrenheit: o.fahrenheit) } ?? "–"
    }

    private static func fanText(_ s: StatsSnapshot?) -> String {
        s?.sensors?.fans.first.map { "\(Int($0.rpm)) rpm" } ?? "–"
    }

    private static func timeLeftText(_ s: StatsSnapshot?) -> String {
        let b = s?.battery
        if let mins = b?.minutesRemaining { return String(format: "%d:%02d", mins / 60, mins % 60) }
        if b?.charged == true || (b?.onAC == true && b?.charging == false) { return "AC" }
        return "–"
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

    private static func single(_ s: String, box: NSRect, font: NSFont = valueFont, align: NSTextAlignment = .right) {
        let lineHeight = ceil(font.ascender - font.descender)
        text(s, font, NSRect(x: box.minX, y: box.minY + (box.height - lineHeight) / 2 - 0.5, width: box.width, height: lineHeight), align: align)
    }

    private static func twoLines(_ top: String, _ bottom: String, box: NSRect) {
        text(top, lineFont, NSRect(x: box.minX, y: 10.5, width: box.width, height: 11), align: .right)
        text(bottom, lineFont, NSRect(x: box.minX, y: 0.5, width: box.width, height: 11), align: .right)
    }

    private static func label(_ s: String, x: CGFloat, top: Bool) {
        text(s, lineFont, NSRect(x: x, y: top ? 10.5 : 0.5, width: 14, height: 11), align: .left)
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

    /// One vertical meter filled from the bottom.
    private static func meter(_ fraction: Double, x: CGFloat) {
        let track = NSRect(x: x, y: 3, width: meterWidth, height: 16)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.2, yRadius: 1.2).fill()
        let h = (16 * CGFloat(min(max(fraction, 0), 1))).rounded()
        guard h >= 1 else { return }
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 3, width: meterWidth, height: h), xRadius: 1.2, yRadius: 1.2).fill()
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

    /// A circular gauge: a faint track with an arc (clockwise from 12 o'clock) for `fraction`.
    private static func ring(_ fraction: Double, center c: NSPoint) {
        let lineWidth: CGFloat = 2.6
        let radius = (pieSize - lineWidth) / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.25).setStroke()
        track.stroke()
        let f = min(max(fraction, 0), 1)
        guard f > 0.005 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(f, 0.999)), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .butt
        NSColor.black.setStroke()
        arc.stroke()
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
    static func signature(_ m: StatsModule, _ elements: [StatsElement], _ s: StatsSnapshot?, _ o: Options, now: Date = Date()) -> String {
        let head = "\(m.rawValue)|" + elements.map(\.rawValue).joined(separator: ",")
        if m == .ai {
            func sig(_ f: AIFigure?) -> String {
                guard let f else { return "-" }
                return AIFormat.tokens(f.tokens) + "/" + AIFormat.cost(f.cost) + "/" + f.windows.map { "\($0.minutes):\(Int($0.usedPercent.rounded()))" }.joined(separator: ",")
                    + "/" + (f.spend.map { AIFormat.compactMoney($0.used, currency: $0.currency) + ":" + String(Int(($0.fraction(left: false) ?? 0) * 100)) } ?? "-")
            }
            let parts = o.aiTags.isEmpty ? [sig(s?.ai?.total)] : o.aiTags.map { tag in sig(s?.ai?.perAgent.first { $0.agent.tag == tag }?.figure) }
            return head + "|" + o.aiTags.joined(separator: ",") + (o.aiPlanLeft ? "|left|" : "|used|") + parts.joined(separator: "#")
        }
        guard let s else {
            return elements.contains(.clock) ? head + "|" + clockText(o.clockFormat, now) : head + "|nil"
        }
        func q(_ values: [Double], scale: Double = 1, steps: Double = 16) -> String {
            values.map { String(Int((min(max($0 / scale, 0), 1) * steps).rounded())) }.joined(separator: ",")
        }
        let parts: [String] = elements.map { e in
            switch e {
            case .label: return ""
            case .graph:
                if let (top, bottom) = series(m, s) {
                    let peak = max(top.max() ?? 0, bottom.max() ?? 0, 1024)
                    return q(top, scale: peak) + "/" + q(bottom, scale: peak)
                }
                return q(history(m, s))
            case .bar: return String(Int((fraction(m, s) * 32).rounded()))
            case .pie: return String(Int((fraction(m, s) * 52).rounded()))
            case .ring: return String(Int((fraction(m, s) * 60).rounded()))
            case .percent: return percentText(m, s)
            case .cores: return q(s.cpu?.perCore ?? [])
            case .usedFree: return amounts(m, s).map { StatFormat.compactAmount($0.used) + "/" + StatFormat.compactAmount($0.free) } ?? "-"
            case .used: return amounts(m, s).map { gigs($0.used) } ?? "-"
            case .free: return amounts(m, s).map { gigs($0.free) } ?? "-"
            case .readWrite: return rateText(s.diskRead, o) + "/" + rateText(s.diskWrite, o)
            case .rates: return rateText(s.netUp, o) + "/" + rateText(s.netDown, o)
            case .temperature: return temperatureText(s, o)
            case .fan: return fanText(s)
            case .tempFan: return temperatureText(s, o) + "/" + fanText(s)
            case .power: return s.sensors?.systemPower.map { String(format: "%.1f", $0) } ?? "-"
            case .battery: return "\(s.battery?.percent ?? -1)|\(s.battery?.charging ?? false)"
            case .timeLeft: return timeLeftText(s)
            case .clock: return clockText(o.clockFormat, now)
            case .aiTokens, .aiCost, .aiTokensCost, .aiPlan, .aiPlanPercent, .aiPlanTwo, .aiCredits: return ""
            case .batteryPower: return PowerFlowMath.barText(s.barWatts)
            case .speaker: return s.audio.map { "\(VolumeMath.waves($0.level, muted: $0.muted))|\($0.muted)" } ?? "-"
            case .levelMeter: return s.audio.map { "\(VolumeMath.filledBars($0.level, muted: $0.muted))" } ?? "-"
            case .bluetoothIcon: return "\(s.bluetooth?.powered ?? false)|\(s.bluetooth?.connected.count ?? -1)"
            case .lowestBattery: return "\(s.bluetooth?.lowest?.lowestBattery ?? -1)"
            case .airPods: return "\(s.bluetooth?.earbuds?.left ?? -1)|\(s.bluetooth?.earbuds?.right ?? -1)"
            case .powerIcon: return "\(s.powerReading?.onAC ?? true)"
            case .powerTwo:
                return "\(s.powerReading?.onAC ?? true)|" + [StatsElement.powerIn, .powerBattery, .powerSystem].map { powerText($0, s.powerBar[$0]) }.joined(separator: "/")
            case .powerIn, .powerBattery, .powerSystem, .powerCPU, .powerGPU, .powerMemory, .powerDisplay, .powerANE,
                 .batteryVolts, .batteryAmps, .adapterRated, .cycleCount:
                return powerText(e, s.powerBar[e])
            case .trio:
                // The battery fill is ~31 px wide at 2x: one step per pixel.
                let fill = s.battery.map { String(Int((Double($0.percent) / 100 * 31).rounded())) } ?? "-"
                return fill + "|\(s.battery?.charging ?? false)|\(s.wifi?.bars ?? -1)|"
                    + (s.audio.map { "\(VolumeMath.waves($0.level, muted: $0.muted))|\($0.muted)" } ?? "-")
            }
        }
        return head + "|" + parts.joined(separator: "#")
    }

    static func accessibilityText(_ m: StatsModule, _ s: StatsSnapshot?, _ o: Options, now: Date = Date()) -> String {
        if m == .time { return clockText(o.clockFormat, now) }
        guard let s else { return m.rawValue }
        switch m {
        case .cpu: return "CPU \(s.cpu.map { StatFormat.percent($0.total) } ?? "")"
        case .gpu: return "GPU \(s.gpu.map { StatFormat.percent($0) } ?? "")"
        case .memory:
            let a = amounts(m, s)
            return "Memory \(s.memory.map { StatFormat.percent($0.usedFraction) } ?? ""), used \(a.map { gigs($0.used) } ?? ""), free \(a.map { gigs($0.free) } ?? "")"
        case .disk:
            return "Disk \(bootVolume(s).map { StatFormat.percent($0.usedFraction) } ?? ""), read \(rateText(s.diskRead, o)), write \(rateText(s.diskWrite, o))"
        case .network: return "Network up \(StatFormat.rate(s.netUp, bits: o.bits)), down \(StatFormat.rate(s.netDown, bits: o.bits))"
        case .sensors: return "CPU temperature \(temperatureText(s, o))"
        case .battery:
            let rate = s.barWatts.map { ", " + PowerFlowMath.barText($0) } ?? ""
            return "Battery \(s.battery.map { "\($0.percent)%" } ?? "")" + rate
        case .time: return ""
        case .power:
            guard let r = s.powerReading else { return "Power" }
            var parts = ["Power: the Mac uses \(PowerMath.watts(r.system))"]
            if r.onAC, let a = r.adapter { parts.append("adapter \(PowerMath.watts(a))") }
            if let b = r.battery, abs(b) >= 0.3 { parts.append(b > 0 ? "charging \(PowerMath.watts(b))" : "battery \(PowerMath.watts(b))") }
            return parts.joined(separator: ", ")
        case .volume:
            guard let a = s.audio else { return "Volume" }
            return a.muted ? "Volume muted" : "Volume \(percentText(.volume, s))"
        case .bluetooth:
            guard let bt = s.bluetooth else { return "Bluetooth" }
            guard bt.powered else { return "Bluetooth off" }
            let low = bt.lowest.flatMap { d in d.lowestBattery.map { ", lowest battery \($0)% (\(d.name))" } } ?? ""
            return "Bluetooth, \(bt.connected.count) connected" + low
        case .trio:
            let battery = s.battery.map { "Battery \($0.percent)%" + ($0.charging ? ", charging" : "") } ?? "No battery"
            let wifi = (s.wifi?.bars ?? 0) > 0 ? "Wi-Fi signal \(s.wifi?.bars ?? 0) of 3" : "Wi-Fi not connected"
            let volume = s.audio.map { $0.muted ? "volume muted" : "volume \(percentText(.volume, s))" } ?? ""
            return [battery, wifi, volume].filter { !$0.isEmpty }.joined(separator: "; ")
        case .ai:
            guard let a = s.ai else { return "AI usage" }
            let credits = a.total.spend.map { s in ", usage credits " + AIFormat.money(s.used, currency: s.currency) + (s.limit.map { " of " + AIFormat.money($0, currency: s.currency) } ?? "") } ?? ""
            return "AI usage \(a.range.rawValue): \(AIFormat.tokens(a.total.tokens)) tokens, \(AIFormat.cost(a.total.cost))" + credits
        }
    }
}
