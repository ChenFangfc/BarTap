import AppKit
import ApplicationServices
import BarTapCore

/// One menu bar icon, as seen through the Accessibility API.
struct BarItem {
    enum Section: Int { case shown, hidden, alwaysHidden }

    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let identifier: String?
    let frame: CGRect
    let element: AXUIElement
    var section: Section = .shown
    /// Distance of the right edge from the bar's right edge (larger = further left).
    var order: CGFloat = 0

    /// Stable-ish identity for per-item hotkeys: bundle + AX identifier/title.
    var key: String { "\(bundleID)|\(identifier ?? title)" }

    var icon: NSImage {
        if let symbol = Icons.systemItemSymbol(for: "\(identifier ?? "") \(title)"),
           bundleID.hasPrefix("com.apple.") {
            return Icons.symbol(symbol, config: .init(pointSize: 15, weight: .regular))
        }
        return NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName)!
    }
}

/// Optional, permission-gated features (search, shelf, per-icon hotkeys) read menu bar icons via
/// Accessibility. Every call runs on a private queue with a short timeout, so a hung app can
/// never freeze BarTap; nothing here runs unless the user opens one of those features.
final class AXCatalog {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private let queue = DispatchQueue(label: "bartap.ax", qos: .userInitiated)

    init() {
        // Applies to every element we touch (children inherit the global default, not the app
        // element's value), so one hung app can never stall the queue for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }
    private var unresponsiveUntil: [pid_t: Date] = [:]
    private var inFlight = false
    private var waiters: [([BarItem]) -> Void] = []

    /// Enumerates every app's extras menu bar. Completion runs on the main thread.
    func snapshot(completion: @escaping ([BarItem]) -> Void) {
        guard Self.isTrusted else { completion([]); return }
        waiters.append(completion)
        guard !inFlight else { return }
        inFlight = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps: [(pid_t, String, String)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }
            return (app.processIdentifier, app.bundleIdentifier ?? "pid.\(app.processIdentifier)", app.localizedName ?? "")
        }
        let skip = unresponsiveUntil.filter { $0.value > Date() }.map(\.key)
        let screens = SystemQueries.screens()
        queue.async { [weak self] in
            var items: [BarItem] = []
            var own: [String: CGRect] = [:]
            var hung: [pid_t] = []
            for (pid, bundle, name) in apps where !skip.contains(pid) {
                let result = Self.items(pid: pid, bundleID: bundle, appName: name)
                if result.hung { hung.append(pid); continue }
                if pid == ownPID {
                    for item in result.items { if let id = item.identifier { own[id] = item.frame } }
                } else {
                    items.append(contentsOf: result.items)
                }
            }
            Self.classify(&items, own: own, screens: screens)
            DispatchQueue.main.async {
                guard let self else { return }
                for pid in hung { self.unresponsiveUntil[pid] = Date().addingTimeInterval(30) }
                self.inFlight = false
                let waiters = self.waiters
                self.waiters.removeAll()
                waiters.forEach { $0(items) }
            }
        }
    }

    private static func items(pid: pid_t, bundleID: String, appName: String) -> (items: [BarItem], hung: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var barRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef)
        if err == .cannotComplete { return ([], true) }
        guard err == .success, let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return ([], false) }
        let bar = barRef as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return ([], false) }
        let attrs = [kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXIdentifierAttribute, kAXHelpAttribute] as CFArray
        var out: [BarItem] = []
        for child in children {
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(child, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
                  let values = valuesRef as? [AnyObject], values.count == 6 else { continue }
            var origin = CGPoint.zero, size = CGSize.zero
            // Unsupported attributes come back as AXValues of the error type; GetValue rejects those.
            if CFGetTypeID(values[0]) == AXValueGetTypeID() { AXValueGetValue(values[0] as! AXValue, .cgPoint, &origin) }
            if CFGetTypeID(values[1]) == AXValueGetTypeID() { AXValueGetValue(values[1] as! AXValue, .cgSize, &size) }
            let title = (values[2] as? String) ?? ""
            let desc = (values[3] as? String) ?? ""
            let ident = values[4] as? String
            let help = (values[5] as? String) ?? ""
            let label = [title, desc, help].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? appName
            out.append(BarItem(pid: pid, bundleID: bundleID, appName: appName, title: label,
                               identifier: (ident?.isEmpty == false) ? ident : nil,
                               frame: CGRect(origin: origin, size: size), element: child))
        }
        return (out, false)
    }

    /// Each app's AX positions come from its own proxy windows, which macOS may place on a
    /// different display per app. Compare "distance from that bar's right edge" instead of raw x:
    /// it is the same on every display. The display is identified by the frame's top edge (each
    /// menu bar sits at its display's top), which works even for icons pushed far off-screen.
    static func rightDistance(_ f: CGRect, screens: [ScreenInfo]) -> CGFloat? {
        let rows = screens.filter { abs($0.frame.minY - f.minY) <= 2 }
        guard !rows.isEmpty else { return nil }
        let s = rows.first { $0.frame.minX <= f.maxX && f.maxX <= $0.frame.maxX + 1 }
            ?? rows.min { abs($0.frame.maxX - f.maxX) < abs($1.frame.maxX - f.maxX) }!
        return s.frame.maxX - f.maxX
    }

    /// Dividers grow leftwards from a fixed right edge, so an icon is hidden when its right edge
    /// is at or beyond the divider's left edge (measured from the right).
    private static func classify(_ items: inout [BarItem], own: [String: CGRect], screens: [ScreenInfo]) {
        guard let hidden = own["bartap.hidden"], let hiddenRD = rightDistance(hidden, screens: screens) else { return }
        let hiddenLeft = hiddenRD + hidden.width
        let alwaysLeft = own["bartap.always"].flatMap { a in rightDistance(a, screens: screens).map { $0 + a.width } }
        for i in items.indices {
            guard let rd = rightDistance(items[i].frame, screens: screens) else { continue }
            items[i].order = rd
            if let a = alwaysLeft, rd >= a - 1 {
                items[i].section = .alwaysHidden
            } else if rd >= hiddenLeft - 1 {
                items[i].section = .hidden
            } else {
                items[i].section = .shown
            }
        }
        // Left to right, as in the menu bar.
        items.sort { $0.order > $1.order }
    }

    /// "Clicks" an icon through Accessibility (AXPress), which opens its menu without moving the
    /// pointer. Menus run modally inside the target app, so a timeout here usually means success.
    func press(_ item: BarItem, completion: @escaping (Bool) -> Void) {
        queue.async {
            AXUIElementSetMessagingTimeout(item.element, 0.5)
            var err = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            if err == .actionUnsupported || err == .attributeUnsupported {
                err = AXUIElementPerformAction(item.element, "AXShowMenu" as CFString)
            }
            let ok = err == .success || err == .cannotComplete
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// x-ranges of the frontmost app's menu titles on a given display, for "empty space" detection.
    func appMenuRanges(pid: pid_t, completion: @escaping ([CGRect]) -> Void) {
        guard Self.isTrusted else { completion([]); return }
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var barRef: CFTypeRef?
            var rects: [CGRect] = []
            if AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
               let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() {
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(barRef as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        var p: CFTypeRef?, s: CFTypeRef?
                        var origin = CGPoint.zero, size = CGSize.zero
                        if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &p) == .success, let p,
                           CFGetTypeID(p) == AXValueGetTypeID() {
                            AXValueGetValue(p as! AXValue, .cgPoint, &origin)
                        }
                        if AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &s) == .success, let s,
                           CFGetTypeID(s) == AXValueGetTypeID() {
                            AXValueGetValue(s as! AXValue, .cgSize, &size)
                        }
                        if size.width > 0 { rects.append(CGRect(origin: origin, size: size)) }
                    }
                }
            }
            DispatchQueue.main.async { completion(rects) }
        }
    }
}
