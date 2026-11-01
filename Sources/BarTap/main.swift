import AppKit

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

if let i = CommandLine.arguments.firstIndex(of: "--export-promo-assets"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    PromoAssets.export(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
