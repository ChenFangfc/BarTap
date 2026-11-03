import AppKit
import Network
import UserNotifications
import BarTapCore

/// Owns the stats status items, their details and alerts. With no stats enabled it owns nothing
/// and the engine is stopped. Details open in a panel below the item, on hover (resting on it) or
/// on click (HoverClickPresenter); a right-click shows a small menu.
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
    private var last: StatsSnapshot?
    private var aiEngine: AIUsageEngine?
    let aiPrices = AIPrices()
    private var aiSnapshot: AIUsageEngine.Snapshot?
    private var aiDisplay: AIDisplay?
    private var aiDay = ""
    /// One timer for the AI ranges' midnight rollover, moved on each recompute. (A fresh
    /// asyncAfter per recompute kept every cancelled one pending until midnight: about a
    /// thousand a day while an agent writes its logs.)
    private var midnight: DispatchSourceTimer?
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
    /// Volume and 3-in-1 items: CoreAudio listeners, only while one of them is on.
    private var audio: AudioMonitor?
    /// Bluetooth item: paired devices and batteries, only while it is on.
    private var bluetooth: BluetoothMonitor?
    private var scrollMonitor: Any?
    /// Hover and click on the items open their details (one at a time).
    private let presenter = HoverClickPresenter()
    private let locator = StatusItemLocator()
    private var detailWindow: DetailWindow?
    /// What the open details belong to: a module, or "combined"; and the module shown.
    private var detailTarget: String?
    private var detailModule: StatsModule?
    /// The item's frame the details hang from (global Cocoa), for the hover gap test.
    private var detailItemFrame: NSRect?
    private var combinedTab: StatsModule?

    /// The image a stats item shows right now, by its Accessibility identifier ("bartap.stats.cpu").
    func itemImage(_ identifier: String) -> NSImage? {
        let name = identifier.dropFirst("bartap.stats.".count)
        if name == "combined" { return combinedItem?.button?.image }
        return StatsModule(rawValue: String(name)).flatMap { items[$0]?.button?.image }
    }

    /// The stats items by module name (debug).
    func debugItems() -> [(String, NSStatusItem)] { items.map { ($0.key.rawValue, $0.value) } }

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
            Memory.returnFreedPages(after: 1.0)
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
        // Ranges start over at midnight even when nothing new is written (wall clock: across sleep too).
        if let next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) {
            if midnight == nil {
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.setEventHandler { [weak self] in self?.recomputeAI() }
                t.resume()
                midnight = t
            }
            midnight?.schedule(wallDeadline: .now() + next.timeIntervalSince(now), leeway: .seconds(30))
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
                combinedItem = makeItem(name: "tb_stats_combined", left: anchor, right: nil, module: nil)
            }
        } else {
            if let c = combinedItem { NSStatusBar.system.removeStatusItem(c); combinedItem = nil }
            for (m, item) in items where !wanted.contains(m) {
                NSStatusBar.system.removeStatusItem(item)
                items[m] = nil
            }
            // Items that exist stay wherever they are: the user arranges them (and hides some) in
            // Settings › Layout. New ones go right of the toggle, in the configured order.
            var left = anchor
            for m in wanted where items[m] == nil {
                let item = makeItem(name: "tb_stats_\(m.rawValue)", left: left, right: nil, module: m)
                items[m] = item
                left = storedKey("tb_stats_\(m.rawValue)") ?? left
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
        let soundShown = wanted.contains(.volume) || wanted.contains(.trio)
        configureAudio(soundShown)
        configureScroll(soundShown)
        let bluetoothElements = settings.statsElements(.bluetooth)
        configureBluetooth(wanted.contains(.bluetooth),
                           batteryShown: bluetoothElements.contains(.lowestBattery) || bluetoothElements.contains(.airPods))
        needed.remove(.ai)   // not sampled by the stats engine
        needed.remove(.volume)      // event-driven (AudioMonitor)
        needed.remove(.bluetooth)   // its own schedule (BluetoothMonitor)
        engine.setPowerInBar(wanted.contains(.battery) && settings.statsElements(.battery).contains(.batteryPower))
        let power = wanted.contains(.power) ? settings.statsElements(.power) : []
        engine.setPowerNeeds(StatsEngine.PowerNeeds(parts: power.contains { [.powerCPU, .powerGPU, .powerMemory, .powerANE].contains($0) },
                                                    display: power.contains(.powerDisplay),
                                                    details: power.contains { [.adapterRated, .cycleCount].contains($0) }))
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
    private func makeItem(name: String, left: Double?, right: Double?, module: StatsModule?) -> NSStatusItem {
        let key = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: key) == nil, let left {
            let value = right.map { (left + $0) / 2 } ?? (left - min(0.05, left / 4))
            UserDefaults.standard.set(value, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: 30)
        itemsCreatedAt = Date()
        item.autosaveName = name
        item.behavior = []
        // Named for Accessibility, so Settings › Layout lists it like any other icon.
        item.button?.setAccessibilityIdentifier("bartap.stats." + (module?.rawValue ?? "combined"))
        item.button?.setAccessibilityLabel(module.map(StatsNames.module) ?? L("Stats"))
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
        hold.update(s, now: ProcessInfo.processInfo.systemUptime)
        var s = s
        s.ai = aiDisplay
        s.aiDetail = aiSnapshot
        s.audio = audio?.state
        s.bluetooth = bluetooth?.state
        s.bluetoothUpdated = bluetooth?.updated
        last = s
        if aiSnapshot != nil, AIUsageBook.dayKey(Date(), calendar: .current) != aiDay { recomputeAI() }
        let started = CFAbsoluteTimeGetCurrent()
        render()
        renderSeconds += CFAbsoluteTimeGetCurrent() - started
        renders += 1
        for (_, panel) in openPanels { panel.update(s, options) }
        evaluateAlerts(s)
    }

    /// Figures the menu bar holds until they really change (see HeldValue).
    private var hold = BarHold()

    /// Last signature drawn into each item; unchanged content is never re-sent.
    private var drawn: [String: String] = [:]
    private(set) var skippedUpdates = 0
    private(set) var performedUpdates = 0

    /// While Settings › Layout's Apply moves icons, the stats items shrink to a sliver: on a narrow
    /// (notched) bar that makes room for every icon, so each one can be reached.
    var slim = false {
        didSet {
            guard slim != oldValue else { return }
            invalidateDrawn()
            render()
        }
    }
    static let slimWidth: CGFloat = 4

    /// Items in a hidden section while it is hidden (see AppDelegate.updateDormantStats): not
    /// redrawn until they can be seen again, then brought up to date at once.
    var dormant: Set<StatsModule> = [] {
        didSet {
            guard dormant != oldValue else { return }
            for m in oldValue.subtracting(dormant) { drawn[m.rawValue] = nil }
            engine.setDormant(dormant)
            render()
        }
    }

    private func render() {
        syncPresenter()
        if slim {
            for item in Array(items.values) + [combinedItem].compactMap({ $0 }) {
                if abs(item.length - Self.slimWidth) > 0.5 { item.length = Self.slimWidth }
                if item.button?.image != nil { item.button?.image = nil }
            }
            return
        }
        let o = options
        let now = Date()
        // The menu bar shows held figures (see BarHold); the details show every reading.
        let bar = last.map(hold.apply)
        let optionKey = "\(o.fahrenheit)|\(o.bits)"
        for (m, item) in items where !dormant.contains(m) {
            let elements = settings.statsElements(m)
            let width = StatsRenderer.width(m, elements, o)
            if abs(item.length - width) > 0.5 { item.length = width }
            let sig = StatsRenderer.signature(m, elements, bar, o, now: now) + optionKey
            guard drawn[m.rawValue] != sig else { skippedUpdates += 1; continue }
            drawn[m.rawValue] = sig
            performedUpdates += 1
            item.button?.image = StatsRenderer.image(m, elements, bar, o, now: now)
            let label = StatsRenderer.accessibilityText(m, bar, o, now: now)
            if item.button?.accessibilityLabel() != label { item.button?.setAccessibilityLabel(label) }
        }
        if let item = combinedItem {
            let parts = settings.statsModules.map { (m: $0, elements: settings.statsElements($0)) }
            let gap: CGFloat = 6
            let width = max(parts.reduce(0) { $0 + StatsRenderer.width($1.m, $1.elements, o) } + gap * CGFloat(max(parts.count - 1, 0)), 10)
            if abs(item.length - width) > 0.5 { item.length = width }
            let sig = parts.map { StatsRenderer.signature($0.m, $0.elements, bar, o, now: now) }.joined(separator: "#") + optionKey
            guard drawn["combined"] != sig else { skippedUpdates += 1; return }
            drawn["combined"] = sig
            let snapshot = bar
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
            item.button?.setAccessibilityLabel(parts.map { StatsRenderer.accessibilityText($0.m, bar, o) }.joined(separator: ", "))
        }
    }

    /// Forget drawn signatures (appearance or settings changed) so everything redraws once.
    func invalidateDrawn() { drawn.removeAll() }

    // MARK: Volume, Bluetooth, 3-in-1

    private func configureAudio(_ on: Bool) {
        if on, audio == nil {
            let a = AudioMonitor()
            a.onChange = { [weak self] state in self?.audioChanged(state) }
            audio = a
            a.start()
        } else if !on, let a = audio {
            a.stop()
            audio = nil
            last?.audio = nil
        }
    }

    private func configureBluetooth(_ on: Bool, batteryShown: Bool) {
        if on, bluetooth == nil {
            let b = BluetoothMonitor()
            b.onChange = { [weak self] state, date in self?.bluetoothChanged(state, date) }
            bluetooth = b
            b.start()
        } else if !on, let b = bluetooth {
            b.stop()
            bluetooth = nil
            last?.bluetooth = nil
        }
        bluetooth?.periodic = batteryShown
    }

    /// Volume and Bluetooth arrive between engine ticks (and with no engine running at all).
    private func audioChanged(_ state: AudioState) {
        if last == nil { last = StatsSnapshot() }
        last?.audio = state
        render()
        guard let s = last else { return }
        for (m, panel) in openPanels where m == .volume || m == .trio { panel.update(s, options) }
    }

    private func bluetoothChanged(_ state: BluetoothState, _ date: Date) {
        if last == nil { last = StatsSnapshot() }
        last?.bluetooth = state
        last?.bluetoothUpdated = date
        render()
        guard let s = last else { return }
        openPanels[.bluetooth]?.update(s, options)
    }

    /// Scrolling over the Volume or 3-in-1 item changes the volume. A local monitor sees only
    /// events sent to BarTap itself, and only those over these items are used (and consumed).
    private func configureScroll(_ on: Bool) {
        if on, scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let audio = self.audio, self.isOverSoundItem(e) else { return e }
                // Momentum after the fingers lift would overshoot.
                if e.momentumPhase.isEmpty {
                    let delta = VolumeMath.scrollDelta(deltaY: Double(e.scrollingDeltaY), precise: e.hasPreciseScrollingDeltas,
                                                       inverted: e.isDirectionInvertedFromDevice)
                    if delta != 0 { audio.adjustVolume(by: delta) }
                }
                return nil
            }
        } else if !on, let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }

    private func isOverSoundItem(_ e: NSEvent) -> Bool {
        var windows = [items[.volume], items[.trio]].compactMap { $0?.button?.window }
        if let c = combinedItem?.button?.window, settings.statsModules.contains(where: { $0 == .volume || $0 == .trio }) { windows.append(c) }
        if let w = e.window { return windows.contains { $0 === w } }
        // A window-less event (not expected): go by where the pointer is.
        let p = NSEvent.mouseLocation
        return windows.contains { $0.frame.contains(p) }
    }

    private static func openSettingsPane(_ id: String) {
        if let url = URL(string: "x-apple.systempreferences:" + id) { NSWorkspace.shared.open(url) }
    }

    @objc private func openSoundSettings() { Self.openSettingsPane("com.apple.Sound-Settings.extension") }
    @objc private func openWiFiSettings() { Self.openSettingsPane("com.apple.wifi-settings-extension") }
    @objc private func openBatterySettings() { Self.openSettingsPane("com.apple.Battery-Settings.extension") }
    @objc private func openBluetoothSettings() { Self.openSettingsPane("com.apple.BluetoothSettings") }

    /// - Parameter done: success, or nil when the person cancelled.
    private func setBluetoothConnected(_ d: BluetoothDevice, _ on: Bool, _ done: @escaping (Bool?) -> Void) {
        let perform = { [weak self] in
            BluetoothControl.shared.setConnected(on, address: d.address) { ok in
                done(ok)
                // The connection settles over a second or two; read the devices again after it.
                self?.bluetooth?.refresh(after: ok ? 2 : 0.5)
            }
        }
        guard !on, [.mouse, .keyboard, .trackpad, .gamepad].contains(d.kind) else { perform(); return }
        // Disconnecting an input device can leave the Mac without a keyboard or pointer: ask
        // first, with the details closed.
        presenter.dismiss()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("Disconnect %@?", d.name)
            alert.informativeText = L("If it's your only keyboard or pointing device, you can't use it until it connects again.")
            alert.addButton(withTitle: L("Disconnect"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { perform() } else { done(nil) }
        }
    }

    // MARK: Details (hover / click)

    /// Items take clicks themselves (no menu; makeItem's is dropped), and the presenter follows
    /// the settings. Runs with every render; does nothing when nothing changed.
    private func syncPresenter() {
        if !presenterReady { configurePresenter() }
        let all = items.map { ($0.key.rawValue, $0.value) } + (combinedItem.map { [("combined", $0)] } ?? [])
        for (_, item) in all where item.menu != nil || item.button?.action != #selector(itemButton(_:)) {
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(itemButton(_:))
            item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        var config = presenter.config
        config.hoverEnabled = settings.statsHoverOpen
        config.dwell = settings.statsHoverDelay
        if config != presenter.config { presenter.config = config }
        presenter.hoverActive = settings.statsHoverOpen && !all.isEmpty
        // Details whose item went away (or that became the combined item) close.
        if let t = detailTarget, !all.contains(where: { $0.0 == t }) { presenter.dismiss() }
    }

    private var presenterReady = false

    private func configurePresenter() {
        presenterReady = true
        // Another Space or a display change: the details' item isn't where they hang from any more.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.presenter.dismiss()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.presenter.dismiss()
        })
        locator.items = { [weak self] in self?.hitItems() ?? [] }
        presenter.inBar = { [weak self] p in self?.locator.inMenuBar(p) ?? false }
        presenter.locate = { [weak self] p in self?.locator.hit(at: p) }
        presenter.contains = { [weak self] p in self?.detailsContain(p) ?? false }
        presenter.open = { [weak self] id, mode, frame in self?.openDetails(id, frame: frame, pinned: mode == .pinned) }
        // Pinned by a click: the details take the keyboard like a menu (Esc closes them).
        presenter.pin = { [weak self] in self?.detailWindow?.makeKey() }
        presenter.close = { [weak self] in self?.closeDetails() }
    }

    /// Our items for the hit test: window names and in-process frames (global CG).
    private func hitItems() -> [StatusItemHitTest.Item] {
        let all = items.map { ($0.key.rawValue, $0.value) } + (combinedItem.map { [("combined", $0)] } ?? [])
        return all.map { id, item in
            StatusItemHitTest.Item(id: id, windowName: "tb_stats_\(id)",
                                   proxyFrame: item.button?.window.map { SystemQueries.cgRect(fromCocoa: $0.frame) })
        }
    }

    private func item(for id: String) -> NSStatusItem? {
        id == "combined" ? combinedItem : StatsModule(rawValue: id).flatMap { items[$0] }
    }

    @objc private func itemButton(_ sender: NSStatusBarButton) {
        let all = items.map { ($0.key.rawValue, $0.value) } + (combinedItem.map { [("combined", $0)] } ?? [])
        guard let id = all.first(where: { $0.1.button === sender })?.0 else { return }
        let e = NSApp.currentEvent
        if e?.type == .rightMouseDown || (e?.type == .leftMouseDown && e?.modifierFlags.contains(.control) == true) {
            presenter.dismiss()
            showContextMenu()
        } else {
            presenter.itemClicked(id)
        }
    }

    /// Right-click: a small menu at the pointer (on whichever display was clicked).
    private func showContextMenu() {
        let menu = NSMenu()
        let prefs = NSMenuItem(title: L("Stats Settings…"), action: #selector(openStatsSettings), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Inside the open details, or the gap between them and their item (crossing it is not leaving).
    private func detailsContain(_ p: NSPoint) -> Bool {
        guard let w = detailWindow, w.isVisible else { return false }
        let f = w.frame
        if f.insetBy(dx: -2, dy: -2).contains(p) { return true }
        guard let item = detailItemFrame else { return false }
        let bridge = NSRect(x: min(item.minX, f.minX), y: f.maxY - 2, width: max(item.maxX, f.maxX) - min(item.minX, f.minX),
                            height: max(0, item.minY - f.maxY) + 4)
        return bridge.contains(p)
    }

    /// Opens an item's details below it: on the display it was hovered or clicked on (`frame`,
    /// global CG), else below the item where BarTap itself has it.
    private func openDetails(_ id: String, frame: CGRect?, pinned: Bool) {
        closeDetails()
        let modules = settings.statsModules
        let module: StatsModule
        if id == "combined" {
            guard let first = modules.first else { return }
            module = combinedTab.flatMap { modules.contains($0) ? $0 : nil } ?? first
        } else {
            guard let m = StatsModule(rawValue: id) else { return }
            module = m
        }
        detailTarget = id
        let tabs = id == "combined" ? DetailTabs(modules: modules, selected: module) { [weak self] m in self?.switchTab(m) } : nil
        let panel = startPanel(module)
        let content = DetailContent(panel: panel, footer: DetailFooter(actions: footerActions(for: module), width: panel.frame.width), tabs: tabs)
        let window = DetailWindow(content: content)
        window.onCancel = { [weak self] in self?.presenter.dismiss() }
        detailWindow = window
        let itemCocoa: NSRect? = frame.map { f in
            NSRect(x: f.minX, y: SystemQueries.mainScreenHeight - f.maxY, width: f.width, height: f.height)
        } ?? item(for: id)?.button?.window?.frame
        detailItemFrame = itemCocoa
        let anchor = itemCocoa ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        window.show(below: anchor, on: screen)
        if pinned { window.makeKey() }
        // Like a menu: the item stays highlighted while its details are open (again once the
        // click that opened them is over, which un-highlights the button).
        for delay in [0.0, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.detailTarget == id else { return }
                self.item(for: id)?.button?.highlight(true)
            }
        }
    }

    /// Builds a module's panel and starts sampling its details (as a dropdown did).
    private func startPanel(_ m: StatsModule) -> StatsPanel {
        let panel = makePanel(m)
        if let last { panel.update(last, options) }
        panel.compact()
        openPanels[m] = panel
        detailModule = m
        if m == .bluetooth { bluetooth?.setDetail(true) } else if m != .volume { engine.setDetail(m, true) }
        if m == .network { fetchPublicIPIfWanted(into: panel as? NetworkPanel) }
        return panel
    }

    private func stopPanel(_ m: StatsModule) {
        if m == .bluetooth { bluetooth?.setDetail(false) } else if m != .volume { engine.setDetail(m, false) }
        // Drop the panel so closed details cost nothing.
        openPanels[m] = nil
    }

    private func switchTab(_ m: StatsModule) {
        guard let window = detailWindow, m != detailModule else { return }
        let content = window.chrome.content
        if let old = detailModule { stopPanel(old) }
        combinedTab = m
        let panel = startPanel(m)
        content.replace(panel: panel, footer: DetailFooter(actions: footerActions(for: m), width: panel.frame.width))
        window.fitContent()
    }

    private func closeDetails() {
        guard let window = detailWindow else { return }
        window.orderOut(nil)
        detailWindow = nil
        if let m = detailModule { stopPanel(m) }
        if let id = detailTarget { item(for: id)?.button?.highlight(false) }
        detailModule = nil
        detailTarget = nil
        detailItemFrame = nil
        // A panel's views, images and the readings behind them are gone: give the pages back.
        Memory.returnFreedPages(after: 1.0)
    }

    /// The details' bottom row: what the menu's footer offered.
    private func footerActions(for module: StatsModule) -> [DetailAction] {
        let volumes = module == .disk ? ejectableVolumes() : []
        return DetailActions.list(for: module, muted: audio?.state?.muted == true, canMute: audio?.state?.canMute == true,
                                  volumes: volumes.map(\.name)) { [weak self] command in self?.run(command, volumes: volumes.map(\.url)) }
    }

    private func run(_ command: DetailCommand, volumes: [URL]) {
        switch command {
        case .eject(let i): if i < volumes.count { eject(volumes[i]) }
        case .diskUtility: openDiskUtility()
        case .activityMonitor: openActivityMonitor()
        case .soundSettings: openSoundSettings()
        case .bluetoothSettings: openBluetoothSettings()
        case .wifiSettings: openWiFiSettings()
        case .batterySettings: openBatterySettings()
        case .statsSettings: openStatsSettingsFromDetails()
        case .toggleMute:
            audio?.toggleMute()
            // The button's title follows the new state.
            if detailModule == .trio, let window = detailWindow {
                let panel = window.chrome.content.panel
                window.chrome.content.replace(panel: panel, footer: DetailFooter(actions: footerActions(for: .trio), width: panel.frame.width))
                window.fitContent()
            }
        }
    }

    private func openStatsSettingsFromDetails() {
        presenter.dismiss()
        openSettings?()
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
        case .power: return L("Power")
        case .time: return L("Time")
        case .ai: return L("AI usage")
        case .volume: return L("Volume")
        case .bluetooth: return L("Bluetooth")
        case .trio: return L("3-in-1 status")
        }
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
        case .power: return PowerPanel(hasBattery: BatteryReader.quick() != nil, interval: settings.statsInterval)
        case .time: return TimePanel(worldClocks: settings.worldClocks)
        case .ai: return AIPanel(settings: settings, prices: aiPrices, agents: aiAgentsShown())
        case .volume: return VolumePanel(audio: audio, state: audio?.state)
        case .bluetooth:
            let p = BluetoothPanel(state: bluetooth?.state, updated: bluetooth?.updated, access: BluetoothControl.access)
            p.onSetConnected = { [weak self] d, on, done in self?.setBluetoothConnected(d, on, done) }
            return p
        case .trio: return TrioPanel()
        }
    }

    /// Removable / ejectable volumes (checked when the disk details open).
    private func ejectableVolumes() -> [(name: String, url: URL)] {
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeLocalizedNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: keys), v.volumeIsRootFileSystem != true,
                  v.volumeIsEjectable == true || v.volumeIsRemovable == true else { return nil }
            return (v.volumeLocalizedName ?? url.lastPathComponent, url)
        }
    }

    private func eject(_ url: URL) {
        presenter.dismiss()
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
            "batteryWatts": last?.power?.battery ?? -999,
            "audio": ["running": audio != nil, "volume": last?.audio?.volume ?? -1, "muted": last?.audio?.muted ?? false,
                      "outputs": last?.audio?.outputs.count ?? -1, "scrollMonitor": scrollMonitor != nil] as [String: Any],
            "bluetooth": ["running": bluetooth != nil, "connected": last?.bluetooth?.connected.count ?? -1,
                          "devices": last?.bluetooth?.devices.count ?? -1,
                          "age": bluetooth?.updated.map { Date().timeIntervalSince($0) } ?? -1] as [String: Any],
            "wifiBars": last?.wifi?.bars ?? -1,
            "openPanels": openPanels.count,
            "powerDots": (openPanels[.power] as? PowerPanel)?.movingDots ?? -1,
            "power": last?.powerReading.map { r in
                ["system": r.system ?? -1, "adapter": r.adapter ?? -1, "battery": r.battery ?? -1,
                 "parts": Dictionary(uniqueKeysWithValues: r.components.map { ($0.key.rawValue, $0.value) })] as [String: Any]
            } ?? [:],
            "dormant": dormant.map(\.rawValue).sorted(),
            "slim": slim,
            "details": (["target": detailTarget ?? "-", "module": detailModule?.rawValue ?? "-",
                         "frame": detailWindow.map { NSStringFromRect($0.frame) } ?? "-"] as [String: Any])
                .merging(presenter.debugInfo) { a, _ in a },
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
                (panel as? PowerPanel)?.drawStill()
                if let last { panel.update(last, options) }
                panel.compact()
                DebugRender.view(panel, "panel_\(m.rawValue)_\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    /// Opens a stats item's details from the shelf or search (its Accessibility identifier,
    /// "bartap.stats.cpu"), hanging from `frame` (global CG). Pressing a hidden item of our own
    /// through Accessibility fails (-25200), so the shelf showed "Couldn't open".
    func showDetails(identifier: String, below frame: CGRect) -> Bool {
        let id = String(identifier.dropFirst("bartap.stats.".count))
        guard item(for: id) != nil else { return false }
        presenter.openPinned(id, at: frame)
        return true
    }

    /// Opens an item's details as a click on it would ("cpu", "combined"…), or "close" (debug).
    func debugShowDetails(_ id: String) {
        if id == "close" { presenter.dismiss() } else { presenter.itemClicked(id) }
    }

    /// Simulates opening a dropdown (debug): builds its panel and samples details for 3 s.
    func debugOpen(_ m: StatsModule) {
        let panel = makePanel(m)
        if let last { panel.update(last, options) }
        openPanels[m] = panel
        if m == .bluetooth { bluetooth?.setDetail(true) } else if m != .volume { engine.setDetail(m, true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if m == .bluetooth { self?.bluetooth?.setDetail(false) } else if m != .volume { self?.engine.setDetail(m, false) }
            self?.openPanels[m] = nil
        }
    }
}

/// The menu bar's held figures: what changes every second by a hair (CPU %, rates, memory,
/// temperature) redraws only on a real change, or after a few seconds. Graphs, per-core bars and
/// the details still follow every reading.
struct BarHold {
    private var cpu = HeldValue(), gpu = HeldValue(), temp = HeldValue()
    private var up = HeldValue(), down = HeldValue(), read = HeldValue(), write = HeldValue()
    private var memory: MemoryBreakdown?
    private var memorySince: TimeInterval = 0

    mutating func update(_ s: StatsSnapshot, now: TimeInterval) {
        cpu.update(s.cpu?.total, now: now, significant: HeldValue.percent)
        gpu.update(s.gpu, now: now, significant: HeldValue.percent)
        temp.update(s.sensors?.cpu, now: now, significant: HeldValue.temperature)
        up.update(s.netUp, now: now, significant: HeldValue.rate)
        down.update(s.netDown, now: now, significant: HeldValue.rate)
        read.update(s.diskRead, now: now, significant: HeldValue.rate)
        write.update(s.diskWrite, now: now, significant: HeldValue.rate)
        // Memory as a whole (its used/free and percentage go together): 150 MB or a point.
        guard let m = s.memory else { memory = nil; return }
        if let shown = memory, abs(Double(m.used) - Double(shown.used)) < 150 * 1_048_576,
           abs(m.usedFraction - shown.usedFraction) < 0.01, now - memorySince < 5 { return }
        memory = m
        memorySince = now
    }

    func apply(_ snapshot: StatsSnapshot) -> StatsSnapshot {
        var s = snapshot
        if let v = cpu.shown, s.cpu != nil { s.cpu?.total = v }
        if let v = gpu.shown, s.gpu != nil { s.gpu = v }
        if let v = temp.shown, s.sensors?.cpu != nil { s.sensors?.cpu = v }
        if let v = up.shown { s.netUp = v }
        if let v = down.shown { s.netDown = v }
        if let v = read.shown { s.diskRead = v }
        if let v = write.shown { s.diskWrite = v }
        if let m = memory, s.memory != nil { s.memory = m }
        return s
    }
}
