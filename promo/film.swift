// BarTap promo film: every frame is a pure function of time, drawn with AppKit and piped as raw
// RGBA into ffmpeg. Assets come from `BarTap --export-promo-assets promo/assets` (real BarTap
// renderings of sample data) and assets/logo/bartap-mark.svg.
//
//   swiftc -O promo/film.swift -o .build/film && .build/film <repo> | ffmpeg -f rawvideo ...
//   (see promo/build.sh)
import AppKit
import CoreImage

let W: CGFloat = 1920, H: CGFloat = 1080, FPS = 30.0
let duration = 49.0
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
    "arrange": "拖动排列图标", "sound": "音量与蓝牙", "power": "用电明细", "video": "视频下载",
    "peek": "悬停看详情", "lid": "合盖不睡眠",
    "lidT": "合上盖子，AI 照样跑。", "lidT2": "合盖不睡眠：长任务、整夜跑，都不会中断",
    "lidOn": "合盖不睡眠 · 已开启",
    "term0": "› AI 代理：重构 12 个文件…", "term1": "✓ 128 项测试全部通过", "term2": "› 继续：更新文档，然后提交…",
    "dl": "存下视频，交给 AI 总结。", "dl2": "粘贴链接，选清晰度，或者只要音频",
    "ask": "总结一下这个视频", "reply": "10 分钟短片：一只大兔子、三个捣蛋鬼，和一场漂亮的反击。",
    "watt": "每一瓦电去了哪，一目了然。", "watt2": "充电器输入、电池充放，CPU、GPU、内存、屏幕各用多少",
    "c1": "每一瓦的去向", "c1s": "充电器 → 本机和电池 → CPU、GPU、内存、屏幕",
    "c2": "最近两分钟", "c2s": "各部件逐秒叠加，电池充电也在里面",
    "c3": "电池状态，实时测量", "c3s": "电压、电流、温度、容量、健康度、循环次数",
    "c4": "充电器参数", "c4s": "额定功率、协商电压电流、此刻输入",
    "c5": "每个 App 的耗电", "c5s": "当前功率，以及启动以来的累计用电",
    "deep": "每一项，都有这样的详情页。", "deep2": "指针停一下就展开，点一下就固定",
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
    "arrange": "Drag to arrange", "sound": "Volume & Bluetooth", "power": "Power, watt by watt", "video": "Video downloads",
    "peek": "Hover for details", "lid": "Awake, lid closed",
    "lidT": "Close the lid. Your AI keeps going.", "lidT2": "Stay awake with the lid closed: long runs and overnight jobs keep running",
    "lidOn": "Awake with lid closed · On",
    "term0": "› agent: refactoring 12 files…", "term1": "✓ all 128 tests passed", "term2": "› next: docs, then commit…",
    "dl": "Save a video. Let AI sum it up.", "dl2": "Paste a link, pick a quality, or audio only",
    "ask": "Sum up this video", "reply": "A 10-minute short: one big rabbit, three bullies and one sweet comeback.",
    "watt": "See where every watt goes.", "watt2": "What the charger delivers, what the battery takes, what CPU, GPU, memory and display use",
    "c1": "Where every watt goes", "c1s": "Charger → Mac and battery → CPU, GPU, memory, display",
    "c2": "The last two minutes", "c2s": "Part by part, the battery's charge on top",
    "c3": "Your battery, measured live", "c3s": "Voltage, current, temperature, capacity, health, cycles",
    "c4": "Your charger", "c4s": "Its rating, the negotiated voltage, what comes in now",
    "c5": "Every app's power", "c5s": "Watts right now, energy used since it started",
    "deep": "Every item has details like this.", "deep2": "Rest the pointer to peek. Click to keep them open.",
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
let downloadPanel = asset("promo/assets/downloads/downloads_preview_\(zh ? "zh" : "en")_light.png")
/// The Power details without their dots (the film moves them along the real flows), and pointing
/// at the CPU's flow; their layout and flows (points, y down from the panel's top).
let lang = zh ? "zh" : "en"
let powerPanel = asset("promo/assets/film/panel_power_\(lang).png")
let powerHover = asset("promo/assets/film/panel_power_hover_\(lang).png")
let powerLayout = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("promo/assets/film/power_\(lang).json"))) as! [String: Any]
let montagePanels = ["cpu", "memory", "network", "power", "ai", "battery", "bluetooth"].map { name in
    name == "power" ? powerPanel : asset("promo/assets/film/panel_\(name)_\(lang).png")
}

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

// MARK: - Lid and download scenes

let green = NSColor(srgbRed: 0.20, green: 0.70, blue: 0.33, alpha: 1)
let blue = NSColor(srgbRed: 0.10, green: 0.45, blue: 1, alpha: 1)

func softShadow(_ alpha: Double, blur: CGFloat = 30, dy: CGFloat = -10, strength: CGFloat = 0.10) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(strength * CGFloat(alpha))
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: dy)
    shadow.set()
}

// A laptop as a simple 3D model (lid scene), seen from a little above and to the right: the lid
// turns on its hinge, the screen shows an AI agent at work (mapped in perspective), and once the lid
// passes the line of sight its aluminium back shows, as a real one does.

struct V3 { var x: CGFloat, y: CGFloat, z: CGFloat }
func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
func - (a: V3, b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
func * (a: V3, k: CGFloat) -> V3 { V3(x: a.x * k, y: a.y * k, z: a.z * k) }
func dot(_ a: V3, _ b: V3) -> CGFloat { a.x * b.x + a.y * b.y + a.z * b.z }
func cross(_ a: V3, _ b: V3) -> V3 { V3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
func unit(_ a: V3) -> V3 { a * (1 / sqrt(dot(a, a))) }

struct Camera {
    let eye: V3, fwd: V3, right: V3, up: V3
    let f: CGFloat, center: CGPoint
    init(eye: V3, target: V3, f: CGFloat, center: CGPoint) {
        self.eye = eye
        self.f = f
        self.center = center
        fwd = unit(target - eye)
        right = unit(cross(fwd, V3(x: 0, y: 1, z: 0)))
        up = cross(right, fwd)
    }
    /// Film coordinates (y down).
    func p(_ q: V3) -> CGPoint {
        let d = q - eye, z = dot(d, fwd)
        return CGPoint(x: center.x + f * dot(d, right) / z, y: center.y - f * dot(d, up) / z)
    }
    /// Whether a face through `q` with outward normal `n` faces the camera.
    func sees(_ q: V3, _ n: V3) -> Bool { dot(n, eye - q) > 0 }
}

let laptopCam = Camera(eye: V3(x: 560, y: 600, z: 1550), target: V3(x: 0, y: 120, z: 0), f: 1050, center: CGPoint(x: 960, y: 540))
let ciContext = CIContext(options: [.cacheIntermediates: false])

func fillQuad(_ q: [CGPoint], _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: q[0])
    for pt in q.dropFirst() { path.line(to: pt) }
    path.close()
    color.setFill()
    path.fill()
}

/// What the screen shows: the agent's lines, then a blinking caret.
func screenImage(t: Double, width: Int, height: Int) -> CGImage? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: g.cgContext, flipped: true)
    g.cgContext.translateBy(x: 0, y: CGFloat(height))
    g.cgContext.scaleBy(x: 1, y: -1)
    NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    // As large as the widest line allows (some languages run longer).
    let lines = (0..<termTimes.count).map { S["term\($0)"] ?? "" }
    let base = NSFont.monospacedSystemFont(ofSize: CGFloat(height) * 0.085, weight: .medium)
    let widest = lines.map { NSAttributedString(string: $0, attributes: [.font: base]).size().width }.max() ?? 1
    let font = NSFont.monospacedSystemFont(ofSize: base.pointSize * min(1, CGFloat(width) * 0.86 / widest), weight: .medium)
    let lineH = CGFloat(height) * 0.16, x0 = CGFloat(width) * 0.06, y0 = CGFloat(height) * 0.12
    for (i, at) in termTimes.enumerated() {
        let la = easeOut(prog(t, at, at + 0.2))
        guard la > 0.001 else { continue }
        let color = i == 1 ? NSColor(srgbRed: 0.45, green: 0.86, blue: 0.55, alpha: CGFloat(la)) : NSColor(white: 0.93, alpha: CGFloat(la))
        NSAttributedString(string: lines[i], attributes: [.font: font, .foregroundColor: color])
            .draw(at: CGPoint(x: x0, y: y0 + CGFloat(i) * lineH))
    }
    if t >= termTimes[2] + 0.2, Int(t / 0.25) % 2 == 0 {
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: x0, y: y0 + 3 * lineH + lineH * 0.05, width: font.pointSize * 0.55, height: font.pointSize * 1.1).fill()
    }
    // A faint sheen across the glass.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.07), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

/// Draws `image` onto the quad (top-left, top-right, bottom-right, bottom-left; film coordinates).
func drawMapped(_ image: CGImage, _ q: [CGPoint], alpha: Double) {
    guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return }
    func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: H - p.y) }   // Core Image's y grows upward
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(v(q[0]), forKey: "inputTopLeft")
    filter.setValue(v(q[1]), forKey: "inputTopRight")
    filter.setValue(v(q[2]), forKey: "inputBottomRight")
    filter.setValue(v(q[3]), forKey: "inputBottomLeft")
    guard let out = filter.outputImage else { return }
    let ext = out.extent.integral
    guard ext.width > 1, ext.height > 1, let cg = ciContext.createCGImage(out, from: ext) else { return }
    NSImage(cgImage: cg, size: ext.size).draw(in: NSRect(x: ext.minX, y: H - ext.maxY, width: ext.width, height: ext.height),
                                              from: .zero, operation: .sourceOver, fraction: CGFloat(alpha), respectFlipped: true, hints: nil)
}

/// The laptop, its lid open by `open` (1 open at 108°, 0 shut).
func drawLaptop(open: Double, t: Double, alpha: Double) {
    guard alpha > 0.001, let gc = NSGraphicsContext.current?.cgContext else { return }
    // Drawn opaque and faded as one piece: faded face by face, the shut lid would let the keyboard
    // show through it.
    gc.saveGState()
    gc.setAlpha(CGFloat(alpha))
    gc.beginTransparencyLayer(auxiliaryInfo: nil)
    defer {
        gc.endTransparencyLayer()
        gc.restoreGState()
    }
    let cam = laptopCam
    let a: CGFloat = 330, b: CGFloat = 225, tb: CGFloat = 14, L: CGFloat = 446, tl: CGFloat = 8
    let A: CGFloat = 1
    func c(_ w: CGFloat) -> NSColor { NSColor(srgbRed: w, green: w, blue: w + 0.02, alpha: A) }
    // Base: the deck (keyboard, trackpad), its front and right side; the shadow grounds it.
    let deck = [V3(x: -a, y: 0, z: -b), V3(x: a, y: 0, z: -b), V3(x: a, y: 0, z: b), V3(x: -a, y: 0, z: b)].map(cam.p)
    NSGraphicsContext.saveGraphicsState()
    softShadow(1, blur: 46, dy: -26, strength: 0.22)
    fillQuad([V3(x: -a, y: -tb, z: -b), V3(x: a, y: -tb, z: -b), V3(x: a, y: -tb, z: b), V3(x: -a, y: -tb, z: b)].map(cam.p), c(0.70))
    NSGraphicsContext.restoreGraphicsState()
    fillQuad([V3(x: a, y: 0, z: -b), V3(x: a, y: 0, z: b), V3(x: a, y: -tb, z: b), V3(x: a, y: -tb, z: -b)].map(cam.p), c(0.66))
    fillQuad([V3(x: -a, y: 0, z: b), V3(x: a, y: 0, z: b), V3(x: a, y: -tb, z: b), V3(x: -a, y: -tb, z: b)].map(cam.p), c(0.74))
    fillQuad(deck, c(0.87))
    fillQuad([V3(x: -295, y: 0, z: -205), V3(x: 295, y: 0, z: -205), V3(x: 295, y: 0, z: -20), V3(x: -295, y: 0, z: -20)].map(cam.p), c(0.24))
    fillQuad([V3(x: -110, y: 0, z: 25), V3(x: 110, y: 0, z: 25), V3(x: 110, y: 0, z: 200), V3(x: -110, y: 0, z: 200)].map(cam.p), c(0.80))
    // Lid: turns on the hinge (the deck's back edge). `u` runs from the hinge to the far edge.
    let th = CGFloat(108 * clamp(open) * .pi / 180)
    let u = V3(x: 0, y: sin(th), z: cos(th))
    let nIn = V3(x: 0, y: -cos(th), z: sin(th))   // the screen side
    let nOut = nIn * -1
    func lid(_ x: CGFloat, _ s: CGFloat, _ outer: Bool = false) -> V3 {
        V3(x: x, y: 0, z: -b) + u * s + (outer ? nOut * tl : V3(x: 0, y: 0, z: 0))
    }
    // Its edges first: the far edge and the right side.
    if cam.sees(lid(0, L), u) { fillQuad([lid(-a, L), lid(a, L), lid(a, L, true), lid(-a, L, true)].map(cam.p), c(0.72)) }
    fillQuad([lid(a, 0), lid(a, L), lid(a, L, true), lid(a, 0, true)].map(cam.p), c(0.68))
    if cam.sees(lid(0, L / 2), nIn) {
        fillQuad([lid(-a, L), lid(a, L), lid(a, 0), lid(-a, 0)].map(cam.p), c(0.12))   // bezel
        let quad = [lid(-a + 18, L - 18), lid(a - 18, L - 18), lid(a - 18, 16), lid(-a + 18, 16)].map(cam.p)
        if let img = screenImage(t: t, width: 1248, height: 824) { drawMapped(img, quad, alpha: 1) }
    } else {
        fillQuad([lid(-a, L, true), lid(a, L, true), lid(a, 0, true), lid(-a, 0, true)].map(cam.p), c(0.84))   // its back
    }
}

/// A capsule with a green dot: BarTap's switch, on.
func pill(_ s: String, center c: CGPoint, alpha: Double) {
    guard alpha > 0.001 else { return }
    let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 27, weight: .semibold),
                                                         .foregroundColor: ink.withAlphaComponent(CGFloat(alpha))])
    let sz = str.size()
    let h: CGFloat = 58, r = NSRect(x: c.x - (sz.width + 84) / 2, y: c.y - h / 2, width: sz.width + 84, height: h)
    NSGraphicsContext.saveGraphicsState()
    softShadow(alpha, blur: 20, dy: -6, strength: 0.08)
    NSColor.white.withAlphaComponent(CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    let border = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: h / 2 - 1.5, yRadius: h / 2 - 1.5)
    border.lineWidth = 3
    green.withAlphaComponent(CGFloat(alpha)).setStroke()
    border.stroke()
    green.withAlphaComponent(CGFloat(alpha)).setFill()
    NSBezierPath(ovalIn: NSRect(x: r.minX + 26, y: c.y - 9, width: 18, height: 18)).fill()
    str.draw(at: CGPoint(x: r.minX + 56, y: c.y - sz.height / 2))
}

/// The downloaded file: name, and a bar filling to a check mark.
func fileChip(_ r: NSRect, progress: Double, alpha: Double) {
    guard alpha > 0.001 else { return }
    NSGraphicsContext.saveGraphicsState()
    softShadow(alpha, blur: 18, dy: -6, strength: 0.10)
    NSColor.white.withAlphaComponent(CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
    NSGraphicsContext.restoreGraphicsState()
    let unit = r.height / 66
    let icon = symbol("film", 26 * unit)
    drawTinted(icon, in: NSRect(x: r.minX + 18 * unit, y: r.midY - icon.size.height / 2 - 4 * unit, width: icon.size.width, height: icon.size.height),
               color: gray, alpha: alpha)
    let name = NSAttributedString(string: "Big Buck Bunny.mp4", attributes: [.font: NSFont.systemFont(ofSize: 23 * unit, weight: .semibold),
                                                                          .foregroundColor: ink.withAlphaComponent(CGFloat(alpha))])
    name.draw(at: CGPoint(x: r.minX + 62 * unit, y: r.midY - name.size().height / 2 - 6 * unit))
    let track = NSRect(x: r.minX + 62 * unit, y: r.maxY - 16 * unit, width: r.width - 120 * unit, height: 6 * unit)
    NSColor.black.withAlphaComponent(0.08 * CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: track, xRadius: 3 * unit, yRadius: 3 * unit).fill()
    (progress >= 1 ? green : blue).withAlphaComponent(CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(progress, 1)), height: track.height),
                 xRadius: 3 * unit, yRadius: 3 * unit).fill()
    if progress >= 1 {
        let check = symbol("checkmark.circle.fill", 26 * unit)
        drawTinted(check, in: NSRect(x: r.maxX - 44 * unit, y: r.midY - check.size.height / 2, width: check.size.width, height: check.size.height),
                   color: green, alpha: alpha)
    }
}

/// A chat with whatever AI you use (not BarTap): the file and a question, then its answer.
func aiChat(_ r: NSRect, t: Double, alpha: Double, landed: Bool) {
    guard alpha > 0.001 else { return }
    NSGraphicsContext.saveGraphicsState()
    softShadow(alpha, blur: 30, dy: -10, strength: 0.10)
    NSColor.white.withAlphaComponent(CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 24, yRadius: 24).fill()
    NSGraphicsContext.restoreGraphicsState()
    let spark = symbol("sparkles", 26)
    drawTinted(spark, in: NSRect(x: r.minX + 26, y: r.minY + 42 - spark.size.height / 2, width: spark.size.width, height: spark.size.height),
               color: ink, alpha: alpha)
    NSAttributedString(string: "AI", attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: ink.withAlphaComponent(CGFloat(alpha))])
        .draw(at: CGPoint(x: r.minX + 66, y: r.minY + 26))
    guard landed else { return }
    // The question, under the file.
    fileChip(NSRect(x: r.maxX - 24 - 330, y: r.minY + 84, width: 330, height: 54), progress: 1, alpha: alpha)
    let askA = alpha * easeOut(prog(t, aiSend + 0.45, aiSend + 0.7))
    let ask = NSAttributedString(string: S["ask"] ?? "", attributes: [.font: NSFont.systemFont(ofSize: 25, weight: .medium),
                                                                     .foregroundColor: NSColor.white.withAlphaComponent(CGFloat(askA))])
    let aw = ask.size().width + 40
    let askRect = NSRect(x: r.maxX - 24 - aw, y: r.minY + 150, width: aw, height: 50)
    blue.withAlphaComponent(CGFloat(askA)).setFill()
    NSBezierPath(roundedRect: askRect, xRadius: 25, yRadius: 25).fill()
    ask.draw(at: CGPoint(x: askRect.minX + 20, y: askRect.midY - ask.size().height / 2))
    // The answer, typed out.
    let reply = S["reply"] ?? ""
    let shown = Int((Double(reply.count) * prog(t, aiReply, aiReply + 0.9)).rounded())
    guard shown > 0 else { return }
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 25, weight: .regular), .foregroundColor: ink.withAlphaComponent(CGFloat(alpha)),
                                                .paragraphStyle: style]
    let textW = r.width - 48 - 40
    let full = NSAttributedString(string: reply, attributes: attrs).boundingRect(with: NSSize(width: textW, height: 400), options: [.usesLineFragmentOrigin])
    let bubble = NSRect(x: r.minX + 24, y: r.minY + 216, width: min(textW, ceil(full.width)) + 40, height: ceil(full.height) + 26)
    NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: CGFloat(alpha)).setFill()
    NSBezierPath(roundedRect: bubble, xRadius: 22, yRadius: 22).fill()
    NSAttributedString(string: String(reply.prefix(shown)), attributes: attrs)
        .draw(with: NSRect(x: bubble.minX + 20, y: bubble.minY + 13, width: textW, height: 400), options: [.usesLineFragmentOrigin])
}

/// BarTap's real download panel (sample data: an open-source short film): Download is clicked, the
/// file comes in and goes to an AI chat, which answers.
func drawDownloadScene(t: Double, alpha a: Double) {
    guard a > 0.001 else { return }
    let pw: CGFloat = 780, ph = pw * 448 / 1120   // rendered by BarTap at 2x
    let slide = easeOut(prog(t, sVideo, sVideo + 0.35))
    let panel = NSRect(x: 180, y: 300 + 30 * CGFloat(1 - slide), width: pw, height: ph)
    let clip = NSBezierPath(roundedRect: panel, xRadius: 20, yRadius: 20)
    NSGraphicsContext.saveGraphicsState()
    softShadow(a * slide, blur: 40, dy: -14, strength: 0.16)
    NSColor.white.withAlphaComponent(CGFloat(a * slide)).setFill()
    clip.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    downloadPanel.draw(in: panel, from: .zero, operation: .sourceOver, fraction: CGFloat(a * slide), respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    // Download (bottom right of the render).
    let button = CGPoint(x: panel.minX + 0.934 * pw, y: panel.minY + 0.80 * ph)
    ripple(at: button, t: t, start: dlClick - 0.05)
    let arrive = ease(prog(t, dlClick - 0.6, dlClick - 0.1))
    cursor(at: CGPoint(x: lerp(1150, button.x + 4, arrive), y: lerp(760, button.y + 2, arrive)),
           alpha: a * window(t, dlClick - 0.6, dlClick + 0.6, 0.2), pressed: abs(t - dlClick) < 0.1)
    // The file fills in under the panel, then flies into the chat.
    let ai = NSRect(x: 1030, y: 300, width: 710, height: 340)
    let chatA = a * easeOut(prog(t, dlDone - 0.25, dlDone + 0.1))
    aiChat(ai, t: t, alpha: chatA, landed: t >= aiSend + 0.45)
    let fly = ease(prog(t, aiSend, aiSend + 0.45))
    let chipIn = easeOut(prog(t, dlClick + 0.05, dlClick + 0.3))
    if chipIn > 0.001, t < aiSend + 0.45 {
        let from = NSRect(x: panel.minX + 24, y: panel.maxY + 24, width: 460, height: 66)
        let to = NSRect(x: ai.maxX - 24 - 330, y: ai.minY + 84, width: 330, height: 54)
        let r = NSRect(x: lerp(from.minX, to.minX, fly), y: lerp(from.minY, to.minY, fly),
                       width: lerp(from.width, to.width, fly), height: lerp(from.height, to.height, fly))
        fileChip(r, progress: prog(t, dlClick + 0.15, dlDone), alpha: a * chipIn)
    }
}

// MARK: - Power scene

/// One flow of the Power details: its centre line (a cubic, as the app draws it) and its dots.
struct Flow {
    let p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint
    let color: NSColor, radius: CGFloat, speed: CGFloat, from: String, to: String
    /// Arc length at 64 even steps of the curve parameter, to move the dots at a steady speed
    /// (Core Animation's paced mode in the app).
    let lengths: [CGFloat]
    var length: CGFloat { lengths.last ?? 1 }

    init(_ d: [String: Any], offset: CGPoint) {
        func v(_ k: String) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? 0) }
        let x0 = v("x0") + offset.x, x1 = v("x1") + offset.x
        let m0 = (v("top0") + v("bottom0")) / 2 + offset.y, m1 = (v("top1") + v("bottom1")) / 2 + offset.y
        let xm = (x0 + x1) / 2
        let a = CGPoint(x: x0, y: m0), b = CGPoint(x: xm, y: m0), c = CGPoint(x: xm, y: m1), e = CGPoint(x: x1, y: m1)
        p0 = a; c1 = b; c2 = c; p3 = e
        let hex = (d["color"] as? String ?? "#808080").dropFirst()
        let n = UInt32(hex, radix: 16) ?? 0x808080
        color = NSColor(srgbRed: CGFloat((n >> 16) & 0xFF) / 255, green: CGFloat((n >> 8) & 0xFF) / 255, blue: CGFloat(n & 0xFF) / 255, alpha: 1)
        radius = v("radius"); speed = v("speed")
        from = d["from"] as? String ?? ""; to = d["to"] as? String ?? ""
        var acc: [CGFloat] = [0], last = a
        for i in 1...64 {
            let u = CGFloat(i) / 64, w = 1 - u
            let p = CGPoint(x: w * w * w * a.x + 3 * w * w * u * b.x + 3 * w * u * u * c.x + u * u * u * e.x,
                            y: w * w * w * a.y + 3 * w * w * u * b.y + 3 * w * u * u * c.y + u * u * u * e.y)
            acc.append(acc[acc.count - 1] + hypot(p.x - last.x, p.y - last.y))
            last = p
        }
        lengths = acc
    }

    func point(at u: CGFloat) -> CGPoint {
        let w = 1 - u
        return CGPoint(x: w * w * w * p0.x + 3 * w * w * u * c1.x + 3 * w * u * u * c2.x + u * u * u * p3.x,
                       y: w * w * w * p0.y + 3 * w * w * u * c1.y + 3 * w * u * u * c2.y + u * u * u * p3.y)
    }

    /// Where a dot is after travelling `fraction` of the way (by length).
    func point(alongLength fraction: CGFloat) -> CGPoint {
        let target = fraction * length
        var i = 1
        while i < lengths.count - 1 && lengths[i] < target { i += 1 }
        let a = lengths[i - 1], b = lengths[i]
        let u = (CGFloat(i - 1) + (b > a ? (target - a) / (b - a) : 0)) / 64
        return point(at: u)
    }
}

/// Panel points of the diagram's flows (the JSON's flows are in the diagram's own coordinates).
let powerFlows: [Flow] = {
    let dg = powerLayout["diagram"] as? [String: Any] ?? [:]
    let off = CGPoint(x: CGFloat((dg["x"] as? NSNumber)?.doubleValue ?? 0), y: CGFloat((dg["y"] as? NSNumber)?.doubleValue ?? 0))
    return (powerLayout["bands"] as? [[String: Any]] ?? []).map { Flow($0, offset: off) }
}()
let powerSize: CGSize = {
    let sz = powerLayout["size"] as? [String: Any] ?? [:]
    return CGSize(width: CGFloat((sz["w"] as? NSNumber)?.doubleValue ?? 392), height: CGFloat((sz["h"] as? NSNumber)?.doubleValue ?? 709))
}()
/// A section's vertical middle in panel points ("diagram", "history", "apps", or tile row 0…2).
func powerSection(_ key: String, row: Int = 0) -> CGFloat {
    let r: [String: Any]?
    if key == "tiles" { r = (powerLayout["tiles"] as? [[String: Any]]).flatMap { row < $0.count ? $0[row] : nil } } else { r = powerLayout[key] as? [String: Any] }
    let y = CGFloat((r?["y"] as? NSNumber)?.doubleValue ?? 0), h = CGFloat((r?["h"] as? NSNumber)?.doubleValue ?? 0)
    return y + h / 2
}

/// A panel image as a details window: a white card with a shadow, the top `crop` of the panel at
/// `scale`, its top-left corner at `origin`.
func panelCard(_ img: NSImage, origin: CGPoint, scale: CGFloat, crop: CGFloat, alpha: Double, radius: CGFloat = 14) {
    guard alpha > 0.001 else { return }
    let w = img.size.width * scale, h = img.size.height * scale * crop
    let r = NSRect(x: origin.x, y: origin.y, width: w, height: h)
    let gc = NSGraphicsContext.current!.cgContext
    gc.saveGState()
    gc.setAlpha(CGFloat(alpha))
    gc.beginTransparencyLayer(auxiliaryInfo: nil)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // The image's top `crop` (it is drawn flipped, top first).
    let src = NSRect(x: 0, y: img.size.height * (1 - crop), width: img.size.width, height: img.size.height * crop)
    img.draw(in: r, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    gc.endTransparencyLayer()
    gc.restoreGState()
}

/// The Power details' dots, moving as the app moves them: evenly spaced along each flow, at the
/// flow's speed, fading in and out at its ends. Flows other than `lit` (when given) dim.
func powerDots(t: Double, since start: Double, origin: CGPoint, scale: CGFloat, clipHeight: CGFloat, alpha: Double, lit: String? = nil, litAmount: Double = 0) {
    guard alpha > 0.001 else { return }
    NSGraphicsContext.saveGraphicsState()
    NSRect(x: origin.x, y: origin.y, width: powerSize.width * scale, height: clipHeight).clip()
    for f in powerFlows {
        let count = max(2, Int(f.length / 26))
        let duration = Double(f.length / max(f.speed, 1))
        let dim = lit.map { "\(f.from)>\(f.to)" == $0 ? 1 : 1 - 0.8 * litAmount } ?? 1
        for k in 0..<count {
            let phase = ((t - start) / duration + Double(k) / Double(count)).truncatingRemainder(dividingBy: 1)
            let u = phase < 0 ? phase + 1 : phase
            let fadeA = min(u / 0.14, 1, (1 - u) / 0.14)
            let p = f.point(alongLength: CGFloat(u))
            let c = CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
            let r = f.radius * scale
            f.color.withAlphaComponent(CGFloat(alpha * fadeA * dim)).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// A callout: a dot on the panel's edge, a hairline to the text, a title and a line under it.
func callout(_ title: String, _ sub: String, from p: CGPoint, textAt q: CGPoint, alpha: Double) {
    guard alpha > 0.001 else { return }
    let a = CGFloat(alpha)
    let line = NSBezierPath()
    line.move(to: p)
    line.line(to: NSPoint(x: q.x - 60, y: q.y))
    line.line(to: NSPoint(x: q.x - 18, y: q.y))
    line.lineWidth = 2
    ink.withAlphaComponent(0.28 * a).setStroke()
    line.stroke()
    blue.withAlphaComponent(a).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
    NSColor.white.withAlphaComponent(a).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
    let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: zh ? 34 : 36, weight: .semibold),
                                                           .foregroundColor: ink.withAlphaComponent(a), .kern: zh ? 0 : -0.4])
    t.draw(at: CGPoint(x: q.x, y: q.y - t.size().height + 4))
    let u = NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: gray.withAlphaComponent(a)])
    u.draw(at: CGPoint(x: q.x, y: q.y + 8))
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

// 120 BPM: every event sits on the grid (beat 0.5 s, eighth 0.25 s, sixteenth 0.125 s) so the music
// can hit it. Two short openers, then one idea every two bars (4 s).
let beat = 0.5
let s1 = 0.0, s2 = 2.5, s3 = 5.0, s4 = 8.0, s5 = 12.0, s6 = 16.0, sLid = 20.0, sVideo = 24.0, sPower = 28.0, sDeep = 36.0, s7 = 40.0, s8 = 44.0
let land = s4                          // the mark settles into the bar
let collapseAt = s4 + 0.75, tap1 = s4 + 2.0, tap2 = s4 + 3.0
/// The pointer reaches CPU, rests (a ring fills for the real 0.5 s), and its details open: no click.
let cpuArrive = s5 + 0.75, cpuRest = s5 + 1.25, cpuPeek = s5 + 1.75
let aiItemTime = s6 + 0.25, aiClick = s6 + 1.5
/// Lid scene: the agent prints, BarTap's switch shows, the lid shuts; the usage keeps climbing.
let termTimes = (0..<3).map { sLid + 0.25 + 0.25 * Double($0) }
let lidPill = sLid + 1.0, lidCloseAt = sLid + 1.5
/// Download scene: click Download, the file lands, goes to the AI, which answers.
let dlClick = sVideo + 0.75, dlDone = sVideo + 1.75, aiSend = sVideo + 2.0, aiReply = sVideo + 2.5
/// Power: the stats come back with Power beside the clock; the pointer rests on it and its details
/// drop, dots moving along the flows; it points at the CPU's flow; then the panel comes forward
/// whole and its parts are named, one per eighth.
let powerItems = (0..<4).map { sPower + 0.125 + 0.125 * Double($0) }
let pArrive = sPower + 0.75, pRest = sPower + 1.25, pOpen = sPower + 1.75
let pPoint = sPower + 2.5, pHover = sPower + 3.0, pUnhover = sPower + 3.75, pLift = sPower + 4.0
let calloutTimes = (0..<5).map { sPower + 4.75 + 0.25 * Double($0) }
/// Details montage: the Power panel takes its place among the others, which arrive in pairs.
let deepTimes = (0..<3).map { sDeep + 0.5 + 0.25 * Double($0) }
let endAt = s8 + 2.0
/// S1: when each third-party icon appears: accelerating, on a 16th-note grid.
let popTimes: [Double] = {
    var out: [Double] = []
    for i in 0..<thirdParty.count {
        let raw = ((0.4 + 1.75 * pow(Double(i) / Double(thirdParty.count), 0.77)) / 0.125).rounded() * 0.125
        out.append(max(raw, (out.last ?? 0) + 0.125))
    }
    return out
}()
let itemTimes = (0..<3).map { s5 + 0.125 + 0.125 * Double($0) }
let cardTimes = (0..<10).map { s7 + 0.25 + 0.125 * Double($0) }
let numberTimes = (0..<3).map { s8 + 0.25 * Double($0) }
let hopTimes = Array(stride(from: s2 + 0.25, to: s3, by: 0.25))   // S2's teleporting cursor

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
        let chaos = t >= s2 ? window(t, s2 + 0.1, s3 + 0.1, 0.25) : 0
        let shake = CGFloat(chaos * (sin(t * 37) * 3 + sin(t * 61) * 2))
        drawBar(alpha: barA, shake: shake)
        drawClock(alpha: barA, shake: shake)
        let sysLeft = drawIcons(systemIcons, right: clockLeft, alpha: barA, jitter: { _ in shake })
        // Apps keep adding icons: each new one appears beside the system icons and pushes the row
        // left, under the notch.
        let count = max(1, popTimes.filter { $0 <= t }.count)
        let enter = easeOut(prog(t, popTimes[count - 1], popTimes[count - 1] + 0.125))
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
            let hop = Int(t / 0.25)
            let px = 1000 + CGFloat((hop * 137) % 700)
            cursor(at: CGPoint(x: px, y: barRect.midY - 8 + CGFloat((hop * 53) % 40)), alpha: chaos)
        }
        caption("full", "full2", t: t, a: s1 + 0.4, b: s2)
        caption("fake", "fake2", t: t, a: s2 + 0.2, b: s3)
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
        let hideA = ease(prog(t, collapseAt, collapseAt + 0.5))
        let reveal = ease(prog(t, tap1, tap1 + 0.4)) * (1 - ease(prog(t, tap2, tap2 + 0.4)))
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
        let cA = window(t, tap1 - 0.75, tap2 + 0.6, 0.3)
        let arrive = ease(prog(t, tap1 - 0.75, tap1 - 0.15))
        ripple(at: s4ToggleCenter, t: t, start: tap1 - 0.05)
        ripple(at: s4ToggleCenter, t: t, start: tap2 - 0.05)
        cursor(at: CGPoint(x: lerp(1450, s4ToggleCenter.x + 4, arrive), y: lerp(520, s4ToggleCenter.y + 2, arrive)),
               alpha: cA, pressed: abs(t - tap1) < 0.12 || abs(t - tap2) < 0.12)
        caption("tuck", "tuck2", t: t, a: collapseAt - 0.25, b: tap1 - 0.1)
        caption("tap", "tap2", t: t, a: tap1, b: s5)
    }

    // ---- S3: the mark draws itself, then flies into the toggle's slot (on top of S4's bar). ------
    if t >= s3, t < land + 0.1 {
        let draw = ease(prog(t, s3 + 0.25, s3 + 1.25))
        let fly = ease(prog(t, s4 - 0.5, land))
        let c = CGPoint(x: lerp(W / 2, s4ToggleCenter.x, fly), y: lerp(470, s4ToggleCenter.y, fly))
        drawMark(center: c, width: lerp(470, toggleMarkWidth, fly), progress: draw, alpha: 1 - prog(t, land, land + 0.1),
                 weight: lerp(48, 58, fly))
        caption("never", "never2", t: t, a: s3 + 0.5, b: s4 - 0.2)
    }

    // ---- S5 + S6 (+ the lid scene): live stats + details, then AI usage, which keeps climbing. --
    if t >= s5, t < sVideo + 0.4 {
        let barA = 1 - prog(t, sVideo, sVideo + 0.4)
        drawBar(alpha: barA)
        drawClock(alpha: barA)
        let step = Int((t - s5) * 2)   // values change twice a second
        // Later the AI usage item cross-fades into Control Center's slot (it leaves to make room,
        // like Wi-Fi did), so the toggle stays clear of the notch. Its value matches the dropdown.
        let aiIn = easeOut(prog(t, aiItemTime, aiItemTime + 0.35))
        // While the lid is shut the agent keeps working: the usage steps up (the sample data rises with the step).
        let aiStep = t < sLid ? 3 : min(11, 3 + Int((t - sLid) / 0.375))
        drawIcons(Array(systemIcons.prefix(1)), right: clockLeft, alpha: barA * (1 - aiIn))
        let gap = 7 * k
        var aiRect = NSRect.zero
        if aiIn > 0.001 {
            let r = clockLeft - 12
            let left = drawItem(item("ai", aiStep), right: r, alpha: barA * aiIn)
            aiRect = NSRect(x: left, y: barRect.minY, width: r - left, height: barRect.height)
            // Lid shut: a soft pulse around the number that keeps going up.
            let glow = window(t, lidCloseAt + 0.5, sVideo - 0.1, 0.25)
            if glow > 0.001 {
                let pulse = 0.55 + 0.45 * sin((t - lidCloseAt) * .pi * 2 / beat)
                let ring = NSBezierPath(roundedRect: aiRect.insetBy(dx: -10, dy: 6), xRadius: 18, yRadius: 18)
                ring.lineWidth = 4
                NSColor(srgbRed: 0.20, green: 0.70, blue: 0.33, alpha: CGFloat(glow * pulse)).setStroke()
                ring.stroke()
            }
        }
        // Stats appear right of the toggle, which slides left to make room (as in the real bar).
        var right = clockLeft - lerp(systemIcons[0].width * k + 4, 12 + item("ai", 3).size.width * k + gap, aiIn)
        var cpuRect = NSRect.zero
        for (i, n) in ["network", "memory", "cpu"].enumerated() {
            let a = barA * easeOut(prog(t, itemTimes[i], itemTimes[i] + 0.35))
            let left = drawItem(item(n, step + i), right: right, alpha: a, dy: CGFloat(14 * (1 - a)))
            if n == "cpu" { cpuRect = NSRect(x: left, y: barRect.minY, width: right - left, height: barRect.height) }
            right = left - gap
        }
        drawItem(toggleCollapsed, right: lerp(s4ToggleRight, right, ease(prog(t, s5, s5 + 0.5))), alpha: barA)
        // Rest the pointer on CPU → its details open (its top half, large enough to read).
        let open = ease(prog(t, cpuPeek, cpuPeek + 0.35)) * (1 - ease(prog(t, s6 - 0.4, s6 - 0.1)))
        if open > 0.001 { dropdown(cpuPanel, under: cpuRect, crop: 0.5, scale: 1.6, reveal: CGFloat(open)) }
        let cA = window(t, cpuArrive, cpuPeek + 0.9, 0.25)
        let arrive = ease(prog(t, cpuArrive, cpuRest))
        let cpuPointer = CGPoint(x: lerp(1500, cpuRect.midX + 4, arrive), y: lerp(560, cpuRect.midY + 2, arrive))
        dwell(at: cpuPointer, progress: prog(t, cpuRest, cpuPeek), alpha: cA * (1 - prog(t, cpuPeek, cpuPeek + 0.25)))
        cursor(at: cpuPointer, alpha: cA)
        caption("stats", "stats2", t: t, a: s5 + 0.3, b: s6)
        // Click AI usage → its dropdown (totals by range and by agent).
        let aiOpen = ease(prog(t, aiClick, aiClick + 0.35)) * (1 - ease(prog(t, sLid - 0.4, sLid - 0.1)))
        if aiOpen > 0.001 { dropdown(aiPanel, under: aiRect, crop: 0.47, scale: 1.45, reveal: CGFloat(aiOpen)) }
        ripple(at: CGPoint(x: aiRect.midX, y: aiRect.midY), t: t, start: aiClick - 0.05)
        let aA = window(t, aiClick - 0.75, aiClick + 0.9, 0.25)
        let aArrive = ease(prog(t, aiClick - 0.75, aiClick - 0.15))
        cursor(at: CGPoint(x: lerp(1500, aiRect.midX + 4, aArrive), y: lerp(560, aiRect.midY + 2, aArrive)),
               alpha: aA, pressed: abs(t - aiClick) < 0.12)
        caption("ai", "ai2", t: t, a: s6 + 0.3, b: sLid)
    }

    // ---- Lid scene: close the lid, the AI keeps going. ------------------------------------------
    if t >= sLid - 0.1, t < sVideo + 0.1 {
        let a = window(t, sLid, sVideo, 0.3)
        drawLaptop(open: 1 - ease(prog(t, lidCloseAt, lidCloseAt + 0.6)), t: t, alpha: a)
        pill(S["lidOn"] ?? "", center: CGPoint(x: W / 2, y: 748), alpha: a * easeOut(prog(t, lidPill, lidPill + 0.3)))
        caption("lidT", "lidT2", t: t, a: sLid + 0.3, b: sVideo)
    }

    // ---- Download scene: save a video, hand it to your AI. ---------------------------------------
    if t >= sVideo - 0.1, t < sPower + 0.3 {
        let a = window(t, sVideo, sPower, 0.3)
        drawDownloadScene(t: t, alpha: a)
        caption("dl", "dl2", t: t, a: sVideo + 0.3, b: sPower)
    }

    // ---- Power: where every watt goes, then the whole panel, named part by part. ---------------
    if t >= sPower - 0.1, t < s7 + 0.1 {
        drawPowerScene(t)
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
            let p = back(prog(t, a0, a0 + 0.4))
            let a = prog(t, a0, a0 + 0.25) * (1 - prog(t, s8, s8 + 0.4))
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
        caption("all", "all2", t: t, a: s7 + 0.4, b: s8)
    }

    // ---- S8: numbers, then the end card. -------------------------------------------------------
    if t >= s8 {
        let nums: [(String, String)] = [("0.02%", "idle"), ("~50 MB", "mem"), ("0", "fakes")]
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

/// The Power scene and the details montage after it (see the timeline).
func drawPowerScene(_ t: Double) {
    let gap = 7 * k
    // The bar: stats as before, Power beside the clock.
    let barA = easeOut(prog(t, sPower, sPower + 0.4)) * (1 - prog(t, pLift, pLift + 0.4))
    var right = clockLeft - 12
    var powerRect = NSRect.zero
    let step = Int((t - sPower) * 2)
    if barA > 0.001 { drawBar(alpha: barA); drawClock(alpha: barA) }
    for (i, n) in ["power", "network", "cpu"].enumerated() {
        let appear = i == 0 ? powerItems[3] : powerItems[i]
        let a = barA * easeOut(prog(t, appear, appear + 0.35))
        let img = item(n == "power" && zh ? "power_zh" : n, step + i)
        let left = right - img.size.width * k
        if n == "power" { powerRect = NSRect(x: left, y: barRect.minY, width: right - left, height: barRect.height) }
        if a > 0.001 { drawItem(img, right: right, alpha: a, dy: CGFloat(14 * (1 - a))) }
        right = left - gap
    }
    if barA > 0.001 { drawItem(toggleCollapsed, right: right, alpha: barA) }

    // The details: dropped under the item (header and diagram, large), then forward and whole.
    let cropA = (powerSection("diagram") + 92 + 8) / powerSize.height   // header + diagram + its caption
    let scaleA: CGFloat = 1.6
    let wA = powerSize.width * scaleA
    let originA = CGPoint(x: min(powerRect.midX - wA / 2, W - wA - 40), y: barRect.maxY + 10)
    let originB = CGPoint(x: 190, y: 80), scaleB: CGFloat = 1.3
    // The montage row: seven panels, Power in the middle.
    let m: CGFloat = 0.72, rowGap: CGFloat = 22, rowTop: CGFloat = 128
    let widths = montagePanels.map { $0.size.width * m }
    let rowLeft = (W - widths.reduce(0, +) - rowGap * CGFloat(widths.count - 1)) / 2
    let slotX = (0..<widths.count).map { i in rowLeft + widths[..<i].reduce(0, +) + rowGap * CGFloat(i) }

    let unroll = ease(prog(t, pOpen, pOpen + 0.35))
    let lift = ease(prog(t, pLift, pLift + 0.6))
    let settle = ease(prog(t, sDeep, sDeep + 0.6))
    let out = 1 - prog(t, s7 - 0.4, s7)
    var origin = CGPoint(x: lerp(originA.x, originB.x, lift), y: lerp(originA.y, originB.y, lift))
    var scale = lerp(scaleA, scaleB, lift)
    let crop = lift > 0 ? lerp(cropA, 1, lift) : cropA * max(unroll, 0.02)
    if settle > 0 {
        origin = CGPoint(x: lerp(origin.x, slotX[3], settle), y: lerp(origin.y, rowTop, settle))
        scale = lerp(scale, m, settle)
    }
    let cardA = (t < pLift ? min(1, unroll * 1.4) : 1) * out
    if t >= pOpen {
        let hover = ease(prog(t, pHover, pHover + 0.2)) * (1 - ease(prog(t, pUnhover, pUnhover + 0.2)))
        panelCard(powerPanel, origin: origin, scale: scale, crop: crop, alpha: cardA)
        if hover > 0.001 { panelCard(powerHover, origin: origin, scale: scale, crop: crop, alpha: cardA * hover) }
        powerDots(t: t, since: pOpen, origin: origin, scale: scale, clipHeight: powerSize.height * scale * crop, alpha: cardA,
                  lit: "mac>cpu", litAmount: hover)
    }

    // The pointer: rests on Power (the ring fills), then points at the CPU's flow.
    let cpuFlow = powerFlows.first { $0.from == "mac" && $0.to == "cpu" }
    let flowPoint = cpuFlow.map { f -> CGPoint in let p = f.point(at: 0.55); return CGPoint(x: originA.x + p.x * scaleA, y: originA.y + p.y * scaleA) }
        ?? CGPoint(x: originA.x + 200, y: originA.y + 200)
    let cA = window(t, pArrive, pUnhover + 0.2, 0.25)
    let arrive = ease(prog(t, pArrive, pRest))
    var pointer = CGPoint(x: lerp(1500, powerRect.midX + 4, arrive), y: lerp(560, powerRect.midY + 2, arrive))
    let toFlow = ease(prog(t, pPoint, pHover - 0.05))
    pointer = CGPoint(x: lerp(pointer.x, flowPoint.x, toFlow), y: lerp(pointer.y, flowPoint.y, toFlow))
    dwell(at: pointer, progress: prog(t, pRest, pOpen), alpha: cA * (1 - prog(t, pOpen, pOpen + 0.25)))
    cursor(at: pointer, alpha: cA)
    caption("watt", "watt2", t: t, a: sPower + 0.3, b: pLift + 0.2)

    // The whole panel, its parts named on the right.
    if t >= pLift {
        let names: [(String, String, CGFloat, CGFloat)] = [
            ("c1", "c1s", powerSection("diagram"), 278), ("c2", "c2s", powerSection("history"), 467),
            ("c3", "c3s", (powerSection("tiles", row: 0) + powerSection("tiles", row: 1)) / 2, 600),
            ("c4", "c4s", powerSection("tiles", row: 2), 712), ("c5", "c5s", powerSection("apps"), 874),
        ]
        let edge = originB.x + powerSize.width * scaleB + 10
        let gone = 1 - prog(t, sDeep - 0.25, sDeep + 0.1)
        for (i, (title, sub, y, textY)) in names.enumerated() {
            let a = easeOut(prog(t, calloutTimes[i], calloutTimes[i] + 0.3)) * gone
            let slide = CGFloat(24 * (1 - a))
            callout(S[title] ?? "", S[sub] ?? "", from: CGPoint(x: edge, y: originB.y + y * scaleB), textAt: CGPoint(x: 820 + slide, y: textY), alpha: a)
        }
    }

    // The montage: every item has details like these.
    if t >= sDeep - 0.1 {
        let pairs = [[2, 4], [1, 5], [0, 6]]
        for (j, pair) in pairs.enumerated() {
            for i in pair {
                let a = easeOut(prog(t, deepTimes[j], deepTimes[j] + 0.35)) * out
                guard a > 0.001 else { continue }
                let from: CGFloat = i < 3 ? -70 : 70
                panelCard(montagePanels[i], origin: CGPoint(x: slotX[i] + from * CGFloat(1 - a), y: rowTop + CGFloat(18 * (1 - a))),
                          scale: m, crop: 1, alpha: a, radius: 12)
            }
        }
        caption("deep", "deep2", t: t, a: sDeep + 0.5, b: s7)
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
    cue(s3 + 0.25, "draw"); cue(s3 + 1.25, "drawn"); cue(s4 - 0.5, "fly"); cue(land, "land")
    cue(collapseAt, "hide"); cue(tap1, "tap", 0); cue(tap2, "tap", 1)
    for (i, p) in itemTimes.enumerated() { cue(p, "item", i) }
    cue(cpuPeek, "click")
    cue(aiItemTime, "item", 3); cue(aiClick, "click")
    for (i, p) in termTimes.enumerated() { cue(p, "item", i) }
    cue(lidPill, "tap", 0); cue(lidCloseAt, "hide")
    cue(dlClick, "click"); cue(dlDone, "item", 4); cue(aiSend, "fly"); cue(aiReply, "tap", 1)
    for (i, p) in powerItems.enumerated() { cue(p, "item", i) }
    cue(pOpen, "click"); cue(pHover, "tap", 0); cue(pLift, "fly")
    for (i, p) in calloutTimes.enumerated() { cue(p, "card", i) }
    cue(sDeep, "land")
    for (i, p) in deepTimes.enumerated() { cue(p, "pop", 10 + i) }
    for (i, p) in cardTimes.enumerated() { cue(p, "card", i) }
    for (i, p) in numberTimes.enumerated() { cue(p, "number", i) }
    cue(endAt, "end")
    let json: [String: Any] = ["duration": duration, "beat": beat, "scenes": [s1, s2, s3, s4, s5, s6, sLid, sVideo, sPower, sDeep, s7, s8], "cues": cues]
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
