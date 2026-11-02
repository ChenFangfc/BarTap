import Foundation
import CoreGraphics
import BarTapCore

// Minimal test harness (CommandLineTools ship without XCTest).
var failures = 0
var checks = 0
var currentTest = ""

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✗ [\(currentTest)] line \(line): \(message())")
    }
}

func test(_ name: String, _ body: () -> Void) {
    currentTest = name
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

/// Throwaway defaults backed by a file in the temporary folder. A named suite would leave an
/// empty plist in ~/Library/Preferences after every run, even after removePersistentDomain.
func scratchDefaults() -> (defaults: UserDefaults, discard: () -> Void) {
    let path = NSTemporaryDirectory() + "bartap-tests-\(UUID().uuidString).plist"
    let d = UserDefaults(suiteName: path)!
    return (d, {
        CFPreferencesAppSynchronize(path as CFString)
        try? FileManager.default.removeItem(atPath: path)
    })
}

// MARK: Fixtures — real measurements from a MacBook Pro (notch) + 2 external displays, macOS 26.6

let builtIn = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 33, notch: 771...956)
let external = ScreenInfo(id: 2, frame: CGRect(x: 0, y: -1692, width: 3008, height: 1692), menuBarHeight: 30)
let portrait = ScreenInfo(id: 3, frame: CGRect(x: -1440, y: -1443, width: 1440, height: 2560), menuBarHeight: 30)

var nextID: UInt32 = 100
func statusWindow(_ x: CGFloat, _ w: CGFloat, on s: ScreenInfo, drawn: Bool = true) -> WindowInfo {
    nextID += 1
    return WindowInfo(id: nextID, pid: 6932, ownerName: "Control Center", layer: 25,
                      bounds: CGRect(x: x, y: s.frame.minY, width: w, height: s.menuBarHeight), isOnScreen: drawn)
}

/// Widths of the 17 icons, left to right (same on every display).
let widths: [CGFloat] = [32, 38, 40, 45, 60, 34, 34, 38, 53, 75, 87, 77, 44, 38, 76, 42, 135]

func row(on s: ScreenInfo, rightEdge: CGFloat, drawnFrom firstDrawnIndex: Int = 0) -> [WindowInfo] {
    var x = rightEdge - widths.reduce(0, +)
    var out: [WindowInfo] = []
    for (i, w) in widths.enumerated() {
        out.append(statusWindow(x, w, on: s, drawn: i >= firstDrawnIndex))
        x += w
    }
    return out
}

let builtInRow = row(on: builtIn, rightEdge: 1730, drawnFrom: 6)   // 6 icons behind the notch
let externalRow = row(on: external, rightEdge: 3008)
let portraitRow = row(on: portrait, rightEdge: 0)

// MARK: Tests

test("row: notch-hidden icons belong to the row") {
    let r = MenuBarGeometry.row(on: builtIn, windows: builtInRow + externalRow + portraitRow)
    expect(r.count == 17, "count \(r.count)")
    expect(r.filter { !$0.isOnScreen }.count == 6)
    expect(r.first?.bounds.minX == 782, "first x \(String(describing: r.first?.bounds.minX))")
}

test("row: icons pushed off by a collapsed separator are excluded") {
    // Separator 5016 wide right of 2 pushed icons, as measured on macOS 26.
    let sep = WindowInfo(id: 1, pid: 6932, ownerName: "Control Center", layer: 25,
                         bounds: CGRect(x: -2956, y: -1692, width: 5016, height: 30), isOnScreen: false)
    let pushed = WindowInfo(id: 2, pid: 6932, ownerName: "Control Center", layer: 25,
                            bounds: CGRect(x: -2998, y: -1692, width: 42, height: 30), isOnScreen: false)
    let r = MenuBarGeometry.row(on: external, windows: externalRow + [sep, pushed])
    expect(r.count == 17, "count \(r.count)")
    expect(!r.contains { $0.id == 1 || $0.id == 2 })
}

test("row: other displays' windows and non-status layers are ignored") {
    let menu = WindowInfo(id: 9, pid: 1, ownerName: "iStat Menus Status", layer: 24,
                          bounds: CGRect(x: 2073, y: -1660, width: 280, height: 595), isOnScreen: true)
    let r = MenuBarGeometry.row(on: external, windows: externalRow + builtInRow + [menu])
    expect(r.count == 17)
    expect(MenuBarGeometry.row(on: portrait, windows: portraitRow).count == 17)
}

test("overflow count: icons laid out but not drawn") {
    let r = MenuBarGeometry.row(on: builtIn, windows: builtInRow)
    expect(MenuBarGeometry.overflowCount(on: builtIn, row: r, leftOf: 1730) == 6)
    expect(MenuBarGeometry.overflowCount(on: builtIn, row: r, leftOf: 900) == 3)
}

test("placement: keeps every currently drawn icon visible, makes room for the toggle") {
    let all = builtInRow + externalRow + portraitRow
    guard let seeds = Placement.initialSeeds(screens: [builtIn, external, portrait], windows: all, toggleWidth: 32) else {
        expect(false, "expected seeds"); return
    }
    // Boundary = notch edge + margin = 972; the 60 pt icon at x=1005 leaves only 33 pt, so it moves
    // to Hidden and the toggle lands left of the 38 pt icon at x=1065 (right distance 625…663).
    expect(seeds.toggle > 625 && seeds.toggle < 663, "toggle \(seeds.toggle)")
    expect(seeds.hidden > seeds.toggle && seeds.hidden < 663, "hidden \(seeds.hidden)")
}

test("placement: nothing overflowing → no seeds (do no harm)") {
    let all = externalRow + portraitRow
    expect(Placement.initialSeeds(screens: [external, portrait], windows: all, toggleWidth: 32) == nil)
}

test("placement: extraDrop moves one more icon into Hidden") {
    let all = builtInRow + externalRow
    let a = Placement.initialSeeds(screens: [builtIn, external], windows: all, toggleWidth: 32)!
    let b = Placement.initialSeeds(screens: [builtIn, external], windows: all, toggleWidth: 32, extraDrop: 1)!
    expect(b.toggle < a.toggle, "\(b.toggle) !< \(a.toggle)")
}

test("placement: a bar that draws nothing (asleep / full screen) is ignored") {
    // Built-in display asleep while two externals draw everything: no overflow is known.
    let asleep = row(on: builtIn, rightEdge: 1730, drawnFrom: 17)
    expect(Placement.initialSeeds(screens: [builtIn, external, portrait], windows: asleep + externalRow + portraitRow, toggleWidth: 32) == nil)
    expect(Placement.initialSeeds(screens: [builtIn], windows: asleep, toggleWidth: 32) == nil)
}

test("layout validator") {
    let ok = OwnItemFrames(toggle: CGRect(x: 140, y: 0, width: 32, height: 33),
                           hidden: CGRect(x: 116, y: 0, width: 24, height: 33),
                           alwaysHidden: CGRect(x: 92, y: 0, width: 24, height: 33))
    expect(LayoutValidator.check(ok) == nil)
    var collapsed = ok
    collapsed.hidden = CGRect(x: 140 - 5016, y: 0, width: 5016, height: 33)
    collapsed.alwaysHidden = CGRect(x: 140 - 5016 - 5016, y: 0, width: 5016, height: 33)
    expect(LayoutValidator.check(collapsed) == nil, "collapsed order must validate")
    var bad = ok
    bad.hidden = CGRect(x: 200, y: 0, width: 24, height: 33)
    expect(LayoutValidator.check(bad) == .hiddenRightOfToggle)
    var bad2 = ok
    bad2.alwaysHidden = CGRect(x: 120, y: 0, width: 24, height: 33)
    expect(LayoutValidator.check(bad2) == .alwaysRightOfHidden)
    expect(LayoutValidator.check(OwnItemFrames(toggle: .zero, hidden: .zero, alwaysHidden: nil)) == .notReady)
    var noAlways = ok
    noAlways.alwaysHidden = nil
    expect(LayoutValidator.check(noAlways) == nil)
}

test("layout validator: stored keys decide the order, frames only readiness") {
    let frames = OwnItemFrames(toggle: CGRect(x: -772, y: 0, width: 42, height: 33),
                               hidden: CGRect(x: -730, y: 0, width: 24, height: 33), alwaysHidden: nil)
    // Proxies swapped (seen on macOS 26) while the keys, and the real bar, are in order.
    expect(LayoutValidator.check(frames) == .hiddenRightOfToggle, "proxies alone report the swap")
    expect(LayoutValidator.check(frames, keys: OwnItemKeys(toggle: 368.5, hidden: 368.75, alwaysHidden: nil)) == nil)
    expect(LayoutValidator.check(frames, keys: OwnItemKeys(toggle: 368.5, hidden: 368.25, alwaysHidden: nil)) == .hiddenRightOfToggle)
    expect(LayoutValidator.check(frames, keys: OwnItemKeys(toggle: 368.5, hidden: 368.5, alwaysHidden: nil)) == .hiddenRightOfToggle, "a tie is not an order")
    expect(LayoutValidator.check(frames, keys: OwnItemKeys(toggle: 368.5, hidden: 368.75, alwaysHidden: 368.6)) == .alwaysRightOfHidden)
    expect(LayoutValidator.check(frames, keys: OwnItemKeys(toggle: 368.5, hidden: 368.75, alwaysHidden: 369)) == nil)
    expect(LayoutValidator.check(OwnItemFrames(toggle: .zero, hidden: .zero, alwaysHidden: nil),
                                 keys: OwnItemKeys(toggle: 1, hidden: 2, alwaysHidden: nil)) == .notReady, "no frames yet: not ready")
    expect(LayoutValidator.check(frames, keys: nil) == .hiddenRightOfToggle, "no keys: fall back to the frames")
}

test("menu bar sections from Accessibility frames (macOS 26, three displays, notch)") {
    // Frames as reported on a MacBook with two external displays (collapsed).
    let screens = [ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 33, notch: 771...956),
                   ScreenInfo(id: 2, frame: CGRect(x: 0, y: -1692, width: 3008, height: 1692), menuBarHeight: 30),
                   ScreenInfo(id: 3, frame: CGRect(x: -1440, y: -1443, width: 1440, height: 2560), menuBarHeight: 30)]
    let toggle = CGRect(x: 984, y: 4.5, width: 39, height: 24)
    let hidden = CGRect(x: -4024, y: 4.5, width: 5002, height: 24)
    let frames = [CGRect(x: -4430, y: 3.5, width: 42, height: 26),     // hidden, far off the left edge
                  CGRect(x: -4111, y: 4.5, width: 73, height: 24),     // hidden, just left of the divider
                  CGRect(x: 1029, y: 4.5, width: 72, height: 24),      // shown, right of the toggle
                  CGRect(x: 1450, y: 5.5, width: 22, height: 22),      // shown (Wi-Fi)
                  CGRect(x: -1, y: 1116, width: 36, height: 24),       // not in any menu bar
                  CGRect(x: 8, y: 1117, width: 0, height: 0)]          // zero width
    let r = MenuBarSections.classify(frames, toggle: toggle, hidden: hidden, always: nil, screens: screens)
    expect(r[0]?.section == .hidden && r[1]?.section == .hidden, "\(r)")
    expect(r[2]?.section == .shown && r[3]?.section == .shown)
    expect(r[4] == nil && r[5] == nil, "icons outside every menu bar are dropped")
    expect(r[2]!.rd == 1728 - 1101 && r[0]!.rd > r[1]!.rd, "distances from the toggle's bar, larger = further left")
    // An always-hidden divider further left splits the hidden icons.
    let always = CGRect(x: -9200, y: 4.5, width: 5002, height: 24)
    let r2 = MenuBarSections.classify([CGRect(x: -9300, y: 4.5, width: 30, height: 24), frames[1]], toggle: toggle, hidden: hidden,
                                      always: always, screens: screens)
    expect(r2[0]?.section == .alwaysHidden && r2[1]?.section == .hidden)
    // Top-edge matching was the old bug: y = 4.5 is still in a 33 pt bar.
    expect(MenuBarSections.inMenuBar(CGRect(x: 0, y: 4.5, width: 24, height: 24), of: screens[0]))
    expect(!MenuBarSections.inMenuBar(CGRect(x: 0, y: 1116, width: 24, height: 24), of: screens[0]))
}

test("reveal model: toggle and toggleAll") {
    var m = RevealModel()
    expect(m.effectiveLevel == .collapsed)
    m.toggle(source: .click)
    expect(m.effectiveLevel == .revealed && m.userSource == .click)
    m.toggle(source: .click)
    expect(m.effectiveLevel == .collapsed && m.userSource == nil)
    m.toggleAll(source: .hotkey)
    expect(m.effectiveLevel == .revealedAll)
    m.toggle(source: .click)
    expect(m.effectiveLevel == .collapsed, "toggle from revealedAll collapses")
    m.reveal(.revealedAll, source: .command)
    m.reveal(.revealed, source: .hover)
    expect(m.effectiveLevel == .revealedAll && m.userSource == .command, "reveal never lowers")
}

test("reveal model: a hover does not take over a click reveal") {
    var m = RevealModel()
    m.toggle(source: .click)
    m.reveal(.revealed, source: .hover)
    expect(m.userSource == .click, "source \(String(describing: m.userSource))")
    m.reveal(.revealedAll, source: .hover)
    expect(m.userSource == .hover && m.effectiveLevel == .revealedAll, "a higher level does take over")
}

test("reveal model: rules, overrides and auto re-hide") {
    var m = RevealModel()
    m.setRuleLevel(.revealed)
    expect(m.effectiveLevel == .revealed)
    m.toggle(source: .click)                 // user hides → overrides rule
    expect(m.effectiveLevel == .collapsed)
    m.setRuleLevel(.revealed)                // same level: still overridden
    expect(m.effectiveLevel == .collapsed)
    m.setRuleLevel(.collapsed)
    m.setRuleLevel(.revealed)                // rule edge clears the override
    expect(m.effectiveLevel == .revealed)
    m.reveal(.revealedAll, source: .click)
    m.autoRehide()                           // timer: back to rule level, not below
    expect(m.effectiveLevel == .revealed)
}

test("reveal model: fail-open states") {
    var m = RevealModel()
    m.layoutBlocked = true
    expect(m.effectiveLevel == .revealedAll)
    m.layoutBlocked = false
    m.setArranging(true)
    expect(m.effectiveLevel == .revealedAll)
    m.setArranging(false)
    expect(m.effectiveLevel == .collapsed)
}

test("rehide policy") {
    expect(RehidePolicy.delay(for: .click, autoRehide: true, delay: 8) == 8)
    expect(RehidePolicy.delay(for: .click, autoRehide: false, delay: 8) == nil)
    expect(RehidePolicy.delay(for: nil, autoRehide: true, delay: 8) == nil)
    expect(RehidePolicy.delay(for: .search, autoRehide: true, delay: 30) == 5)
    expect(RehidePolicy.delay(for: .hover, autoRehide: true, delay: 0.5) == 2)
}

test("interaction detector") {
    let base = InteractionDetector.Context(windows: [], screens: [builtIn, external], pointer: CGPoint(x: 500, y: 500), ownPID: 42, ownPanelVisible: false)
    expect(InteractionDetector.busyReason(base) == nil)
    var c = base
    c.pointer = CGPoint(x: 1200, y: 10)
    expect(InteractionDetector.busyReason(c) == .pointerInMenuBar)
    c.pointer = CGPoint(x: 2000, y: -1690)
    expect(InteractionDetector.busyReason(c) == .pointerInMenuBar, "external bar")
    c = base
    c.windows = [WindowInfo(id: 1, pid: 7, ownerName: "Outlook", layer: 101, bounds: CGRect(x: 900, y: 33, width: 220, height: 300), isOnScreen: true)]
    expect(InteractionDetector.busyReason(c) == .menuOpen)
    c.windows = [WindowInfo(id: 1, pid: 7, ownerName: "iStat Menus Status", layer: 24, bounds: CGRect(x: 1150, y: 35, width: 275, height: 499), isOnScreen: true)]
    expect(InteractionDetector.busyReason(c) == .popoverOpen)
    // Maximised app window right under the bar, and a Chinese IME candidate window: not busy.
    c.windows = [WindowInfo(id: 1, pid: 7, ownerName: "Safari", layer: 0, bounds: CGRect(x: 0, y: 33, width: 1728, height: 1000), isOnScreen: true),
                 WindowInfo(id: 2, pid: 8, ownerName: "Simplified Chinese Input Method", layer: 24, bounds: CGRect(x: 477, y: 283, width: 397, height: 28), isOnScreen: true)]
    expect(InteractionDetector.busyReason(c) == nil)
    // Notification Center's permanent full-screen overlay (layer 21) and the Dock's: not busy.
    c.windows = [WindowInfo(id: 1, pid: 1159, ownerName: "Notification Center", layer: 21, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), isOnScreen: true),
                 WindowInfo(id: 2, pid: 63582, ownerName: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), isOnScreen: true)]
    expect(InteractionDetector.busyReason(c) == nil, "full-screen overlays must not block re-hiding")
    // Our own windows never count; off-screen menus never count.
    c.windows = [WindowInfo(id: 1, pid: 42, ownerName: "BarTap", layer: 101, bounds: CGRect(x: 900, y: 33, width: 220, height: 300), isOnScreen: true),
                 WindowInfo(id: 2, pid: 9, ownerName: "X", layer: 101, bounds: CGRect(x: 900, y: 33, width: 220, height: 300), isOnScreen: false)]
    expect(InteractionDetector.busyReason(c) == nil)
    c.ownPanelVisible = true
    expect(InteractionDetector.busyReason(c) == .ownPanel)
}

test("key combos") {
    let c = KeyCombo(keyCode: 11, modifiers: KeyCombo.control | KeyCombo.option | KeyCombo.cmd)
    expect(c.isValid)
    expect(KeyCombo(storage: c.storage) == c)
    expect(c.display() == "⌃⌥⌘B", c.display())
    expect(!KeyCombo(keyCode: 11, modifiers: 0).isValid, "bare letter must be rejected")
    expect(!KeyCombo(keyCode: 11, modifiers: KeyCombo.shift).isValid, "shift-only must be rejected")
    expect(KeyCombo(keyCode: 0x7A, modifiers: 0).isValid, "bare F1 is fine")
    expect(KeyCombo(storage: "") == nil && KeyCombo(storage: "x:y") == nil && KeyCombo(storage: "11:0") == nil)
}

test("url commands") {
    func p(_ s: String) -> URLCommand? { URLCommand(url: URL(string: s)!) }
    expect(p("bartap://toggle") == .toggle)
    expect(p("bartap://show") == .show)
    expect(p("bartap://show/all") == .showAll)
    expect(p("bartap://hide") == .hide)
    expect(p("bartap://clean/on") == .clean(true))
    expect(p("bartap://clean") == .clean(nil))
    expect(p("bartap://keep-awake?minutes=30") == .keepAwake(minutes: 30))
    expect(p("bartap://keep-awake?minutes=99999") == .keepAwake(minutes: nil))
    expect(p("bartap://keep-awake/off") == .keepAwakeOff)
    expect(p("bartap://debug/dump") == .debug("dump"))
    expect(p("bartap://debug") == nil)
    expect(p("bartap://nonsense") == nil)
    expect(p("https://toggle") == nil)
}

test("rule engine") {
    var s = RuleSettings()
    var f = RuleFacts(activeScreenWidth: 3008, frontmostBundleID: "us.zoom.xos", batteryPercent: 15, onBatteryPower: true, networkOnline: false)
    expect(RuleEngine.evaluate(f, s).level == .collapsed, "all rules off")
    s.largeScreen = true
    expect(RuleEngine.evaluate(f, s).reasons == [.largeScreen])
    f.activeScreenWidth = 1728
    expect(RuleEngine.evaluate(f, s).level == .collapsed)
    s.apps = true
    s.bundleIDs = ["us.zoom.xos"]
    expect(RuleEngine.evaluate(f, s).reasons == [.app])
    s.lowBattery = true
    expect(RuleEngine.evaluate(f, s).reasons == [.app, .lowBattery])
    f.onBatteryPower = false
    expect(RuleEngine.evaluate(f, s).reasons == [.app], "charging: no low-battery reveal")
    s.offline = true
    expect(RuleEngine.evaluate(f, s).reasons == [.app, .offline])
}

test("settings: defaults, clamping, cleared hotkeys stay cleared") {
    let (d, discard) = scratchDefaults()
    defer { discard() }
    let s = Settings(defaults: d)
    expect(s.autoRehide && s.rehideDelay == 8 && !s.alwaysHiddenEnabled && s.startCollapsed)
    expect(s.hotkey(.toggle)?.display() == "⌃⌥⌘B")
    s.rehideDelay = 0
    expect(s.rehideDelay == 1)
    expect(s.hoverDelay == 0.5 && s.toggleHoverOpen, "one hover delay, 0.5 s; the button opens on hover")
    s.hoverDelay = 99
    expect(s.hoverDelay == 1.5)
    s.hoverDelay = 0
    expect(s.hoverDelay == 0.2 && s.statsHoverDelay == 0.2, "shared with the stats details")
    s.setHotkey(.toggle, nil)
    expect(s.hotkey(.toggle) == nil, "cleared hotkey must not fall back to the factory default")
    expect(s.provisionalToggleKey == nil)
    s.provisionalToggleKey = 884.5
    expect(Settings(defaults: d).provisionalToggleKey == 884.5)
    s.provisionalToggleKey = nil
    expect(d.object(forKey: "provisionalToggleKey") == nil, "cleared, not stored as 0")
    var r = s.rules
    r.largeScreen = true
    r.bundleIDs = ["a", "b"]
    s.rules = r
    expect(Settings(defaults: d).rules == r)
    expect(s.shelfMode == .whenCrowded && s.spacingPreset == .system)
}

test("localization") {
    Loc.language = .en
    expect(L("Hidden") == "Hidden")
    expect(L("%d s", 5) == "5 s")
    Loc.language = .zhHans
    expect(L("Hidden") != "Hidden", "missing zh for Hidden")
    expect(L("%d s", 5).contains("5"))
    Loc.language = .system
}


test("stats: ring buffer") {
    var r = RingBuffer(capacity: 3)
    expect(r.values.isEmpty && r.last == nil)
    for v in [1.0, 2, 3, 4, .nan] { r.append(v) }
    expect(r.values == [3, 4, 0], "\(r.values)")
    expect(r.last == 0 && r.count == 3 && r.max == 4)
}

test("stats: cpu usage from ticks") {
    let a = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
    let b = [CPUTicks(user: 200, system: 100, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]
    let u = CPUMath.usage(previous: a, current: b)
    expect(abs(u.perCore[0] - 1) < 1e-9 && u.perCore[1] == 0, "\(u.perCore)")
    expect(abs(u.total - 150.0 / 250.0) < 1e-9, "\(u.total)")
    expect(abs(u.user - 100.0 / 250.0) < 1e-9 && abs(u.system - 50.0 / 250.0) < 1e-9)
    // A counter going backwards (core reset) must never produce negative or >100% usage.
    let reset = CPUMath.usage(previous: b, current: a)
    expect(reset.total >= 0 && reset.total <= 1 && reset.perCore.allSatisfy { $0 >= 0 && $0 <= 1 })
    expect(CPUMath.usage(previous: [], current: a).total == 0)
}

test("stats: counter rates") {
    expect(CounterMath.rate(previous: 1000, current: 3000, seconds: 2) == 1000)
    expect(CounterMath.rate(previous: 3000, current: 1000, seconds: 2) == 0, "reset → 0, not a spike")
    expect(CounterMath.rate(previous: 0, current: 1000, seconds: 0) == 0)
}

test("stats: memory breakdown matches Activity Monitor formulas") {
    let m = MemoryMath.breakdown(pageSize: 16384, total: 64 << 30, internalPages: 1000, purgeablePages: 100, externalPages: 500,
                                 wiredPages: 200, compressorPages: 50, freePages: 300, speculativePages: 10)
    expect(m.app == 900 * 16384 && m.wired == 200 * 16384 && m.compressed == 50 * 16384)
    expect(m.cached == 600 * 16384 && m.free == 310 * 16384)
    expect(m.used == (900 + 200 + 50) * 16384)
    expect(m.usedFraction > 0 && m.usedFraction < 1)
    expect(MemoryMath.breakdown(pageSize: 1, total: 0, internalPages: 1, purgeablePages: 5, externalPages: 0, wiredPages: 0,
                                compressorPages: 0, freePages: 0, speculativePages: 0).app == 0, "no underflow")
    expect(MemoryPressure(kernelLevel: 4) == .critical && MemoryPressure(kernelLevel: 99) == .normal)
}

test("stats: formatting") {
    expect(StatFormat.percent(0.123) == "12%" && StatFormat.percent(1.7) == "100%" && StatFormat.percent(-1) == "0%")
    expect(StatFormat.rate(512) == "512 B/s", StatFormat.rate(512))
    expect(StatFormat.rate(1536) == "1.5 KB/s", StatFormat.rate(1536))
    expect(StatFormat.rate(5_000_000) == "4.8 MB/s", StatFormat.rate(5_000_000))
    expect(StatFormat.rate(5_000_000, compact: true) == "4.8M", StatFormat.rate(5_000_000, compact: true))
    expect(StatFormat.rate(1000, bits: true) == "7.8 Kb/s", StatFormat.rate(1000, bits: true))
    expect(StatFormat.bytes(1536) == "1.5 KB" && StatFormat.bytes(0) == "0 B")
    expect(StatFormat.temperature(50, fahrenheit: false) == "50°" && StatFormat.temperature(50, fahrenheit: true) == "122°")
    expect(StatFormat.duration(90061) == "1d 1h" && StatFormat.duration(3700) == "1h 1m" && StatFormat.duration(59) == "0m")
}

test("stats: alert tracker fires once per episode") {
    var t = AlertTracker(holdSeconds: 10)
    let t0 = Date()
    expect(!t.update(conditionMet: true, now: t0))
    expect(!t.update(conditionMet: true, now: t0.addingTimeInterval(9)))
    expect(t.update(conditionMet: true, now: t0.addingTimeInterval(10)), "fires after hold")
    expect(!t.update(conditionMet: true, now: t0.addingTimeInterval(60)), "no repeat while still high")
    expect(!t.update(conditionMet: false, now: t0.addingTimeInterval(61)))
    expect(!t.update(conditionMet: true, now: t0.addingTimeInterval(62)))
    expect(t.update(conditionMet: true, now: t0.addingTimeInterval(72)), "re-armed after clearing")
    var instant = AlertTracker(holdSeconds: 0)
    expect(instant.update(conditionMet: true, now: t0))
}

test("stats: sensor classification and decoding") {
    expect(SensorClassifier.group(for: "Tp0j") == .cpu && SensorClassifier.group(for: "Tg0f") == .gpu)
    expect(SensorClassifier.group(for: "TB0T") == .battery && SensorClassifier.group(for: "TH0a") == .storage)
    expect(SensorClassifier.group(for: "Tf04") == nil && SensorClassifier.group(for: "F0Ac") == nil && SensorClassifier.group(for: "Tp") == nil)
    let keys = (0..<60).map { String(format: "Tp%02X", $0) }
    let pick = SensorClassifier.representative(keys, max: 6)
    expect(pick.count == 6 && Set(pick).count == 6 && pick.first == keys.sorted().first)
    expect(SensorClassifier.representative(["a", "b"], max: 6) == ["a", "b"])
    expect(SensorClassifier.plausible(55) && !SensorClassifier.plausible(-3) && !SensorClassifier.plausible(130))
    var f: Float = 1358.63
    let bytes = withUnsafeBytes(of: &f) { Array($0) }
    expect(abs((SMCValue.decode(type: "flt ", bytes: bytes) ?? 0) - 1358.63) < 0.01)
    expect(SMCValue.decode(type: "ui8 ", bytes: [2]) == 2)
    expect(SMCValue.decode(type: "fpe2", bytes: [0x1F, 0x40]) == 2000)
    expect(SMCValue.decode(type: "sp78", bytes: [0x32, 0x80]) == 50.5)
    expect(SMCValue.decode(type: "flt ", bytes: [1, 2]) == nil && SMCValue.decode(type: "????", bytes: [1]) == nil)
}

test("stats: settings") {
    let (d, discard) = scratchDefaults()
    defer { discard() }
    let s = Settings(defaults: d)
    expect(s.statsModules.isEmpty && s.statsInterval == 1 && !s.statsCombined)
    s.statsModules = [.cpu, .network]
    expect(Settings(defaults: d).statsModules == [.cpu, .network])
    expect(s.statsElements(.cpu) == [.graph, .percent], "default elements")
    s.setStatsElements(.cpu, [.rates])   // not a CPU element → ignored
    expect(s.statsElements(.cpu) == [.graph, .percent])
    s.setStatsElements(.cpu, [.cores])
    expect(s.statsElements(.cpu) == [.cores])
    s.statsInterval = 0.2
    expect(s.statsInterval == 1)
    var a = s.alerts
    expect(!a.anyEnabled && a.cpuPercent == 90)
    a.cpuEnabled = true
    a.cpuPercent = 500
    s.alerts = a
    expect(s.alerts.cpuEnabled && s.alerts.cpuPercent == 100, "clamped")
    for m in StatsModule.allCases {
        expect(!m.presets.isEmpty && !m.elements.isEmpty)
        for p in m.presets { expect(m.sanitized(p) == p, "\(m) preset uses only its own elements, once: \(p)") }
    }
    expect(s.statsElements(.memory) == [.pie, .percent] && s.statsElements(.disk) == [.pie, .percent]
           && s.statsElements(.battery) == [.battery, .percent], "classic iStat layouts are the defaults")
    expect(s.clockFormat == "EEE HH:mm")
    s.worldClocks = ["Asia/Tokyo", "Not/AZone", "Europe/London"]
    expect(s.worldClocks == ["Asia/Tokyo", "Europe/London"], "invalid time zones are dropped")
}

test("stats: element lists, presets, migration and module order") {
    let (d, discard) = scratchDefaults()
    defer { discard() }
    let s = Settings(defaults: d)
    // The memory and disk layouts people asked for exist as presets.
    expect(StatsModule.memory.presets.contains([.usedFree]) && StatsModule.memory.presets.contains([.pie, .usedFree]))
    expect(StatsModule.disk.presets.contains([.readWrite]) && StatsModule.disk.presets.contains([.pie, .readWrite]))
    expect(StatsModule.network.presets.contains([.graph, .rates]))
    // Custom combinations keep their order; unknown, foreign and repeated elements are dropped.
    s.setStatsElements(.memory, [.usedFree, .pie, .usedFree, .rates, .label])
    expect(s.statsElements(.memory) == [.usedFree, .pie, .label])
    s.setStatsElements(.memory, [])
    expect(s.statsElements(.memory) == [.usedFree, .pie, .label], "an empty list is ignored")
    d.set(["bogus", "percent"], forKey: "stats.elements.gpu")
    expect(s.statsElements(.gpu) == [.percent])
    // BarTap 1.0 stored one mode per module.
    d.set("usedAmount", forKey: "stats.mode.disk")
    expect(s.statsElements(.disk) == [.used])
    d.set("activity", forKey: "stats.mode.disk")
    expect(s.statsElements(.disk) == [.readWrite])
    d.set("iconPercent", forKey: "stats.mode.battery")
    expect(s.statsElements(.battery) == [.battery, .percent])
    d.set("rates", forKey: "stats.mode.cpu")
    expect(s.statsElements(.cpu) == [.graph, .percent], "a foreign legacy mode falls back to the default")
    s.setStatsElements(.disk, [.pie, .readWrite])
    expect(s.statsElements(.disk) == [.pie, .readWrite], "the element list wins over the legacy mode")
    // Module order is the user's, without repeats.
    s.statsModules = [.network, .memory, .cpu, .network]
    expect(s.statsModules == [.network, .memory, .cpu])
    for raw in ["graphPercent", "graph", "percent", "cores", "pie", "piePercent", "usedAmount", "freeAmount", "activity", "rates",
                "cpuTemperature", "temperatureAndFan", "power", "iconPercent", "timeRemaining", "clock"] {
        expect(StatsElement.fromLegacyMode(raw) != nil, "legacy mode \(raw) maps")
    }
}

test("stats: compact amounts for U:/F:") {
    let gb: UInt64 = 1_073_741_824
    expect(StatFormat.compactAmount(512 * 1_048_576) == "512M")
    expect(StatFormat.compactAmount(12 * gb + gb / 3) == "12.3G")
    expect(StatFormat.compactAmount(412 * gb) == "412G")
    expect(StatFormat.compactAmount(1843 * gb) == "1.8T")
}

test("ai: Claude Code lines") {
    let line = #"{"parentUuid":"a","isSidechain":false,"type":"assistant","timestamp":"2026-11-01T10:15:30.123Z","requestId":"req_1","sessionId":"s","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"hi \"model\":\"fake\""}],"usage":{"input_tokens":2,"cache_creation_input_tokens":14672,"cache_read_input_tokens":25978,"output_tokens":1330,"output_tokens_details":{"thinking_tokens":1166},"cache_creation":{"ephemeral_1h_input_tokens":4000,"ephemeral_5m_input_tokens":10672}}}}"#
    guard let e = ClaudeCodeLog.entry(from: Data(line.utf8)) else { expect(false, "parsed"); return }
    expect(e.agent == .claudeCode && e.model == "claude-opus-5-5" && e.dedupeKey == "msg_1|req_1")
    expect(e.tokens == TokenCounts(input: 2, output: 1330, cacheRead: 25978, cacheWrite: 10672, cacheWrite1h: 4000, reasoning: 1166), "\(e.tokens)")
    expect(e.tokens.total == 2 + 1330 + 25978 + 14672 && !e.longContext)
    expect(abs(e.date.timeIntervalSince1970 - 1793528130.123) < 0.01, "timestamp with fractions")
    let user = #"{"type":"user","timestamp":"2026-11-01T10:15:30Z","message":{"role":"user","content":"usage"}}"#
    expect(ClaudeCodeLog.entry(from: Data(user.utf8)) == nil, "user lines carry no usage")
    let synthetic = line.replacingOccurrences(of: "claude-opus-5-5", with: "<synthetic>")
    expect(ClaudeCodeLog.entry(from: Data(synthetic.utf8)) == nil, "synthetic placeholders are skipped")
    let long = line.replacingOccurrences(of: #""cache_read_input_tokens":25978"#, with: #""cache_read_input_tokens":250000"#)
    expect(ClaudeCodeLog.entry(from: Data(long.utf8))?.longContext == true, "prompt over 200k")
    expect(ClaudeCodeLog.entry(from: Data("not json".utf8)) == nil)
}

test("ai: Codex session totals become per-turn usage; rate limits") {
    var r = CodexLogReader()
    func event(_ input: Int, _ cached: Int, _ output: Int, _ reasoning: Int, at ts: String, limits: String = "null") -> Data {
        Data(#"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)},"last_token_usage":{}},"rate_limits":\#(limits)}}"#.utf8)
    }
    expect(r.read(Data(#"{"timestamp":"2026-11-01T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5-codex","effort":"high"}}"#.utf8)).isEmpty)
    let first = r.read(event(28071, 0, 319, 0, at: "2026-11-01T09:00:05Z"))
    guard case .usage(let a)? = first.first else { expect(false, "first turn"); return }
    expect(a.model == "gpt-5.5-codex" && a.tokens == TokenCounts(input: 28071, output: 319), "\(a.tokens)")
    let limits = #"{"limit_id":"codex","primary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1793811197},"secondary":{"used_percent":41.5,"window_minutes":300,"resets_at":1793532000},"credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},"plan_type":"plus"}"#
    let second = r.read(event(60000, 20000, 900, 200, at: "2026-11-01T09:01:00Z", limits: limits))
    guard case .usage(let b)? = second.first else { expect(false, "second turn"); return }
    expect(b.tokens == TokenCounts(input: 60000 - 28071 - 20000, output: 581, cacheRead: 20000, reasoning: 200), "delta: \(b.tokens)")
    guard case .limits(let l)? = second.last else { expect(false, "limits"); return }
    expect(l.plan == "plus" && l.credits == 12.5 && l.windows.count == 2)
    expect(l.windows[0].minutes == 10080 && l.windows[0].shortName == "7d" && l.windows[1].shortName == "5h")
    expect(l.tightest(now: Date(timeIntervalSince1970: 1793500000))?.usedPercent == 41.5, "the fuller window")
    expect(l.tightest(now: Date(timeIntervalSince1970: 1793600000))?.usedPercent == 6.0, "a window that already reset is ignored")
    expect(r.read(event(60000, 20000, 900, 200, at: "2026-11-01T09:02:00Z")).isEmpty, "an unchanged total adds nothing")
    let restart = r.read(event(500, 0, 10, 0, at: "2026-11-01T09:03:00Z"))
    guard case .usage(let c)? = restart.first else { expect(false, "restart"); return }
    expect(c.tokens == TokenCounts(input: 500, output: 10), "a smaller total starts a new count")
}

test("ai: OpenCode messages") {
    let data = Data(#"{"role":"assistant","cost":0.0123,"tokens":{"input":1200,"output":300,"reasoning":50,"cache":{"read":800,"write":100}},"modelID":"claude-sonnet-5","providerID":"anthropic","time":{"created":1793528130000,"completed":1793528131000}}"#.utf8)
    guard let e = OpenCodeLog.entry(fromMessageData: data) else { expect(false, "parsed"); return }
    expect(e.agent == .openCode && e.model == "claude-sonnet-5" && e.recordedCost == 0.0123)
    expect(e.tokens == TokenCounts(input: 1200, output: 350, cacheRead: 800, cacheWrite: 100, reasoning: 50))
    let free = Data(#"{"role":"assistant","cost":0,"tokens":{"input":10,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"x","time":{"created":1}}"#.utf8)
    expect(OpenCodeLog.entry(fromMessageData: free)?.recordedCost == nil, "zero cost is computed from prices instead")
    expect(OpenCodeLog.entry(fromMessageData: Data(#"{"role":"user","time":{"created":1}}"#.utf8)) == nil)
}

test("ai: ranges, book totals, prices") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    cal.firstWeekday = 2   // Monday
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15))!   // a Wednesday
    func key(_ r: AIRange) -> String { AIUsageBook.dayKey(r.start(containing: now, calendar: cal), calendar: cal) }
    expect(key(.today) == "2026-11-04" && key(.week) == "2026-11-02" && key(.month) == "2026-11-01")
    expect(key(.quarter) == "2026-10-01" && key(.year) == "2026-01-01")

    let p = ModelPrice(input: 5e-6, output: 25e-6, cacheRead: 0.5e-6, cacheWrite: 6.25e-6, inputLong: 10e-6, outputLong: 37.5e-6)
    let table = ["claude-opus-5-5": p, "gpt-5.5-codex": ModelPrice(input: 1.25e-6, output: 10e-6, cacheRead: 0.125e-6, cacheWrite: 0)]
    let prices: (String) -> ModelPrice? = { AIPricing.lookup($0, in: table) }
    expect(AIPricing.lookup("anthropic/claude-opus-5-5", in: table) == p, "provider prefix")
    expect(AIPricing.lookup("claude-opus-5-5-20261015", in: table) == p, "date suffix")
    expect(AIPricing.lookup("gpt-5.5-codex-latest", in: table) != nil, "suffixed variant")
    expect(AIPricing.lookup("mystery-model", in: table) == nil)
    let t = TokenCounts(input: 1_000_000, output: 100_000, cacheRead: 2_000_000, cacheWrite: 400_000, cacheWrite1h: 100_000)
    expect(abs(AIPricing.cost(t, p, long: false) - (5 + 2.5 + 1 + 2.5 + 1)) < 1e-9, "1h writes default to 2x input")
    expect(abs(AIPricing.cost(TokenCounts(input: 1_000_000), p, long: true) - 10) < 1e-9, "long-context tier")

    var book = AIUsageBook()
    let day = { (d: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 12))! }
    book.add(AIUsageEntry(agent: .claudeCode, model: "claude-opus-5-5", date: day(4), tokens: TokenCounts(input: 1_000_000)), calendar: cal)
    book.add(AIUsageEntry(agent: .claudeCode, model: "claude-opus-5-5", date: day(1), tokens: TokenCounts(output: 1_000_000)), calendar: cal)
    book.add(AIUsageEntry(agent: .codex, model: "gpt-5.5-codex", date: day(3), tokens: TokenCounts(input: 2_000_000)), calendar: cal)
    book.add(AIUsageEntry(agent: .openCode, model: "mystery-model", date: day(4), tokens: TokenCounts(input: 7), recordedCost: 0.5), calendar: cal)
    book.add(AIUsageEntry(agent: .openCode, model: "mystery-model", date: day(4), tokens: TokenCounts(input: 3)), calendar: cal)
    let all = Set(AIAgent.allCases)
    let today = book.total(from: key(.today), agents: all, prices: prices)
    expect(today.tokens.total == 1_000_010 && abs(today.cost - 5.5) < 1e-9 && today.unpricedTokens == 0, "recorded cost wins for its key: \(today)")
    let week = book.total(from: key(.week), agents: [.claudeCode, .codex], prices: prices)
    expect(week.tokens.total == 3_000_000 && abs(week.cost - 7.5) < 1e-9, "\(week)")
    let month = book.total(from: key(.month), agents: [.claudeCode], prices: prices)
    expect(month.tokens.total == 2_000_000 && abs(month.cost - 30) < 1e-9)
    var unknown = AIUsageBook()
    unknown.add(AIUsageEntry(agent: .geminiCLI, model: "mystery-model", date: day(4), tokens: TokenCounts(input: 9)), calendar: cal)
    expect(unknown.total(from: "2026-01-01", agents: all, prices: prices).unpricedTokens == 9, "unpriced tokens are reported, not guessed")
    expect(book.daily(last: 4, now: now, calendar: cal, agents: all, prices: prices).map { $0.tokens.total } == [1_000_000, 0, 2_000_000, 1_000_010])
    expect(book.models(from: key(.month), agents: all, prices: prices).first?.model == "claude-opus-5-5", "most expensive first")
    var replaced = book
    replaced.replace(.openCode, with: [AIUsageEntry(agent: .openCode, model: "m", date: day(2), tokens: TokenCounts(output: 1))], calendar: cal)
    expect(replaced.total(from: key(.today), agents: [.openCode], prices: prices).tokens.total == 0)
    expect(replaced.total(from: key(.month), agents: [.openCode], prices: prices).tokens.total == 1)
    book.prune(before: "2026-11-02")
    expect(book.days.keys.sorted() == ["2026-11-03", "2026-11-04"] && book.recordedCosts.keys.sorted() == ["2026-11-04"])
}

test("ai: prompt tiers, fast mode, model thresholds") {
    expect(AIUsageEntry.tier(99_000) == 0 && AIUsageEntry.tier(150_000) == 100 && AIUsageEntry.tier(250_000) == 200 && AIUsageEntry.tier(300_000) == 272)
    let e = AIUsageEntry(agent: .claudeCode, model: "claude-haiku-5-5", date: Date(), tokens: TokenCounts(input: 1), promptTokens: 150_000, fast: true)
    expect(AIUsageBook.key(e) == "claudeCode|claude-haiku-5-5|t100|fast")
    let k = AIUsageBook.parse(key: AIUsageBook.key(e))
    expect(k?.tier == 100 && k?.fast == true && k?.model == "claude-haiku-5-5")
    expect(AIUsageBook.parse(key: "claudeCode|m|long")?.tier == 200, "keys saved by earlier builds still read")
    let haiku = ModelPrice(input: 1e-6, output: 5e-6, cacheRead: 1e-7, cacheWrite: 1.25e-6, inputLong: 2e-6, outputLong: 7.5e-6, threshold: 100_000)
    let t = TokenCounts(input: 1_000_000)
    expect(abs(AIPricing.cost(t, haiku, tier: 100) - 2) < 1e-9, "Haiku 5.5 bills the whole request higher above 100k")
    expect(abs(AIPricing.cost(t, haiku, tier: 0) - 1) < 1e-9)
    let gpt = ModelPrice(input: 1e-6, output: 1e-5, cacheRead: 1e-7, cacheWrite: 1e-6, inputLong: 2e-6, threshold: 272_000)
    expect(abs(AIPricing.cost(t, gpt, tier: 200) - 1) < 1e-9 && abs(AIPricing.cost(t, gpt, tier: 272) - 2) < 1e-9, "GPT tier starts at 272k")
    expect(abs(AIPricing.cost(t, haiku, tier: 0, fast: true) - 2) < 1e-9, "fast mode defaults to 2x")
    var fastPrice = haiku; fastPrice.fast = 6
    expect(abs(AIPricing.cost(t, fastPrice, tier: 0, fast: true) - 6) < 1e-9)
}

test("ai: Codex forks and limit ids") {
    var r = CodexLogReader()
    _ = r.read(Data(#"{"timestamp":"2026-11-01T10:00:00Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","timestamp":"2026-11-01T10:00:00Z","base_instructions":{"text":"long"}}}"#.utf8))
    expect(r.forkedAt != nil, "fork marker read")
    let replay = Data(#"{"timestamp":"2026-11-01T09:59:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900000,"cached_input_tokens":0,"output_tokens":5000,"reasoning_output_tokens":0,"total_tokens":905000}},"rate_limits":null}}"#.utf8)
    expect(r.read(replay).isEmpty, "usage stamped before the fork belongs to the parent")
    let own = Data(#"{"timestamp":"2026-11-01T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":905000,"cached_input_tokens":0,"output_tokens":5100,"reasoning_output_tokens":0,"total_tokens":910100}},"rate_limits":{"limit_id":"other","primary":{"used_percent":99,"window_minutes":300,"resets_at":1893456000}}}}"#.utf8)
    let events = r.read(own)
    guard case .usage(let u)? = events.first else { expect(false, "own usage"); return }
    expect(u.tokens == TokenCounts(input: 5000, output: 100), "only the fork's own turn: \(u.tokens)")
    expect(events.count == 1, "limits of another limit id are ignored")
}

test("ai: Claude Code's cached plan usage") {
    let json = Data(#"{"numStartups":3,"projects":{"/x":{"history":[]}},"cachedUsageUtilization":{"fetchedAtMs":1793528130000,"accountUuid":"a","utilization":{"five_hour":{"utilization":43,"resets_at":"2026-11-01T15:00:00Z","remaining_dollars":null},"seven_day":{"utilization":61.5,"resets_at":null},"seven_day_opus":null,"tangelo":null},"limits":[{"kind":"weekly_scoped","percent":38,"scope":{"model":{"display_name":"Fable"}}}]},"other":1}"#.utf8)
    guard let st = ClaudePlanCache.status(fromClaudeJSON: json) else { expect(false, "parsed"); return }
    expect(st.agent == .claudeCode && st.windows.count == 3, "\(st.windows)")
    expect(st.windows[0].minutes == 300 && st.windows[0].usedPercent == 43 && st.windows[0].resetsAt != nil)
    expect(st.windows[1].minutes == 10_080 && st.windows[1].usedPercent == 61.5 && st.windows[1].resetsAt == nil)
    expect(st.windows[2].scope == "Fable" && st.windows[2].usedPercent == 38)
    expect(abs(st.updated.timeIntervalSince1970 - 1793528130) < 1)
    expect(ClaudePlanCache.status(fromClaudeJSON: Data(#"{"numStartups":3}"#.utf8)) == nil)
    let pretty = Data("{\n  \"cachedUsageUtilization\": {\n    \"fetchedAtMs\": 1793528130000,\n    \"utilization\": {\n      \"five_hour\": { \"utilization\": 12, \"resets_at\": null }\n    }\n  }\n}".utf8)
    expect(ClaudePlanCache.status(fromClaudeJSON: pretty)?.windows.first?.usedPercent == 12, "pretty-printed, as Claude Code writes it")
}

test("layout plan: icons already in order stay, every other one moves once") {
    let anchors: Set<String> = ["‖", "│", "CC", "Clock"]
    func applied(_ current: [String], _ steps: [LayoutPlan.Step]) -> [String] {
        var order = current
        for step in steps {
            order.removeAll { $0 == step.item }
            order.insert(step.item, at: order.firstIndex(of: step.leftOf)!)
        }
        return order
    }
    // Already in order: nothing to do.
    expect(LayoutPlan.nextStep(current: ["A", "‖", "B", "│", "C", "CC", "Clock"], wanted: ["A", "‖", "B", "│", "C", "CC", "Clock"], anchors: anchors) == nil)
    // Hide C (shown → hidden) and swap A and B: two moves.
    let current = ["A", "B", "‖", "│", "C", "D", "CC", "Clock"]
    let wanted = ["B", "A", "‖", "C", "│", "D", "CC", "Clock"]
    let steps = LayoutPlan.steps(current: current, wanted: wanted, anchors: anchors)
    expect(steps.count == 2 && applied(current, steps) == wanted, "\(steps)")
    // One icon from the far right to the hidden section: one move, nothing else shuffled.
    let row = ["H1", "H2", "│", "S1", "S2", "S3", "S4", "AI", "T", "CC", "Clock"]
    let hide = ["H1", "H2", "AI", "│", "S1", "S2", "S3", "S4", "T", "CC", "Clock"]
    let one = LayoutPlan.steps(current: row, wanted: hide, anchors: anchors)
    expect(one == [LayoutPlan.Step(item: "AI", leftOf: "│")], "\(one)")
    // Anchors never move, even when out of place.
    expect(LayoutPlan.steps(current: ["│", "A"], wanted: ["A", "│"], anchors: anchors) == [LayoutPlan.Step(item: "A", leftOf: "│")])
    // Icons the plan doesn't know (just appeared) stay; ones that vanished are skipped.
    let unknown = LayoutPlan.steps(current: ["X", "A", "B", "CC"], wanted: ["B", "A", "Gone", "CC"], anchors: anchors)
    expect(unknown.count == 1 && applied(["X", "A", "B", "CC"], unknown).filter { $0 != "X" } == ["B", "A", "CC"], "\(unknown)")
    // An unknown icon between two that are in order doesn't cost a move.
    expect(LayoutPlan.nextStep(current: ["A", "X", "B", "CC"], wanted: ["A", "B", "CC"], anchors: anchors) == nil)
    // Reverse a row of five: four moves.
    let five = ["A", "B", "C", "D", "E", "CC"]
    let reversed = LayoutPlan.steps(current: five, wanted: ["E", "D", "C", "B", "A", "CC"], anchors: anchors)
    expect(reversed.count == 4 && applied(five, reversed) == ["E", "D", "C", "B", "A", "CC"], "\(reversed)")
}

test("layout rows: drag between rows, reorder, nearest end, merge") {
    var a = LayoutArrangement(shown: ["S1", "S2"], hidden: ["H1", "H2", "H3"], always: [], pinned: ["CC", "Clock"])
    // Within a row, an index counts the icons before the move.
    a.move("H1", to: .hidden, at: 3)
    expect(a.hidden == ["H2", "H3", "H1"], "\(a.hidden)")
    a.move("H1", to: .hidden, at: 0)
    expect(a.hidden == ["H1", "H2", "H3"])
    a.move("S2", to: .hidden, at: 1)
    expect(a.hidden == ["H1", "S2", "H2", "H3"] && a.shown == ["S1"])
    // Out-of-range indexes clamp; pinned icons never move.
    a.move("H3", to: .shown, at: 99)
    expect(a.shown == ["S1", "H3"])
    a.move("CC", to: .hidden, at: 0)
    expect(a.pinned == ["CC", "Clock"] && a.row(of: "CC") == nil)
    // Sending goes to the end nearest the row it came from.
    a.send("H1", to: .shown)
    expect(a.shown.first == "H1")
    a.send("S1", to: .hidden)
    expect(a.hidden.last == "S1")
    a.send("H2", to: .always)
    expect(a.always == ["H2"])
    a.send("S1", to: .always)
    expect(a.always == ["H2", "S1"])
    a.send("H2", to: .hidden)
    expect(a.hidden.first == "H2")
    expect(a.order(alwaysSection: true) == ["S1", "‖", "H2", "S2", "│", "H1", "H3", "CC", "Clock"], "\(a.order(alwaysSection: true))")
    expect(a.order(alwaysSection: false) == ["S1", "H2", "S2", "│", "H1", "H3", "CC", "Clock"])
    // Merging edits into a changed bar: gone icons drop out, new ones land where they appeared.
    let edits = LayoutArrangement(shown: ["B", "A"], hidden: ["C"], always: [], pinned: ["CC"])
    let live = LayoutArrangement(shown: ["A", "N", "B"], hidden: [], always: [], pinned: ["CC"])
    let m = edits.merged(into: live)
    expect(m.shown == ["B", "A", "N"] && m.hidden == [] && m.pinned == ["CC"], "\(m)")
    // The plan for those edits, with BarTap's dividers and pinned icons as anchors.
    let steps = LayoutPlan.steps(current: live.order(alwaysSection: false), wanted: m.order(alwaysSection: false), anchors: ["│", "CC"])
    expect(steps.count == 1, "\(steps)")
}

test("layout rows: Apply moves only the icons the user moved") {
    // The rows were read earlier; since then (or because a reading was stale) H1 and H2 swapped.
    let edited = LayoutArrangement(shown: ["S1"], hidden: ["H1", "H2", "H3", "S2"], always: [], pinned: ["CC"])
    let now = LayoutArrangement(shown: ["S1", "S2"], hidden: ["H2", "H1", "H3"], always: [], pinned: ["CC"])
    let goal = edited.rebased(onto: now, touched: ["S2"])
    expect(goal.hidden == ["H2", "H1", "H3", "S2"] && goal.shown == ["S1"], "\(goal)")
    // Dropped before an icon: lands before it, wherever that icon is now.
    let before = LayoutArrangement(shown: [], hidden: ["H1", "X", "H2"], always: [], pinned: [])
    let reality = LayoutArrangement(shown: ["X"], hidden: ["H2", "H1"], always: [], pinned: [])
    expect(before.rebased(onto: reality, touched: ["X"]).hidden == ["X", "H2", "H1"])
    // Two moved icons keep their order; an icon that went away is skipped.
    let two = LayoutArrangement(shown: ["A", "B", "S"], hidden: [], always: [], pinned: [])
    let bar = LayoutArrangement(shown: ["S"], hidden: ["A", "B"], always: [], pinned: [])
    expect(two.rebased(onto: bar, touched: ["A", "B", "Gone"]).shown == ["A", "B", "S"])
    // Nothing touched: the bar as it is.
    expect(edited.rebased(onto: now, touched: []) == now)
}

test("short rows: a display too narrow for every shown icon is named, others not") {
    // Collapsed: BarTap's long divider, then the shown run up to the right edge; `undrawn` icons at
    // its left end don't fit.
    func bar(_ s: ScreenInfo, _ run: [CGFloat], undrawn: Int = 0) -> [WindowInfo] {
        var x = s.frame.maxX - run.reduce(0, +)
        var out = [statusWindow(x - 10000, 10000, on: s)]
        for (i, w) in run.enumerated() {
            out.append(statusWindow(x, w, on: s, drawn: i >= undrawn))
            x += w
        }
        return out
    }
    let run: [CGFloat] = [31, 47, 60, 218, 76, 42, 135]
    expect(MenuBarGeometry.shortRows(screens: [external, portrait], windows: bar(external, run) + bar(portrait, run)).isEmpty,
           "same icons everywhere")
    let short = MenuBarGeometry.shortRows(screens: [external, builtIn], windows: bar(external, run) + bar(builtIn, run, undrawn: 2))
    expect(short.count == 1 && short.first?.screen == builtIn && short.first?.missing == 2, "\(short)")
    // A display whose bar isn't drawn (full screen) is not short.
    expect(MenuBarGeometry.shortRows(screens: [external, portrait], windows: bar(external, run)).isEmpty)
}

test("own run: BarTap's items found by width in the window list") {
    let screen = ScreenInfo(id: 9, frame: CGRect(x: 0, y: -1692, width: 3008, height: 1692), menuBarHeight: 30)
    // Right to left as macOS lays them out: clock, Control Center, Battery, stats (ai … cpu), toggle, │, Wi-Fi, input, ‖, LogiMos.
    func row(_ widths: [CGFloat], wideAt: Int? = nil) -> [WindowInfo] {
        var x = screen.frame.maxX
        var out: [WindowInfo] = []
        for (i, w) in widths.enumerated() {
            let width = i == wideAt ? 5016 : w
            x -= width
            out.append(WindowInfo(id: UInt32(i + 1), pid: 1, ownerName: "Control Center", layer: WindowLevel.status,
                                  bounds: CGRect(x: x, y: screen.frame.minY, width: width, height: 30), isOnScreen: x >= 0))
        }
        return out
    }
    let widths: [CGFloat] = [132, 42, 76, 218, 63, 67, 60, 47, 31, 18, 38, 44, 18, 38]
    let run = OwnRun(hidden: 18, toggle: 31, stats: [47, 60, 67, 63, 218], always: 18)
    let open = row(widths)
    guard let found = run.locate(screens: [screen], windows: open) else { expect(false, "found open"); return }
    expect(found.toggle == open[8].bounds && found.hidden == open[9].bounds && found.always == open[12].bounds, "\(found)")
    // Collapsed: │ is 5,016 pt wide; the row stops there, the run is still found.
    let collapsed = row(widths, wideAt: 9)
    let c = run.locate(screens: [screen], windows: collapsed)
    expect(c?.toggle == collapsed[8].bounds && c?.hidden.width == 5016, "\(String(describing: c))")
    // Stats items moved elsewhere: │ right before the toggle is enough.
    expect(OwnRun(hidden: 18, toggle: 31, stats: [47, 61], always: nil).locate(screens: [screen], windows: open)?.toggle == open[8].bounds)
    // A look-alike (an 18 pt icon, then a 31 pt one) further left: the one the stats items follow wins,
    // and without them the one nearest where BarTap last saw its toggle.
    let twin = row([132, 42, 76, 218, 63, 67, 60, 47, 31, 18, 38, 31, 18, 38])
    expect(run.locate(screens: [screen], windows: twin)?.toggle == twin[8].bounds)
    let rd = { (w: WindowInfo) in MenuBarGeometry.rightDistance(of: w.bounds, on: screen) }
    expect(OwnRun(hidden: 18, toggle: 31, stats: [], always: nil, toggleRD: rd(twin[11]) + 3).locate(screens: [screen], windows: twin)?.toggle == twin[11].bounds)
    expect(OwnRun(hidden: 18, toggle: 31, stats: [], always: nil, toggleRD: rd(twin[8]) - 2).locate(screens: [screen], windows: twin)?.toggle == twin[8].bounds)
    // Named windows (Screen Recording granted) are exact, wherever the stats items are.
    var named = open
    named[8].name = "tb_toggle"
    named[9].name = "tb_hidden"
    named[12].name = "tb_always"
    let n = OwnRun(hidden: 99, toggle: 99, stats: [], always: 99).locate(screens: [screen], windows: named)
    expect(n?.toggle == open[8].bounds && n?.hidden == open[9].bounds && n?.always == open[12].bounds, "\(String(describing: n))")
    // No visible bar: nothing found.
    let asleep = open.map { w -> WindowInfo in var w = w; w.isOnScreen = false; return w }
    expect(run.locate(screens: [screen], windows: asleep) == nil)
}

test("ai: Claude usage credits, limit kinds, stale windows") {
    // Claude Code's cache as of late 2026 (numbers made up): extra usage on, a session limit that
    // repeats five_hour, no weekly limit.
    let json = Data(#"""
    {"cachedUsageUtilization":{"fetchedAtMs":1793555494833,"utilization":{
      "five_hour":{"utilization":12,"resets_at":null,"limit_dollars":null,"used_dollars":null,"remaining_dollars":null},
      "seven_day":null,"seven_day_opus":null,
      "extra_usage":{"is_enabled":true,"monthly_limit":500000,"used_credits":123456,"utilization":24.69,"currency":"USD","decimal_places":2,"spend_limit_reached":false},
      "limits":[{"kind":"session","group":"session","percent":12,"resets_at":null,"scope":null},
                {"kind":"weekly_scoped","percent":38,"scope":{"model":{"display_name":"Fable"}}},
                {"kind":"mystery","percent":99}],
      "spend":{"used":{"amount_minor":123456,"currency":"USD","exponent":2},"limit":{"amount_minor":500000,"currency":"USD","exponent":2},"percent":24,"enabled":true}}}}
    """#.utf8)
    guard let st = ClaudePlanCache.status(fromClaudeJSON: json), let spend = st.spend else { expect(false, "parsed with credits"); return }
    expect(spend.used == 1234.56 && spend.limit == 5000 && spend.currency == "USD" && !spend.limitReached, "\(spend)")
    expect(st.windows.map(\.minutes) == [300, 10_080] && st.windows[1].scope == "Fable", "session not doubled, unknown kinds skipped: \(st.windows)")
    expect(spend.amount(left: false) == 1234.56 && abs((spend.amount(left: true) ?? 0) - 3765.44) < 0.001)
    expect(abs((spend.fraction(left: false) ?? 0) - 0.246912) < 1e-6 && abs((spend.fraction(left: true) ?? 0) - 0.753088) < 1e-6)
    // Only the newer "spend" block: same numbers.
    let spendOnly = Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1793555494833,"utilization":{"spend":{"used":{"amount_minor":250,"currency":"EUR","exponent":2},"limit":{"amount_minor":250,"exponent":2},"enabled":true}}}}"#.utf8)
    let s2 = ClaudePlanCache.status(fromClaudeJSON: spendOnly)?.spend
    expect(s2?.used == 2.5 && s2?.currency == "EUR" && s2?.limitReached == true, "\(String(describing: s2))")
    // Turned off: no credits.
    let off = Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1,"utilization":{"five_hour":{"utilization":5},"extra_usage":{"is_enabled":false,"used_credits":0}}}}"#.utf8)
    expect(ClaudePlanCache.status(fromClaudeJSON: off)?.spend == nil)
    // A 5-hour figure without a reset time means nothing 5 hours after it was read.
    let read = st.updated
    expect(st.current(now: read.addingTimeInterval(3600)).count == 2)
    expect(st.current(now: read.addingTimeInterval(6 * 3600)).map(\.minutes) == [10_080], "5h dropped, 7d kept")
    expect(st.tightest(now: read.addingTimeInterval(8 * 86_400)) == nil)
    // The menu bar figure carries the credits of the agents counted.
    var book = AIUsageBook()
    book.add(AIUsageEntry(agent: .codex, model: "gpt-5.5", date: read, tokens: TokenCounts(input: 10)), calendar: .current)
    let d = AIDisplay.make(book: book, plans: [.claudeCode: st], agents: [.claudeCode, .codex], range: .today, now: read,
                           calendar: .current, prices: { _ in nil })
    expect(d.total.spend == spend && d.perAgent.first { $0.agent == .codex }?.figure.spend == nil)
    expect(AIFormat.money(1234.56, currency: "USD") == "$1,235" && AIFormat.money(98.5, currency: "USD") == "$98.50")
    expect(AIFormat.money(9000, currency: "USD") == "$9,000" && AIFormat.money(1_234_567, currency: "EUR") == "€1,234,567")
    expect(AIFormat.compactMoney(6814.43, currency: "USD") == "$6.8K" && AIFormat.compactMoney(12.3, currency: "EUR") == "€12.30")
    expect(StatsModule.ai.elements.contains(.aiCredits) && StatsModule.ai.presets.contains([.aiCredits]))
}

test("ai: plan limits as used or left") {
    let w = AIPlanWindow(minutes: 300, usedPercent: 43, resetsAt: nil)
    expect(w.percent(left: false) == 43 && w.percent(left: true) == 57)
    expect(AIPlanWindow(minutes: 300, usedPercent: 104, resetsAt: nil).percent(left: true) == 0, "over the limit: nothing left")
    let (d, discard) = scratchDefaults()
    defer { discard() }
    let s = Settings(defaults: d)
    expect(!s.aiPlanLeft, "shows what's used by default")
    s.aiPlanLeft = true
    expect(Settings(defaults: d).aiPlanLeft)
}

test("ai: price tables") {
    let litellm = Data(#"""
    {"sample_spec":{"mode":"chat"},
     "claude-haiku-5-5":{"litellm_provider":"anthropic","mode":"chat","input_cost_per_token":1e-6,"output_cost_per_token":5e-6,"cache_read_input_token_cost":1e-7,"cache_creation_input_token_cost":1.25e-6,"cache_creation_input_token_cost_above_1hr":2e-6,"input_cost_per_token_above_100k_tokens":2e-6,"output_cost_per_token_above_100k_tokens":1e-5,"provider_specific_entry":{"fast":2.0,"us":1.1}},
     "gemini/gemini-2.5-pro":{"litellm_provider":"gemini","mode":"chat","input_cost_per_token":1.25e-6,"output_cost_per_token":1e-5,"input_cost_per_token_above_200k_tokens":2.5e-6},
     "bedrock/anthropic.claude":{"litellm_provider":"bedrock","mode":"chat","input_cost_per_token":1,"output_cost_per_token":1},
     "text-embedding-3":{"litellm_provider":"openai","mode":"embedding","input_cost_per_token":1e-8,"output_cost_per_token":0},
     "gpt-5.5":{"litellm_provider":"openai","mode":"chat","input_cost_per_token":5e-6,"output_cost_per_token":3e-5,"cache_read_input_token_cost":5e-7,"input_cost_per_token_above_272k_tokens":1e-5}}
    """#.utf8)
    guard let compact = AIPriceTable.compact(fromLiteLLM: litellm, fetched: "2026-11-01"), let table = AIPriceTable.decode(compact) else {
        expect(false, "converted"); return
    }
    expect(table.fetched == "2026-11-01" && Set(table.models.keys) == ["claude-haiku-5-5", "gemini-2.5-pro", "gpt-5.5"], "\(table.models.keys)")
    let h = table.models["claude-haiku-5-5"]!
    expect(h.threshold == 100_000 && h.inputLong == 2e-6 && h.cacheWrite1h == 2e-6 && h.fast == 2)
    expect(table.models["gemini-2.5-pro"]?.threshold == 200_000 && table.models["gpt-5.5"]?.threshold == 272_000)
    expect(table.models["gpt-5.5"]?.cacheWrite == 5e-6, "no cache-write price: input rate")
    expect(table.models["gemini-2.5-pro"]?.cacheRead == 1.25e-6, "no cache-read price: input rate")
}

test("ai: Gemini, Qwen and Kimi logs") {
    let gemini = Data(#"{"id":"msg-1","timestamp":"2026-05-01T00:01:00.000Z","type":"gemini","model":"gemini-3.1-pro-preview","tokens":{"input":14918,"output":60,"cached":4000,"thoughts":863,"tool":7,"total":15848}}"#.utf8)
    guard let g = GeminiLog.entries(from: gemini).first else { expect(false, "gemini"); return }
    expect(g.agent == .geminiCLI && g.dedupeKey == "gemini|msg-1" && g.model == "gemini-3.1-pro-preview")
    expect(g.tokens == TokenCounts(input: 14918 - 4000 + 7, output: 60 + 863, cacheRead: 4000, reasoning: 863), "\(g.tokens)")
    expect(GeminiLog.entries(from: Data(#"{"id":"u1","type":"user","timestamp":"2026-05-01T00:00:00Z","content":"hi"}"#.utf8)).isEmpty)
    let session = Data(#"{"sessionId":"s","messages":[{"id":"a","type":"user","timestamp":"2026-05-01T00:00:00Z"},{"id":"b","type":"gemini","timestamp":"2026-05-01T00:00:05Z","model":"gemini-2.5-pro","tokens":{"input":10,"output":2,"cached":0,"thoughts":0,"tool":0,"total":12}}]}"#.utf8)
    expect(GeminiLog.entries(from: session).count == 1, "older whole-session files")
    let qwen = Data(#"{"type":"assistant","model":"qwen3.5-plus","timestamp":"2026-02-23T14:24:56.857Z","sessionId":"d96bf338","uuid":"q1","usageMetadata":{"promptTokenCount":12414,"candidatesTokenCount":76,"thoughtsTokenCount":39,"cachedContentTokenCount":2000,"totalTokenCount":12529}}"#.utf8)
    guard let q = QwenLog.entry(from: qwen) else { expect(false, "qwen"); return }
    expect(q.tokens == TokenCounts(input: 10414, output: 115, cacheRead: 2000, reasoning: 39), "\(q.tokens)")
    let qwenInside = Data(#"{"type":"assistant","model":"m","timestamp":"2026-02-23T14:24:56Z","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":50,"thoughtsTokenCount":20,"cachedContentTokenCount":0,"totalTokenCount":150}}"#.utf8)
    expect(QwenLog.entry(from: qwenInside)?.tokens.output == 50, "thoughts already inside candidates are not added twice")
    let kimi = Data(#"{"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":5102,"output":172,"inputCacheRead":13312,"inputCacheCreation":0},"usageScope":"turn","time":1780319377014}"#.utf8)
    guard let k = KimiLog.entry(from: kimi) else { expect(false, "kimi"); return }
    expect(k.model == "kimi-for-coding" && k.tokens == TokenCounts(input: 5102, output: 172, cacheRead: 13312))
    expect(abs(k.date.timeIntervalSince1970 - 1780319377.014) < 0.001)
}

test("ai: formatting") {
    expect(AIFormat.tokens(845) == "845" && AIFormat.tokens(1234) == "1.2K" && AIFormat.tokens(45_600) == "46K")
    expect(AIFormat.tokens(4_560_000) == "4.6M" && AIFormat.tokens(123_000_000) == "123M" && AIFormat.tokens(2_500_000_000) == "2.5B")
    expect(AIFormat.cost(0.4) == "$0.40" && AIFormat.cost(12.345) == "$12.35" && AIFormat.cost(234.4) == "$234" && AIFormat.cost(1234) == "$1.2K")
}

test("stats: data usage rolls over by day and month") {
    var u = DataUsage(day: "2026-10-31", month: "2026-10")
    u.add(rx: 100, tx: 10, day: "2026-10-31", month: "2026-10")
    u.add(rx: 50, tx: 5, day: "2026-10-31", month: "2026-10")
    expect(u.dayRx == 150 && u.dayTx == 15 && u.monthRx == 150)
    u.add(rx: 7, tx: 1, day: "2026-11-01", month: "2026-11")
    expect(u.dayRx == 7 && u.monthRx == 7 && u.day == "2026-11-01" && u.month == "2026-11", "new day and month reset")
    u.add(rx: 3, tx: 0, day: "2026-11-02", month: "2026-11")
    expect(u.dayRx == 3 && u.monthRx == 10, "new day keeps the month")
}

test("stats: clock formats") {
    expect(ClockFormat.showsSeconds("HH:mm:ss") && !ClockFormat.showsSeconds("EEE HH:mm"))
    expect(!ClockFormat.showsSeconds("'s' HH:mm"), "quoted literals are not seconds")
    expect(ClockFormat.presets.contains("EEE HH:mm"))
}

runTrioTests()
runVideoDownloadTests()
runPresenterTests()

print("\n\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
