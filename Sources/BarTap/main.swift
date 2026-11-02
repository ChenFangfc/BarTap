import AppKit
import BarTapCore

if let i = CommandLine.arguments.firstIndex(of: "--ai-scan"), i + 1 < CommandLine.arguments.count {
    // Headless check of the AI usage reader against this Mac's real logs.
    AIUsageEngine.storeOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let started = Date()
    let s = AIUsageEngine().scanOnce()
    let cal = Calendar.current
    print(String(format: "read in %.1f s; detected: %@", Date().timeIntervalSince(started), s.detected.map(\.rawValue).sorted().joined(separator: ", ")))
    for range in AIRange.allCases {
        let from = AIUsageBook.dayKey(range.start(containing: Date(), calendar: cal), calendar: cal)
        let parts = AIAgent.allCases.map { a -> String in
            let t = s.book.total(from: from, agents: [a], prices: { _ in nil })
            return "\(a.tag) \(t.tokens.total)"
        }
        print("\(range.rawValue) from \(from): " + parts.joined(separator: "  "))
    }
    for (agent, plan) in s.plans { print("plan \(agent.rawValue): \(plan.plan ?? "-") \(plan.windows.map { "\($0.shortName) \($0.usedPercent)%" }) credits \(plan.credits.map { "\($0)" } ?? "-")") }
    print("days kept: \(s.book.days.count), keys: \(s.book.days.values.reduce(0) { $0 + $1.count })")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--export-promo-assets"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    PromoAssets.export(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// One-time migration of settings (and the user's menu bar arrangement) from the app's
// previous name, Tidybar.
let defaults = UserDefaults.standard
if !defaults.bool(forKey: "migratedFromPreviousName"),
   let previous = defaults.persistentDomain(forName: "dev.tidybar.Tidybar"), !previous.isEmpty {
    // Never overwrite anything already set under the new name.
    for (key, value) in previous where key != "debugCommands" && defaults.object(forKey: key) == nil {
        defaults.set(value, forKey: key)
    }
}
defaults.set(true, forKey: "migratedFromPreviousName")

// One BarTap at a time: two copies (say, one still on the DMG) would fight over the same icons,
// exactly like two menu bar managers do.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}
// A little tighter than macOS's 16 pt between BarTap's own items (stats sit side by side). It is
// a registered default, so a spacing the user picked for every app (Settings › Layout) still wins.
UserDefaults.standard.register(defaults: ["NSStatusItemSpacing": 10])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
