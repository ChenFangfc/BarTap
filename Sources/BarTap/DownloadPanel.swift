import AppKit
import BarTapCore

// MARK: - Panel

/// "Download Video…": a link field, a quality menu and the jobs. Built when opened and released
/// when closed; rows refresh only while it is on screen.
final class DownloadPanel: FloatingPanel, NSWindowDelegate, NSTextFieldDelegate {
    static let width: CGFloat = 520
    private static let maxListHeight: CGFloat = 300

    var onClose: (() -> Void)?
    private let model: VideoDownloads
    private let field = NSTextField()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let downloadButton = NSButton()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var listHeight: NSLayoutConstraint!
    private let footer = NSTextField(labelWithString: "")
    private let footerHint = NSTextField(wrappingLabelWithString: "")
    private let toolButton = NSButton()
    private let clearButton = NSButton()
    private let content = NSStackView()
    private var rows: [UUID: DownloadRow] = [:]
    private var presets: [VideoPreset] = []
    private var observers: [NSObjectProtocol] = []

    init(model: VideoDownloads) {
        self.model = model
        super.init(size: NSSize(width: Self.width, height: 200))
        delegate = self

        field.placeholderString = L("Paste a video link")
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 14)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        downloadButton.title = L("Download")
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"
        downloadButton.target = self
        downloadButton.action = #selector(download)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        downloadButton.setContentHuggingPriority(.required, for: .horizontal)
        let input = NSStackView(views: [field, popup, downloadButton])
        input.spacing = 8
        input.alignment = .centerY

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = Self.width - 28

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerHint.font = .systemFont(ofSize: 11)
        footerHint.textColor = .systemOrange
        footerHint.preferredMaxLayoutWidth = Self.width - 28
        for (b, title, action) in [(toolButton, "", #selector(toolAction)), (clearButton, L("Clear"), #selector(clear))] {
            b.title = title
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
            b.action = action
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerRow = NSStackView(views: [footer, spacer, toolButton, clearButton])
        footerRow.spacing = 8
        footerRow.alignment = .centerY

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        for v in [input, hint, scroll, footerRow, footerHint] as [NSView] { content.addArrangedSubview(v) }
        content.setCustomSpacing(6, after: footerRow)
        contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView!.topAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            input.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            footerRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            listHeight,
        ])

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .barTapDownloadsChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, self.isVisible || self.isRendering else { return }
            if let job = n.object as? DownloadJob, let row = self.rows[job.id] { row.update() } else { self.reloadJobs() }
        })
        observers.append(nc.addObserver(forName: .barTapVideoToolsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshTools()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Headless renders update rows without the panel being on screen.
    var isRendering = false

    /// - Parameter prefill: link to put in the field; nil looks at the clipboard.
    func present(prefill: String?) {
        rebuildPresets()
        reloadJobs()
        refreshTools()
        field.stringValue = prefill ?? ""
        field.placeholderString = L("Paste a video link")
        if prefill == nil { offerClipboardLink() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - f.height * 0.12))
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// macOS 15.4+ asks the user before an app reads the clipboard on its own, so there BarTap
    /// only checks whether a link is there and lets ⌘V (a user paste, never asked about) do the rest.
    private func offerClipboardLink() {
        let pb = NSPasteboard.general
        if #available(macOS 15.4, *), pb.accessBehavior != .alwaysAllow {
            Task { @MainActor [weak self] in
                let found = (try? await pb.detectedPatterns(for: [\.probableWebURL]))?.contains(\NSPasteboard.DetectedValues.probableWebURL) ?? false
                if found, let self, self.field.stringValue.isEmpty { self.field.placeholderString = L("Press ⌘V to paste the copied link") }
            }
            return
        }
        if let link = LinkDetector.firstWebURL(in: pb.string(forType: .string) ?? "") { field.stringValue = link }
    }

    func rebuildPresets() {
        let hasFFmpeg = VideoTools.shared.status.ffmpeg != nil || !VideoTools.shared.lookedUp
        let previous = popup.indexOfSelectedItem >= 0 && popup.indexOfSelectedItem < presets.count ? presets[popup.indexOfSelectedItem] : model.settings.videoPreset
        presets = VideoPreset.allCases.filter { !$0.needsFFmpeg || hasFFmpeg }
        popup.removeAllItems()
        presets.forEach { popup.addItem(withTitle: $0.title) }
        popup.selectItem(at: presets.firstIndex(of: previous) ?? presets.firstIndex(of: .audio).flatMap { previous.isAudio ? $0 : nil } ?? 0)
    }

    func reloadJobs() {
        let jobs = model.jobs
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var kept: [UUID: DownloadRow] = [:]
        for job in jobs {
            let row = rows[job.id] ?? DownloadRow(job: job, model: model)
            row.update()
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            kept[job.id] = row
        }
        rows = kept
        hint.stringValue = L("Works with YouTube and the many other sites yt-dlp supports. Download only videos you have the right to.")
        hint.isHidden = !jobs.isEmpty
        scroll.isHidden = jobs.isEmpty
        clearButton.isHidden = !jobs.contains { !$0.state.isActive }
        list.layoutSubtreeIfNeeded()
        listHeight.constant = min(list.fittingSize.height, Self.maxListHeight)
        resize()
    }

    func refreshTools() {
        let tools = VideoTools.shared
        footer.stringValue = tools.summary
        switch tools.install {
        case .running(let text, let fraction):
            footer.stringValue = fraction.map { "\(text) \(StatFormat.percent($0))" } ?? text
            toolButton.title = L("Cancel")
            toolButton.isHidden = false
        case .failed(let why):
            footer.stringValue = why
            toolButton.title = L("Try Again")
            toolButton.isHidden = false
        default:
            toolButton.title = L("Download yt-dlp")
            toolButton.isHidden = tools.status.path != nil || !tools.lookedUp
        }
        let hints = tools.hints(compact: true)
        footerHint.stringValue = hints.joined(separator: "\n")
        footerHint.isHidden = hints.isEmpty
        if tools.lookedUp && (presets.contains(.mp3) != (tools.status.ffmpeg != nil)) { rebuildPresets() }
        resize()
    }

    private func resize() {
        content.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height)
        guard abs(frame.height - height) > 0.5 else { return }
        // Grow or shrink downwards: the field stays where the user is looking.
        var f = frame
        f.origin.y += f.height - height
        f.size = NSSize(width: Self.width, height: height)
        setFrame(f, display: true)
    }

    @objc private func download() {
        guard let link = LinkDetector.firstWebURL(in: field.stringValue) else {
            NSSound.beep()
            field.placeholderString = L("Paste a link that starts with http:// or https://")
            field.stringValue = ""
            return
        }
        let i = popup.indexOfSelectedItem
        model.add(url: link, preset: i >= 0 && i < presets.count ? presets[i] : .best)
        field.stringValue = ""
        field.placeholderString = L("Paste a video link")
    }

    @objc private func toolAction() {
        let tools = VideoTools.shared
        if tools.isInstalling { tools.cancelInstall() } else { tools.installManaged() }
    }

    @objc private func clear() { model.clearFinished() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): download(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    /// BarTap has no Edit menu, so the standard text shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            case "w": close(); return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private var closing = false

    override func close() {
        // Closing resigns key, which calls close() again.
        guard !closing else { return }
        closing = true
        super.close()
        closing = false
        let done = onClose
        onClose = nil
        done?()
    }

    /// The panel's content, for headless renders.
    var renderView: NSView { content }
}

// MARK: - Row

final class DownloadRow: NSView {
    private static let actionWidth: CGFloat = 24
    private let job: DownloadJob
    private weak var model: VideoDownloads?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = DownloadRow.iconButton("xmark.circle.fill", L("Cancel"))
    private let revealButton = DownloadRow.iconButton("magnifyingglass.circle.fill", L("Show in Finder"))
    private let retryButton = DownloadRow.iconButton("arrow.clockwise.circle.fill", L("Retry"))

    init(job: DownloadJob, model: VideoDownloads) {
        self.job = job
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: DownloadPanel.width - 28, height: 50))
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        status.cell?.truncatesLastVisibleLine = true
        status.preferredMaxLayoutWidth = DownloadPanel.width - 28 - 18 - 10 - Self.actionWidth - 10
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, bar, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.action = #selector(cancel)
        revealButton.action = #selector(reveal)
        retryButton.action = #selector(retry)
        // One action per state (cancel, show, retry), kept at the right edge.
        let buttons = NSStackView()
        buttons.setViews([retryButton, revealButton, cancelButton], in: .trailing)
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for b in [cancelButton, revealButton, retryButton] { b.target = self }
        addSubview(icon)
        addSubview(text)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.topAnchor.constraint(equalTo: text.topAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            text.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -10),
            title.widthAnchor.constraint(equalTo: text.widthAnchor),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            status.widthAnchor.constraint(equalTo: text.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.widthAnchor.constraint(equalToConstant: Self.actionWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func iconButton(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(image: Icons.symbol(symbol, config: .init(pointSize: 15, weight: .regular)), target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    func update() {
        var name = job.displayTitle
        if let item = job.item { name += "  (\(item.index)/\(item.count))" }
        title.stringValue = name
        title.toolTip = job.title.map { "\($0)\n\(job.url)" } ?? job.url
        let symbol: String, tint: NSColor
        switch job.state {
        case .queued: (symbol, tint) = ("clock", .secondaryLabelColor)
        case .running, .finishing: (symbol, tint) = ("arrow.down.circle", .controlAccentColor)
        case .done: (symbol, tint) = job.message == nil ? ("checkmark.circle.fill", .systemGreen) : ("exclamationmark.circle.fill", .systemOrange)
        case .failed: (symbol, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        case .cancelled: (symbol, tint) = ("xmark.circle", .tertiaryLabelColor)
        }
        icon.image = Icons.symbol(symbol, config: .init(pointSize: 15, weight: .regular))
        icon.contentTintColor = tint

        let active = job.state == .running || job.state == .finishing
        bar.isHidden = !active
        if active {
            let known = job.meter.fraction.map { $0 > 0 } ?? false
            if job.step != nil || !known {
                if !bar.isIndeterminate { bar.isIndeterminate = true }
                if isVisibleOnScreen { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
            } else {
                if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
                bar.doubleValue = job.meter.fraction ?? 0
            }
        } else {
            bar.stopAnimation(nil)
        }
        status.textColor = job.state == .failed || (job.state == .done && job.message != nil) ? .systemOrange : .secondaryLabelColor
        status.stringValue = job.statusText
        status.toolTip = job.message
        cancelButton.isHidden = !job.state.isActive
        revealButton.isHidden = job.state != .done
        retryButton.isHidden = job.state != .failed && job.state != .cancelled
    }

    private var isVisibleOnScreen: Bool { window?.isVisible ?? false }

    @objc private func cancel() { model?.cancel(job) }
    @objc private func reveal() { model?.reveal(job) }
    @objc private func retry() { model?.retry(job) }
}

extension DownloadJob {
    /// "42% · 3.1 MB/s · 0:12 left", "Done · 742.0 KB", or why it failed.
    var statusText: String {
        switch state {
        case .queued: return L("Waiting…")
        case .running, .finishing:
            if let step { return step }
            let progress = DownloadText.progress(meter)
            return progress.isEmpty ? L("Getting video info…") : progress
        case .done:
            let sizes = files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? NSNumber }
            let total = sizes.reduce(UInt64(0)) { $0 + $1.uint64Value }
            var parts = [L("Done")]
            if files.count > 1 { parts.append(L("%d files", files.count)) }
            if total > 0 { parts.append(StatFormat.bytes(total)) }
            if let message { parts.append(message) }
            return parts.joined(separator: " · ")
        case .failed: return message ?? L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }
}

// MARK: - Settings

/// Settings › Power-ups › Video Downloads.
enum VideoDownloadSettings {
    static func build(_ f: Form, settings s: Settings) {
        f.section(L("Video Downloads"))
        f.toggle(L("Show Download Video… in the BarTap menu"), get: { s.videoDownloadsEnabled }, set: { s.videoDownloadsEnabled = $0 })

        let folderLabel = NSTextField(labelWithString: "")
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let showFolder = { folderLabel.stringValue = ((s.videoFolder.isEmpty ? VideoDownloads.defaultFolder : s.videoFolder) as NSString).abbreviatingWithTildeInPath }
        showFolder()
        let choose = ClosureTarget { _ in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = L("Choose")
            panel.directoryURL = URL(fileURLWithPath: s.videoFolder.isEmpty ? VideoDownloads.defaultFolder : s.videoFolder)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            s.videoFolder = url.path == VideoDownloads.defaultFolder ? "" : url.path
            showFolder()
        }
        f.keep(choose)
        let chooseButton = NSButton(title: L("Choose…"), target: choose, action: #selector(ClosureTarget.fire(_:)))
        chooseButton.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderLabel, chooseButton])
        folderRow.spacing = 8
        folderRow.alignment = .centerY
        f.custom(L("Save to"), folderRow)

        f.popup(L("Default quality"), options: VideoPreset.allCases.map { ($0.rawValue, $0.title) },
                help: L("Best prefers H.264 video in MP4 (plays everywhere) when the resolution is the same. MP3 needs ffmpeg."),
                get: { s.videoPreset.rawValue }, set: { s.videoPreset = VideoPreset(rawValue: $0) ?? .best })
        f.toggle(L("Download whole playlists"), help: L("When off, a playlist link downloads only its first video."),
                 get: { s.videoPlaylists }, set: { s.videoPlaylists = $0 })

        let tools = VideoToolsView(settings: s)
        f.keep(tools)
        f.custom(nil, tools.view)
        f.onAppear { tools.start() }
        f.onDisappear { tools.stop() }
        f.note(L("Download only videos you have the right to. yt-dlp is fetched from its official GitHub release only when you ask."))
    }
}

/// yt-dlp's status in Settings, with Download / Check for Updates / Show in Finder / Remove.
final class VideoToolsView {
    let view = NSStackView()
    private let settings: Settings
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let buttons = NSStackView()
    private var targets: [ClosureTarget] = []
    private var observer: NSObjectProtocol?

    init(settings: Settings) {
        self.settings = settings
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        summary.font = .systemFont(ofSize: 13)
        summary.preferredMaxLayoutWidth = 560
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 560
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 300).isActive = true
        buttons.spacing = 8
        [summary, detail, progress, buttons].forEach { view.addArrangedSubview($0) }
        update()
    }

    deinit { stop() }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .barTapVideoToolsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
        VideoTools.shared.forgetInstallResult()
        VideoTools.shared.refresh()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func update() {
        let tools = VideoTools.shared
        let s = tools.status
        summary.stringValue = tools.summary
        var lines = tools.sourceText.map { [$0] } ?? []
        var installing = false
        switch tools.install {
        case .running(let text, let fraction):
            installing = true
            lines.insert(text, at: 0)
            progress.isIndeterminate = fraction == nil
            progress.doubleValue = fraction ?? 0
            if fraction == nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        case .failed(let why): lines.insert(why, at: 0)
        case .finished(let what): lines.insert(what, at: 0)
        case .idle: break
        }
        lines += tools.hints(compact: false)
        detail.stringValue = lines.joined(separator: "\n")
        detail.isHidden = lines.isEmpty
        progress.isHidden = !installing
        if !installing { progress.stopAnimation(nil) }

        var list: [(String, () -> Void)] = []
        if installing {
            list.append((L("Cancel"), { tools.cancelInstall() }))
        } else {
            switch s.source {
            case nil: if tools.lookedUp { list.append((L("Download yt-dlp"), { tools.installManaged() })) }
            case .managed?: list.append((L("Check for Updates"), { tools.installManaged() }))
            // An existing install may be months old: BarTap's own copy is kept current and is used once it exists.
            default: list.append((L("Use BarTap's Own Copy"), { tools.installManaged() }))
            }
            if let path = s.path {
                list.append((L("Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }))
            }
            if s.source == .managed { list.append((L("Remove"), { tools.removeManaged() })) }
            if s.source == .custom {
                list.append((L("Use Default"), { [weak self] in self?.settings.videoToolPath = ""; tools.refresh() }))
            } else {
                list.append((L("Choose…"), { [weak self] in self?.chooseTool() }))
            }
        }
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets = list.map { _, action in ClosureTarget { _ in action() } }
        for ((title, _), target) in zip(list, targets) {
            let b = NSButton(title: title, target: target, action: #selector(ClosureTarget.fire(_:)))
            b.bezelStyle = .rounded
            buttons.addArrangedSubview(b)
        }
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = L("Choose")
        panel.message = L("Choose a yt-dlp program")
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard VideoTools.isExecutable(url.path) else { NSSound.beep(); return }
        settings.videoToolPath = url.path
        VideoTools.shared.refresh()
    }
}
