import AppKit
import Network
import UserNotifications
import BarTapCore

/// Owns the stats status items, their dropdowns and alerts. With no stats enabled it owns
/// nothing and the engine is stopped.
final class StatsController: NSObject, NSMenuDelegate {
    private let settings: Settings
    private let engine = StatsEngine()
    private var items: [StatsModule: NSStatusItem] = [:]
    private var combinedItem: NSStatusItem?
    /// When the last stats item was added to the bar (placement checks wait for it to settle).
    private(set) var itemsCreatedAt = Date.distantPast

    /// Window widths of the stats items, left to right (see `OwnRun`).
    func itemWindowWidths() -> [CGFloat] {
        if let c = combinedItem { return [c.button?.window?.frame.width ?? 0] }
        return settings.statsModules.compactMap { items[$0]?.button?.window?.frame.width }
    }

    /// Wanted items that don't exist yet (apply() waits for the toggle's position first).
    var awaitingItems: Bool {
        let wanted = settings.statsModules
        return settings.statsCombined ? (combinedItem == nil && !wanted.isEmpty) : wanted.contains { items[$0] == nil }
    }
    private var openPanels: [StatsModule: StatsPanel] = [:]
    private var openMenus = 0
    private var last: StatsSnapshot?
    private var aiEngine: AIUsageEngine?
    let aiPrices = AIPrices()
    private var aiSnapshot: AIUsageEngine.Snapshot?
    private var aiDisplay: AIDisplay?
    private var aiDay = ""
    private var midnight: DispatchWorkItem?
    /// Latest values, for previews in Settings.
    var latest: StatsSnapshot? { last }
    private var observers: [NSObjectProtocol] = []
    private var publicIP: (value: String, at: Date)?
    private var alertTrackers: [AlertKind: AlertTracker] = [:]
    private var notificationsAuthorized = false
    /// The toggle's stored order key, so new stats items land just right of it (Shown).
    var toggleKeyProvider: () -> Double? = { nil }
    /// Used only if no key is stored after waiting: an estimate from the toggle's geometry.
    var toggleKeyEstimate: () -> Double? = { nil }
    var openSettings: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init()
        engine.onSnapshot = { [weak self] s in self?.received(s) }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, paused) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.engine.setPaused(paused) })
        }
    }

    var options: StatsRenderer.Options {
        StatsRenderer.Options(fahrenheit: settings.statsFahrenheit, bits: settings.statsNetworkBits, clockFormat: settings.clockFormat,
                              aiTags: settings.aiPerAgent ? aiAgentsShown().map(\.tag) : [], aiPlanLeft: settings.aiPlanLeft)
    }

    /// Agents the AI item counts: the chosen ones (all, if none chosen) that exist on this Mac.
    func aiAgentsShown() -> [AIAgent] {
        let detected = aiSnapshot?.detected ?? []
        let chosen = settings.aiAgents
        return AIAgent.allCases.filter { detected.contains($0) && (chosen.isEmpty || chosen.contains($0)) }
    }

    private var pathMonitor: NWPathMonitor?
    private var lastOnline: Bool?
    private var lastCharged: Bool?

    /// Persist data-usage counters and AI usage sums (on quit).
    func flush() {
        engine.flush()
        aiEngine?.flush()
    }

    // MARK: AI usage

    /// The reader runs only while the AI item is on; turning it off frees everything it held.
    private func configureAI(_ on: Bool) {
        if on, aiEngine == nil {
            let e = AIUsageEngine()
            e.onUpdate = { [weak self] snapshot in self?.aiUpdated(snapshot) }
            aiEngine = e
            e.start()
        } else if !on, let e = aiEngine {
            e.stop()
            aiEngine = nil
            aiSnapshot = nil
            aiDisplay = nil
            midnight?.cancel()
            midnight = nil
        }
    }

    private func aiUpdated(_ snapshot: AIUsageEngine.Snapshot) {
        aiSnapshot = snapshot
        recomputeAI()
        if settings.aiPricesOnline, snapshot.progress == nil {
            aiPrices.refreshIfNeeded(hasUnpriced: aiDisplay?.total.partlyPriced == true) { [weak self] in self?.recomputeAI() }
        }
    }

    /// The menu bar summary, recomputed when usage or settings change and at midnight, never
    /// every second.
    private func recomputeAI() {
        let now = Date()
        aiDay = AIUsageBook.dayKey(now, calendar: .current)
        guard let s = aiSnapshot else { aiDisplay = nil; return }
        // Ranges start over at midnight even when nothing new is written.
        midnight?.cancel()
        if let next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) {
            let work = DispatchWorkItem { [weak self] in self?.recomputeAI() }
            midnight = work
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + next.timeIntervalSince(now), execute: work)
        }
        aiDisplay = AIDisplay.make(book: s.book, plans: s.plans, agents: aiAgentsShown(), range: settings.aiRange,
                                   now: now, calendar: .current, prices: { [aiPrices] in aiPrices.price($0) })
        last?.ai = aiDisplay
        last?.aiDetail = aiSnapshot
        render()
        for (_, panel) in openPanels { if let s = last { panel.update(s, options) } }
    }

    /// Settings › Stats › Read history again.
    func rereadAIHistory() { aiEngine?.reset() }

    // MARK: Configuration

    /// Re-reads settings: creates/removes items and (re)configures sampling.
    private var anchorRetries = 0

    func apply() {
        let wanted = settings.statsModules
        // New items are placed relative to the toggle. Right after launch the toggle may not be
        // laid out yet; wait for it (briefly) rather than dropping items into the Hidden section.
        var anchor = toggleKeyProvider()
        if awaitingItems && anchor == nil {
            if anchorRetries < 40 {
                anchorRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.apply() }
                return
            }
            anchor = toggleKeyEstimate()
        }
        anchorRetries = 0
        let combined = settings.statsCombined && !wanted.isEmpty
        if combined {
            for (_, item) in items { NSStatusBar.system.removeStatusItem(item) }
            items.removeAll()
            if combinedItem == nil {
                combinedItem = makeItem(name: "tb_stats_combined", left: anchor, right: nil)
            }
        } else {
            if let c = combinedItem { NSStatusBar.system.removeStatusItem(c); combinedItem = nil }
            for (m, item) in items where !wanted.contains(m) {
                NSStatusBar.system.removeStatusItem(item)
                items[m] = nil
            }
            // The stored keys must run strictly downwards from the toggle's in the configured
            // order (larger = further left). If they don't (the user reordered, or a key is gone),
            // start over: remove everything first, since removing an item deletes its key.
            let existing = wanted.filter { items[$0] != nil }
            if let anchor, !existing.isEmpty {
                let keys = existing.map { storedKey("tb_stats_\($0.rawValue)") }
                let chain = [anchor] + keys.compactMap { $0 }
                if keys.contains(where: { $0 == nil }) || !zip(chain, chain.dropFirst()).allSatisfy({ $0 > $1 }) {
                    removeItemsForReplacement()
                }
            }
            // New items get a key between their neighbours', so the order holds.
            for (i, m) in wanted.enumerated() where items[m] == nil {
                let left = i == 0 ? anchor : storedKey("tb_stats_\(wanted[i - 1].rawValue)") ?? anchor
                let right = wanted[(i + 1)...].lazy.compactMap { [self] n in items[n] != nil ? storedKey("tb_stats_\(n.rawValue)") : nil }.first
                items[m] = makeItem(name: "tb_stats_\(m.rawValue)", left: left, right: right)
            }
        }
        var needed = Set(wanted)
        let a = settings.alerts
        if a.cpuEnabled { needed.insert(.cpu) }
        if a.memoryPressureEnabled { needed.insert(.memory) }
        if a.diskEnabled { needed.insert(.disk) }
        if a.temperatureEnabled { needed.insert(.sensors) }
        if a.batteryEnabled || a.chargedEnabled { needed.insert(.battery) }
        if a.anyEnabled { requestNotificationPermission() }
        configureNetworkAlert(a.networkEnabled)
        configureAI(wanted.contains(.ai))
        if aiSnapshot != nil { recomputeAI() }
        needed.remove(.ai)   // not sampled by the stats engine
        engine.configure(modules: needed, interval: settings.statsInterval)
        invalidateDrawn()   // items may be new: draw everything once
        render()
    }

    /// Width the stats items occupy right of the toggle (including macOS's per-item padding).
    func shownWidth() -> CGFloat { Self.estimatedWidth(settings) }

    static func estimatedWidth(_ settings: Settings) -> CGFloat {
        let o = StatsRenderer.Options(fahrenheit: settings.statsFahrenheit, bits: settings.statsNetworkBits)
        let modules = settings.statsModules
        guard !modules.isEmpty else { return 0 }
        let widths = modules.map { StatsRenderer.width($0, settings.statsElements($0), o) }
        if settings.statsCombined { return widths.reduce(0, +) + 6 * CGFloat(modules.count - 1) + 16 }
        return widths.reduce(0) { $0 + $1 + 16 }
    }

    /// Removes every stats item and forgets their positions, so the next `apply()` places them
    /// right of the toggle again (used when the toggle itself is re-placed).
    func removeItemsForReplacement() {
        for (m, item) in items {
            NSStatusBar.system.removeStatusItem(item)
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position tb_stats_\(m.rawValue)")
        }
        items.removeAll()
        if let c = combinedItem {
            NSStatusBar.system.removeStatusItem(c)
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position tb_stats_combined")
        }
        combinedItem = nil
        drawn.removeAll()
    }

    private func storedKey(_ name: String) -> Double? {
        UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(name)") as? Double
    }

    /// macOS lays the bar out by stored keys (larger = further left), so a key just below the
    /// toggle's puts the item right of the toggle (Shown): between `left` (the toggle or the
    /// previous stats item) and `right` (the next one, if any). The proxy frames are not trusted
    /// for this: right after launch they can be stale or even swapped.
    /// Note: removing a status item also deletes its stored key; set keys after removing.
    private func makeItem(name: String, left: Double?, right: Double?) -> NSStatusItem {
        let key = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: key) == nil, let left {
            let value = right.map { (left + $0) / 2 } ?? (left - min(0.05, left / 4))
            UserDefaults.standard.set(value, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: 30)
        itemsCreatedAt = Date()
        item.autosaveName = name
        item.behavior = []
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        return item
    }

    // MARK: Rendering

    private(set) var renderSeconds: Double = 0
    private(set) var renders = 0

    private func received(_ s: StatsSnapshot) {
        var s = s
        s.ai = aiDisplay
        s.aiDetail = aiSnapshot
        last = s
        if aiSnapshot != nil, AIUsageBook.dayKey(Date(), calendar: .current) != aiDay { recomputeAI() }
        let started = CFAbsoluteTimeGetCurrent()
        render()
        renderSeconds += CFAbsoluteTimeGetCurrent() - started
        renders += 1
        for (_, panel) in openPanels { panel.update(s, options) }
        evaluateAlerts(s)
    }

    /// Last signature drawn into each item; unchanged content is never re-sent.
    private var drawn: [String: String] = [:]
    private(set) var skippedUpdates = 0
    private(set) var performedUpdates = 0

    private func render() {
        let o = options
        let now = Date()
        let optionKey = "\(o.fahrenheit)|\(o.bits)"
        for (m, item) in items {
            let elements = settings.statsElements(m)
            let width = StatsRenderer.width(m, elements, o)
            if abs(item.length - width) > 0.5 { item.length = width }
            let sig = StatsRenderer.signature(m, elements, last, o, now: now) + optionKey
            guard drawn[m.rawValue] != sig else { skippedUpdates += 1; continue }
            drawn[m.rawValue] = sig
            performedUpdates += 1
            item.button?.image = StatsRenderer.image(m, elements, last, o, now: now)
            let label = StatsRenderer.accessibilityText(m, last, o, now: now)
            if item.button?.accessibilityLabel() != label { item.button?.setAccessibilityLabel(label) }
        }
        if let item = combinedItem {
            let parts = settings.statsModules.map { (m: $0, elements: settings.statsElements($0)) }
            let gap: CGFloat = 6
            let width = max(parts.reduce(0) { $0 + StatsRenderer.width($1.m, $1.elements, o) } + gap * CGFloat(max(parts.count - 1, 0)), 10)
            if abs(item.length - width) > 0.5 { item.length = width }
            let sig = parts.map { StatsRenderer.signature($0.m, $0.elements, last, o, now: now) }.joined(separator: "#") + optionKey
            guard drawn["combined"] != sig else { skippedUpdates += 1; return }
            drawn["combined"] = sig
            let snapshot = last
            item.button?.image = StatsRenderer.bitmap(width: width) { _ in
                var x: CGFloat = 0
                for p in parts {
                    let w = StatsRenderer.width(p.m, p.elements, o)
                    NSGraphicsContext.saveGraphicsState()
                    let shift = NSAffineTransform()
                    shift.translateX(by: x, yBy: 0)
                    shift.concat()
                    StatsRenderer.drawContent(p.m, p.elements, snapshot, o, NSRect(x: 0, y: 0, width: w, height: StatsRenderer.height), now: now)
                    NSGraphicsContext.restoreGraphicsState()
                    x += w + gap
                }
            }
            item.button?.setAccessibilityLabel(parts.map { StatsRenderer.accessibilityText($0.m, last, o) }.joined(separator: ", "))
        }
    }

    /// Forget drawn signatures (appearance or settings changed) so everything redraws once.
    func invalidateDrawn() { drawn.removeAll() }

    // MARK: Menus

    private func module(for menu: NSMenu) -> StatsModule? {
        items.first { $0.value.menu === menu }?.key
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if combinedItem?.menu === menu {
            for m in settings.statsModules {
                let entry = NSMenuItem(title: title(for: m), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.delegate = self
                sub.autoenablesItems = false
                entry.submenu = sub
                entry.representedObject = m.rawValue
                menu.addItem(entry)
            }
            appendFooter(to: menu)
            return
        }
        guard let m = module(for: menu) ?? submenuModule(menu) else { return }
        let panel = makePanel(m)
        if let last { panel.update(last, options) }
        panel.compact()
        openPanels[m] = panel
        let host = NSMenuItem()
        host.view = panel
        menu.addItem(host)
        if m == .network { fetchPublicIPIfWanted(into: panel as? NetworkPanel) }
        if menu.supermenu == nil { appendFooter(to: menu, module: m) }
    }

    private func submenuModule(_ menu: NSMenu) -> StatsModule? {
        guard let parent = menu.supermenu,
              let entry = parent.items.first(where: { $0.submenu === menu }),
              let raw = entry.representedObject as? String else { return nil }
        return StatsModule(rawValue: raw)
    }

    private func title(for m: StatsModule) -> String {
        switch m {
        case .cpu: return L("CPU")
        case .gpu: return "GPU"
        case .memory: return L("Memory")
        case .disk: return L("Disk")
        case .network: return L("Network")
        case .sensors: return L("Sensors")
        case .battery: return L("Battery")
        case .time: return L("Time")
        case .ai: return L("AI usage")
        }
    }

    private func appendFooter(to menu: NSMenu, module: StatsModule? = nil) {
        menu.addItem(.separator())
        if module == .disk { appendEjectItems(to: menu) }
        let monitor = NSMenuItem(title: L("Open Activity Monitor"), action: #selector(openActivityMonitor), keyEquivalent: "")
        monitor.target = self
        menu.addItem(monitor)
        let prefs = NSMenuItem(title: L("Stats Settings…"), action: #selector(openStatsSettings), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
    }

    private func makePanel(_ m: StatsModule) -> StatsPanel {
        switch m {
        case .cpu: return CPUPanel()
        case .gpu: return GPUPanel()
        case .memory: return MemoryPanel()
        case .disk: return DiskPanel()
        case .network: return NetworkPanel()
        case .sensors: return SensorsPanel()
        case .battery: return BatteryPanel()
        case .time: return TimePanel(worldClocks: settings.worldClocks)
        case .ai: return AIPanel(settings: settings, prices: aiPrices, agents: aiAgentsShown())
        }
    }

    /// "Eject <volume>" for every removable / ejectable volume (checked when the menu opens).
    private func appendEjectItems(to menu: NSMenu) {
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var added = false
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys), v.volumeIsRootFileSystem != true,
                  v.volumeIsEjectable == true || v.volumeIsRemovable == true else { continue }
            let item = NSMenuItem(title: L("Eject %@", v.volumeLocalizedName ?? url.lastPathComponent), action: #selector(eject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
            added = true
        }
        let utility = NSMenuItem(title: L("Open Disk Utility"), action: #selector(openDiskUtility), keyEquivalent: "")
        utility.target = self
        menu.addItem(utility)
        if added { menu.addItem(.separator()) }
    }

    @objc private func eject(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        } catch {
            Toast.show(L("Couldn't eject %@", url.lastPathComponent), symbol: "exclamationmark.triangle")
        }
    }

    @objc private func openDiskUtility() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// Internet lost/restored alert: event-driven, only while enabled.
    private func configureNetworkAlert(_ on: Bool) {
        if !on {
            pathMonitor?.cancel()
            pathMonitor = nil
            lastOnline = nil
            return
        }
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastOnline = online }
                guard let previous = self.lastOnline, previous != online else { return }
                self.notify(online ? L("Back online") : L("Internet connection lost"),
                            online ? L("Your Mac is connected to the internet again.") : L("Your Mac has no internet connection."))
            }
        }
        m.start(queue: DispatchQueue(label: "bartap.alerts.path", qos: .utility))
        pathMonitor = m
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let m = module(for: menu) ?? submenuModule(menu) else { return }
        openMenus += 1
        engine.setDetail(m, true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let m = module(for: menu) ?? submenuModule(menu) else { return }
        openMenus = max(0, openMenus - 1)
        engine.setDetail(m, false)
        // Drop the panel so a closed dropdown costs nothing.
        openPanels[m] = nil
        DispatchQueue.main.async { menu.removeAllItems() }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openStatsSettings() { openSettings?() }

    // MARK: Public IP (opt-in; one HTTPS request when the dropdown opens, cached 10 minutes)

    private func fetchPublicIPIfWanted(into panel: NetworkPanel?) {
        guard settings.statsShowPublicIP else { panel?.publicIP = L("Off (enable in Settings)"); return }
        if let cached = publicIP, Date().timeIntervalSince(cached.at) < 600 { panel?.publicIP = cached.value; return }
        panel?.publicIP = "…"
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self, weak panel] data, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = text.map { $0.count <= 45 && $0.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" } } ?? false
            DispatchQueue.main.async {
                if valid, let text {
                    self?.publicIP = (text, Date())
                    panel?.publicIP = text
                } else {
                    panel?.publicIP = L("Unavailable")
                }
            }
        }.resume()
    }

    // MARK: Alerts

    private func requestNotificationPermission() {
        guard !notificationsAuthorized else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationsAuthorized = granted }
        }
    }

    private func evaluateAlerts(_ s: StatsSnapshot) {
        let a = settings.alerts
        guard a.anyEnabled else { return }
        let now = Date()
        func check(_ kind: AlertKind, hold: Double, _ met: Bool, _ title: String, _ body: @autoclosure () -> String) {
            var t = alertTrackers[kind] ?? AlertTracker(holdSeconds: hold)
            t.holdSeconds = hold
            if t.update(conditionMet: met, now: now) { notify(title, body()) }
            alertTrackers[kind] = t
        }
        if a.cpuEnabled, let c = s.cpu {
            check(.cpuAbove, hold: Double(a.cpuSeconds), c.total * 100 >= Double(a.cpuPercent),
                  L("High CPU usage"), L("CPU usage has been above %d%% for %d s.", a.cpuPercent, a.cpuSeconds))
        }
        if a.memoryPressureEnabled, s.memory != nil {
            check(.memoryPressure, hold: 10, s.pressure != .normal, L("Memory pressure"),
                  s.pressure == .critical ? L("Memory pressure is critical.") : L("Memory pressure is elevated."))
        }
        if a.diskEnabled, let boot = StatsRenderer.bootVolume(s) {
            check(.diskFreeBelow, hold: 0, boot.free < UInt64(a.diskFreeGB) * 1_073_741_824, L("Low disk space"),
                  L("Only %@ free on %@.", StatFormat.bytes(boot.free), boot.name))
        }
        if a.temperatureEnabled, let t = s.sensors?.cpu {
            check(.temperatureAbove, hold: 30, t >= Double(a.temperatureC), L("High temperature"),
                  L("CPU temperature is %@.", StatFormat.temperature(t, fahrenheit: settings.statsFahrenheit)))
        }
        if a.batteryEnabled, let b = s.battery {
            check(.batteryBelow, hold: 0, !b.onAC && b.percent <= a.batteryPercent, L("Low battery"),
                  L("Battery is at %d%%.", b.percent))
        }
        if a.chargedEnabled, let b = s.battery {
            let charged = b.charged && b.onAC
            if lastCharged == false && charged { notify(L("Battery charged"), L("Your battery is fully charged.")) }
            lastCharged = charged
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Debug

    var debugInfo: [String: Any] {
        [
            "items": items.keys.map(\.rawValue).sorted(),
            "combined": combinedItem != nil,
            "widths": Dictionary(uniqueKeysWithValues: items.map { ($0.key.rawValue, Double($0.value.length)) }),
            // Distance of each item's right edge from the bar's right edge (same on every display).
            "rds": Dictionary(uniqueKeysWithValues: items.compactMap { m, item -> (String, Double)? in
                guard let f = item.button?.window?.frame, f.width > 0,
                      let s = NSScreen.screens.first(where: { NSPointInRect(NSPoint(x: f.maxX - 0.5, y: f.maxY - 0.5), $0.frame) }) else { return nil }
                return (m.rawValue, Double(s.frame.maxX - f.maxX))
            }),
            "hasSnapshot": last != nil,
            "cpu": last?.cpu?.total ?? -1,
            "memory": last?.memory?.usedFraction ?? -1,
            "netDown": last?.netDown ?? -1,
            "cpuTemp": last?.sensors?.cpu ?? -1,
            "fans": last?.sensors?.fans.map(\.rpm) ?? [],
            "volumes": last?.volumes.map(\.name) ?? [],
            "battery": last?.battery?.percent ?? -1,
            "openPanels": openPanels.count,
            "ai": [
                "running": aiEngine != nil,
                "detected": (aiSnapshot?.detected ?? []).map(\.rawValue).sorted(),
                "progress": aiSnapshot?.progress ?? -1,
                "todayTokens": aiDisplay?.total.tokens ?? -1,
                "todayCost": aiDisplay?.total.cost ?? -1,
                "days": aiSnapshot?.book.days.count ?? 0,
                "plans": (aiSnapshot?.plans.keys.map(\.rawValue) ?? []).sorted(),
                "pricesFetched": aiPrices.fetched,
            ] as [String: Any],
            "renderMs": renderSeconds * 1000,
            "skippedUpdates": skippedUpdates,
            "performedUpdates": performedUpdates,
            "renders": renders,
            "sampleMs": lastSampleSeconds * 1000,
            "ticks": lastTicks,
        ]
    }

    private var lastSampleSeconds = 0.0
    private var lastTicks = 0
    func refreshTiming() { engine.timing { [weak self] s, t in self?.lastSampleSeconds = s; self?.lastTicks = t } }

    /// Renders every item mode and every dropdown (light + dark) to PNG (debug).
    func debugRender() {
        DebugRender.statusImages(last, options: options)
        for m in StatsModule.allCases {
            for dark in [false, true] {
                let panel = makePanel(m)
                if let last { panel.update(last, options) }
                panel.compact()
                DebugRender.view(panel, "panel_\(m.rawValue)_\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    /// Simulates opening a dropdown (debug): builds its panel and samples details for 3 s.
    func debugOpen(_ m: StatsModule) {
        let panel = makePanel(m)
        if let last { panel.update(last, options) }
        openPanels[m] = panel
        engine.setDetail(m, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.engine.setDetail(m, false)
            self?.openPanels[m] = nil
        }
    }
}
