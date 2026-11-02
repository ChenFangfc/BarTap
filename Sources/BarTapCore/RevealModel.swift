import Foundation

/// How much of the menu bar is revealed.
public enum RevealLevel: Int, Comparable, CustomStringConvertible {
    case collapsed = 0      // hidden + always-hidden sections pushed off-screen
    case revealed = 1       // hidden section visible
    case revealedAll = 2    // both sections visible

    public static func < (a: RevealLevel, b: RevealLevel) -> Bool { a.rawValue < b.rawValue }
    public var description: String { ["collapsed", "revealed", "revealedAll"][rawValue] }
}

/// What caused the current user-initiated reveal. Determines how it ends.
public enum RevealSource: String, Equatable {
    case click, hotkey, hover, scroll, emptyClick, command, search, shelf
    /// Opened from the BarTap button by resting on it or clicking it: closed by the pointer leaving
    /// or a click elsewhere (HoverClickPresenter), never by a timer.
    case button
}

/// Pure state machine for the reveal level. The app feeds it events; whoever owns it applies
/// `effectiveLevel` to the status items whenever it changes.
public struct RevealModel: Equatable {
    public private(set) var userLevel: RevealLevel = .collapsed
    public private(set) var userSource: RevealSource?
    public private(set) var ruleLevel: RevealLevel = .collapsed
    /// The user collapsed while a rule wanted things open; honoured until the rule changes.
    public private(set) var ruleOverridden = false
    /// ⌘-drag arranging in progress: show every section so icons can be dropped anywhere.
    public private(set) var arranging = false
    /// The divider order is wrong or unknown: never collapse (fail open).
    public var layoutBlocked = false

    public init() {}

    public var effectiveLevel: RevealLevel {
        if layoutBlocked || arranging { return .revealedAll }
        let rule = ruleOverridden ? RevealLevel.collapsed : ruleLevel
        return max(userLevel, rule)
    }

    /// Click on the toggle / main hotkey.
    public mutating func toggle(source: RevealSource) {
        if effectiveLevel == .collapsed {
            userLevel = .revealed
            userSource = source
        } else {
            collapseByUser()
        }
    }

    /// ⌥-click / always-hidden hotkey.
    public mutating func toggleAll(source: RevealSource) {
        if effectiveLevel == .revealedAll {
            collapseByUser()
        } else {
            userLevel = .revealedAll
            userSource = source
        }
    }

    /// Reveal without toggling (hover, search, shelf, URL command). Never lowers the level.
    public mutating func reveal(_ level: RevealLevel, source: RevealSource) {
        guard level > .collapsed else { return }
        if level > userLevel {
            userLevel = level
            userSource = source
        }
    }

    /// Explicit user intent to hide: also silences an active rule until that rule changes.
    public mutating func collapseByUser() {
        userLevel = .collapsed
        userSource = nil
        if ruleLevel > .collapsed { ruleOverridden = true }
    }

    /// Automatic re-hide: only undoes user reveals; rules keep holding.
    public mutating func autoRehide() {
        userLevel = .collapsed
        userSource = nil
    }

    public mutating func setRuleLevel(_ level: RevealLevel) {
        guard level != ruleLevel else { return }
        ruleLevel = level
        ruleOverridden = false
    }

    public mutating func setArranging(_ on: Bool) { arranging = on }
}

public enum RehidePolicy {
    /// Seconds after which a user reveal should be undone, or nil to keep it.
    public static func delay(for source: RevealSource?, autoRehide: Bool, delay: TimeInterval) -> TimeInterval? {
        guard let source, autoRehide else { return nil }
        switch source {
        case .button:
            return nil
        case .hover:
            // Hover reveals end when the pointer leaves the menu bar; this is only a backstop.
            return max(delay, 2)
        case .search, .shelf:
            // The opened menu blocks the re-hide while it is up (see InteractionDetector).
            return min(max(delay, 1.5), 5)
        case .click, .hotkey, .scroll, .emptyClick, .command:
            return max(delay, 1)
        }
    }

    /// How long to wait before re-checking when the user is busy with a menu.
    public static let busyRecheck: TimeInterval = 1.0
    /// After a blocking menu closes, linger briefly so the user sees what they did.
    public static let afterMenuGrace: TimeInterval = 0.8
}
