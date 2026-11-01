import AppKit
import BarTapCore

/// Borderless panel that can take keyboard focus *without* activating BarTap, so the app the
/// user was in stays frontmost (like Spotlight).
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        contentView = effect
    }
}

// MARK: - Quick Search

/// ⌃⌥⌘F (default): type to find any menu bar icon, ↩ to open it — even hidden ones.
final class SearchPanel: FloatingPanel, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onActivate: ((BarItem) -> Void)?

    private let field = NSSearchField()
    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "")
    private var all: [BarItem] = []
    private var shown: [BarItem] = []
    private var searchKeys: [String] = []

    init() {
        super.init(size: NSSize(width: 520, height: 380))
        delegate = self
        let content = contentView!

        field.placeholderString = L("Search menu bar icons")
        field.font = .systemFont(ofSize: 18)
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateSelection)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(scroll)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    func present(on screen: NSScreen?, items: [BarItem], trusted: Bool) {
        all = items.sorted { a, b in
            a.section.rawValue != b.section.rawValue ? a.section.rawValue > b.section.rawValue : a.frame.minX < b.frame.minX
        }
        searchKeys = all.map { Self.searchKey(for: $0) }
        field.stringValue = ""
        hint.stringValue = trusted
            ? L("↩ open   ⎋ close   %d icons", all.count)
            : L("Grant Accessibility access in Settings to search menu bar icons.")
        filter()
        let s = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let f = s.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - f.height * 0.18))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// Title, app name and their pinyin, so "wifi", "无线" and "wuxian" all match.
    private static func searchKey(for item: BarItem) -> String {
        let base = "\(item.title) \(item.appName) \(item.bundleID)"
        let latin = base.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? ""
        return (base + " " + latin + " " + latin.replacingOccurrences(of: " ", with: "")).lowercased()
    }

    private func filter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            shown = all
        } else {
            let words = q.split(separator: " ").map(String.init)
            shown = zip(all, searchKeys).filter { _, key in words.allSatisfy { key.contains($0) } }.map(\.0)
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func activateSelection() {
        let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
        guard row >= 0, row < shown.count else { return }
        let item = shown[row]
        close()
        onActivate?(item)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: item.icon)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let section: String
        switch item.section {
        case .shown: section = L("Shown")
        case .hidden: section = L("Hidden")
        case .alwaysHidden: section = L("Always Hidden")
        }
        let sub = NSTextField(labelWithString: "\(item.appName) · \(section)")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Shelf

/// A strip under the menu bar listing hidden icons, like Bartender's bar below the menu bar:
/// clicking one reveals its section and opens it via Accessibility. Nothing is moved, and the
/// pointer is never touched. Real icon images need Screen Recording; until then, app icons.
final class ShelfPanel: FloatingPanel {
    var onActivate: ((BarItem) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRequestImages: (() -> Void)?
    /// Lets the owner drop the outside-click monitor once the shelf is gone.
    var onClosed: (() -> Void)?
    private let stack = NSStackView()
    private var items: [BarItem] = []
    private var buttons: [NSButton] = []
    private var widths: [NSLayoutConstraint] = []
    private var placement: (screen: ScreenInfo, anchorX: CGFloat)?
    private static let iconHeight: CGFloat = 24

    init() {
        super.init(size: NSSize(width: 200, height: 40))
        level = .statusBar
        (contentView as? NSVisualEffectView)?.material = .menu
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
        ])
    }

    /// - Parameters:
    ///   - anchorX: CG x the shelf's right edge should align with (the toggle on that display).
    ///   - appearance: the menu bar's, so captured icons keep their contrast.
    func present(items: [BarItem], trusted: Bool, on screen: ScreenInfo, anchorX: CGFloat, appearance: NSAppearance?) {
        self.items = items
        self.appearance = appearance
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        widths.removeAll()
        if !trusted {
            let b = NSButton(title: L("Allow Accessibility to list hidden icons here…"), target: self, action: #selector(openSettings))
            b.bezelStyle = .inline
            stack.addArrangedSubview(b)
        } else if items.isEmpty {
            let l = NSTextField(labelWithString: L("No hidden icons. ⌘-drag icons left of the divider to hide them."))
            l.textColor = .secondaryLabelColor
            stack.addArrangedSubview(l)
        } else {
            for (i, item) in items.enumerated() {
                let b = NSButton(image: item.icon, target: self, action: #selector(clicked(_:)))
                b.tag = i
                b.isBordered = false
                b.imageScaling = .scaleProportionallyDown
                b.toolTip = item.title == item.appName ? item.title : "\(item.title) — \(item.appName)"
                b.setAccessibilityLabel(b.toolTip)
                b.translatesAutoresizingMaskIntoConstraints = false
                let width = b.widthAnchor.constraint(equalToConstant: 30)
                width.isActive = true
                b.heightAnchor.constraint(equalToConstant: Self.iconHeight + 2).isActive = true
                stack.addArrangedSubview(b)
                buttons.append(b)
                widths.append(width)
            }
            if !ItemImages.permitted {
                let b = NSButton(title: L("Show real icons…"), target: self, action: #selector(requestImages))
                b.bezelStyle = .inline
                b.controlSize = .small
                b.toolTip = L("Allow Screen Recording so the shelf can show each icon as it looks in the menu bar.")
                stack.addArrangedSubview(b)
            }
        }
        placement = (screen, anchorX)
        layoutAndPlace()
        orderFrontRegardless()
    }

    /// Swaps in captured images, keyed by `BarItem.key`, at menu bar size.
    func updateImages(_ images: [String: NSImage]) {
        guard !images.isEmpty else { return }
        for (i, item) in items.enumerated() where i < buttons.count {
            guard let img = images[item.key], img.size.height > 0 else { continue }
            let scale = min(1, Self.iconHeight / img.size.height)
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            let sized = NSImage(size: size, flipped: false) { r in img.draw(in: r); return true }
            buttons[i].image = sized
            widths[i].constant = max(size.width, 16)
        }
        layoutAndPlace()
    }

    private func layoutAndPlace() {
        guard let (screen, anchorX) = placement else { return }
        stack.layoutSubtreeIfNeeded()
        let width = min(max(stack.fittingSize.width, 60), screen.frame.width - 40)
        let height: CGFloat = Self.iconHeight + 12
        // Just under the bar, right-aligned to the toggle, clamped to the display.
        let maxX = min(max(anchorX, screen.frame.minX + width + 8), screen.frame.maxX - 8)
        let cgRect = CGRect(x: maxX - width, y: screen.frame.minY + screen.menuBarHeight + 6, width: width, height: height)
        let cocoaY = SystemQueries.mainScreenHeight - cgRect.maxY
        setFrame(NSRect(x: cgRect.minX, y: cocoaY, width: width, height: height), display: true)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        let item = items[sender.tag]
        orderOut(nil)
        onClosed?()
        onActivate?(item)
    }

    @objc private func openSettings() {
        orderOut(nil)
        onClosed?()
        onOpenSettings?()
    }

    @objc private func requestImages() {
        orderOut(nil)
        onClosed?()
        onRequestImages?()
    }

    func containsCG(_ p: CGPoint) -> Bool {
        guard isVisible else { return false }
        return SystemQueries.cgRect(fromCocoa: frame).insetBy(dx: -2, dy: -2).contains(p)
    }
}

// MARK: - Toast

/// Small transient HUD ("Copied #3A7BD5").
final class Toast {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ text: String, symbol: String? = nil) {
        work?.cancel()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let views: [NSView] = (symbol.map { [NSImageView(image: Icons.symbol($0))] } ?? []) + [label]
        let stack = NSStackView(views: views)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        let size = stack.fittingSize
        let p = panel ?? FloatingPanel(size: size)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        stack.frame = NSRect(origin: .zero, size: size)
        p.contentView?.addSubview(stack)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
        panel = p
        let w = DispatchWorkItem { panel?.orderOut(nil) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }
}
