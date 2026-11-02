import AppKit
import BarTapCore

/// Finds order keys that put an item in a chosen gap between other apps' icons (Settings › Layout).
///
/// macOS orders menu bar items by a stored key per item ("NSStatusItem Preferred Position"). Other
/// apps' keys can't be read (some live in sandbox containers) and drift from where their icons sit
/// now, so the key is found by experiment: a 3 pt status item of our own is added for a moment, the
/// window list says where macOS drew it, and it is removed again. A few tries narrow down the keys
/// that land in the gap. Nothing but our own items moves, and no input is synthesized.
final class DividerPlacer {
    private var probe: NSStatusItem?
    private(set) var busy = false
    /// Tries of the last search (debug).
    private(set) var lastTries = 0
    /// key → gap of each try in the last search (debug).
    private(set) var lastLog: [String] = []

    private static let probeName = "tb_probe"


    /// A range of keys that land in gap `gap` of `items` (left to right, measured with BarTap's
    /// items in place): `gap` icons end up left of an item with such a key. nil if none was found.
    func keys(forGap gap: Int, among items: [BarItem], estimate: Double,
              completion: @escaping ((low: Double, high: Double)?) -> Void) {
        guard !busy else { completion(nil); return }
        busy = true
        lastTries = 0
        lastLog = []
        var lo: Double?        // largest key that landed right of the gap: too small
        var hi: Double?        // smallest key that landed left of it: too large
        var inLow: Double?, inHigh: Double?
        var step = 16.0, widen = 1.0
        var offset: Double?    // centre distance minus key, from the last probe: keys follow positions locally
        // The gap's own distance from the right edge, between its two neighbours.
        let target: Double = {
            if items.isEmpty { return estimate }
            if gap == 0 { return Double(items[0].order + items[0].frame.width + 20) }
            if gap >= items.count { return Double(max(1, items[items.count - 1].order / 2)) }
            return Double(items[gap - 1].order + items[gap].order + items[gap].frame.width) / 2
        }()
        func within(_ k: Double) -> Bool { k > (lo ?? 0) && k < (hi ?? .greatestFiniteMagnitude) && k > 0.005 }
        func next() -> Double? {
            if let a = inLow, let b = inHigh {
                // Widen the range known to work until there is room for three items.
                if b - a >= 2 { return nil }
                defer { widen *= 2 }
                if lo == nil, a > 0.02 { return max(0.01, a - widen) }
                if hi == nil { return b + widen }
                if let lo, a - lo > 0.5 { return (lo + a) / 2 }
                if let hi, hi - b > 0.5 { return (b + hi) / 2 }
                return nil
            }
            // Aim with the last probe's key-to-position offset when it lands inside what is still open.
            if let offset, within(target - offset) { return target - offset }
            switch (lo, hi) {
            case let (l?, h?): return h - l > 0.01 ? (l + h) / 2 : nil
            case let (l?, nil):
                defer { step *= 2 }
                return l + step
            case let (nil, h?):
                defer { step *= 2 }
                return h > 0.02 ? max(h / 2, h - step) : nil
            default: return max(0.5, estimate)
            }
        }
        func finish() {
            busy = false
            if let a = inLow, let b = inHigh, b - a >= 0.5 { completion((a, b)) } else { completion(nil) }
        }
        func run() {
            guard lastTries < 16, let k = next() else { finish(); return }
            lastTries += 1
            measure(key: k, among: items) { [weak self] result in
                self?.lastLog.append(String(format: "%.2f→%@", k, result.map { String($0.gap) } ?? "?"))
                guard let result else { finish(); return }
                offset = Double(result.centre) - k
                if result.gap == gap {
                    inLow = min(inLow ?? k, k)
                    inHigh = max(inHigh ?? k, k)
                } else if result.gap > gap {
                    lo = max(lo ?? k, k)
                } else {
                    hi = min(hi ?? k, k)
                }
                run()
            }
        }
        run()
    }

    /// Adds the probe with `key`, reads where macOS drew it, removes it. Reports the number of
    /// `items` left of it, comparing centres (icons left of the probe shift by its width meanwhile).
    ///
    /// The probe is found in the window list (bounds need no permission) as a new status window of
    /// its own odd width: 3 pt plus macOS's padding, which no divider and no real icon has (stats
    /// items get new windows as they redraw, so newness alone won't do). Our own Accessibility
    /// frames and proxy windows can't be used for where it is: for about a second after creation
    /// they report the bar's far ends before catching up.
    private func measure(key: Double, among items: [BarItem], completion: @escaping ((gap: Int, centre: CGFloat)?) -> Void) {
        let before = Set(Self.statusWindows().map(\.id))
        UserDefaults.standard.set(key, forKey: StatusBarController.preferredPositionKey(Self.probeName))
        let item = NSStatusBar.system.statusItem(withLength: 3)
        item.autosaveName = Self.probeName
        item.behavior = []
        probe = item
        var readings: [CGFloat] = []
        func done(_ centre: CGFloat?) {
            removeProbe()
            completion(centre.map { c in (items.filter { $0.order + $0.frame.width / 2 > c }.count, c) })
        }
        func read(_ tries: Int) {
            let width = item.button?.window?.frame.width ?? 0
            let screens = SystemQueries.screens()
            let centres: [(CGFloat, Bool)] = width <= 0 ? [] : Self.statusWindows().compactMap { w in
                guard !before.contains(w.id), abs(w.bounds.width - width) < 0.75,
                      let s = screens.first(where: { MenuBarSections.inMenuBar(w.bounds, of: $0) && w.bounds.maxX <= $0.frame.maxX + 1 }) else { return nil }
                // Its centre's distance from its bar's right edge: the same on every display.
                return (MenuBarGeometry.rightDistance(of: w.bounds, on: s) + w.bounds.width / 2, w.isOnScreen)
            }
            if let c = (centres.first { $0.1 } ?? centres.first)?.0 { readings.append(c) }
            // Settled: the same place three times over 0.2 s.
            if readings.count >= 3, let l = readings.last, readings.suffix(3).allSatisfy({ abs($0 - l) < 2 }) { done(l); return }
            if tries < 25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { read(tries + 1) }
            } else {
                done(readings.last)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { read(0) }
    }

    private static func statusWindows() -> [WindowInfo] {
        SystemQueries.windows(onScreenOnly: false).filter { $0.layer == WindowLevel.status }
    }

    private func removeProbe() {
        if let p = probe { NSStatusBar.system.removeStatusItem(p) }   // also deletes its key
        probe = nil
    }
}
