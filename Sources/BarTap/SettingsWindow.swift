import AppKit
import BarTapCore

/// What the settings UI needs from the app.
protocol SettingsHost: AnyObject {
    var settings: Settings { get }
    var hotkeyFailures: Set<HotkeyAction> { get }
    var keepAwake: KeepAwake { get }
    func applyHotkeys()
    func setHotkeysSuspended(_ on: Bool)
    func resetPositions()
    func revealEverything()
    func catalogSnapshot(_ completion: @escaping ([BarItem]) -> Void)
    func requestAccessibility()
    func pickColor()
    func restartMenuBarHost()
    func reopenSettings()
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

        let panes: [(String, String, (Form) -> Void)] = [
            (L("General"), "gearshape", buildGeneral),
            (L("Reveal"), "cursorarrow.motionlines", buildReveal),
            (L("Hotkeys"), "command", buildHotkeys),
            (L("Rules"), "wand.and.stars", buildRules),
            (L("Layout"), "menubar.rectangle", buildLayout),
            (L("Stats"), "chart.xyaxis.line", buildStats),
            (L("Power-ups"), "bolt", buildPowerUps),
            (L("About"), "info.circle", buildAbout),
        ]
        for (title, symbol, build) in panes {
            let form = Form()
            build(form)
            forms.append(form)
            let vc = PaneController(form: form)
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        Self.liveCount += 1
    }

    deinit { Self.liveCount -= 1 }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        host?.setHotkeysSuspended(false)
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
        f.popup(L("Toggle icon"), options: [
            (ToggleIconStyle.logo.rawValue, L("BarTap")), (ToggleIconStyle.chevron.rawValue, L("Chevron")),
            (ToggleIconStyle.dot.rawValue, L("Dot")), (ToggleIconStyle.ellipsis.rawValue, L("Ellipsis")),
            (ToggleIconStyle.line.rawValue, L("Lines")), (ToggleIconStyle.grid.rawValue, L("Grid")),
        ], get: { [unowned self] in s.iconStyle.rawValue }, set: { [unowned self] in s.iconStyle = ToggleIconStyle(rawValue: $0) ?? .chevron })
        f.toggle(L("Show section dividers while icons are revealed"), get: { [unowned self] in s.showDivider }, set: { [unowned self] in s.showDivider = $0 })
    }

    private func buildReveal(_ f: Form) {
        f.section(L("Click"))
        f.note(L("Click the toggle to show or hide icons. ⌥-click also shows the Always Hidden section. Right-click for the menu."))
        f.section(L("Gestures"))
        f.toggle(L("Show when hovering over empty menu bar space"), get: { [unowned self] in s.hoverReveal }, set: { [unowned self] in s.hoverReveal = $0 })
        f.slider(L("Hover delay"), min: 0, max: 1.5, step: 0.05, format: { String(format: L("%.2f s"), $0) },
                 get: { [unowned self] in s.hoverDelay }, set: { [unowned self] in s.hoverDelay = $0 })
        f.toggle(L("Show or hide by scrolling in the menu bar"), get: { [unowned self] in s.scrollReveal }, set: { [unowned self] in s.scrollReveal = $0 })
        f.toggle(L("Show when clicking empty menu bar space"), get: { [unowned self] in s.emptyClickReveal }, set: { [unowned self] in s.emptyClickReveal = $0 })
        f.toggle(L("Show every section while ⌘-dragging icons"), get: { [unowned self] in s.revealWhileDragging }, set: { [unowned self] in s.revealWhileDragging = $0 })
        f.note(L("Gestures only observe events; BarTap never moves the pointer or blocks clicks. Without Accessibility access, \"empty space\" is limited to the area right of the notch or the right third of the bar."))

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
        f.section(L("How it works"))
        f.note(L("Hold ⌘ and drag icons in the menu bar. Icons left of the │ divider are hidden; icons left of the ‖ divider are always hidden; icons right of the BarTap toggle are always shown. BarTap never moves icons itself."))
        f.buttons([
            (L("Reveal Everything"), { [weak self] in self?.host?.revealEverything() }),
            (L("Reset BarTap Positions"), { [weak self] in self?.host?.resetPositions() }),
        ])

        f.section(L("Current layout"))
        let lists = LayoutListView()
        f.custom(nil, lists)
        f.buttons([(L("Refresh"), { [weak self] in self?.reloadLayout(lists) })])
        reloadLayout(lists)

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

    private func reloadLayout(_ view: LayoutListView) {
        guard AXCatalog.isTrusted else {
            view.show(message: L("Grant Accessibility access to see which icons are in each section."))
            return
        }
        host?.catalogSnapshot { items in view.show(items: items) }
    }

    private func buildStats(_ f: Form) {
        f.section(L("Menu bar stats"))
        f.note(L("Lightweight system monitor: one process, no background daemon, no root helper. Details and process lists are sampled only while a dropdown is open."))
        let names: [(StatsModule, String)] = [
            (.cpu, L("CPU")), (.gpu, "GPU"), (.memory, L("Memory")), (.disk, L("Disk")),
            (.network, L("Network")), (.sensors, L("Sensors")), (.battery, L("Battery")), (.time, L("Time")),
        ]
        let modeNames: [StatsMode: String] = [
            .percent: L("Percentage"), .graph: L("Graph"), .graphPercent: L("Graph + percentage"), .cores: L("Per-core bars"),
            .pie: L("Pie"), .piePercent: L("Pie + percentage"), .usedAmount: L("Used amount"), .freeAmount: L("Free space"),
            .activity: L("Read / write"), .rates: L("Upload / download"), .cpuTemperature: L("CPU temperature"),
            .temperatureAndFan: L("Temperature + fan"), .power: L("Power (W)"), .iconPercent: L("Icon + percentage"),
            .timeRemaining: L("Time remaining"), .clock: L("Clock"),
        ]
        for (module, name) in names {
            let check = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 190).isActive = true
            for mode in module.modes { popup.addItem(withTitle: modeNames[mode] ?? mode.rawValue) }
            let sync = { [weak self] in
                guard let s = self?.host?.settings else { return }
                check.state = s.statsModules.contains(module) ? .on : .off
                popup.selectItem(at: module.modes.firstIndex(of: s.statsMode(module)) ?? 0)
                popup.isEnabled = check.state == .on
            }
            let toggleTarget = ClosureTarget { [weak self] _ in
                guard let s = self?.host?.settings else { return }
                var list = s.statsModules
                if check.state == .on { if !list.contains(module) { list.append(module) } } else { list.removeAll { $0 == module } }
                // Keep a stable, sensible order.
                s.statsModules = StatsModule.allCases.filter { list.contains($0) }
                sync()
            }
            let popupTarget = ClosureTarget { [weak self] _ in
                guard let s = self?.host?.settings, popup.indexOfSelectedItem >= 0 else { return }
                s.setStatsMode(module, module.modes[popup.indexOfSelectedItem])
            }
            check.target = toggleTarget
            check.action = #selector(ClosureTarget.fire(_:))
            popup.target = popupTarget
            popup.action = #selector(ClosureTarget.fire(_:))
            retained.append(contentsOf: [toggleTarget, popupTarget])
            check.translatesAutoresizingMaskIntoConstraints = false
            check.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let row = NSStackView(views: [check, popup])
            row.spacing = 10
            f.custom(nil, row)
            sync()
        }
        f.toggle(L("Combine into a single menu bar item"), help: L("Saves space beside the notch; each metric gets its own submenu."),
                 get: { [unowned self] in s.statsCombined }, set: { [unowned self] in s.statsCombined = $0 })

        f.section(L("Options"))
        f.slider(L("Update every"), min: 1, max: 10, step: 1,
                 help: L("1 s matches iStat Menus. Only values that changed are redrawn; a longer interval or a combined item saves a little more."),
                 format: { L("%d s", Int($0)) },
                 get: { [unowned self] in s.statsInterval }, set: { [unowned self] in s.statsInterval = $0 })
        f.toggle(L("Show temperatures in °F"), get: { [unowned self] in s.statsFahrenheit }, set: { [unowned self] in s.statsFahrenheit = $0 })
        f.toggle(L("Show network speed in bits"), get: { [unowned self] in s.statsNetworkBits }, set: { [unowned self] in s.statsNetworkBits = $0 })
        f.toggle(L("Show public IP address"), help: L("Asks api.ipify.org for your public address when you open the Network dropdown (at most every 10 minutes)."),
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

        f.section(L("Color Picker"))
        f.popup(L("Copy as"), options: [("hex", "#RRGGBB"), ("rgb", "rgb(r, g, b)"), ("swiftui", "SwiftUI Color")],
                get: { [unowned self] in s.colorFormat }, set: { [unowned self] in s.colorFormat = $0 })
        f.button(L("Pick a Color")) { [weak self] in self?.host?.pickColor() }
    }

    private func buildAbout(_ f: Form) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        f.section("BarTap \(version)")
        f.note(L("A lightweight menu bar organizer. Hiding works by resizing BarTap's own divider items; BarTap never posts mouse or keyboard events, never moves the pointer and never blocks clicks. The release build is checked for this automatically."))
        f.section(L("Permissions"))
        f.note("") {
            AXCatalog.isTrusted ? L("Accessibility: granted — search, shelf and per-icon features are available.")
                                : L("Accessibility: not granted — hiding works fully; search, shelf and layout lists need it.")
        }
        f.button(L("Grant Accessibility Access…")) { [weak self] in self?.host?.requestAccessibility() }
        f.section(L("Resource usage"))
        f.note("") {
            L("Memory %.1f MB · CPU time %.2f s since launch", ProcessStats.memoryMB(), ProcessStats.cpuSeconds())
        }
        f.buttons([(L("Quit BarTap"), { NSApp.terminate(nil) })])
    }
}

private final class PaneController: NSViewController {
    let form: Form
    init(form: Form) {
        self.form = form
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = form.makeView() }
    override func viewWillAppear() {
        super.viewWillAppear()
        form.refresh()
    }
}

/// Three rows of icons: Shown / Hidden / Always Hidden.
final class LayoutListView: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(message: String) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let l = NSTextField(wrappingLabelWithString: message)
        l.textColor = .secondaryLabelColor
        addArrangedSubview(l)
    }

    func show(items: [BarItem]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let groups: [(String, BarItem.Section)] = [(L("Shown"), .shown), (L("Hidden"), .hidden), (L("Always Hidden"), .alwaysHidden)]
        for (title, section) in groups {
            let members = items.filter { $0.section == section }
            let label = NSTextField(labelWithString: "\(title) (\(members.count))")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            var views: [NSView] = [label]
            for m in members.prefix(24) {
                let iv = NSImageView(image: m.icon)
                iv.toolTip = "\(m.title) — \(m.appName)"
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
                iv.heightAnchor.constraint(equalToConstant: 18).isActive = true
                views.append(iv)
            }
            if members.count > 24 { views.append(NSTextField(labelWithString: "+\(members.count - 24)")) }
            let row = NSStackView(views: views)
            row.spacing = 6
            addArrangedSubview(row)
        }
    }
}
