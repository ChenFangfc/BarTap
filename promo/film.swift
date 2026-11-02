// BarTap promo film: every frame is a pure function of time, drawn with AppKit and piped as raw
// RGBA into ffmpeg. Assets come from `BarTap --export-promo-assets promo/assets` (real BarTap
// renderings of sample data) and assets/logo/bartap-mark.svg.
//
//   swiftc -O promo/film.swift -o .build/film && .build/film <repo> | ffmpeg -f rawvideo ...
//   (see promo/build.sh)
import AppKit

let W: CGFloat = 1920, H: CGFloat = 1080, FPS = 30.0
let duration = 37.2
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
/// "frames" (default), a time in seconds (one still for review), or "cues" (sound cues as JSON).
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "frames"
let language = ProcessInfo.processInfo.environment["FILM_LANG"] ?? "en"

// MARK: - Strings

let zh = language == "zh"
let S: [String: String] = zh ? [
    "full": "菜单栏塞满了。", "full2": "图标越堆越多，躲到了刘海后面。",
    "fake": "很多整理工具靠伪造鼠标拖动来挪图标。", "fake2": "于是屏幕抽动，鼠标也不听使唤。",
    "never": "BarTap 从不和你抢鼠标。", "never2": "隐藏图标从不伪造点击；只有你点「应用」时才移动图标。",
    "tuck": "一条分隔线，图标就收起来了。", "tuck2": "其余什么都不动。",
    "tap": "点一下显示，再点一下收起。", "tap2": "",
    "stats": "实时系统监控，就在菜单栏里。", "stats2": "CPU · GPU · 内存 · 磁盘 · 网络 · 传感器 · 电池 · 时间，每秒刷新",
    "ai": "AI 编程用量，也一眼看清。", "ai2": "Claude Code、Codex、Gemini CLI 等：token、按 API 价折算的费用、套餐额度",
    "all": "菜单栏管理该有的，都有。", "all2": "就是不会抽动。",
    "search": "搜索任意图标", "shelf": "刘海下方的图标架", "rules": "自动规则与快捷键", "clean": "一键干净菜单栏",
    "arrange": "拖动排列图标", "sound": "音量与蓝牙", "power": "电池功率流向", "video": "视频下载",
    "peek": "悬停看详情", "lid": "合盖不睡眠",
    "idle": "空闲时 CPU", "mem": "内存", "fakes": "被拦截的点击",
    "end2": "免费 · macOS 13+ · github.com/ChenFangfc/BarTap",
] : [
    "full": "Your menu bar is full.", "full2": "Icons pile up and vanish behind the notch.",
    "fake": "Many organizers move icons by faking mouse drags.", "fake2": "So the screen twitches and the mouse fights back.",
    "never": "BarTap never fights you for the mouse.", "never2": "Hiding never fakes a click. Icons move only when you click Apply.",
    "tuck": "One divider. Icons tuck away.", "tuck2": "Nothing else moves.",
    "tap": "Tap to show. Tap to hide.", "tap2": "",
    "stats": "Live system stats, right in the bar.", "stats2": "CPU · GPU · memory · disk · network · sensors · battery · time, every second",
    "ai": "Your AI coding usage, too.", "ai2": "Claude Code, Codex, Gemini CLI and more: tokens, cost at API prices, plan limits",
    "all": "Everything a menu bar manager should do.", "all2": "Without the twitching.",
    "search": "Search any icon", "shelf": "Shelf below the notch", "rules": "Rules & hotkeys", "clean": "Clean menu bar",
    "arrange": "Drag to arrange", "sound": "Volume & Bluetooth", "power": "Battery power flow", "video": "Video downloads",
    "peek": "Hover for details", "lid": "Awake, lid closed",
    "idle": "CPU when idle", "mem": "memory", "fakes": "clicks blocked",
    "end2": "Free · macOS 13+ · github.com/ChenFangfc/BarTap",
]

// MARK: - Easing

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func back(_ x: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
/// Fade in over [a, a+d] and out over [b-d, b].
func window(_ t: Double, _ a: Double, _ b: Double, _ d: Double = 0.45) -> Double { min(prog(t, a, a + d), 1 - prog(t, b - d, b)) }

// MARK: - Assets

let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
let gray = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
let studio = NSColor(srgbRed: 0.925, green: 0.922, blue: 0.91, alpha: 1)

func asset(_ path: String) -> NSImage {
    guard let img = NSImage(contentsOf: root.appendingPathComponent(path)) else { fatalError("missing \(path)") }
    return img
}
let markSVG = asset("assets/logo/bartap-mark.svg")
var itemCache: [String: NSImage] = [:]
func item(_ name: String, _ step: Int) -> NSImage {
    let key = "\(name)_\(step % 12)"
    if let i = itemCache[key] { return i }
    let i = asset("promo/assets/items/\(key).png")
    itemCache[key] = i
    return i
}
let toggleCollapsed = asset("promo/assets/items/toggle_collapsed.png")
let toggleRevealed = asset("promo/assets/items/toggle_revealed.png")
let cpuPanel = asset("promo/assets/panel_cpu_light.png")
let aiPanel = asset("promo/assets/panel_ai_light.png")

func symbol(_ name: String, _ size: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
}

/// Draws a template-style image tinted with `color`.
func drawTinted(_ img: NSImage, in r: NSRect, color: NSColor, alpha: Double = 1) {
    guard alpha > 0.001 else { return }
    let tinted = NSImage(size: img.size, flipped: false) { rect in
        img.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: CGFloat(alpha), respectFlipped: true, hints: nil)
}

// MARK: - Text

func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = ink, center: CGPoint, alpha: Double, tracking: CGFloat = 0) {
    guard alpha > 0.001, !s.isEmpty else { return }
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(CGFloat(alpha)), .kern: tracking]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
}

/// Caption lockup: always at the same place below the object.
func caption(_ key: String, _ sub: String, t: Double, a: Double, b: Double) {
    let main = window(t, a, b)
    let rise = CGFloat(10 * (1 - easeOut(prog(t, a, a + 0.6))))
    text(S[key] ?? "", size: zh ? 52 : 56, weight: .semibold, center: CGPoint(x: W / 2, y: 812 + rise), alpha: main, tracking: zh ? 0 : -0.6)
    let subA = window(t, a + 0.35, b)
    text(S[sub] ?? "", size: 28, weight: .regular, color: gray, center: CGPoint(x: W / 2, y: 878 + rise), alpha: subA)
}

// MARK: - The menu bar

/// Menu bar scale: real points → film pixels.
let k: CGFloat = 2.75
let barRect = NSRect(x: 60, y: 210, width: 1800, height: 33 * k)
let notch = NSRect(x: 520, y: barRect.minY, width: 250, height: barRect.height)
let rightEdge = barRect.maxX - 22

struct Icon { let symbol: String; let width: CGFloat }   // width in points (glyph + padding)
let systemIcons: [Icon] = [Icon(symbol: "switch.2", width: 38), Icon(symbol: "wifi", width: 38), Icon(symbol: "battery.75percent", width: 44)]
let thirdParty: [Icon] = ["cloud.fill", "music.note", "paperplane.fill", "bolt.horizontal.fill", "keyboard", "globe", "cup.and.saucer.fill",
                          "camera.fill", "waveform", "timer", "doc.on.clipboard.fill", "lock.shield.fill", "headphones", "drop.fill",
                          "flame.fill", "leaf.fill", "moon.fill", "sparkles"].map { Icon(symbol: $0, width: 36) }
let clockWidth: CGFloat = 80

func drawBar(alpha: Double, dy: CGFloat = 0, shake: CGFloat = 0) {
    guard alpha > 0.001 else { return }
    let r = barRect.offsetBy(dx: shake, dy: dy)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.10 * CGFloat(alpha))
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.withAlphaComponent(0.86 * CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    // Left: Apple menu and an app's menus.
    let y = r.midY
    drawTinted(symbol("apple.logo", 34), in: NSRect(x: r.minX + 40, y: y - 20, width: 33, height: 40), color: ink, alpha: alpha)
    var x = r.minX + 110
    let menus = zh ? ["Safari", "文件", "编辑", "显示", "历史记录", "窗口", "帮助"] : ["Safari", "File", "Edit", "View", "History", "Window", "Help"]
    for (i, title) in menus.enumerated() {
        let font = NSFont.systemFont(ofSize: 34, weight: i == 0 ? .bold : .regular)
        let s = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(CGFloat(alpha))])
        s.draw(at: CGPoint(x: x + shake, y: y - s.size().height / 2))
        x += s.size().width + 40
        if x > notch.minX - 90 { break }
    }
    // The notch.
    NSColor.black.withAlphaComponent(CGFloat(alpha)).setFill()
    let n = notch.offsetBy(dx: shake, dy: dy)
    let p = NSBezierPath()
    p.move(to: NSPoint(x: n.minX - 6, y: n.minY))
    p.line(to: NSPoint(x: n.maxX + 6, y: n.minY))
    p.appendArc(from: NSPoint(x: n.maxX, y: n.minY), to: NSPoint(x: n.maxX, y: n.minY + 12), radius: 6)
    p.line(to: NSPoint(x: n.maxX, y: n.maxY - 22))
    p.appendArc(from: NSPoint(x: n.maxX, y: n.maxY), to: NSPoint(x: n.maxX - 22, y: n.maxY), radius: 22)
    p.line(to: NSPoint(x: n.minX + 22, y: n.maxY))
    p.appendArc(from: NSPoint(x: n.minX, y: n.maxY), to: NSPoint(x: n.minX, y: n.maxY - 22), radius: 22)
    p.line(to: NSPoint(x: n.minX, y: n.minY + 12))
    p.appendArc(from: NSPoint(x: n.minX, y: n.minY), to: NSPoint(x: n.minX - 6, y: n.minY), radius: 6)
    p.close()
    p.fill()
}

func clockString(_ alpha: Double) -> NSAttributedString {
    NSAttributedString(string: zh ? "11月3日 周二 9:41" : "Tue Nov 3  9:41",
                       attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .medium), .foregroundColor: ink.withAlphaComponent(CGFloat(alpha))])
}
/// Where status icons start, right to left.
let clockLeft = rightEdge - clockString(1).size().width - 22

/// Clock text at the far right.
func drawClock(alpha: Double, shake: CGFloat = 0) {
    let s = clockString(alpha)
    s.draw(at: CGPoint(x: rightEdge - s.size().width + shake, y: barRect.midY - s.size().height / 2))
}

/// Draws status icons right-to-left starting at `right`; icons that would cross the notch are not
/// drawn (that is what macOS does). Returns the left edge reached.
@discardableResult
func drawIcons(_ icons: [Icon], right: CGFloat, alpha: Double, jitter: (Int) -> CGFloat = { _ in 0 }, fade: (Int) -> Double = { _ in 1 },
               offset: (Int) -> CGFloat = { _ in 0 }) -> CGFloat {
    var x = right
    for (i, icon) in icons.enumerated() {
        let w = icon.width * k
        x -= w
        let a = alpha * fade(i)
        let drawX = x + offset(i) + jitter(i)
        if drawX + w < notch.maxX { continue }   // fully behind the notch
        let img = symbol(icon.symbol, 15 * k)
        let gw = min(img.size.width, w - 10), gh = img.size.height * gw / max(img.size.width, 1)
        // Clipped at the notch's edge: icons slide under it and vanish.
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: notch.maxX + 2, y: barRect.minY, width: barRect.maxX - notch.maxX, height: barRect.height).clip()
        drawTinted(img, in: NSRect(x: drawX + (w - gw) / 2, y: barRect.midY - gh / 2, width: gw, height: gh), color: ink, alpha: a)
        NSGraphicsContext.restoreGraphicsState()
    }
    return x
}

/// A real BarTap menu bar image (template), tinted for the light bar.
@discardableResult
func drawItem(_ img: NSImage, right: CGFloat, alpha: Double, dy: CGFloat = 0) -> CGFloat {
    let w = img.size.width * k, h = img.size.height * k
    drawTinted(img, in: NSRect(x: right - w, y: barRect.midY - h / 2 + dy, width: w, height: h), color: ink, alpha: alpha)
    return right - w
}

/// A dropdown under a bar item: the top `crop` of a panel image, unrolling with `reveal`.
func dropdown(_ panel: NSImage, under item: NSRect, crop: CGFloat, scale: CGFloat, reveal: CGFloat) {
    let pw = panel.size.width * scale, ph = panel.size.height * scale * crop
    let px = min(item.midX - pw / 2, W - pw - 40)
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(roundedRect: NSRect(x: px, y: barRect.maxY + 10, width: pw, height: ph * reveal), xRadius: 14, yRadius: 14)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18 * reveal)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor.white.setFill()
    clip.fill()
    clip.addClip()
    let src = NSRect(x: 0, y: panel.size.height * (1 - crop), width: panel.size.width, height: panel.size.height * crop)
    panel.draw(in: NSRect(x: px, y: barRect.maxY + 10, width: pw, height: ph), from: src, operation: .sourceOver,
               fraction: reveal, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

func cursor(at p: CGPoint, alpha: Double, pressed: Bool = false) {
    guard alpha > 0.001 else { return }
    let s: CGFloat = pressed ? 0.9 : 1
    let path = NSBezierPath()
    path.move(to: NSPoint(x: p.x, y: p.y))
    path.line(to: NSPoint(x: p.x, y: p.y + 44 * s))
    path.line(to: NSPoint(x: p.x + 11 * s, y: p.y + 33 * s))
    path.line(to: NSPoint(x: p.x + 19 * s, y: p.y + 51 * s))
    path.line(to: NSPoint(x: p.x + 26 * s, y: p.y + 48 * s))
    path.line(to: NSPoint(x: p.x + 18 * s, y: p.y + 30 * s))
    path.line(to: NSPoint(x: p.x + 32 * s, y: p.y + 30 * s))
    path.close()
    NSColor.black.withAlphaComponent(CGFloat(alpha)).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(CGFloat(alpha)).setStroke()
    path.lineWidth = 3
    path.stroke()
}

/// Resting the pointer: a ring fills around it; when it closes, the details open.
func dwell(at p: CGPoint, progress x: Double, alpha: Double) {
    guard alpha > 0.001, x > 0 else { return }
    let c = CGPoint(x: p.x + 13, y: p.y + 22), r: CGFloat = 36
    let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    track.lineWidth = 5
    NSColor.black.withAlphaComponent(0.10 * CGFloat(alpha)).setStroke()
    track.stroke()
    // y grows downward here, so increasing angles run clockwise on screen, from 12 o'clock.
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * CGFloat(min(x, 1)), clockwise: false)
    arc.lineWidth = 5
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: CGFloat(alpha)).setStroke()
    arc.stroke()
}

func ripple(at c: CGPoint, t: Double, start: Double) {
    let x = prog(t, start, start + 0.55)
    guard x > 0, x < 1 else { return }
    let r = CGFloat(18 + 46 * easeOut(x))
    NSColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: CGFloat(0.35 * (1 - x))).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
}

// MARK: - The mark (drawn progressively)

func drawMark(center c: CGPoint, width w: CGFloat, progress p: Double, alpha: Double, weight: CGFloat = 48) {
    guard alpha > 0.001 else { return }
    let s = w / 438   // mark viewBox is 438 wide incl. stroke
    NSGraphicsContext.saveGraphicsState()
    let tr = NSAffineTransform()
    tr.translateX(by: c.x - 219 * s + 24 * s, yBy: c.y - 123.5 * s + 24 * s)
    tr.scale(by: s)
    tr.concat()
    ink.withAlphaComponent(CGFloat(alpha)).setStroke()
    // Path A: horizontal 339, arc (quarter of r=51 → 80), vertical 148 → total 567.
    let a = clamp(p / 0.7) * 567
    let pathA = NSBezierPath()
    pathA.move(to: NSPoint(x: 0, y: 0))
    pathA.line(to: NSPoint(x: min(339, a), y: 0))
    if a > 339 {
        let arc = min(1, (a - 339) / 80)
        pathA.appendArc(withCenter: NSPoint(x: 339, y: 51), radius: 51, startAngle: 270, endAngle: 270 + 90 * arc, clockwise: false)
    }
    if a > 419 { pathA.line(to: NSPoint(x: 390, y: 51 + (a - 419))) }
    // Path B appears after A.
    let b = clamp((p - 0.62) / 0.38)
    let pathB = NSBezierPath()
    pathB.move(to: NSPoint(x: 56, y: 199))
    pathB.line(to: NSPoint(x: 56 + 132 * b, y: 199 - 132 * b))
    for path in [pathA, pathB] {
        path.lineWidth = weight
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
    if a > 0 { pathA.stroke() }
    if b > 0.01 { pathB.stroke() }
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Timeline

// Every event sits on the 100 BPM grid (beat 0.6 s, eighth 0.3 s) so the music can hit it.
let s1 = 0.0, s2 = 4.2, s3 = 8.4, s4 = 12.6, s5 = 18.0, s6 = 23.4, s7 = 28.2, s8 = 31.8
let land = s4                          // the mark settles into the bar
let collapseAt = s4 + 1.2, tap1 = s4 + 3.0, tap2 = s4 + 4.2
let cpuClick = s5 + 1.8
/// The pointer rests on CPU, a ring fills, and its details open: no click (S6 clicks).
let cpuRest = cpuClick - 0.1, cpuPeek = cpuClick + 0.3
let aiItemTime = s6 + 0.3, aiClick = s6 + 1.8
let endAt = s8 + 2.4
/// S1: when each third-party icon appears: accelerating, on a 16th-note grid.
let popTimes: [Double] = {
    var out: [Double] = []
    for i in 0..<thirdParty.count {
        let raw = ((0.6 + 3.0 * pow(Double(i) / Double(thirdParty.count), 0.77)) / 0.15).rounded() * 0.15
        out.append(max(raw, (out.last ?? 0) + 0.15))
    }
    return out
}()
let itemTimes = (0..<3).map { s5 + 0.15 + 0.15 * Double($0) }
let cardTimes = (0..<10).map { s7 + 0.3 + 0.15 * Double($0) }
let numberTimes = (0..<3).map { s8 + 0.3 * Double($0) }
let hopTimes = Array(stride(from: s2 + 0.3, to: s3, by: 0.3))   // S2's teleporting cursor

// MARK: - Scenes

// S4's bar, which S3 needs too (the mark lands exactly on the toggle):
// clock | 2 system icons | 2 shown icons | toggle | divider | hidden icons ... notch.
let s4SysLeft = clockLeft - (systemIcons[0].width + systemIcons[1].width) * k
let s4ToggleRight = s4SysLeft - (thirdParty[0].width + thirdParty[1].width) * k - 4
let toggleWidth = toggleCollapsed.size.width * k
let s4ToggleCenter = CGPoint(x: s4ToggleRight - toggleWidth / 2, y: barRect.midY)
/// drawMark width that matches the bar glyph (21 pt for the SVG's 450 units; drawMark spans 438).
let toggleMarkWidth = 21 * k * 438 / 450

func frame(_ t: Double) {
    studio.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // ---- S1 + S2: the crowded bar, then the twitching. ------------------------------------
    if t < s3 + 0.6 {
        let barA = min(easeOut(prog(t, s1, s1 + 0.6)), 1 - prog(t, s3, s3 + 0.6))
        let chaos = t >= s2 ? window(t, s2 + 0.2, s3 + 0.2, 0.3) : 0
        let shake = CGFloat(chaos * (sin(t * 37) * 3 + sin(t * 61) * 2))
        drawBar(alpha: barA, shake: shake)
        drawClock(alpha: barA, shake: shake)
        let sysLeft = drawIcons(systemIcons, right: clockLeft, alpha: barA, jitter: { _ in shake })
        // Apps keep adding icons: each new one appears beside the system icons and pushes the row
        // left, under the notch.
        let count = max(1, popTimes.filter { $0 <= t }.count)
        let enter = easeOut(prog(t, popTimes[count - 1], popTimes[count - 1] + 0.15))
        let row = Array(thirdParty.prefix(count).reversed())   // newest first (rightmost)
        drawIcons(row, right: sysLeft, alpha: barA,
                  jitter: { i in
                      guard chaos > 0 else { return 0 }
                      // Bursts of synthetic drags: icons jump sideways.
                      let burst = sin(t * 9 + Double(i) * 1.7) > 0.55 ? 1.0 : 0.0
                      return CGFloat(chaos * burst * (sin(t * 47 + Double(i)) * 26))
                  },
                  fade: { i in i == 0 ? enter : 1 },
                  offset: { i in i == 0 ? 0 : CGFloat(1 - enter) * row[0].width * k })
        if chaos > 0 {
            // A cursor that teleports from icon to icon.
            let hop = Int(t / 0.3)
            let px = 1000 + CGFloat((hop * 137) % 700)
            cursor(at: CGPoint(x: px, y: barRect.midY - 8 + CGFloat((hop * 53) % 40)), alpha: chaos)
        }
        caption("full", "full2", t: t, a: s1 + 0.7, b: s2)
        caption("fake", "fake2", t: t, a: s2 + 0.3, b: s3)
    }

    // ---- S4: hide / show with one divider. ----------------------------------------------------
    if t >= s4 - 0.5, t < s5 {
        let barA = easeOut(prog(t, s4 - 0.5, land))
        let iconA = easeOut(prog(t, land, land + 0.4)) * (1 - prog(t, s5 - 0.35, s5))
        drawBar(alpha: barA)
        drawClock(alpha: barA)
        // Wi-Fi leaves with the shown icons at the end, to make room for the stats.
        drawIcons(Array(systemIcons.prefix(2)), right: clockLeft, alpha: barA, fade: { i in i == 1 ? 1 - prog(t, s5 - 0.35, s5) : 1 })
        drawIcons(Array(thirdParty.prefix(2)), right: s4SysLeft, alpha: iconA)
        // Collapse, tap to reveal, tap to collapse again.
        let hideA = ease(prog(t, collapseAt, collapseAt + 0.6))
        let reveal = ease(prog(t, tap1, tap1 + 0.5)) * (1 - ease(prog(t, tap2, tap2 + 0.5)))
        let collapsed = clamp(hideA - reveal)
        if t >= land {
            drawItem(t >= tap1 && t < tap2 ? toggleRevealed : toggleCollapsed, right: s4ToggleRight, alpha: 1)
        }
        // The divider grows and pushes the hidden icons left, under the notch. Nothing right of it moves.
        let dividerX = s4ToggleRight - toggleWidth - 8
        let travel = dividerX - notch.maxX + 10
        drawIcons(Array(thirdParty.dropFirst(2)), right: dividerX - 6, alpha: iconA,
                  fade: { _ in 1 - 0.5 * collapsed }, offset: { _ in -travel * CGFloat(collapsed) })
        NSColor.black.withAlphaComponent(0.3 * CGFloat(iconA * (1 - collapsed))).setFill()
        NSRect(x: dividerX - 1.5, y: barRect.midY - 20, width: 3, height: 40).fill()
        // The user's own cursor: calm, taps the toggle twice.
        let cA = window(t, tap1 - 0.9, tap2 + 0.7, 0.4)
        let arrive = ease(prog(t, tap1 - 0.9, tap1 - 0.2))
        ripple(at: s4ToggleCenter, t: t, start: tap1 - 0.05)
        ripple(at: s4ToggleCenter, t: t, start: tap2 - 0.05)
        cursor(at: CGPoint(x: lerp(1450, s4ToggleCenter.x + 4, arrive), y: lerp(520, s4ToggleCenter.y + 2, arrive)),
               alpha: cA, pressed: abs(t - tap1) < 0.12 || abs(t - tap2) < 0.12)
        caption("tuck", "tuck2", t: t, a: collapseAt - 0.3, b: tap1 - 0.1)
        caption("tap", "tap2", t: t, a: tap1, b: s5)
    }

    // ---- S3: the mark draws itself, then flies into the toggle's slot (on top of S4's bar). ------
    if t >= s3, t < land + 0.1 {
        let draw = ease(prog(t, s3 + 0.5, s3 + 2.1))
        let fly = ease(prog(t, s4 - 0.7, land))
        let c = CGPoint(x: lerp(W / 2, s4ToggleCenter.x, fly), y: lerp(470, s4ToggleCenter.y, fly))
        drawMark(center: c, width: lerp(470, toggleMarkWidth, fly), progress: draw, alpha: 1 - prog(t, land, land + 0.1),
                 weight: lerp(48, 58, fly))
        caption("never", "never2", t: t, a: s3 + 0.9, b: s4 - 0.2)
    }

    // ---- S5 + S6: live stats + a dropdown, then AI usage + its dropdown. -----------------------
    if t >= s5, t < s7 + 0.4 {
        let barA = 1 - prog(t, s7, s7 + 0.4)
        drawBar(alpha: barA)
        drawClock(alpha: barA)
        let step = Int((t - s5) * 2)   // values change twice a second
        // Later the AI usage item cross-fades into Control Center's slot (it leaves to make room,
        // like Wi-Fi did), so the toggle stays clear of the notch. Its value matches the dropdown.
        let aiIn = easeOut(prog(t, aiItemTime, aiItemTime + 0.45))
        drawIcons(Array(systemIcons.prefix(1)), right: clockLeft, alpha: barA * (1 - aiIn))
        let gap = 7 * k
        var aiRect = NSRect.zero
        if aiIn > 0.001 {
            let r = clockLeft - 12
            let left = drawItem(item("ai", 3), right: r, alpha: barA * aiIn)
            aiRect = NSRect(x: left, y: barRect.minY, width: r - left, height: barRect.height)
        }
        // Stats appear right of the toggle, which slides left to make room (as in the real bar).
        var right = clockLeft - lerp(systemIcons[0].width * k + 4, 12 + item("ai", 3).size.width * k + gap, aiIn)
        var cpuRect = NSRect.zero
        for (i, n) in ["network", "memory", "cpu"].enumerated() {
            let a = barA * easeOut(prog(t, itemTimes[i], itemTimes[i] + 0.45))
            let left = drawItem(item(n, step + i), right: right, alpha: a, dy: CGFloat(14 * (1 - a)))
            if n == "cpu" { cpuRect = NSRect(x: left, y: barRect.minY, width: right - left, height: barRect.height) }
            right = left - gap
        }
        drawItem(toggleCollapsed, right: lerp(s4ToggleRight, right, ease(prog(t, s5, s5 + 0.7))), alpha: barA)
        // Rest the pointer on CPU → its details open (its top half, large enough to read).
        let open = ease(prog(t, cpuPeek, cpuPeek + 0.4)) * (1 - ease(prog(t, s6 - 0.5, s6 - 0.1)))
        if open > 0.001 { dropdown(cpuPanel, under: cpuRect, crop: 0.5, scale: 1.6, reveal: CGFloat(open)) }
        let cA = window(t, cpuClick - 0.8, cpuPeek + 1.0, 0.3)
        let arrive = ease(prog(t, cpuClick - 0.8, cpuRest))
        let cpuPointer = CGPoint(x: lerp(1500, cpuRect.midX + 4, arrive), y: lerp(560, cpuRect.midY + 2, arrive))
        dwell(at: cpuPointer, progress: prog(t, cpuRest, cpuPeek), alpha: cA * (1 - prog(t, cpuPeek, cpuPeek + 0.25)))
        cursor(at: cpuPointer, alpha: cA)
        caption("stats", "stats2", t: t, a: s5 + 0.4, b: s6)
        // Click AI usage → its dropdown (totals by range and by agent).
        let aiOpen = ease(prog(t, aiClick, aiClick + 0.4)) * (1 - ease(prog(t, s7 - 0.5, s7 - 0.1)))
        if aiOpen > 0.001 { dropdown(aiPanel, under: aiRect, crop: 0.47, scale: 1.45, reveal: CGFloat(aiOpen)) }
        ripple(at: CGPoint(x: aiRect.midX, y: aiRect.midY), t: t, start: aiClick - 0.05)
        let aA = window(t, aiClick - 0.8, aiClick + 1.0, 0.3)
        let aArrive = ease(prog(t, aiClick - 0.8, aiClick - 0.1))
        cursor(at: CGPoint(x: lerp(1500, aiRect.midX + 4, aArrive), y: lerp(560, aiRect.midY + 2, aArrive)),
               alpha: aA, pressed: abs(t - aiClick) < 0.12)
        caption("ai", "ai2", t: t, a: s6 + 0.4, b: s7)
    }

    // ---- S7: feature cards. --------------------------------------------------------------------
    if t >= s7, t < s8 + 0.4 {
        let cards: [(String, String)] = [("arrow.left.and.right", "arrange"), ("magnifyingglass", "search"),
                                         ("rectangle.bottomthird.inset.filled", "shelf"), ("wand.and.stars", "rules"),
                                         ("cursorarrow.rays", "peek"),
                                         ("speaker.wave.2", "sound"), ("powerplug", "power"),
                                         ("arrow.down.circle", "video"), ("laptopcomputer", "lid"), ("eye.slash", "clean")]
        let perRow = 5
        let cw: CGFloat = 300, ch: CGFloat = 190, gap: CGFloat = 26
        let total = CGFloat(perRow) * cw + CGFloat(perRow - 1) * gap
        for (i, (sym, key)) in cards.enumerated() {
            let a0 = cardTimes[i]
            let p = back(prog(t, a0, a0 + 0.5))
            let a = prog(t, a0, a0 + 0.3) * (1 - prog(t, s8, s8 + 0.4))
            guard a > 0.001 else { continue }
            let x = (W - total) / 2 + CGFloat(i % perRow) * (cw + gap)
            let y: CGFloat = 270 + CGFloat(i / perRow) * (ch + gap) + CGFloat(40 * (1 - p))
            let r = NSRect(x: x, y: y, width: cw, height: ch)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.08 * CGFloat(a))
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.white.withAlphaComponent(CGFloat(a)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill()
            NSGraphicsContext.restoreGraphicsState()
            let img = symbol(sym, 54)
            let iw = img.size.width, ih = img.size.height
            drawTinted(img, in: NSRect(x: r.midX - iw / 2, y: r.minY + 86 - ih / 2, width: iw, height: ih), color: ink, alpha: a)
            text(S[key] ?? "", size: 26, weight: .semibold, center: CGPoint(x: r.midX, y: r.maxY - 44), alpha: a)
        }
        caption("all", "all2", t: t, a: s7 + 0.5, b: s8)
    }

    // ---- S8: numbers, then the end card. -------------------------------------------------------
    if t >= s8 {
        let nums: [(String, String)] = [("0.02%", "idle"), ("~40 MB", "mem"), ("0", "fakes")]
        let fadeNums = 1 - prog(t, endAt - 0.4, endAt)
        for (i, (big, key)) in nums.enumerated() {
            let a0 = numberTimes[i]
            let a = easeOut(prog(t, a0, a0 + 0.4)) * fadeNums
            let x = W / 2 + CGFloat(i - 1) * 470
            text(big, size: 110, weight: .bold, center: CGPoint(x: x, y: 470 + CGFloat(20 * (1 - a))), alpha: a, tracking: -2)
            text(S[key] ?? "", size: 30, weight: .medium, color: gray, center: CGPoint(x: x, y: 560), alpha: a)
        }
        let endA = easeOut(prog(t, endAt, endAt + 0.6))
        drawMark(center: CGPoint(x: W / 2, y: 440), width: 300, progress: ease(prog(t, endAt, endAt + 1.0)), alpha: endA, weight: 46)
        text("BarTap", size: 76, weight: .bold, center: CGPoint(x: W / 2, y: 640), alpha: easeOut(prog(t, endAt + 0.3, endAt + 0.8)), tracking: -1.5)
        text(S["end2"] ?? "", size: 28, weight: .regular, color: gray, center: CGPoint(x: W / 2, y: 712), alpha: easeOut(prog(t, endAt + 0.6, endAt + 1.1)))
    }
}

// MARK: - Render loop

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: Int(W) * 4, bitsPerPixel: 32)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
// Flip so y grows downward, like a page layout.
func render(_ t: Double) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    ctx.cgContext.saveGState()
    ctx.cgContext.translateBy(x: 0, y: H)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    frame(t)
    ctx.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
}

if mode == "cues" {
    // Sound cues for promo/music.py.
    var cues: [[String: Any]] = []
    func cue(_ t: Double, _ type: String, _ n: Int = 0) { cues.append(["t": (t * 1000).rounded() / 1000, "type": type, "n": n]) }
    for (i, p) in popTimes.enumerated() { cue(p, "pop", i) }
    for h in hopTimes { cue(h, "glitch") }
    cue(s3 + 0.5, "draw"); cue(s3 + 2.1, "drawn"); cue(s4 - 0.7, "fly"); cue(land, "land")
    cue(collapseAt, "hide"); cue(tap1, "tap", 0); cue(tap2, "tap", 1)
    for (i, p) in itemTimes.enumerated() { cue(p, "item", i) }
    cue(cpuPeek, "click")
    cue(aiItemTime, "item", 3); cue(aiClick, "click")
    for (i, p) in cardTimes.enumerated() { cue(p, "card", i) }
    for (i, p) in numberTimes.enumerated() { cue(p, "number", i) }
    cue(endAt, "end")
    let json: [String: Any] = ["duration": duration, "scenes": [s1, s2, s3, s4, s5, s6, s7, s8], "cues": cues]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
} else if let still = Double(mode) {
    render(still)
    let out = root.appendingPathComponent("promo/out/still-\(language)-\(String(format: "%05.2f", still)).png")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
    FileHandle.standardError.write("wrote \(out.path)\n".data(using: .utf8)!)
} else {
    let frames = Int(duration * FPS)
    let out = FileHandle.standardOutput
    for i in 0..<frames {
        autoreleasepool {
            render(Double(i) / FPS)
            out.write(Data(bytes: rep.bitmapData!, count: Int(W * H * 4)))
        }
    }
}
