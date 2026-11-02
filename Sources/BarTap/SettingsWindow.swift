import AppKit
import BarTapCore

/// What the settings UI needs from the app.
extension Notification.Name {
    /// Posted when Accessibility access is granted while BarTap runs.
    static let barTapTrustChanged = Notification.Name("BarTapTrustChanged")
}

protocol SettingsHost: AnyObject {
    var settings: Settings { get }
    var hotkeyFailures: Set<HotkeyAction> { get }
    var keepAwake: KeepAwake { get }
    var lidAwake: LidAwake { get }
    func applyHotkeys()
    func setHotkeysSuspended(_ on: Bool)
    func resetPositions()
    func revealEverything()
    func catalogSnapshot(_ completion: @escaping ([BarItem]) -> Void)
    func requestAccessibility()
    func resetAccessibility()
    func statsSnapshot() -> StatsSnapshot?
    func rereadAIHistory()
    func pickColor()
    func restartMenuBarHost()
    func reopenSettings()
    /// Reveals every icon while Settings › Layout reads the bar and captures its icons.
    func revealForLayout(_ on: Bool)
    /// Shrinks BarTap's stats items meanwhile, when the bar is too crowded to draw every icon.
    func setStatsSlim(_ on: Bool)
    /// Hidden icons are hidden right now (Settings › Layout checks which displays fit the rest).
    var barCollapsed: Bool { get }
    /// What BarTap's own stats item (by Accessibility identifier) shows right now.
    func statsItemImage(_ identifier: String) -> NSImage?
    func applyLayout(_ request: LayoutApplier.Request, progress: @escaping (Int, Int) -> Void, completion: @escaping (LayoutApplier.Report) -> Void)
    func cancelLayoutApply()
    var menuBarIsDark: Bool { get }
}

/// Built on demand and released when closed, so it costs nothing while you are not using it.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Live instances; the debug dump checks this drops to 0 after closing (no retain cycles).
    static var liveCount = 0
    private weak var host: SettingsHost?
    private var forms: [Form] = []
    /// Targets for controls built outside `Form` helpers.
    private var retained: [ClosureTarget] = []
    var onClose: (() -> Void)?

    init(host: SettingsHost) {
        self.host = host
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.title = L("BarTap Settings")
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        // Unbound builders: a pane not opened yet must not keep this controller alive.
        let panes: [(String, String, (SettingsWindowController) -> (Form) -> Void)] = [
            (L("General"), "gearshape", SettingsWindowController.buildGeneral),
            (L("Reveal"), "cursorarrow.motionlines", SettingsWindowController.buildReveal),
            (L("Hotkeys"), "command", SettingsWindowController.buildHotkeys),
            (L("Rules"), "wand.and.stars", SettingsWindowController.buildRules),
            (L("Layout"), "menubar.rectangle", SettingsWindowController.buildLayout),
            (L("Stats"), "chart.xyaxis.line", SettingsWindowController.buildStats),
            (L("Downloads"), "arrow.down.circle", SettingsWindowController.buildDownloads),
            (L("Power-ups"), "bolt", SettingsWindowController.buildPowerUps),
            (L("About"), "info.circle", SettingsWindowController.buildAbout),
        ]
        for (title, symbol, build) in panes {
            // Each pane is built the first time its tab shows: most visits touch one or two.
            let vc = PaneController { [weak self] form in
                guard let self else { return }
                build(self)(form)
                self.forms.append(form)
            }
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        // Permission state can change in System Settings while this window is open.
        NotificationCenter.default.addObserver(self, selector: #selector(refreshForms), name: .barTapTrustChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshForms), name: NSApplication.didBecomeActiveNotification, object: nil)
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        Self.liveCount += 1
    }

    deinit { Self.liveCount -= 1 }

    @objc private func refreshForms() { forms.forEach { $0.refresh() } }

    private var elementEditor: StatsElementEditor?

    private func openElementEditor(_ m: StatsModule) {
        guard let host, let window, elementEditor == nil else { return }
        let editor = StatsElementEditor(module: m, settings: host.settings, liveSnapshot: { [weak host] in host?.statsSnapshot() })
        editor.onClose = { [weak self] in self?.elementEditor = nil }
        elementEditor = editor
        if let sheet = editor.window { window.beginSheet(sheet) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        host?.setHotkeysSuspended(false)
        host?.revealForLayout(false)
        onClose?()
    }

    private var s: Settings { host!.settings }

    // MARK: Panes

    private func buildGeneral(_ f: Form) {
        f.section(L("Startup"))
        f.toggle(L("Launch BarTap at login"), get: { LoginItem.isEnabled }, set: { [weak self] on in
            if !LoginItem.set(on) {
                let a = NSAlert()
                a.messageText = L("Could not change the login item")
                a.informativeText = L("Move BarTap to the Applications folder and try again, or add it in System Settings › General › Login Items.")
                a.runModal()
            }
            // Reflect what actually happened, not what was clicked.
            self?.forms.forEach { $0.refresh() }
        })
        f.toggle(L("Start with hidden icons hidden"), get: { [unowned self] in s.startCollapsed }, set: { [unowned self] in s.startCollapsed = $0 })
        f.popup(L("Language"), options: [(AppLanguage.system.rawValue, L("System")), (AppLanguage.en.rawValue, "English"), (AppLanguage.zhHans.rawValue, "简体中文")],
                get: { [unowned self] in s.language.rawValue },
                set: { [unowned self] v in
                    s.language = AppLanguage(rawValue: v) ?? .system
                    Loc.language = s.language
                    DispatchQueue.main.async { self.host?.reopenSettings() }
                })

        f.section(L("Hiding"))
        f.toggle(L("Automatically re-hide icons"), help: L("Re-hiding waits while a menu from the menu bar is open or the pointer is in the menu bar."),
                 get: { [unowned self] in s.autoRehide }, set: { [unowned self] in s.autoRehide = $0 })
        f.slider(L("Re-hide after"), min: 1, max: 60, step: 1, format: { L("%d s", Int($0)) },
                 get: { [unowned self] in s.rehideDelay }, set: { [unowned self] in s.rehideDelay = $0 })
        f.toggle(L("Enable the Always Hidden section"),
                 help: L("Adds a ‖ divider. Icons left of it stay hidden until you ⌥-click the toggle. New apps place their icons at the far left, so they start out in this section."),
                 get: { [unowned self] in s.alwaysHiddenEnabled }, set: { [unowned self] in s.alwaysHiddenEnabled = $0 })

        f.section(L("Appearance"))
        toggleStylePopup(f)
        f.toggle(L("Show section dividers while icons are revealed"), get: { [unowned self] in s.showDivider }, set: { [unowned self] in s.showDivider = $0 })
    }

    private func buildReveal(_ f: Form) {
        f.section(L("BarTap button"))
        f.toggle(L("Show hidden icons when the pointer rests on it"),
                 help: L("Shown this way, they hide again when the pointer leaves them. Clicked open, they stay until you click elsewhere. ⌥-click also shows the Always Hidden section; right-click for the menu."),
                 get: { [unowned self] in s.toggleHoverOpen }, set: { [unowned self] in s.toggleHoverOpen = $0 })
        f.slider(L("Hover delay"), min: 0.2, max: 1.5, step: 0.1,
                 help: L("How long the pointer rests on the BarTap button, a stats item or empty menu bar space before it opens. Passing over doesn't count."),
                 format: { L("%.1f s", $0) },
                 get: { [unowned self] in s.hoverDelay }, set: { [unowned self] in s.hoverDelay = $0 })
        f.section(L("Gestures"))
        f.toggle(L("Show when hovering over empty menu bar space"), get: { [unowned self] in s.hoverReveal }, set: { [unowned self] in s.hoverReveal = $0 })
        f.toggle(L("Show or hide by scrolling in the menu bar"), get: { [unowned self] in s.scrollReveal }, set: { [unowned self] in s.scrollReveal = $0 })
        f.toggle(L("Show when clicking empty menu bar space"), get: { [unowned self] in s.emptyClickReveal }, set: { [unowned self] in s.emptyClickReveal = $0 })
        f.toggle(L("Show every section while ⌘-dragging icons"), get: { [unowned self] in s.revealWhileDragging }, set: { [unowned self] in s.revealWhileDragging = $0 })
        f.note(L("Gestures only observe events: they never move the pointer or block clicks. Without Accessibility access, \"empty space\" is limited to the area right of the notch or the right third of the bar."))

        f.section(L("Shelf"))
        f.popup(L("Shelf under the menu bar"), options: [
            (ShelfMode.off.rawValue, L("Off")),
            (ShelfMode.whenCrowded.rawValue, L("When icons don't fit (notch)")),
            (ShelfMode.always.rawValue, L("Always, instead of the menu bar")),
        ], help: L("The shelf lists hidden icons below the menu bar — handy on notched screens where revealed icons can disappear behind the camera. Requires Accessibility access."),
           get: { [unowned self] in s.shelfMode.rawValue }, set: { [unowned self] in s.shelfMode = ShelfMode(rawValue: $0) ?? .whenCrowded })
        f.button(L("Grant Accessibility Access…")) { [weak self] in self?.host?.requestAccessibility() }
    }

    private func buildHotkeys(_ f: Form) {
        f.section(L("Global shortcuts"))
        let rows: [(HotkeyAction, String)] = [
            (.toggle, L("Show / hide icons")),
            (.toggleAll, L("Show / hide all, incl. Always Hidden")),
            (.search, L("Search menu bar icons")),
            (.shelf, L("Open the shelf")),
            (.clean, L("Clean menu bar on/off")),
            (.keepAwake, L("Keep awake on/off")),
            (.downloadVideo, L("Download Video…")),
        ]
        for (action, title) in rows {
            let rec = ShortcutRecorder(combo: s.hotkey(action))
            rec.onRecordingChange = { [weak self] on in self?.host?.setHotkeysSuspended(on) }
            rec.onChange = { [weak self] combo in
                guard let self else { return }
                self.s.setHotkey(action, combo)
                self.host?.applyHotkeys()
                // Show a conflict warning right away. Registration happens once recording ends.
                DispatchQueue.main.async { self.forms.forEach { $0.refresh() } }
            }
            f.custom(title, rec)
        }
        f.note("", color: .systemOrange) { [weak self] in
            guard let failed = self?.host?.hotkeyFailures, !failed.isEmpty else { return "" }
            return L("Some shortcuts could not be registered because another app already uses them. Pick a different combination.")
        }
        f.note(L("Hotkeys use the system hotkey service; no Accessibility or Input Monitoring permission is needed. Click a field and press ⌫ to clear it."))
    }

    private func buildRules(_ f: Form) {
        f.section(L("Show hidden icons automatically when…"))
        f.toggle(L("…the active display is large"), get: { [unowned self] in s.rules.largeScreen },
                 set: { [unowned self] v in var r = s.rules; r.largeScreen = v; s.rules = r })
        f.slider(L("Minimum width"), min: 1400, max: 6000, step: 50, format: { L("%d pt", Int($0)) },
                 get: { [unowned self] in Double(s.rules.largeScreenMinWidth) },
                 set: { [unowned self] v in var r = s.rules; r.largeScreenMinWidth = CGFloat(v); s.rules = r })
        f.note(L("Your displays: %@", NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width)) pt" }.joined(separator: ", ")))

        f.toggle(L("…one of these apps is in front"), get: { [unowned self] in s.rules.apps },
                 set: { [unowned self] v in var r = s.rules; r.apps = v; s.rules = r })
        let list = f.note("") { [weak self] in
            guard let self else { return "" }
            let ids = self.s.rules.bundleIDs.sorted()
            if ids.isEmpty { return L("No apps yet.") }
            return ids.map { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
            }.joined(separator: ", ")
        }
        f.buttons([
            (L("Add App…"), { [weak self] in self?.addRuleApp(); self?.forms.forEach { $0.refresh() } }),
            (L("Clear"), { [weak self] in
                guard let self else { return }
                var r = self.s.rules; r.bundleIDs = []; self.s.rules = r
                self.forms.forEach { $0.refresh() }
            }),
        ])
        _ = list

        f.toggle(L("…the battery is low (on battery power)"), get: { [unowned self] in s.rules.lowBattery },
                 set: { [unowned self] v in var r = s.rules; r.lowBattery = v; s.rules = r })
        f.slider(L("Battery at or below"), min: 5, max: 50, step: 1, format: { "\(Int($0))%" },
                 get: { [unowned self] in Double(s.rules.lowBatteryPercent) },
                 set: { [unowned self] v in var r = s.rules; r.lowBatteryPercent = Int(v); s.rules = r })
        f.toggle(L("…there is no network connection"), get: { [unowned self] in s.rules.offline },
                 set: { [unowned self] v in var r = s.rules; r.offline = v; s.rules = r })
        f.note(L("Rules are event-driven (no polling). Clicking the toggle still hides icons; the rule applies again the next time its condition changes."))
    }

    private func addRuleApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var r = s.rules
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { r.bundleIDs.insert(id) } }
        s.rules = r
    }

    private func buildLayout(_ f: Form) {
        f.section(L("Menu bar"))
        let model = LayoutPaneModel(host: host)
        f.keep(model)
        f.note(L("Drag icons between the rows to show or hide them, and along a row to change their order (right-click an icon for the same moves). Nothing changes until you click Apply: BarTap then moves each icon with a ⌘-drag, as you would, with the pointer hidden. Leave the mouse and keyboard alone for those few seconds; using them stops it."))
        f.custom(nil, model.editor)
        let apply = NSButton(title: L("Apply"), target: nil, action: nil)
        let revert = NSButton(title: L("Revert"), target: nil, action: nil)
        for (button, run) in [(apply, { model.apply() }), (revert, { model.revert() })] {
            let t = ClosureTarget { _ in run() }
            f.keep(t)
            button.target = t
            button.action = #selector(ClosureTarget.fire(_:))
            button.bezelStyle = .rounded
        }
        f.custom(nil, NSStackView(views: [apply, revert]))
        model.applyButton = apply
        model.revertButton = revert
        f.custom(nil, model.status)
        toggleStylePopup(f)
        let allow = f.button(L("Allow Screen Recording…")) { ItemImages.request() }
        model.permissionButton = allow
        f.toggle(L("Enable the Always Hidden section"),
                 get: { [unowned self] in s.alwaysHiddenEnabled }, set: { [unowned self] in s.alwaysHiddenEnabled = $0 })
        f.button(L("Reset BarTap Positions")) { [weak self] in self?.host?.resetPositions() }
        f.onAppear { model.start() }
        f.onDisappear { model.stop() }

        f.section(L("Icon spacing"))
        f.popup(L("Spacing between icons"), options: [
            (SpacingPreset.system.rawValue, L("System default")), (SpacingPreset.compact.rawValue, L("Compact")),
            (SpacingPreset.tight.rawValue, L("Tight")), (SpacingPreset.minimal.rawValue, L("Minimal")),
        ], help: L("Tighter spacing fits more icons beside the notch. It applies to every app after you log out and back in."),
           get: { [unowned self] in s.spacingPreset.rawValue },
           set: { [unowned self] v in
               s.spacingPreset = SpacingPreset(rawValue: v) ?? .system
               Spacing.apply(s.spacingPreset)
           })
        f.button(L("Apply to System Icons Now"),
                 help: L("Restarts Control Center so Wi-Fi, battery and the clock pick up the new spacing immediately. All icons disappear for a second; an app that does not re-add its icon may need to be reopened.")) { [weak self] in
            self?.host?.restartMenuBarHost()
        }

        f.section(L("Clean menu bar"))
        f.toggle(L("Show a restore button while the menu bar is clean"),
                 help: L("Clean mode hides every third-party icon (for screenshots, recordings and presentations)."),
                 get: { [unowned self] in s.cleanShowsExitButton }, set: { [unowned self] in s.cleanShowsExitButton = $0 })
    }

    /// The expand/collapse button's look, each style shown with its icon (General and Layout).
    private func toggleStylePopup(_ f: Form) {
        let names: [ToggleIconStyle: String] = [.logo: L("BarTap logo"), .chevron: L("Arrow"), .dot: L("Dot"),
                                                .ellipsis: L("Ellipsis"), .line: L("Lines"), .grid: L("Grid")]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for style in ToggleIconStyle.allCases {
            popup.addItem(withTitle: names[style] ?? style.rawValue)
            popup.lastItem?.image = Icons.toggle(style: style, expanded: false, badge: nil)
            popup.lastItem?.representedObject = style.rawValue
        }
        let sync: () -> Void = { [weak popup, unowned self] in popup?.selectItem(at: ToggleIconStyle.allCases.firstIndex(of: s.iconStyle) ?? 0) }
        sync()
        let t = ClosureTarget { [unowned self] sender in
            guard let raw = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            s.iconStyle = ToggleIconStyle(rawValue: raw) ?? .logo
        }
        f.keep(t)
        popup.target = t
        popup.action = #selector(ClosureTarget.fire(_:))
        f.onAppear(sync)
        f.custom(L("Expand/collapse button"), popup)
    }

    private func selectPane(titled title: String) {
        guard let tabs = window?.contentViewController as? NSTabViewController,
              let i = tabs.tabViewItems.firstIndex(where: { $0.label == title }) else { return }
        tabs.selectedTabViewItemIndex = i
    }

    private func buildStats(_ f: Form) {
        f.section(L("Menu bar stats"))
        f.note(L("Lightweight system monitor: one process, no background daemon, no root helper. Details and process lists are sampled only while an item's details are open."))
        f.note(L("Pick a layout for each item, or Customize… to combine elements like iStat Menus. New items appear right of the BarTap button; arrange them, or hide some, in Layout."))
        f.button(L("Arrange in Layout…")) { [weak self] in self?.selectPane(titled: L("Layout")) }
        let modules = StatsModulesView(settings: s, liveSnapshot: { [weak self] in self?.host?.statsSnapshot() },
                                       openEditor: { [weak self] m in self?.openElementEditor(m) })
        f.custom(nil, modules)
        f.toggle(L("Combine into a single menu bar item"), help: L("Saves space beside the notch; its details show each metric in a tab."),
                 get: { [unowned self] in s.statsCombined }, set: { [unowned self] in s.statsCombined = $0 })
        f.toggle(L("Open details on hover"),
                 help: L("Rest the pointer on an item to see its details; they close when the pointer leaves them. A click keeps them open until you click elsewhere."),
                 get: { [unowned self] in s.statsHoverOpen }, set: { [unowned self] on in s.statsHoverOpen = on })

        f.section(L("AI usage"))
        let detected = AISources.detected()
        if detected.isEmpty {
            f.note(L("No supported coding agent found on this Mac yet (Claude Code, Codex, Gemini CLI, OpenCode, Kilo Code, Qwen Code, Kimi Code)."))
        }
        f.popup(L("Time range"), options: AIRange.allCases.map { ($0.rawValue, AIPanel.rangeName($0)) },
                get: { [unowned self] in s.aiRange.rawValue }, set: { [unowned self] in s.aiRange = AIRange(rawValue: $0) ?? .today })
        for agent in AIAgent.allCases where detected.contains(agent) {
            f.toggle(L("Count %@", agent.displayName), get: { [unowned self] in s.aiAgents.isEmpty || s.aiAgents.contains(agent) },
                     set: { [unowned self] on in
                         var chosen = s.aiAgents.isEmpty ? detected : s.aiAgents
                         if on { chosen.insert(agent) } else { chosen.remove(agent) }
                         s.aiAgents = chosen == detected ? [] : chosen
                     })
        }
        f.toggle(L("One segment per agent"), help: L("Each agent's numbers side by side in the menu bar, tagged CC, CX, GM…"),
                 get: { [unowned self] in s.aiPerAgent }, set: { [unowned self] in s.aiPerAgent = $0 })
        f.popup(L("Plan limits"), options: [("used", L("Show what's used")), ("left", L("Show what's left"))],
                get: { [unowned self] in s.aiPlanLeft ? "left" : "used" }, set: { [unowned self] in s.aiPlanLeft = $0 == "left" })
        f.toggle(L("Update model prices weekly"), help: L("Downloads LiteLLM's public price list from GitHub, only while AI usage is on."),
                 get: { [unowned self] in s.aiPricesOnline }, set: { [unowned self] in s.aiPricesOnline = $0 })
        f.note(L("Read from the agents' own logs on this Mac; nothing is uploaded. Cost is what the tokens would cost at API prices. Plan limits come from Claude Code's and Codex's own records."))
        f.button(L("Read History Again")) { [weak self] in self?.host?.rereadAIHistory() }

        f.section(L("Options"))
        f.slider(L("Update every"), min: 1, max: 10, step: 1,
                 help: L("1 s matches iStat Menus. Only values that changed are redrawn; a longer interval or a combined item saves a little more."),
                 format: { L("%d s", Int($0)) },
                 get: { [unowned self] in s.statsInterval }, set: { [unowned self] in s.statsInterval = $0 })
        f.toggle(L("Show temperatures in °F"), get: { [unowned self] in s.statsFahrenheit }, set: { [unowned self] in s.statsFahrenheit = $0 })
        f.toggle(L("Show network speed in bits"), get: { [unowned self] in s.statsNetworkBits }, set: { [unowned self] in s.statsNetworkBits = $0 })
        f.toggle(L("Show public IP address"), help: L("Asks api.ipify.org for your public address when you open the Network details (at most every 10 minutes)."),
                 get: { [unowned self] in s.statsShowPublicIP }, set: { [unowned self] in s.statsShowPublicIP = $0 })

        f.section(L("Time"))
        f.popup(L("Clock format"), options: ClockFormat.presets.map { ($0, StatsRenderer.clockText($0, Date())) },
                get: { [unowned self] in s.clockFormat }, set: { [unowned self] in s.clockFormat = $0 })
        let zoneBox = NSComboBox()
        zoneBox.completes = true
        zoneBox.addItems(withObjectValues: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }.sorted())
        zoneBox.placeholderString = "Asia/Shanghai"
        zoneBox.translatesAutoresizingMaskIntoConstraints = false
        zoneBox.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let addTarget = ClosureTarget { [weak self] _ in
            guard let self, TimeZone(identifier: zoneBox.stringValue) != nil else { NSSound.beep(); return }
            var list = self.s.worldClocks
            if !list.contains(zoneBox.stringValue) { list.append(zoneBox.stringValue) }
            self.s.worldClocks = list
            zoneBox.stringValue = ""
            self.forms.forEach { $0.refresh() }
        }
        retained.append(addTarget)
        let addButton = NSButton(title: L("Add"), target: addTarget, action: #selector(ClosureTarget.fire(_:)))
        addButton.bezelStyle = .rounded
        let zoneRow = NSStackView(views: [zoneBox, addButton])
        zoneRow.spacing = 8
        f.custom(L("World clocks"), zoneRow)
        f.note("") { [weak self] in
            let list = self?.s.worldClocks ?? []
            return list.isEmpty ? L("No world clocks yet.") : list.joined(separator: ", ")
        }
        f.buttons([(L("Clear World Clocks"), { [weak self] in
            self?.s.worldClocks = []
            self?.forms.forEach { $0.refresh() }
        })])

        f.section(L("Alerts"))
        f.toggle(L("Internet connection lost or restored"), get: { [unowned self] in s.alerts.networkEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.networkEnabled = v; s.alerts = a })
        f.toggle(L("Battery fully charged"), get: { [unowned self] in s.alerts.chargedEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.chargedEnabled = v; s.alerts = a })
        f.toggle(L("CPU usage stays high"), get: { [unowned self] in s.alerts.cpuEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.cpuEnabled = v; s.alerts = a })
        f.slider(L("Above"), min: 50, max: 100, step: 5, format: { "\(Int($0))%" },
                 get: { [unowned self] in Double(s.alerts.cpuPercent) }, set: { [unowned self] v in var a = s.alerts; a.cpuPercent = Int(v); s.alerts = a })
        f.slider(L("For at least"), min: 10, max: 600, step: 10, format: { L("%d s", Int($0)) },
                 get: { [unowned self] in Double(s.alerts.cpuSeconds) }, set: { [unowned self] v in var a = s.alerts; a.cpuSeconds = Int(v); s.alerts = a })
        f.toggle(L("Memory pressure is elevated"), get: { [unowned self] in s.alerts.memoryPressureEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.memoryPressureEnabled = v; s.alerts = a })
        f.toggle(L("Startup disk is almost full"), get: { [unowned self] in s.alerts.diskEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.diskEnabled = v; s.alerts = a })
        f.slider(L("Free space below"), min: 1, max: 200, step: 1, format: { "\(Int($0)) GB" },
                 get: { [unowned self] in Double(s.alerts.diskFreeGB) }, set: { [unowned self] v in var a = s.alerts; a.diskFreeGB = Int(v); s.alerts = a })
        f.toggle(L("CPU temperature is high"), get: { [unowned self] in s.alerts.temperatureEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.temperatureEnabled = v; s.alerts = a })
        f.slider(L("Temperature above"), min: 60, max: 110, step: 1, format: { "\(Int($0))°C" },
                 get: { [unowned self] in Double(s.alerts.temperatureC) }, set: { [unowned self] v in var a = s.alerts; a.temperatureC = Int(v); s.alerts = a })
        f.toggle(L("Battery is low"), get: { [unowned self] in s.alerts.batteryEnabled },
                 set: { [unowned self] v in var a = s.alerts; a.batteryEnabled = v; s.alerts = a })
        f.slider(L("Battery at or below"), min: 5, max: 50, step: 1, format: { "\(Int($0))%" },
                 get: { [unowned self] in Double(s.alerts.batteryPercent) }, set: { [unowned self] v in var a = s.alerts; a.batteryPercent = Int(v); s.alerts = a })

        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bjango.istatmenus") != nil {
            f.section("iStat Menus")
            f.note(L("iStat Menus is installed. Its menu bar items are restarted by macOS if you just quit them; turn them off inside iStat Menus (or use its Uninstall) to avoid duplicate icons and save its background CPU."))
            f.button(L("Open iStat Menus")) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bjango.istatmenus") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    private func buildPowerUps(_ f: Form) {
        f.section(L("Keep Awake"))
        f.note("") { [weak self] in L("Status: %@", self?.host?.keepAwake.statusText ?? "") }
        let options: [(String, Int?)] = [(L("15 min"), 15), (L("1 hour"), 60), (L("2 hours"), 120), (L("4 hours"), 240), (L("Indefinitely"), nil)]
        f.buttons(options.map { title, minutes in
            (title, { [weak self] in
                guard let self, let host = self.host else { return }
                host.keepAwake.start(minutes: minutes, allowDisplaySleep: self.s.keepAwakeAllowDisplaySleep)
                self.forms.forEach { $0.refresh() }
            })
        } + [(L("Turn Off"), { [weak self] in self?.host?.keepAwake.stop(); self?.forms.forEach { $0.refresh() } })])
        f.toggle(L("Let the display sleep (keep only the Mac awake)"),
                 get: { [unowned self] in s.keepAwakeAllowDisplaySleep }, set: { [unowned self] in s.keepAwakeAllowDisplaySleep = $0 })

        f.section(L("Stay Awake with Lid Closed"))
        f.note("") { [weak self] in
            self?.host?.lidAwake.isOn == true ? L("On: the Mac stays awake with the lid closed.") : L("Off: the Mac sleeps when the lid closes.")
        }
        f.buttons([
            (L("Turn On"), { [weak self] in self?.host?.lidAwake.turnOn() }),
            (L("Turn Off"), { [weak self] in self?.host?.lidAwake.turnOff() }),
        ])
        f.note(String(format: L("Turning it on asks for an administrator password (it runs pmset -a disablesleep 1); turning it off doesn't. Sleep also comes back by itself when BarTap quits, or on battery at %d%% or below. Don't put the Mac in a bag while it's on."), LidAwake.batteryMin))

        f.section(L("Color Picker"))
        f.popup(L("Copy as"), options: [("hex", "#RRGGBB"), ("rgb", "rgb(r, g, b)"), ("swiftui", "SwiftUI Color")],
                get: { [unowned self] in s.colorFormat }, set: { [unowned self] in s.colorFormat = $0 })
        f.button(L("Pick a Color")) { [weak self] in self?.host?.pickColor() }
    }

    private func buildDownloads(_ f: Form) {
        VideoDownloadSettings.build(f, settings: s)
    }

    private func buildAbout(_ f: Form) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        f.section("BarTap \(version)")
        f.note(L("A lightweight menu bar organizer. Hiding works by resizing BarTap's own divider items, without input events, event taps or cursor warps, and never blocks clicks. Icons move only when you click Apply in Settings › Layout, and that stops as soon as you touch the mouse or keyboard. The release build is checked for this automatically."))
        f.section(L("Permissions"))
        f.note("") {
            AXCatalog.isTrusted ? L("Accessibility: granted — search, shelf and per-icon features are available.")
                                : L("Accessibility: not granted — hiding works fully; search, shelf and layout lists need it.")
        }
        f.buttons([(L("Grant Accessibility Access…"), { [weak self] in self?.host?.requestAccessibility() }),
                   (L("Reset and Ask Again"), { [weak self] in self?.host?.resetAccessibility() })])
        f.note(L("Already switched on in System Settings, but still not granted? macOS is holding the permission for an earlier build of BarTap. Click Reset and Ask Again, then switch BarTap on once more."))
        f.note("") {
            ItemImages.permitted ? L("Screen Recording: granted — the shelf shows each icon as it looks in the menu bar.")
                                 : L("Screen Recording: not granted — optional; the shelf shows app icons instead of the real ones.")
        }
        f.button(L("Allow Screen Recording…")) { ItemImages.request() }
        f.section(L("Resource usage"))
        f.note("") {
            L("Memory %.1f MB · CPU time %.2f s since launch", ProcessStats.memoryMB(), ProcessStats.cpuSeconds())
        }
        f.buttons([(L("Quit BarTap"), { NSApp.terminate(nil) })])
    }
}

private final class PaneController: NSViewController {
    private let form = Form()
    private var build: ((Form) -> Void)?
    init(build: @escaping (Form) -> Void) {
        self.build = build
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        build?(form)
        build = nil
        view = form.makeView()
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        form.refresh()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        form.appeared()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        form.disappeared()
    }
}

