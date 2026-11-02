import AppKit
import BarTapCore

// MARK: - Panel

/// "Download Video…": paste or drop a link, see what it is, pick a quality, download. Built when
/// opened and released when closed. It stays up while you work in other apps (links are
/// dragged in from a browser), floating like a small utility window.
final class DownloadPanel: FloatingPanel, NSWindowDelegate, NSTextFieldDelegate {
    static let width: CGFloat = 560
    private static let maxListHeight: CGFloat = 250
    /// Top-left corner where the user last left it, for this session.
    private static var lastTopLeft: NSPoint?

    var onClose: (() -> Void)?
    /// Headless renders update rows without the panel being on screen.
    var isRendering = false

    private let model: VideoDownloads
    private var options: VideoOptions {
        didSet { if options != oldValue { model.settings.videoOptions = options } }
    }

    private let root = DropTargetView()
    private let content = NSStackView()
    private let field = NSTextField()
    private let pasteButton = PasteLinkButton()
    private let closeButton = NSButton()
    private let card = PreviewCard()
    private let qualityPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let folderPopup = NSPopUpButton()
    private let optionsToggle = NSButton()
    private let downloadButton = NSButton()
    private let optionsView: DownloadOptionsView
    private let componentRow = NSStackView()
    private let componentLabel = NSTextField(labelWithString: "")
    private let componentButton = NSButton()
    private let separator = NSBox()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var listHeight: NSLayoutConstraint!
    private let warningButton = NSButton()
    private let note = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var rows: [UUID: DownloadRow] = [:]
    private var targets: [ClosureTarget] = []
    private var observers: [NSObjectProtocol] = []

    // The link being looked at.
    private var infoLink: String?
    private var info: VideoInfo?
    private var thumbnail: NSImage?
    private var fetch: VideoDownloads.InfoFetch?
    private var thumbnailTask: URLSessionDataTask?
    private var qualities: [VideoQuality] = []
    private var pasteChangeCount = -1
    private var linkOnClipboard = false

    init(model: VideoDownloads) {
        self.model = model
        options = model.settings.videoOptions
        optionsView = DownloadOptionsView(options: model.settings.videoOptions)
        super.init(size: NSSize(width: Self.width, height: 200))
        delegate = self
        // A small utility window: above other apps' windows, movable, closed with × or Esc.
        level = .floating
        isMovableByWindowBackground = true

        field.placeholderString = L("Paste or drop a video link")
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 14)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pasteButton.field = field
        pasteButton.title = L("Paste Link")
        pasteButton.image = Icons.symbol("link", config: .init(pointSize: 12, weight: .medium))
        pasteButton.imagePosition = .imageLeading
        pasteButton.bezelStyle = .rounded
        pasteButton.refusesFirstResponder = true
        // The standard Paste command, sent to the link field: macOS treats it like ⌘V.
        pasteButton.target = nil
        pasteButton.action = #selector(NSText.paste(_:))
        pasteButton.toolTip = L("Paste the link you copied")
        pasteButton.isHidden = true
        closeButton.image = Icons.symbol("xmark.circle.fill", config: .init(pointSize: 15, weight: .regular))
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = L("Close")
        closeButton.setAccessibilityLabel(L("Close"))
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let top = NSStackView(views: [field, pasteButton, closeButton])
        top.spacing = 8

        card.isHidden = true

        for (popup, tip, action) in [(qualityPopup, L("Quality"), #selector(qualityChanged)), (formatPopup, L("Format"), #selector(formatChanged)),
                                     (folderPopup, L("Save to"), #selector(folderChanged))] {
            popup.toolTip = tip
            popup.target = self
            popup.action = action
            popup.setContentHuggingPriority(.required, for: .horizontal)
        }
        folderPopup.translatesAutoresizingMaskIntoConstraints = false
        folderPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let saveLabel = Self.label(L("Save to"))
        let choices = NSStackView(views: [qualityPopup, formatPopup, spacer, saveLabel, folderPopup])
        choices.spacing = 8
        choices.setCustomSpacing(4, after: saveLabel)

        optionsToggle.setButtonType(.pushOnPushOff)
        optionsToggle.bezelStyle = .disclosure
        optionsToggle.title = ""
        optionsToggle.target = self
        optionsToggle.action = #selector(toggleOptions)
        let optionsTitle = NSButton(title: L("Options"), target: self, action: #selector(toggleOptionsFromTitle))
        optionsTitle.isBordered = false
        optionsTitle.font = .systemFont(ofSize: 12)
        optionsTitle.contentTintColor = .secondaryLabelColor
        downloadButton.title = L("Download")
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(download)
        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [optionsToggle, optionsTitle, spacer2, downloadButton])
        actions.spacing = 2
        actions.setCustomSpacing(8, after: spacer2)

        optionsView.isHidden = true
        optionsView.onChange = { [weak self] o in
            self?.options = o
            self?.updateChoices()
        }
        optionsView.onLayoutChange = { [weak self] in self?.resize() }

        componentLabel.font = .systemFont(ofSize: 12)
        componentLabel.lineBreakMode = .byTruncatingTail
        componentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        componentButton.bezelStyle = .rounded
        componentButton.controlSize = .small
        componentButton.target = self
        componentButton.action = #selector(componentAction)
        let spacer3 = NSView()
        spacer3.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [componentLabel, spacer3, componentButton].forEach { componentRow.addArrangedSubview($0) }
        componentRow.spacing = 8
        componentRow.isHidden = true

        separator.boxType = .separator

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
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

        warningButton.image = Icons.symbol("exclamationmark.triangle.fill", config: .init(pointSize: 11, weight: .regular))
        warningButton.isBordered = false
        warningButton.contentTintColor = .systemOrange
        warningButton.isHidden = true
        note.stringValue = L("Only download what you have the right to.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.title = L("Clear Finished")
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        let spacer4 = NSView()
        spacer4.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [warningButton, note, spacer4, clearButton])
        footer.spacing = 6

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        for v in [top, card, choices, actions, optionsView, componentRow, separator, scroll, footer] as [NSView] {
            content.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }
        content.setCustomSpacing(6, after: choices)
        content.setCustomSpacing(6, after: separator)

        root.frame = contentView!.bounds
        root.autoresizingMask = [.width, .height]
        root.onDrop = { [weak self] link in self?.take(link) }
        contentView?.addSubview(root)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            listHeight,
        ])

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .barTapDownloadsChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, self.isVisible || self.isRendering else { return }
            if let job = n.object as? DownloadJob, let row = self.rows[job.id] { row.update() } else { self.reloadJobs() }
            self.clearButton.isHidden = !self.model.jobs.contains { $0.state.isFinished }
        })
        observers.append(nc.addObserver(forName: .barTapVideoToolsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshComponent()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        fetch?.cancel()
        thumbnailTask?.cancel()
    }

    private static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// - Parameter prefill: a link to show right away.
    func present(prefill: String?) {
        rebuildFolders()
        reloadJobs()
        refreshComponent()
        updateChoices()
        if let prefill { take(prefill) }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let topLeft = Self.lastTopLeft {
            setFrameTopLeftPoint(topLeft)
        } else if let f = screen?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - f.height * 0.1))
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        checkClipboard()
    }

    // MARK: Link

    /// Whether the clipboard holds a link. On macOS 15.4 and later only the kind of content is
    /// checked: reading it would make macOS ask the user. The Paste Link button then pastes
    /// like ⌘V does.
    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteChangeCount else { return }
        pasteChangeCount = pb.changeCount
        if #available(macOS 15.4, *), pb.accessBehavior != .alwaysAllow {
            Task { @MainActor [weak self] in
                let found = (try? await pb.detectedPatterns(for: [\.probableWebURL]))?.contains(\NSPasteboard.DetectedValues.probableWebURL) ?? false
                self?.linkOnClipboard = found
                self?.updatePasteButton()
            }
            return
        }
        linkOnClipboard = LinkDetector.firstWebURL(in: pb.string(forType: .string) ?? "") != nil
        updatePasteButton()
    }

    private func updatePasteButton() {
        pasteButton.isHidden = !(linkOnClipboard && field.stringValue.isEmpty)
    }

    /// A link from a drop, a paste or a prefill: show it and fetch its details.
    private func take(_ text: String) {
        field.stringValue = text
        fetchInfo()
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePasteButton()
        let text = field.stringValue
        if let infoLink, !text.contains(infoLink) { forgetLink() }
        // A paste or drop lands all at once; typing doesn't.
        if let link = LinkDetector.firstWebURL(in: text), link != infoLink, text.count - lastFieldLength > 8 { fetchInfo() }
        lastFieldLength = text.count
    }

    private var lastFieldLength = 0

    private func forgetLink() {
        fetch?.cancel()
        fetch = nil
        thumbnailTask?.cancel()
        infoLink = nil
        info = nil
        thumbnail = nil
        card.isHidden = true
        optionsView.resetForLink()
        updateChoices()
        resize()
    }

    private func fetchInfo() {
        guard let link = LinkDetector.firstWebURL(in: field.stringValue) else { notALink(); return }
        if field.stringValue != link { field.stringValue = link }
        lastFieldLength = link.count
        updatePasteButton()
        if link == infoLink && (info != nil || fetch != nil) { return }
        forgetLink()
        infoLink = link
        card.showLoading(link)
        card.isHidden = false
        fetch = model.fetchInfo(url: link, browser: options.browser) { [weak self] result in
            guard let self, self.infoLink == link else { return }
            self.fetch = nil
            switch result {
            case .success(let info):
                self.info = info
                self.card.show(info)
                self.loadThumbnail(info.thumbnail, for: link)
            case .failure(let error):
                self.card.showError(error.message)
            }
            self.updateChoices()
            self.resize()
        }
        updateChoices()
        resize()
    }

    private func loadThumbnail(_ address: String?, for link: String) {
        guard let address, let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return }
        thumbnailTask = Self.thumbnailSession.dataTask(with: url) { [weak self] data, _, _ in
            // Kept small: the card shows it at 128×72 points (256×144 pixels).
            let image = data.flatMap(NSImage.init(data:)).map { Self.scaled($0, to: NSSize(width: 128, height: 72)) }
            DispatchQueue.main.async {
                guard let self, self.infoLink == link, let image else { return }
                self.thumbnail = image
                self.card.setThumbnail(image)
            }
        }
        thumbnailTask?.resume()
    }

    /// No disk cache, no cookies: a thumbnail is fetched once, for the card.
    private static let thumbnailSession = URLSession(configuration: .ephemeral)

    /// Drawn once into a bitmap at 2x, so the decoded original can go.
    static func scaled(_ image: NSImage, to box: NSSize) -> NSImage {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return image }
        let k = min(box.width / s.width, box.height / s.height)
        let size = NSSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: size)
        small.addRepresentation(rep)
        return small
    }

    private func notALink() {
        NSSound.beep()
        if field.stringValue.isEmpty { field.placeholderString = L("Paste a link that starts with http:// or https://") }
    }

    // MARK: Choices

    private var hasFFmpeg: Bool { VideoTools.shared.status.ffmpeg != nil || !VideoTools.shared.lookedUp }

    /// Quality list from the video's own formats when known, a common list otherwise.
    func updateChoices() {
        let known = info
        let previous = selectedQuality
        if let known, !known.qualities.isEmpty {
            qualities = known.qualities.map { .height($0.height) } + [.audio]
        } else {
            qualities = VideoQuality.common
        }
        qualityPopup.removeAllItems()
        for q in qualities { qualityPopup.addItem(withTitle: title(for: q)) }
        let wanted = previous ?? model.settings.videoQuality
        qualityPopup.selectItem(at: index(for: wanted))
        rebuildFormats()
        optionsView.configure(info: known, link: infoLink, quality: selectedQuality ?? .best, hasFFmpeg: hasFFmpeg)
        downloadButton.keyEquivalent = info != nil ? "\r" : ""
    }

    private var selectedQuality: VideoQuality? {
        let i = qualityPopup.indexOfSelectedItem
        return i >= 0 && i < qualities.count ? qualities[i] : nil
    }

    /// The same choice, or the nearest smaller resolution the video has.
    private func index(for wanted: VideoQuality) -> Int {
        if let i = qualities.firstIndex(of: wanted) { return i }
        switch wanted {
        case .audio: return qualities.firstIndex(of: .audio) ?? 0
        case .best: return 0
        case .height(let h):
            return qualities.firstIndex { if case .height(let x) = $0 { return x <= h } else { return false } }
                ?? qualities.lastIndex { if case .height = $0 { return true } else { return false } } ?? 0
        }
    }

    private func title(for q: VideoQuality) -> String {
        guard let known = info else { return q.title }
        var bytes: Int64?
        var name = q.title
        switch q {
        case .height(let h):
            if let option = known.qualities.first(where: { $0.height == h }) {
                name = option.title
                bytes = option.bytes[hasFFmpeg ? options.container : .mp4]
            }
        case .audio:
            switch options.audioFormat {
            case .mp3: bytes = known.mp3Bytes(options.audioQuality)
            case .opus: bytes = known.audioBytes[.opus] ?? known.audioBytes[.m4a]
            case .m4a: bytes = known.audioBytes[.m4a]
            }
        case .best: break
        }
        guard let b = bytes, b > 0 else { return name }
        return name + " · " + DownloadText.approximateSize(b)
    }

    private func rebuildFormats() {
        formatPopup.removeAllItems()
        if selectedQuality?.isAudio == true {
            let formats = hasFFmpeg ? AudioFormat.allCases : [.m4a]
            formats.forEach { formatPopup.addItem(withTitle: $0.title) }
            formatPopup.selectItem(at: formats.firstIndex(of: options.audioFormat) ?? 0)
        } else {
            let containers = hasFFmpeg ? VideoContainer.allCases : [.mp4]
            containers.forEach { formatPopup.addItem(withTitle: $0.title) }
            formatPopup.selectItem(at: containers.firstIndex(of: options.container) ?? 0)
        }
    }

    @objc private func qualityChanged() {
        rebuildFormats()
        optionsView.configure(info: info, link: infoLink, quality: selectedQuality ?? .best, hasFFmpeg: hasFFmpeg)
        resize()
    }

    @objc private func formatChanged() {
        let i = formatPopup.indexOfSelectedItem
        if selectedQuality?.isAudio == true {
            let formats = hasFFmpeg ? AudioFormat.allCases : [.m4a]
            if i >= 0 && i < formats.count { options.audioFormat = formats[i] }
        } else {
            let containers = hasFFmpeg ? VideoContainer.allCases : [.mp4]
            if i >= 0 && i < containers.count { options.container = containers[i] }
        }
        optionsView.options = options
        // Sizes depend on the format.
        let keep = qualityPopup.indexOfSelectedItem
        for (n, q) in qualities.enumerated() { qualityPopup.item(at: n)?.title = title(for: q) }
        qualityPopup.selectItem(at: keep)
        optionsView.configure(info: info, link: infoLink, quality: selectedQuality ?? .best, hasFFmpeg: hasFFmpeg)
    }

    // MARK: Folder

    func rebuildFolders() {
        folderPopup.removeAllItems()
        let current = model.folder
        let recent = model.settings.videoRecentFolders.filter { $0 != current && FileManager.default.fileExists(atPath: $0) }
        for path in [current] + recent.prefix(4) {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: path), action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = path
            item.toolTip = (path as NSString).abbreviatingWithTildeInPath
            folderPopup.menu?.addItem(item)
        }
        folderPopup.menu?.addItem(.separator())
        folderPopup.menu?.addItem(NSMenuItem(title: L("Choose…"), action: nil, keyEquivalent: ""))
        folderPopup.selectItem(at: 0)
        folderPopup.toolTip = (current as NSString).abbreviatingWithTildeInPath
    }

    @objc private func folderChanged() {
        if let path = folderPopup.selectedItem?.representedObject as? String {
            model.choose(folder: path)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = L("Choose")
            panel.directoryURL = URL(fileURLWithPath: model.folder)
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url { model.choose(folder: url.path) }
            makeKeyAndOrderFront(nil)
        }
        rebuildFolders()
    }

    // MARK: Options

    @objc private func toggleOptions() {
        optionsView.isHidden = optionsToggle.state != .on
        resize()
    }

    @objc private func toggleOptionsFromTitle() {
        optionsToggle.state = optionsToggle.state == .on ? .off : .on
        toggleOptions()
    }

    /// For headless renders.
    func setOptionsOpen(_ open: Bool) {
        optionsToggle.state = open ? .on : .off
        optionsView.isHidden = !open
        resize()
    }

    // MARK: Download

    @objc private func download() {
        guard let link = LinkDetector.firstWebURL(in: field.stringValue) else { notALink(); return }
        let known = link == infoLink ? info : nil
        var request = model.request(url: link, quality: selectedQuality)
        request.options = options
        guard let playlist = optionsView.playlistChoice(info: known, link: link) else {
            optionsView.flagItems()
            NSSound.beep()
            return
        }
        request.playlist = playlist
        if playlist == .single {
            switch optionsView.clipInput(duration: known?.duration) {
            case .invalid:
                optionsView.flagClip()
                NSSound.beep()
                return
            case .valid(let clip): request.clip = hasFFmpeg ? clip : nil
            case .none: break
            }
        }
        model.add(request, title: known?.title, thumbnail: known == nil ? nil : thumbnail)
        // Ready for the next link.
        field.stringValue = ""
        lastFieldLength = 0
        forgetLink()
        updatePasteButton()
        makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            // Return looks the link up; once its details are shown, Return downloads.
            if let link = LinkDetector.firstWebURL(in: field.stringValue), link == infoLink, info != nil { download() } else { fetchInfo() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// BarTap has no Edit menu, so the standard text shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch key {
            case "v":
                if firstResponder !== field.currentEditor() { makeFirstResponder(field) }
                action = #selector(NSText.paste(_:))
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

    override func cancelOperation(_ sender: Any?) { close() }

    // MARK: Queue

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
        separator.isHidden = jobs.isEmpty
        scroll.isHidden = jobs.isEmpty
        clearButton.isHidden = !jobs.contains { $0.state.isFinished }
        list.layoutSubtreeIfNeeded()
        listHeight.constant = min(list.fittingSize.height, Self.maxListHeight)
        resize()
    }

    @objc private func clearFinished() { model.clearFinished() }

    // MARK: Component

    func refreshComponent() {
        let tools = VideoTools.shared
        var text: String?
        var button: String?
        switch tools.install {
        case .running(let what, let fraction):
            text = fraction.map { "\(what) \(StatFormat.percent($0))" } ?? what
            button = L("Cancel")
        case .failed(let why):
            text = why
            button = L("Try Again")
        default:
            if tools.lookedUp && tools.status.path == nil {
                text = L("The download component isn't installed.")
                button = L("Install")
            } else if tools.lookedUp && tools.status.version == nil && !tools.status.checking {
                text = L("The download component doesn't start.")
                button = L("Install")
            }
        }
        componentRow.isHidden = text == nil
        componentLabel.stringValue = text ?? ""
        componentButton.title = button ?? ""
        let problems = tools.problems
        warningButton.isHidden = problems.isEmpty
        warningButton.toolTip = problems.joined(separator: "\n")
        updateChoices()
        resize()
    }

    @objc private func componentAction() {
        let tools = VideoTools.shared
        if tools.isInstalling { tools.cancelInstall() } else { tools.installManaged() }
    }

    // MARK: Window

    private func resize() {
        content.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height)
        guard abs(frame.height - height) > 0.5 else { return }
        // Grow or shrink downwards: the link field stays where the user is looking.
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setContentSize(NSSize(width: Self.width, height: height))
        setFrameTopLeftPoint(topLeft)
    }

    func windowDidMove(_ notification: Notification) {
        guard isVisible else { return }
        Self.lastTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
    }

    func windowDidBecomeKey(_ notification: Notification) { checkClipboard() }

    @objc private func closeClicked() { close() }

    private var closing = false

    override func close() {
        // Closing resigns key, which may call close() again.
        guard !closing else { return }
        closing = true
        fetch?.cancel()
        thumbnailTask?.cancel()
        super.close()
        closing = false
        let done = onClose
        onClose = nil
        done?()
    }

    /// For headless renders: what a fetched link would show.
    func showPreview(link: String, info: VideoInfo, thumbnail: NSImage?) {
        field.stringValue = link
        infoLink = link
        self.info = info
        self.thumbnail = thumbnail
        card.show(info)
        if let thumbnail { card.setThumbnail(thumbnail) }
        card.isHidden = false
        updateChoices()
        resize()
    }

    /// The panel's content, for headless renders.
    var renderView: NSView { content }
}

/// Pastes into the link field with the standard Paste action, exactly as Edit › Paste or ⌘V
/// would, so macOS counts it as the user pasting: BarTap never reads the clipboard itself.
final class PasteLinkButton: NSButton {
    weak var field: NSTextField?

    override func mouseDown(with event: NSEvent) {
        if let field, field.currentEditor() == nil { window?.makeFirstResponder(field) }
        super.mouseDown(with: event)
    }
}

/// The panel's background: takes a link dragged in from a browser's address bar or a page.
/// Drags carry their own pasteboard, so this never touches the clipboard.
final class DropTargetView: NSView {
    var onDrop: ((String) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func link(_ info: NSDraggingInfo) -> String? {
        let pb = info.draggingPasteboard
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first,
           let link = LinkDetector.firstWebURL(in: url.absoluteString) { return link }
        return pb.string(forType: .string).flatMap(LinkDetector.firstWebURL(in:))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard link(sender) != nil else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let link = link(sender) else { return false }
        onDrop?(link)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        path.lineWidth = 3
        path.stroke()
    }
}

// MARK: - Preview card

/// Thumbnail, title, uploader and length of the link being looked at.
final class PreviewCard: NSView {
    private let image = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: DownloadPanel.width - 28, height: 84))
        wantsLayer = true
        layer?.cornerRadius = 8
        image.wantsLayer = true
        image.layer?.cornerRadius = 5
        image.layer?.masksToBounds = true
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.preferredMaxLayoutWidth = DownloadPanel.width - 28 - 128 - 36
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let lines = NSStackView(views: [title, detail, spinner])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 4
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(lines)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            image.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            image.widthAnchor.constraint(equalToConstant: 128),
            image.heightAnchor.constraint(equalToConstant: 72),
            lines.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            lines.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        // A faint panel behind the card, in both appearances.
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private func placeholder() -> NSImage {
        Icons.symbol("play.rectangle", config: .init(pointSize: 28, weight: .light))
    }

    func showLoading(_ link: String) {
        image.image = placeholder()
        image.contentTintColor = .tertiaryLabelColor
        title.stringValue = link
        title.textColor = .secondaryLabelColor
        detail.stringValue = L("Getting info…")
        detail.textColor = .secondaryLabelColor
        spinner.startAnimation(nil)
    }

    func show(_ info: VideoInfo) {
        spinner.stopAnimation(nil)
        title.stringValue = info.title
        title.textColor = .labelColor
        var parts: [String] = []
        if let count = info.playlistCount {
            parts.append(L("Playlist · %d videos", count))
        } else {
            if let u = info.uploader { parts.append(u) }
            if info.isLive { parts.append(L("Live")) } else if let d = info.duration, d > 0 { parts.append(DownloadText.duration(d)) }
        }
        detail.stringValue = parts.joined(separator: " · ")
        detail.textColor = .secondaryLabelColor
    }

    func showError(_ message: String) {
        spinner.stopAnimation(nil)
        detail.stringValue = message
        detail.textColor = .systemOrange
        detail.toolTip = message
    }

    func setThumbnail(_ thumbnail: NSImage) {
        image.image = thumbnail
        image.contentTintColor = nil
    }
}

// MARK: - Options

/// The collapsed "Options" section: subtitles, playlist, time range, embedding, sponsors,
/// sign-in, speed, file name, audio quality, live streams. Labels are plain; tooltips explain.
final class DownloadOptionsView: NSView {
    var options: VideoOptions { didSet { sync() } }
    var onChange: ((VideoOptions) -> Void)?
    var onLayoutChange: (() -> Void)?

    private let grid = NSGridView()
    private var targets: [ClosureTarget] = []
    private let subtitleMode = NSPopUpButton()
    private let subtitleLanguage = NSPopUpButton()
    private let autoSubtitles = NSButton(checkboxWithTitle: L("Auto-generated"), target: nil, action: nil)
    private let playlistMode = NSPopUpButton()
    private let itemsField = NSTextField()
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let cover = NSButton(checkboxWithTitle: L("Cover"), target: nil, action: nil)
    private let details = NSButton(checkboxWithTitle: L("Details"), target: nil, action: nil)
    private let chapters = NSButton(checkboxWithTitle: L("Chapters"), target: nil, action: nil)
    private let sponsors = NSPopUpButton()
    private let browser = NSPopUpButton()
    private let speed = NSPopUpButton()
    private let fileName = NSPopUpButton()
    private let audioQuality = NSPopUpButton()
    private let live = NSButton(checkboxWithTitle: L("Record from the Start"), target: nil, action: nil)

    private var languages: [String] = []
    private var browsers: [CookieBrowser?] = []
    private var playlistModes: [PlaylistMode] = []
    private enum PlaylistMode { case single, all, items }
    private enum Row: Int, CaseIterable { case subtitles, playlist, clip, embed, sponsors, signIn, speed, fileName, audioQuality, live }

    init(options: VideoOptions) {
        self.options = options
        super.init(frame: NSRect(x: 0, y: 0, width: DownloadPanel.width - 28, height: 100))

        subtitleMode.autoenablesItems = false
        subtitleMode.addItems(withTitles: [L("Off"), L("Save as File"), L("Embed in Video")])
        on(subtitleMode) { o, v in o.subtitles = [SubtitleMode.off, .file, .embed][max(0, (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0)] }
        on(subtitleLanguage) { [unowned self] o, v in
            let i = (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            o.subtitleLanguage = i >= 0 && i < self.languages.count ? self.languages[i] : ""
        }
        on(autoSubtitles) { o, v in o.autoSubtitles = (v as? NSButton)?.state == .on }
        autoSubtitles.toolTip = L("Include subtitles the site generates automatically")
        subtitleMode.toolTip = L("Subtitles as a separate file, or inside the video")
        let subtitleRow = Self.row([subtitleMode, subtitleLanguage, autoSubtitles])

        on(playlistMode) { [unowned self] _, _ in self.syncPlaylist() }
        itemsField.placeholderString = L("e.g. 1-5, 8")
        itemsField.toolTip = L("Video numbers or ranges; 10- means from 10 to the end")
        itemsField.translatesAutoresizingMaskIntoConstraints = false
        itemsField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let playlistRow = Self.row([playlistMode, itemsField])

        for (f, placeholder) in [(startField, L("Start")), (endField, L("End"))] {
            f.placeholderString = placeholder
            f.toolTip = L("Download only this part, e.g. 1:30 to 2:45")
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 72).isActive = true
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        let dash = NSTextField(labelWithString: "–")
        dash.textColor = .secondaryLabelColor
        let clipRow = Self.row([startField, dash, endField])

        on(cover) { o, v in o.embedThumbnail = (v as? NSButton)?.state == .on }
        on(details) { o, v in o.embedMetadata = (v as? NSButton)?.state == .on }
        on(chapters) { o, v in o.embedChapters = (v as? NSButton)?.state == .on }
        cover.toolTip = L("The thumbnail as the file's cover art")
        details.toolTip = L("Title, uploader, date and description in the file")
        chapters.toolTip = L("The video's chapter markers")
        let embedRow = Self.row([cover, details, chapters])

        sponsors.addItems(withTitles: [L("Keep"), L("Mark as Chapters"), L("Remove")])
        on(sponsors) { o, v in o.sponsors = [SponsorMode.keep, .mark, .remove][max(0, (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0)] }
        sponsors.toolTip = L("Sponsor segments in YouTube videos, found by SponsorBlock")

        browsers = [nil] + CookieBrowser.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
        browser.addItems(withTitles: browsers.map { $0?.title ?? L("None") })
        on(browser) { [unowned self] o, v in
            let i = (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            o.browser = i > 0 && i < self.browsers.count ? self.browsers[i] : nil
        }
        browser.toolTip = L("For members-only, age-restricted or private videos: use your sign-in from this browser. macOS may ask for permission.")

        speed.addItems(withTitles: SpeedLimit.choices.map(SpeedLimit.title))
        on(speed) { o, v in o.speedLimit = SpeedLimit.choices[max(0, (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0)] }
        speed.toolTip = L("Leave bandwidth for everything else")

        fileName.addItems(withTitles: FileNameStyle.allCases.map(\.title))
        on(fileName) { o, v in o.fileName = FileNameStyle.allCases[max(0, (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0)] }

        audioQuality.addItems(withTitles: AudioQuality.allCases.map { $0 == .best ? L("Best") : "\($0.kbps) kbps" })
        on(audioQuality) { o, v in o.audioQuality = AudioQuality.allCases[max(0, (v as? NSPopUpButton)?.indexOfSelectedItem ?? 0)] }
        audioQuality.toolTip = L("Used when the audio is converted, e.g. to MP3")

        on(live) { o, v in o.liveFromStart = (v as? NSButton)?.state == .on }
        live.toolTip = L("Record a live stream from its beginning, not from now")

        // One width for the single menus, so the column reads as a list.
        for p in [subtitleMode, playlistMode, sponsors, browser, speed, fileName, audioQuality] {
            p.translatesAutoresizingMaskIntoConstraints = false
            p.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        }
        let labels = [L("Subtitles"), L("Playlist"), L("Time Range"), L("Embed"), L("Sponsors"), L("Sign In"),
                      L("Speed Limit"), L("File Name"), L("Audio Quality"), L("Live Stream")]
        let controls: [NSView] = [subtitleRow, playlistRow, clipRow, embedRow, Self.row([sponsors]), Self.row([browser]),
                                  Self.row([speed]), Self.row([fileName]), Self.row([audioQuality]), Self.row([live])]
        for (label, control) in zip(labels, controls) {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            grid.addRow(with: [l, control])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        for f in [itemsField, startField, endField] {
            NotificationCenter.default.addObserver(self, selector: #selector(fieldEdited(_:)), name: NSControl.textDidChangeNotification, object: f)
        }
        configure(info: nil, link: nil, quality: .best, hasFFmpeg: true)
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        s.alignment = .firstBaseline
        return s
    }

    /// Wires a control: the handler edits a copy of the options, which is then reported.
    private func on(_ control: NSControl, _ edit: @escaping (inout VideoOptions, Any?) -> Void) {
        let t = ClosureTarget { [weak self] sender in
            guard let self else { return }
            var o = self.options
            edit(&o, sender)
            self.options = o
            self.onChange?(o)
        }
        targets.append(t)
        control.target = t
        control.action = #selector(ClosureTarget.fire(_:))
    }

    @objc private func fieldEdited(_ n: Notification) {
        (n.object as? NSTextField)?.textColor = .labelColor
    }

    /// Shows the controls in their current values.
    private func sync() {
        subtitleMode.selectItem(at: [SubtitleMode.off, .file, .embed].firstIndex(of: options.subtitles) ?? 0)
        subtitleLanguage.selectItem(at: languages.firstIndex(of: options.subtitleLanguage) ?? 0)
        subtitleLanguage.isEnabled = options.subtitles != .off
        autoSubtitles.state = options.autoSubtitles ? .on : .off
        autoSubtitles.isEnabled = options.subtitles != .off
        cover.state = options.embedThumbnail ? .on : .off
        details.state = options.embedMetadata ? .on : .off
        chapters.state = options.embedChapters ? .on : .off
        sponsors.selectItem(at: [SponsorMode.keep, .mark, .remove].firstIndex(of: options.sponsors) ?? 0)
        browser.selectItem(at: browsers.firstIndex(of: options.browser) ?? 0)
        speed.selectItem(at: SpeedLimit.choices.firstIndex(of: options.speedLimit) ?? 0)
        fileName.selectItem(at: FileNameStyle.allCases.firstIndex(of: options.fileName) ?? 0)
        audioQuality.selectItem(at: AudioQuality.allCases.firstIndex(of: options.audioQuality) ?? 0)
        live.state = options.liveFromStart ? .on : .off
    }

    /// Shows only what applies to this link and quality; what needs ffmpeg is greyed out without it.
    func configure(info: VideoInfo?, link: String?, quality: VideoQuality, hasFFmpeg: Bool) {
        let audio = quality.isAudio
        let playlist = info?.isPlaylist == true
        // Subtitle languages: those the video has. Generated ones come in the original language and
        // as dozens of machine translations, so only the original, this Mac's language and English.
        let mac = String(Locale.preferredLanguages.first?.split(separator: "-").first ?? "en")
        var codes = info?.subtitles ?? []
        if options.autoSubtitles, let auto = info?.autoSubtitles {
            codes += auto.filter { $0.hasSuffix("-orig") }.map { String($0.dropLast(5)) } + [mac, "en"].filter(auto.contains)
        }
        if codes.isEmpty { codes = [mac, "en"] }
        var unique: [String] = []
        for c in codes where !unique.contains(c) { unique.append(c) }
        languages = [""] + unique.prefix(40) + ["all"]
        subtitleLanguage.removeAllItems()
        subtitleLanguage.addItems(withTitles: languages.map(Self.languageName))
        subtitleMode.item(at: 2)?.isEnabled = hasFFmpeg

        let inList = link.map { $0.contains("list=") } ?? false
        let previous = playlistModes.isEmpty ? nil : playlistModes[max(0, playlistMode.indexOfSelectedItem)]
        playlistModes = playlist ? [.all, .items] : [.single, .all, .items]
        playlistMode.removeAllItems()
        playlistMode.addItems(withTitles: playlistModes.map {
            switch $0 {
            case .single: return L("This Video Only")
            case .all: return L("All Videos")
            case .items: return L("Choose Videos")
            }
        })
        playlistMode.selectItem(at: previous.flatMap { playlistModes.firstIndex(of: $0) } ?? 0)

        for c in [cover, details, chapters, sponsors] as [NSControl] { c.isEnabled = hasFFmpeg }
        if !audio && options.container == .webm { cover.isEnabled = false }
        for f in [startField, endField] { f.isEnabled = hasFFmpeg }
        let tip = hasFFmpeg ? nil : L("Needs ffmpeg: brew install ffmpeg")
        for c in [cover, details, chapters, sponsors, startField, endField] as [NSView] where tip != nil { c.toolTip = tip }

        let visible: [Row: Bool] = [
            .subtitles: !audio, .playlist: playlist || inList, .clip: !playlist, .embed: true, .sponsors: true,
            .signIn: true, .speed: true, .fileName: true, .audioQuality: audio, .live: info?.isLive == true,
        ]
        chapters.isHidden = audio
        for r in Row.allCases { grid.row(at: r.rawValue).isHidden = !(visible[r] ?? true) }
        sync()
        syncPlaylist()
        onLayoutChange?()
    }

    private func syncPlaylist() {
        let i = playlistMode.indexOfSelectedItem
        itemsField.isHidden = !(i >= 0 && i < playlistModes.count && playlistModes[i] == .items)
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "": return L("Automatic")
        case "all": return L("All Languages")
        default: return Locale.current.localizedString(forIdentifier: code) ?? code
        }
    }

    /// Forgets what belonged to the previous link.
    func resetForLink() {
        itemsField.stringValue = ""
        startField.stringValue = ""
        endField.stringValue = ""
        playlistModes = []
    }

    /// nil when the item list can't be read.
    func playlistChoice(info: VideoInfo?, link: String) -> PlaylistChoice? {
        let visible = info?.isPlaylist == true || link.contains("list=")
        let i = playlistMode.indexOfSelectedItem
        guard visible, i >= 0, i < playlistModes.count else { return .single }
        switch playlistModes[i] {
        case .single: return .single
        case .all: return .all
        case .items: return PlaylistItems.normalize(itemsField.stringValue).map { .items($0) }
        }
    }

    func clipInput(duration: Double?) -> ClipRange.Input {
        ClipRange.parse(start: startField.stringValue, end: endField.stringValue, duration: duration)
    }

    func flagItems() { itemsField.textColor = .systemRed }

    func flagClip() {
        startField.textColor = .systemRed
        endField.textColor = .systemRed
    }
}

// MARK: - Row

/// One download: progress, then Show in Finder / Open; finished files can be dragged out.
final class DownloadRow: NSView, NSDraggingSource {
    private static let actionWidth: CGFloat = 46
    private let job: DownloadJob
    private weak var model: VideoDownloads?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pauseButton = DownloadRow.iconButton("pause.circle.fill", L("Pause"))
    private let resumeButton = DownloadRow.iconButton("play.circle.fill", L("Resume"))
    private let cancelButton = DownloadRow.iconButton("xmark.circle.fill", L("Cancel"))
    private let retryButton = DownloadRow.iconButton("arrow.clockwise.circle.fill", L("Retry"))
    private let revealButton = DownloadRow.iconButton("magnifyingglass.circle.fill", L("Show in Finder"))
    private var mouseDown: NSEvent?

    init(job: DownloadJob, model: VideoDownloads) {
        self.job = job
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: DownloadPanel.width - 28, height: 50))
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
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
        status.lineBreakMode = .byWordWrapping
        status.cell?.truncatesLastVisibleLine = true
        status.preferredMaxLayoutWidth = DownloadPanel.width - 28 - 48 - 10 - Self.actionWidth - 10
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, bar, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView()
        buttons.setViews([pauseButton, resumeButton, retryButton, revealButton, cancelButton], in: .trailing)
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.action = #selector(pause)
        resumeButton.action = #selector(resume)
        cancelButton.action = #selector(cancel)
        retryButton.action = #selector(retry)
        revealButton.action = #selector(reveal)
        for b in [pauseButton, resumeButton, cancelButton, retryButton, revealButton] { b.target = self }
        addSubview(icon)
        addSubview(text)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 27),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
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
        if let thumbnail = job.thumbnail {
            icon.image = thumbnail
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.contentTintColor = nil
        } else {
            icon.image = Icons.symbol(job.request.quality.isAudio ? "music.note" : "film", config: .init(pointSize: 15, weight: .regular))
            icon.imageScaling = .scaleNone
            icon.contentTintColor = .tertiaryLabelColor
        }
        let active = job.state == .running || job.state == .finishing
        bar.isHidden = !(active || job.state == .paused)
        if active && (job.step != nil || !(job.meter.fraction.map { $0 > 0 } ?? false)) {
            if !bar.isIndeterminate { bar.isIndeterminate = true }
            if window?.isVisible == true { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        } else {
            bar.stopAnimation(nil)
            if bar.isIndeterminate { bar.isIndeterminate = false }
            bar.doubleValue = job.meter.fraction ?? 0
        }
        let problem = job.state == .failed || (job.state == .done && job.message != nil)
        status.textColor = problem ? .systemOrange : .secondaryLabelColor
        status.stringValue = job.statusText
        status.toolTip = job.message
        pauseButton.isHidden = job.state != .running
        resumeButton.isHidden = job.state != .paused
        cancelButton.isHidden = !(job.state.isActive || job.state == .paused)
        retryButton.isHidden = job.state != .failed && job.state != .cancelled
        revealButton.isHidden = job.state != .done
    }

    // Clicks on the row are the row's own: dragging out a file, not the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
        if event.clickCount == 2 && job.state == .done { model?.open(job) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDown, job.state == .done, let model else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        mouseDown = nil
        let files = model.existingFiles(job)
        guard !files.isEmpty else { return }
        let items = files.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(icon.frame, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // A copy: the downloaded file stays where it is.
        .copy
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            m.addItem(item)
        }
        switch job.state {
        case .done:
            add(L("Open"), #selector(open))
            add(L("Show in Finder"), #selector(reveal))
        case .running: add(L("Pause"), #selector(pause))
        case .paused: add(L("Resume"), #selector(resume))
        case .failed, .cancelled: add(L("Retry"), #selector(retry))
        default: break
        }
        add(L("Copy Link"), #selector(copyLink))
        if job.state.isActive || job.state == .paused {
            add(L("Cancel"), #selector(cancel))
        } else {
            add(L("Remove from List"), #selector(remove))
        }
        return m
    }

    @objc private func pause() { model?.pause(job) }
    @objc private func resume() { model?.resume(job) }
    @objc private func cancel() { model?.cancel(job) }
    @objc private func retry() { model?.retry(job) }
    @objc private func reveal() { model?.reveal(job) }
    @objc private func open() { model?.open(job) }
    @objc private func remove() { model?.remove(job) }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(job.url, forType: .string)
    }
}

extension DownloadJob {
    /// "42% · 3.1 MB/s · 0:12 left", "Paused · 42%", "Done · 742.0 KB", or why it failed.
    var statusText: String {
        switch state {
        case .queued: return L("Waiting…")
        case .running, .finishing:
            if let step { return step }
            let progress = DownloadText.progress(meter)
            return progress.isEmpty ? L("Starting…") : progress
        case .paused:
            return ([L("Paused")] + (meter.fraction.map { [StatFormat.percent($0)] } ?? [])).joined(separator: " · ")
        case .done:
            if alreadyThere { return L("Already in the folder") }
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

/// Settings › Power-ups › Video Downloads: the defaults the panel starts with, and the download
/// component.
enum VideoDownloadSettings {
    static func build(_ f: Form, settings s: Settings) {
        f.section(L("Video Downloads"))
        f.toggle(L("Show Download Video… in the menu"), get: { s.videoDownloadsEnabled }, set: { s.videoDownloadsEnabled = $0 })

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
            s.videoRecentFolders = RecentFolders.adding(url.path, to: s.videoRecentFolders)
            showFolder()
        }
        f.keep(choose)
        let chooseButton = NSButton(title: L("Choose…"), target: choose, action: #selector(ClosureTarget.fire(_:)))
        chooseButton.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderLabel, chooseButton])
        folderRow.spacing = 8
        f.custom(L("Save to"), folderRow)

        f.popup(L("Quality"), options: VideoQuality.common.map { ($0.storage, $0.title) },
                get: { s.videoQuality.storage }, set: { s.videoQuality = VideoQuality(storage: $0) ?? .best })
        f.popup(L("File Name"), options: FileNameStyle.allCases.map { ($0.rawValue, $0.title) },
                get: { s.videoOptions.fileName.rawValue },
                set: { v in var o = s.videoOptions; o.fileName = FileNameStyle(rawValue: v) ?? .title; s.videoOptions = o })

        let component = VideoToolsView(settings: s)
        f.keep(component)
        f.custom(L("Download Component"), component.view)
        f.onAppear { component.start() }
        f.onDisappear { component.stop() }
        f.note(L("Only download what you have the right to."))
    }
}

/// "2026.10.26 [Update] [Show in Finder] [Remove]", with a warning sign when something is missing.
final class VideoToolsView {
    let view = NSStackView()
    private let settings: Settings
    private let summary = NSTextField(labelWithString: "")
    private let warning = NSImageView()
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
        summary.lineBreakMode = .byTruncatingMiddle
        warning.image = Icons.symbol("exclamationmark.triangle.fill", config: .init(pointSize: 12, weight: .regular))
        warning.contentTintColor = .systemOrange
        let line = NSStackView(views: [summary, warning])
        line.spacing = 6
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 240).isActive = true
        buttons.spacing = 8
        [line, progress, buttons].forEach { view.addArrangedSubview($0) }
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
        var installing = false
        switch tools.install {
        case .running(let text, let fraction):
            installing = true
            summary.stringValue = text
            progress.isIndeterminate = fraction == nil
            progress.doubleValue = fraction ?? 0
            if fraction == nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        case .failed(let why): summary.stringValue = why
        case .finished(let what): summary.stringValue = what
        case .idle: summary.stringValue = tools.statusLine
        }
        summary.textColor = { if case .failed = tools.install { return .systemOrange } else { return .labelColor } }()
        let problems = tools.problems
        warning.isHidden = problems.isEmpty || installing
        warning.toolTip = problems.joined(separator: "\n")
        progress.isHidden = !installing
        if !installing { progress.stopAnimation(nil) }

        var list: [(String, () -> Void)] = []
        if installing {
            list.append((L("Cancel"), { tools.cancelInstall() }))
        } else {
            switch s.source {
            case nil: if tools.lookedUp { list.append((L("Install"), { tools.installManaged() })) }
            case .managed?: list.append((L("Update"), { tools.installManaged() }))
            case .custom?: list.append((L("Use Default"), { [weak self] in self?.settings.videoToolPath = ""; tools.refresh() }))
            // An existing install may be months old: BarTap's own copy is kept current and is used once it exists.
            default: list.append((L("Use BarTap's Own Copy"), { tools.installManaged() }))
            }
            if let path = s.path {
                list.append((L("Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }))
            }
            if s.source == .managed { list.append((L("Remove"), { tools.removeManaged() })) }
        }
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets = list.map { _, action in ClosureTarget { _ in action() } }
        for ((title, _), target) in zip(list, targets) {
            let b = NSButton(title: title, target: target, action: #selector(ClosureTarget.fire(_:)))
            b.bezelStyle = .rounded
            buttons.addArrangedSubview(b)
        }
    }
}
