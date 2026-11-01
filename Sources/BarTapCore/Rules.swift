import CoreGraphics

/// Automatic reveal rules ("triggers"). Everything here is event-driven by the app; this type
/// only turns the latest facts into a reveal level.
public struct RuleSettings: Equatable {
    public var largeScreen = false
    public var largeScreenMinWidth: CGFloat = 2500
    public var apps = false
    public var bundleIDs: Set<String> = []
    public var lowBattery = false
    public var lowBatteryPercent = 20
    public var offline = false

    public init() {}

    public var anyEnabled: Bool { largeScreen || (apps && !bundleIDs.isEmpty) || lowBattery || offline }
}

public struct RuleFacts: Equatable {
    public var activeScreenWidth: CGFloat?
    public var frontmostBundleID: String?
    public var batteryPercent: Int?
    public var onBatteryPower = false
    public var networkOnline = true

    public init(activeScreenWidth: CGFloat? = nil, frontmostBundleID: String? = nil,
                batteryPercent: Int? = nil, onBatteryPower: Bool = false, networkOnline: Bool = true) {
        self.activeScreenWidth = activeScreenWidth
        self.frontmostBundleID = frontmostBundleID
        self.batteryPercent = batteryPercent
        self.onBatteryPower = onBatteryPower
        self.networkOnline = networkOnline
    }
}

public enum RuleReason: String, Equatable {
    case largeScreen, app, lowBattery, offline
}

public enum RuleEngine {
    public static func evaluate(_ f: RuleFacts, _ s: RuleSettings) -> (level: RevealLevel, reasons: [RuleReason]) {
        var reasons: [RuleReason] = []
        if s.largeScreen, let w = f.activeScreenWidth, w >= s.largeScreenMinWidth { reasons.append(.largeScreen) }
        if s.apps, let id = f.frontmostBundleID, s.bundleIDs.contains(id) { reasons.append(.app) }
        if s.lowBattery, f.onBatteryPower, let p = f.batteryPercent, p <= s.lowBatteryPercent { reasons.append(.lowBattery) }
        if s.offline, !f.networkOnline { reasons.append(.offline) }
        return (reasons.isEmpty ? .collapsed : .revealed, reasons)
    }
}
