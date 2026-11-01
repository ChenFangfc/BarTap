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
    let suite = "bartap.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    let s = Settings(defaults: d)
    expect(s.autoRehide && s.rehideDelay == 8 && !s.alwaysHiddenEnabled && s.startCollapsed)
    expect(s.hotkey(.toggle)?.display() == "⌃⌥⌘B")
    s.rehideDelay = 0
    expect(s.rehideDelay == 1)
    s.hoverDelay = 99
    expect(s.hoverDelay == 2)
    s.setHotkey(.toggle, nil)
    expect(s.hotkey(.toggle) == nil, "cleared hotkey must not fall back to the factory default")
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
    let suite = "bartap.tests.stats.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    let s = Settings(defaults: d)
    expect(s.statsModules.isEmpty && s.statsInterval == 1 && !s.statsCombined)
    s.statsModules = [.cpu, .network]
    expect(Settings(defaults: d).statsModules == [.cpu, .network])
    expect(s.statsMode(.cpu) == .graphPercent, "default mode")
    s.setStatsMode(.cpu, .rates)   // not a CPU mode → ignored
    expect(s.statsMode(.cpu) == .graphPercent)
    s.setStatsMode(.cpu, .cores)
    expect(s.statsMode(.cpu) == .cores)
    s.statsInterval = 0.2
    expect(s.statsInterval == 1)
    var a = s.alerts
    expect(!a.anyEnabled && a.cpuPercent == 90)
    a.cpuEnabled = true
    a.cpuPercent = 500
    s.alerts = a
    expect(s.alerts.cpuEnabled && s.alerts.cpuPercent == 100, "clamped")
    for m in StatsModule.allCases { expect(!m.modes.isEmpty) }
    expect(s.statsMode(.memory) == .piePercent && s.statsMode(.disk) == .piePercent && s.statsMode(.battery) == .iconPercent,
           "classic iStat layouts are the defaults")
    expect(s.clockFormat == "EEE HH:mm")
    s.worldClocks = ["Asia/Tokyo", "Not/AZone", "Europe/London"]
    expect(s.worldClocks == ["Asia/Tokyo", "Europe/London"], "invalid time zones are dropped")
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

print("\n\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
