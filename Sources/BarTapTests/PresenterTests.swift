import Foundation
import CoreGraphics
import BarTapCore

// Details on hover / click (HoverClickModel), finding our items under the pointer on any display
// (StatusItemHitTest), placement and settings. Called from main.swift.
func runPresenterTests() {
    typealias Model = HoverClickModel<String>
    let p0 = CGPoint(x: 1000, y: 10)
    func at(_ item: String?, _ p: CGPoint = p0, panel: Bool = false) -> Model.Sample { Model.Sample(point: p, item: item, inPanel: panel) }
    func moved(_ dx: CGFloat) -> CGPoint { CGPoint(x: p0.x + dx, y: p0.y) }
    func near(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

    test("details: resting opens, passing over doesn't") {
        var m = Model()
        // Passing over: on the item for 0.3 s, then gone.
        expect(m.pointer(at("cpu"), now: 0).isEmpty && near(m.deadline, 0.5))
        expect(m.pointer(at("cpu", moved(20)), now: 0.15).isEmpty, "moving across restarts the rest")
        expect(m.pointer(at(nil, moved(60)), now: 0.3).isEmpty && m.deadline == nil, "left before resting")
        // A slow drag across a wide item never rests long enough in one spot.
        for i in 0..<12 { expect(m.pointer(at("network", moved(CGFloat(i) * 8)), now: 1 + Double(i) * 0.1).isEmpty) }
        // Resting (a few points of jitter are fine) opens after the delay.
        expect(m.pointer(at("cpu"), now: 3).isEmpty)
        expect(m.pointer(at("cpu", moved(4)), now: 3.3).isEmpty, "jitter within the radius")
        expect(m.pointer(at("cpu", moved(2)), now: 3.5) == [.open("cpu", .hover)])
        expect(m.shown == Model.Shown(target: "cpu", mode: .hover) && m.deadline == nil)
    }

    test("details: hover-opened ones close after the pointer leaves both, with grace") {
        var m = Model()
        _ = m.pointer(at("cpu"), now: 0)
        expect(m.pointer(at("cpu"), now: 0.5) == [.open("cpu", .hover)])
        // Down through the gap into the details: no close.
        expect(m.pointer(at(nil, CGPoint(x: 1000, y: 40)), now: 0.6).isEmpty && near(m.deadline, 0.9))
        expect(m.pointer(at(nil, CGPoint(x: 1000, y: 60), panel: true), now: 0.8).isEmpty && m.deadline == nil, "inside the details")
        // Out of the details for good.
        expect(m.pointer(at(nil, CGPoint(x: 1500, y: 400)), now: 2).isEmpty && near(m.deadline, 2.3))
        expect(m.pointer(at(nil, CGPoint(x: 1500, y: 400)), now: 2.2).isEmpty)
        expect(m.pointer(at(nil, CGPoint(x: 1500, y: 400)), now: 2.3) == [.close] && m.shown == nil)
        // Back on the item in time keeps them.
        _ = m.pointer(at("cpu"), now: 5)
        _ = m.pointer(at("cpu"), now: 5.5)
        _ = m.pointer(at(nil, CGPoint(x: 1200, y: 10)), now: 5.6)
        expect(m.pointer(at("cpu"), now: 5.8).isEmpty && m.shown != nil && m.deadline == nil)
    }

    test("details: a click pins them; leaving doesn't close, a click outside does") {
        var m = Model()
        expect(m.click(on: "cpu", now: 0) == [.open("cpu", .pinned)], "a click opens at once")
        expect(m.pointer(at(nil, CGPoint(x: 1500, y: 600)), now: 1).isEmpty && m.deadline == nil, "leaving doesn't close")
        expect(m.pointer(at(nil, CGPoint(x: 1500, y: 600)), now: 9).isEmpty && m.shown?.mode == .pinned)
        expect(m.clickOutside(now: 10) == [.close] && m.shown == nil)
        expect(m.clickOutside(now: 11).isEmpty, "nothing to close")
        // Hover-open, then a click on the item pins it.
        _ = m.pointer(at("memory"), now: 20)
        expect(m.pointer(at("memory"), now: 20.5) == [.open("memory", .hover)])
        expect(m.click(on: "memory", now: 21) == [.pin] && m.shown?.mode == .pinned)
        expect(m.pointer(at(nil, CGPoint(x: 0, y: 900)), now: 25).isEmpty && m.shown != nil)
    }

    test("details: another click on the item closes them, and resting there doesn't reopen") {
        var m = Model()
        _ = m.click(on: "cpu", now: 0)
        expect(m.click(on: "cpu", now: 1) == [.close])
        expect(m.pointer(at("cpu"), now: 1.1).isEmpty && m.pointer(at("cpu"), now: 3).isEmpty && m.deadline == nil, "no hover reopen while still on it")
        _ = m.pointer(at(nil, moved(80)), now: 3.1)
        _ = m.pointer(at("cpu"), now: 4)
        expect(m.pointer(at("cpu"), now: 4.5) == [.open("cpu", .hover)], "after leaving it, a rest opens again")
    }

    test("details: one at a time") {
        var m = Model()
        // Hover-open: resting on another item switches (grace closes the first, then the rest completes).
        _ = m.pointer(at("cpu"), now: 0)
        _ = m.pointer(at("cpu"), now: 0.5)
        expect(m.pointer(at("disk", moved(90)), now: 1).isEmpty)
        expect(m.pointer(at("disk", moved(90)), now: 1.3) == [.close])
        expect(m.pointer(at("disk", moved(90)), now: 1.5) == [.open("disk", .hover)])
        // With a delay shorter than the grace, it switches directly.
        var fast = Model(config: .init(dwell: 0.2))
        _ = fast.pointer(at("cpu"), now: 0)
        _ = fast.pointer(at("cpu"), now: 0.2)
        _ = fast.pointer(at("disk", moved(90)), now: 1)
        expect(fast.pointer(at("disk", moved(90)), now: 1.2) == [.open("disk", .hover)], "\(fast)")
        // Pinned: hovering others does nothing; clicking another switches, pinned.
        _ = m.click(on: "disk", now: 2)
        expect(m.shown == Model.Shown(target: "disk", mode: .pinned))
        expect(m.pointer(at("network", moved(200)), now: 3).isEmpty && m.pointer(at("network", moved(200)), now: 9).isEmpty && m.deadline == nil)
        expect(m.click(on: "network", now: 10) == [.open("network", .pinned)])
        // Idle: a click on another item while a hover one is open switches pinned.
        var h = Model()
        _ = h.pointer(at("cpu"), now: 0)
        _ = h.pointer(at("cpu"), now: 0.5)
        expect(h.click(on: "gpu", now: 1) == [.open("gpu", .pinned)])
    }

    test("details: hover off, dismiss, deadlines") {
        var m = Model(config: .init(hoverEnabled: false))
        expect(m.pointer(at("cpu"), now: 0).isEmpty && m.deadline == nil && m.pointer(at("cpu"), now: 5).isEmpty, "no hover opening")
        expect(m.click(on: "cpu", now: 6) == [.open("cpu", .pinned)], "clicks still work")
        var d = Model()
        _ = d.pointer(at("cpu"), now: 0)
        _ = d.pointer(at("cpu"), now: 0.5)
        expect(d.dismiss() == [.close] && d.dismiss().isEmpty)
        expect(d.pointer(at("cpu"), now: 2).isEmpty && d.deadline == nil, "dismissed: no reopen until the pointer leaves")
        // Turning hover off while hover-opened details are open still lets them close by leaving.
        var o = Model()
        _ = o.pointer(at("cpu"), now: 0)
        _ = o.pointer(at("cpu"), now: 0.5)
        o.config.hoverEnabled = false
        _ = o.pointer(at(nil, moved(300)), now: 1)
        expect(o.pointer(at(nil, moved(300)), now: 1.3) == [.close])
        // The earliest of a rest completing and a grace running out.
        var e = Model()
        _ = e.pointer(at("cpu"), now: 0)
        _ = e.pointer(at("cpu"), now: 0.5)
        _ = e.pointer(at("disk", moved(90)), now: 1)
        expect(near(e.deadline, 1.3), "grace before the new rest: \(String(describing: e.deadline))")
    }

    // MARK: Hit test

    // Three displays, measured shapes: the built-in one hosts the items (window names, with Screen
    // Recording), an external one draws unnamed copies the same way, and a narrow portrait one
    // leaves out one icon (not the leftmost), so the icons left of it sit further right there.
    let host = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 33, notch: 771...956)
    let wide = ScreenInfo(id: 2, frame: CGRect(x: 1728, y: -400, width: 2560, height: 1440), menuBarHeight: 30)
    let narrow = ScreenInfo(id: 3, frame: CGRect(x: -1080, y: -800, width: 1080, height: 1920), menuBarHeight: 30)
    let lid = ScreenInfo(id: 4, frame: CGRect(x: 4288, y: 0, width: 1512, height: 982), menuBarHeight: 33, asleep: true)
    // Left to right; the run ends at each display's right edge.
    let layout: [(name: String, width: CGFloat)] = [("Item-0", 40), ("tb_stats_cpu", 45), ("Item-1", 38), ("tb_hidden", 10),
                                                    ("tb_toggle", 32), ("tb_stats_network", 62), ("Item-2", 30), ("Item-3", 76)]
    var nextID: UInt32 = 1
    var placed: [UInt32: [String: CGRect]] = [:]   // where each icon sits on each display
    func row(on s: ScreenInfo, named: Bool, leaving out: Set<String> = []) -> [WindowInfo] {
        let shown = layout.filter { !out.contains($0.name) }
        var x = s.frame.maxX - shown.reduce(0) { $0 + $1.width }
        return shown.map { item in
            let r = CGRect(x: x, y: s.frame.minY, width: item.width, height: s.menuBarHeight)
            placed[s.id, default: [:]][item.name] = r
            x += item.width
            nextID += 1
            return WindowInfo(id: nextID, pid: 500, ownerName: "Control Center", name: named ? item.name : nil, layer: WindowLevel.status,
                              bounds: r, isOnScreen: true)
        }
    }
    let items = [StatusItemHitTest.Item(id: "cpu", windowName: "tb_stats_cpu", proxyFrame: nil),
                 StatusItemHitTest.Item(id: "network", windowName: "tb_stats_network", proxyFrame: nil)]
    let screens = [host, wide, narrow, lid]
    let windows = row(on: host, named: true) + row(on: wide, named: false) + row(on: narrow, named: false, leaving: ["Item-1"])
        + row(on: lid, named: false, leaving: ["Item-0", "tb_stats_cpu"])
    func center(_ name: String, on s: ScreenInfo, in _: [WindowInfo] = []) -> CGPoint {
        let r = placed[s.id]?[name] ?? CGRect(x: -1e6, y: 0, width: 1, height: 1)
        return CGPoint(x: r.midX, y: s.frame.minY + 10)
    }

    test("hit test: by window name on the display that hosts the items") {
        let hit = StatusItemHitTest.hit(at: center("tb_stats_cpu", on: host, in: windows), screens: screens, windows: windows, items: items)
        expect(hit?.id == "cpu" && hit?.screenID == host.id && hit?.frame.width == 45, "\(String(describing: hit))")
        expect(StatusItemHitTest.hit(at: center("Item-0", on: host, in: windows), screens: screens, windows: windows, items: items) == nil,
               "another app's icon")
        expect(StatusItemHitTest.hit(at: center("tb_toggle", on: host, in: windows), screens: screens, windows: windows, items: items) == nil,
               "only the items asked about")
        let below = CGPoint(x: center("tb_stats_cpu", on: host, in: windows).x, y: 60)
        expect(StatusItemHitTest.hit(at: below, screens: screens, windows: windows, items: items) == nil, "below the bar")
        expect(StatusItemHitTest.hit(at: center("tb_stats_cpu", on: host, in: windows), screens: screens, windows: windows, items: []) == nil)
    }

    test("hit test: unnamed copies on other displays") {
        let onWide = StatusItemHitTest.hit(at: center("tb_stats_network", on: wide, in: windows), screens: screens, windows: windows, items: items)
        expect(onWide?.id == "network" && onWide?.screenID == wide.id && onWide?.frame.minY == wide.frame.minY, "\(String(describing: onWide))")
        expect(StatusItemHitTest.hit(at: center("Item-1", on: wide, in: windows), screens: screens, windows: windows, items: items) == nil)
        // The narrow display leaves out Item-1: CPU sits 38 pt further right there than on the host.
        let cpuNarrow = center("tb_stats_cpu", on: narrow)
        let hostRD = host.frame.maxX - (placed[host.id]?["tb_stats_cpu"]?.maxX ?? 0)
        let narrowRD = narrow.frame.maxX - (placed[narrow.id]?["tb_stats_cpu"]?.maxX ?? 0)
        expect(abs(hostRD - narrowRD - 38) < 0.01, "fixture: shifted by the missing icon")
        expect(StatusItemHitTest.hit(at: cpuNarrow, screens: screens, windows: windows, items: items)?.id == "cpu", "aligned from the right")
        expect(StatusItemHitTest.hit(at: center("tb_stats_network", on: narrow, in: windows), screens: screens, windows: windows, items: items)?.id == "network")
        expect(StatusItemHitTest.hit(at: center("Item-0", on: narrow, in: windows), screens: screens, windows: windows, items: items) == nil)
        // A closed lid's bar is stale: nothing there counts.
        let onLid = CGPoint(x: lid.frame.maxX - 50, y: lid.frame.minY + 10)
        expect(StatusItemHitTest.hit(at: onLid, screens: screens, windows: windows, items: items) == nil)
    }

    test("hit test: without Screen Recording, by slot from BarTap's own frames") {
        let anonymous = windows.map { w -> WindowInfo in var w = w; w.name = nil; return w }
        let hostCPU = windows.first { $0.name == "tb_stats_cpu" }!.bounds
        let hostNet = windows.first { $0.name == "tb_stats_network" }!.bounds
        let proxies = [StatusItemHitTest.Item(id: "cpu", windowName: "tb_stats_cpu", proxyFrame: hostCPU),
                       StatusItemHitTest.Item(id: "network", windowName: "tb_stats_network", proxyFrame: hostNet)]
        expect(StatusItemHitTest.hit(at: CGPoint(x: hostCPU.midX, y: 10), screens: screens, windows: anonymous, items: proxies)?.id == "cpu")
        let wideCPU = center("tb_stats_cpu", on: wide, in: windows)
        expect(StatusItemHitTest.hit(at: wideCPU, screens: screens, windows: anonymous, items: proxies)?.id == "cpu", "same slot on another display")
        expect(StatusItemHitTest.hit(at: center("Item-2", on: wide, in: windows), screens: screens, windows: anonymous, items: proxies) == nil)
        expect(StatusItemHitTest.hit(at: wideCPU, screens: screens, windows: anonymous, items: proxies.map { var i = $0; i.proxyFrame = nil; return i }) == nil,
               "no names and no frames: nothing to match")
    }

    test("hit test: aligning rows from the right") {
        func w(_ widths: [CGFloat]) -> [WindowInfo] {
            var x: CGFloat = 0
            return widths.map { width in
                defer { x += width }
                return WindowInfo(id: 0, pid: 0, ownerName: "", layer: WindowLevel.status, bounds: CGRect(x: x, y: 0, width: width, height: 24), isOnScreen: true)
            }
        }
        // b = 40 45 38 32 62 30; a leaves out the 38.
        expect(MenuBarGeometry.alignFromRight(w([40, 45, 32, 62, 30]), w([40, 45, 38, 32, 62, 30])) == [0: 0, 1: 1, 2: 3, 3: 4, 4: 5])
        // The other way round: a has an icon b doesn't.
        expect(MenuBarGeometry.alignFromRight(w([40, 45, 38, 32]), w([40, 45, 32])) == [0: 0, 1: 1, 3: 2])
        expect(MenuBarGeometry.alignFromRight(w([]), w([40])).isEmpty)
    }

    test("details: placement and footer rows") {
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let item = CGRect(x: 1000, y: 1084, width: 40, height: 33)
        expect(DetailPlacement.frame(below: item, size: CGSize(width: 300, height: 400), visible: visible) == CGRect(x: 994, y: 681, width: 300, height: 400))
        let right = DetailPlacement.frame(below: CGRect(x: 1700, y: 1084, width: 28, height: 33), size: CGSize(width: 300, height: 400), visible: visible)
        expect(right.maxX == 1722 && right.maxY == 1081, "kept inside the right edge: \(right)")
        let left = DetailPlacement.frame(below: CGRect(x: 2, y: 1084, width: 28, height: 33), size: CGSize(width: 300, height: 400), visible: visible)
        expect(left.minX == 6)
        // A second display left of the main one (negative x).
        let other = CGRect(x: -1080, y: 100, width: 1080, height: 1890)
        let there = DetailPlacement.frame(below: CGRect(x: -400, y: 1990, width: 45, height: 30), size: CGSize(width: 300, height: 500), visible: other)
        expect(there.minX == -406 && there.maxY == 1987 && other.contains(there))
        expect(DetailPlacement.rows([60, 80, 100, 22], width: 272, spacing: 6) == [0..<2, 2..<4], "the gear doesn't sit alone")
        expect(DetailPlacement.rows([60, 80, 22], width: 272, spacing: 6) == [0..<3])
        expect(DetailPlacement.rows([100, 100, 60, 100, 22], width: 272, spacing: 6) == [0..<3, 3..<5])
        expect(DetailPlacement.rows([300, 20], width: 272, spacing: 6) == [0..<1, 1..<2], "too wide for a row: its own")
        expect(DetailPlacement.rows([], width: 272, spacing: 6).isEmpty)
    }

    test("details: settings") {
        let (d, discard) = scratchDefaults()
        defer { discard() }
        let s = Settings(defaults: d)
        expect(s.statsHoverOpen && s.statsHoverDelay == 0.5, "on, 0.5 s by default")
        s.statsHoverOpen = false
        s.statsHoverDelay = 3
        expect(!Settings(defaults: d).statsHoverOpen && s.statsHoverDelay == 1.5, "clamped to 1.5 s")
        s.statsHoverDelay = 0.05
        expect(s.statsHoverDelay == 0.2)
    }
}
