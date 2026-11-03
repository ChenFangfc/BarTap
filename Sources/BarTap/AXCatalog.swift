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
    var frame: CGRect
    let element: AXUIElement
    var section: Section = .shown
    /// Distance of the right edge from the bar's right edge (larger = further left).
    var order: CGFloat = 0

    /// Stable-ish identity for per-item hotkeys: bundle + AX identifier/title.
    var key: String { "\(bundleID)|\(identifier ?? title)" }
    /// Names one icon for its captured image: its app, its Accessibility identifier and its place
    /// among that app's icons (left to right). Titles can't be used: many carry live values (iStat
    /// Menus' "CPU 25%", a calendar's current event).
    var slotKey = ""

    var icon: NSImage {
        if let symbol = Icons.systemItemSymbol(for: "\(identifier ?? "") \(title)"),
           bundleID.hasPrefix("com.apple.") {
            return Icons.symbol(symbol, config: .init(pointSize: 15, weight: .regular))
        }
        return AppIcons.thumbnail(pid: pid, bundleID: bundleID)
    }
}

/// App icons as small thumbnails. `NSRunningApplication.icon` keeps the full icon (up to 1024 px,
/// many representations) decoded for as long as the app runs; a 24 pt bitmap is all we draw.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func thumbnail(pid: pid_t, bundleID: String) -> NSImage {
        if let hit = cache[bundleID] { return hit }
        let source = NSRunningApplication(processIdentifier: pid)?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)!
        let size = NSSize(width: 24, height: 24)
        let thumb = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            thumb.addRepresentation(rep)
        }
        cache[bundleID] = thumb
        return thumb
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

    /// macOS keys the grant to the app's code signature. A grant recorded for another build shows
    /// as switched on in System Settings, yet this build is not trusted, and relaunching doesn't
    /// help. Removing the entry lets the next request register this build.
    static func resetTrust() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.chenfangfc.BarTap"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private let queue = DispatchQueue(label: "bartap.ax", qos: .userInitiated)
    /// Window widths of our own items (main thread), to find where they really are; see `OwnRun`.
    var ownRun: (() -> OwnRun?)?

    init() {
        // Applies to every element we touch (children inherit the global default, not the app
        // element's value), so one hung app can never stall the queue for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }
    private var unresponsiveUntil: [pid_t: Date] = [:]
    private var inFlight = false
    private var waiters: [([BarItem]) -> Void] = []
    /// Bundle ID and name per running app, read once on the queue: each can be a synchronous
    /// round trip to LaunchServices, which took the main thread for tens of ms per refresh (and
    /// seconds while LaunchServices was busy). Touched only on `queue`.
    private var appInfo: [pid_t: (app: Weak<NSRunningApplication>, bundle: String, name: String, skip: Bool)] = [:]

    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    /// The apps to look at, with their bundle IDs and names (on `queue`). Terminated apps leave
    /// the list as the main run loop notices; Accessibility simply finds nothing in one meanwhile.
    /// Background-only processes (open/save panels, Quick Look, AutoFill: about half of what runs)
    /// and WebKit's helpers can't own a menu bar icon, so they aren't asked.
    private func apps(_ running: [NSRunningApplication]) -> [(pid_t, String, String)] {
        var seen = Set<pid_t>()
        var out: [(pid_t, String, String)] = []
        for app in running {
            let pid = app.processIdentifier
            seen.insert(pid)
            let entry: (bundle: String, name: String, skip: Bool)
            if let known = appInfo[pid], known.app.value === app {
                entry = (known.bundle, known.name, known.skip)
            } else {
                let bundle = app.bundleIdentifier ?? "pid.\(pid)"
                let skip = app.activationPolicy == .prohibited || bundle.hasPrefix("com.apple.WebKit.")
                entry = (bundle, app.localizedName ?? "", skip)
                appInfo[pid] = (Weak(app), entry.bundle, entry.name, skip)
            }
            if !entry.skip || pid == ProcessInfo.processInfo.processIdentifier { out.append((pid, entry.bundle, entry.name)) }
        }
        appInfo = appInfo.filter { seen.contains($0.key) }
        return out
    }

    /// Enumerates every app's extras menu bar. Completion runs on the main thread.
    func snapshot(completion: @escaping ([BarItem]) -> Void) {
        guard Self.isTrusted else { completion([]); return }
        waiters.append(completion)
        guard !inFlight else { return }
        inFlight = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        let skip = unresponsiveUntil.filter { $0.value > Date() }.map(\.key)
        let screens = SystemQueries.screens()
        let run = ownRun?()
        queue.async { [weak self] in
            guard let apps = self?.apps(running) else { return }
            var items: [BarItem] = []
            var own: [String: CGRect] = [:]
            var hung: [pid_t] = []
            for (pid, bundle, name) in apps where !skip.contains(pid) {
                let result = Self.items(pid: pid, bundleID: bundle, appName: name)
                if result.hung { hung.append(pid); continue }
                if pid == ownPID {
                    for item in result.items {
                        guard let id = item.identifier else { continue }
                        // BarTap's stats items are icons like any other: Settings › Layout arranges them.
                        if id.hasPrefix("bartap.stats.") { items.append(item) } else { own[id] = item.frame }
                    }
                } else {
                    items.append(contentsOf: result.items)
                }
            }
            // Sections from where our items really are: their Accessibility frames lag for seconds
            // after they are re-created. Those frames still say which display Accessibility uses.
            if let run, let t = own["bartap.toggle"], let ref = MenuBarSections.referenceScreen(toggle: t, screens: screens),
               let found = run.locate(screens: screens, windows: SystemQueries.windows(onScreenOnly: false)) {
                func onRef(_ f: CGRect) -> CGRect {
                    let rd = found.screen.frame.maxX - f.maxX
                    return CGRect(x: ref.frame.maxX - rd - f.width, y: ref.frame.minY + 4, width: f.width, height: 22)
                }
                own["bartap.toggle"] = onRef(found.toggle)
                own["bartap.hidden"] = onRef(found.hidden)
                if let a = found.always { own["bartap.always"] = onRef(a) }
            }
            // BarTap's own stats items: Accessibility reports their places late (and swapped for a
            // while); the window server knows, by the names it gives status item windows (their
            // autosave names, visible with Screen Recording), in the same main-display coordinates.
            let named = Dictionary(SystemQueries.windows(onScreenOnly: false).compactMap { w -> (String, CGRect)? in
                guard w.layer == WindowLevel.status, let n = w.name, n.hasPrefix("tb_stats_"),
                      screens.first(where: { $0.frame.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) })?.asleep == false else { return nil }
                return (String(n.dropFirst("tb_stats_".count)), w.bounds)
            }, uniquingKeysWith: { first, _ in first })
            for i in items.indices where items[i].pid == ownPID {
                if let id = items[i].identifier, let w = named[String(id.dropFirst("bartap.stats.".count))] { items[i].frame = w }
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
        var err = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef)
        if err == .cannotComplete {
            // Busy rather than hung (iStat Menus redraws every second): one more, longer try before
            // its icons are left out for a while.
            AXUIElementSetMessagingTimeout(app, 0.6)
            err = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef)
            if err == .cannotComplete { return ([], true) }
        }
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

    /// BarTap's own items as Accessibility reports them (it mirrors the real bar; the in-process
    /// proxy frames can lag behind), by identifier; items without one are keyed by position.
    func ownExtras(completion: @escaping ([String: CGRect]) -> Void) {
        guard Self.isTrusted else { completion([:]); return }
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async {
            var out: [String: CGRect] = [:]
            for (i, item) in Self.items(pid: pid, bundleID: "", appName: "").items.enumerated() {
                out[item.identifier ?? "item\(i)"] = item.frame
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Every app's extras, our own included, unclassified (debug).
    func rawDump(completion: @escaping ([[String: Any]]) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
            .map { ($0.processIdentifier, $0.bundleIdentifier ?? "", $0.localizedName ?? "") }
        queue.async {
            var rows: [[String: Any]] = []
            for (pid, bundle, name) in apps {
                for item in Self.items(pid: pid, bundleID: bundle, appName: name).items {
                    rows.append(["app": name, "id": item.identifier ?? "", "title": item.title,
                                 "x": Double(item.frame.minX), "y": Double(item.frame.minY), "w": Double(item.frame.width), "h": Double(item.frame.height)])
                }
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Sections from comparing every icon with our own items (see `MenuBarSections`); icons in
    /// no menu bar are dropped: they can't be revealed or opened from here.
    private static func classify(_ items: inout [BarItem], own: [String: CGRect], screens: [ScreenInfo]) {
        guard let toggle = own["bartap.toggle"], let hidden = own["bartap.hidden"] else { items.removeAll(); return }
        let result = MenuBarSections.classify(items.map(\.frame), toggle: toggle, hidden: hidden, always: own["bartap.always"], screens: screens)
        items = zip(items, result).compactMap { item, r in
            guard let r else { return nil }
            var item = item
            item.order = r.rd
            switch r.section {
            case .shown: item.section = .shown
            case .hidden: item.section = .hidden
            case .alwaysHidden: item.section = .alwaysHidden
            }
            return item
        }
        // Left to right, as in the menu bar.
        items.sort { $0.order > $1.order }
        var seen: [String: Int] = [:]
        for i in items.indices {
            let base = "\(items[i].bundleID)|\(items[i].identifier ?? "")"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            items[i].slotKey = "\(base)#\(n)"
        }
    }

    /// "Clicks" an icon through Accessibility (AXPress), which opens its menu without moving the
    /// pointer. Menus run modally inside the target app, so a timeout here usually means success.
    /// Result of the last press, for the debug dump.
    private(set) var lastPress = ""
    private(set) var lastPressed: AXUIElement?

    /// Cancels any menu that a menu bar icon has open (Accessibility only; no synthetic keys).
    func cancelOpenMenu() {
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        queue.async {
            for pid in pids {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
                      CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                var extras: CFTypeRef?
                guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &extras) == .success,
                      let items = extras as? [AXUIElement] else { continue }
                for item in items {
                    var children: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &children) == .success,
                          let list = children as? [AXUIElement] else { continue }
                    for child in list {
                        var role: CFTypeRef?
                        AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                        if (role as? String) == kAXMenuRole { AXUIElementPerformAction(child, kAXCancelAction as CFString) }
                    }
                }
            }
        }
    }

    func press(_ item: BarItem, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            AXUIElementSetMessagingTimeout(item.element, 0.5)
            var err = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            let first = err
            if err == .actionUnsupported || err == .attributeUnsupported {
                err = AXUIElementPerformAction(item.element, "AXShowMenu" as CFString)
            }
            var actions: CFArray?
            AXUIElementCopyActionNames(item.element, &actions)
            let ok = err == .success || err == .cannotComplete
            let note = "\(item.appName): press=\(first.rawValue) final=\(err.rawValue) actions=\((actions as? [String]) ?? []) frame=\(item.frame)"
            DispatchQueue.main.async {
                self?.lastPress = note
                self?.lastPressed = item.element
                completion(ok)
            }
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
