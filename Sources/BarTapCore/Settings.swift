import Foundation

public extension Notification.Name {
    static let barTapSettingsChanged = Notification.Name("BarTapSettingsChanged")
}

public enum ShelfMode: String, CaseIterable {
    case off            // reveal in the menu bar only
    case whenCrowded    // open the shelf when revealed icons cannot be drawn (notch / crowding)
    case always         // reveal into the shelf instead of the menu bar
}

public enum ToggleIconStyle: String, CaseIterable {
    case logo, chevron, dot, ellipsis, line, grid
}

public enum SpacingPreset: String, CaseIterable {
    case system, compact, tight, minimal

    /// (NSStatusItemSpacing, NSStatusItemSelectionPadding); nil = remove the overrides.
    public var values: (spacing: Int, padding: Int)? {
        switch self {
        case .system: return nil
        case .compact: return (10, 10)
        case .tight: return (6, 8)
        case .minimal: return (3, 6)
        }
    }
}

public enum HotkeyAction: String, CaseIterable {
    case toggle, toggleAll, search, shelf, clean, keepAwake
}

/// Typed facade over UserDefaults. Tests pass an isolated suite.
public final class Settings {
    public let defaults: UserDefaults
    public static let currentSchema = 1

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Settings.factoryDefaults)
        if defaults.integer(forKey: "schema") < Settings.currentSchema {
            defaults.set(Settings.currentSchema, forKey: "schema")
        }
    }

    public static let factoryDefaults: [String: Any] = [
        "autoRehide": true,
        "rehideDelay": 8.0,
        "alwaysHiddenEnabled": false,
        "showDivider": true,
        "iconStyle": ToggleIconStyle.logo.rawValue,
        "startCollapsed": true,
        "hoverReveal": false,
        "hoverDelay": 0.3,
        "scrollReveal": false,
        "emptyClickReveal": false,
        "revealWhileDragging": true,
        "shelfMode": ShelfMode.whenCrowded.rawValue,
        "language": AppLanguage.system.rawValue,
        "spacingPreset": SpacingPreset.system.rawValue,
        "cleanShowsExitButton": true,
        "keepAwakeAllowDisplaySleep": false,
        "colorFormat": "hex",
        "ruleLargeScreen": false,
        "ruleLargeScreenWidth": 2500.0,
        "ruleApps": false,
        "ruleBundleIDs": [String](),
        "ruleLowBattery": false,
        "ruleLowBatteryPercent": 20,
        "ruleOffline": false,
        "debugCommands": false,
        "hotkey.toggle": "11:\(KeyCombo.control | KeyCombo.option | KeyCombo.cmd)",   // ⌃⌥⌘B
        "hotkey.search": "3:\(KeyCombo.control | KeyCombo.option | KeyCombo.cmd)",    // ⌃⌥⌘F
    ]

    private func changed(_ key: String) {
        NotificationCenter.default.post(name: .barTapSettingsChanged, object: self, userInfo: ["key": key])
    }

    private func bool(_ k: String) -> Bool { defaults.bool(forKey: k) }
    private func setBool(_ k: String, _ v: Bool) { guard bool(k) != v else { return }; defaults.set(v, forKey: k); changed(k) }
    private func double(_ k: String) -> Double { defaults.double(forKey: k) }
    private func setDouble(_ k: String, _ v: Double) { guard double(k) != v else { return }; defaults.set(v, forKey: k); changed(k) }
    private func string(_ k: String) -> String { defaults.string(forKey: k) ?? "" }
    private func setString(_ k: String, _ v: String) { guard string(k) != v else { return }; defaults.set(v, forKey: k); changed(k) }

    // MARK: Hiding
    public var autoRehide: Bool { get { bool("autoRehide") } set { setBool("autoRehide", newValue) } }
    public var rehideDelay: Double {
        get { min(max(double("rehideDelay"), 1), 600) }
        set { setDouble("rehideDelay", min(max(newValue, 1), 600)) }
    }
    public var alwaysHiddenEnabled: Bool { get { bool("alwaysHiddenEnabled") } set { setBool("alwaysHiddenEnabled", newValue) } }
    public var showDivider: Bool { get { bool("showDivider") } set { setBool("showDivider", newValue) } }
    public var iconStyle: ToggleIconStyle {
        get { ToggleIconStyle(rawValue: string("iconStyle")) ?? .logo }
        set { setString("iconStyle", newValue.rawValue) }
    }
    public var startCollapsed: Bool { get { bool("startCollapsed") } set { setBool("startCollapsed", newValue) } }

    // MARK: Reveal gestures
    public var hoverReveal: Bool { get { bool("hoverReveal") } set { setBool("hoverReveal", newValue) } }
    public var hoverDelay: Double {
        get { min(max(double("hoverDelay"), 0), 2) }
        set { setDouble("hoverDelay", min(max(newValue, 0), 2)) }
    }
    public var scrollReveal: Bool { get { bool("scrollReveal") } set { setBool("scrollReveal", newValue) } }
    public var emptyClickReveal: Bool { get { bool("emptyClickReveal") } set { setBool("emptyClickReveal", newValue) } }
    public var revealWhileDragging: Bool { get { bool("revealWhileDragging") } set { setBool("revealWhileDragging", newValue) } }
    public var shelfMode: ShelfMode {
        get { ShelfMode(rawValue: string("shelfMode")) ?? .whenCrowded }
        set { setString("shelfMode", newValue.rawValue) }
    }

    // MARK: Misc
    public var language: AppLanguage {
        get { AppLanguage(rawValue: string("language")) ?? .system }
        set { setString("language", newValue.rawValue) }
    }
    public var spacingPreset: SpacingPreset {
        get { SpacingPreset(rawValue: string("spacingPreset")) ?? .system }
        set { setString("spacingPreset", newValue.rawValue) }
    }
    public var cleanShowsExitButton: Bool { get { bool("cleanShowsExitButton") } set { setBool("cleanShowsExitButton", newValue) } }
    public var keepAwakeAllowDisplaySleep: Bool {
        get { bool("keepAwakeAllowDisplaySleep") } set { setBool("keepAwakeAllowDisplaySleep", newValue) }
    }
    public var colorFormat: String { get { string("colorFormat") } set { setString("colorFormat", newValue) } }
    public var debugCommands: Bool { get { bool("debugCommands") } set { setBool("debugCommands", newValue) } }

    // MARK: Placement bookkeeping
    public var didPlaceItems: Bool { get { bool("didPlaceItems") } set { defaults.set(newValue, forKey: "didPlaceItems") } }
    public var onboardingShown: Bool { get { bool("onboardingShown") } set { defaults.set(newValue, forKey: "onboardingShown") } }
    /// First launch happened while the notched display's menu bar was not visible (lid closed,
    /// display asleep, full screen): place the items as soon as it is.
    public var placementPending: Bool { get { bool("placementPending") } set { defaults.set(newValue, forKey: "placementPending") } }

    // MARK: Rules
    public var rules: RuleSettings {
        get {
            var r = RuleSettings()
            r.largeScreen = bool("ruleLargeScreen")
            r.largeScreenMinWidth = CGFloat(min(max(double("ruleLargeScreenWidth"), 800), 10000))
            r.apps = bool("ruleApps")
            r.bundleIDs = Set(defaults.stringArray(forKey: "ruleBundleIDs") ?? [])
            r.lowBattery = bool("ruleLowBattery")
            r.lowBatteryPercent = min(max(defaults.integer(forKey: "ruleLowBatteryPercent"), 1), 99)
            r.offline = bool("ruleOffline")
            return r
        }
        set {
            defaults.set(newValue.largeScreen, forKey: "ruleLargeScreen")
            defaults.set(Double(newValue.largeScreenMinWidth), forKey: "ruleLargeScreenWidth")
            defaults.set(newValue.apps, forKey: "ruleApps")
            defaults.set(newValue.bundleIDs.sorted(), forKey: "ruleBundleIDs")
            defaults.set(newValue.lowBattery, forKey: "ruleLowBattery")
            defaults.set(newValue.lowBatteryPercent, forKey: "ruleLowBatteryPercent")
            defaults.set(newValue.offline, forKey: "ruleOffline")
            changed("rules")
        }
    }

    // MARK: Hotkeys
    public func hotkey(_ action: HotkeyAction) -> KeyCombo? {
        defaults.string(forKey: "hotkey.\(action.rawValue)").flatMap(KeyCombo.init(storage:))
    }

    public func setHotkey(_ action: HotkeyAction, _ combo: KeyCombo?) {
        // An explicit empty string records "cleared" so the factory default does not come back.
        defaults.set(combo?.storage ?? "", forKey: "hotkey.\(action.rawValue)")
        changed("hotkey")
    }
}
