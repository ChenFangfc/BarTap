import AppKit
import BarTapCore

/// Settings › Layout: the menu bar's icons in rows, Shown, Hidden and Always Hidden, each left to
/// right as in the menu bar. Drag an icon to another row to show or hide it, or along its row to
/// change the order; right-click for the same moves without dragging. Nothing moves in the menu bar
/// until Apply. Icons show as captured from the menu bar (Screen Recording) or as their app's icon
/// with a name underneath, so two icons of one app can be told apart.
final class LayoutEditorView: NSView, NSViewToolTipOwner {
    typealias Row = LayoutArrangement.Row

    private struct Slot {
        let key: String
        let row: Row
        /// Index among the row's movable icons (pinned ones come after them).
        let index: Int
        let pinned: Bool
        var frame: NSRect
    }

    private struct Box { let row: Row; let frame: NSRect; let lines: [ClosedRange<CGFloat>] }

    /// An icon was dropped at `index` of `row` (an index among that row's icons before the move).
    var onMove: ((String, Row, Int) -> Void)?
    /// "Move to …" from the context menu.
    var onSend: ((String, Row) -> Void)?
    var isEnabled = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var darkBar = false { didSet { needsDisplay = true } }

    private var arrangement = LayoutArrangement()
    private var items: [String: BarItem] = [:]
    private var images: [String: NSImage] = [:]
    private var touched: Set<String> = []
    private var rows: [Row] = [.shown, .hidden]
    private var captions = false
    private var slots: [Slot] = []
    private var boxes: [Box] = []
    /// BarTap's own place at the left of Shown.
    private var anchorFrame = NSRect.zero

    private var pressed: (slot: Slot, at: NSPoint)?
    private var dragging: Slot?
    private var dragPoint = NSPoint.zero
    private var target: (row: Row, index: Int)?

    static let width: CGFloat = 592
    private static let iconHeight: CGFloat = 20
    private static let slotPad: CGFloat = 6
    private static let boxPad: CGFloat = 5
    private static let titleHeight: CGFloat = 20
    private static let rowGap: CGFloat = 10
    private static let captionHeight: CGFloat = 13
    private static let captionFont = NSFont.systemFont(ofSize: 9)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }

    func show(_ arrangement: LayoutArrangement, items: [String: BarItem], images: [String: NSImage], touched: Set<String>, alwaysSection: Bool) {
        self.arrangement = arrangement
        self.items = items
        self.images = images
        self.touched = touched
        captions = images.isEmpty
        rows = alwaysSection ? [.shown, .hidden, .always] : [.shown, .hidden]
        relayout()
    }

    private var lineHeight: CGFloat { Self.iconHeight + 10 + (captions ? Self.captionHeight : 0) }

    private func slotWidth(_ key: String) -> CGFloat {
        if let img = images[key], img.size.height > 0 {
            return max(Self.iconHeight, img.size.width * min(1, Self.iconHeight / img.size.height)) + 2 * Self.slotPad
        }
        let caption = captions ? min(64, ((items[key]?.appName ?? "") as NSString).size(withAttributes: [.font: Self.captionFont]).width) : 0
        return max(Self.iconHeight, caption) + 2 * Self.slotPad
    }

    private func relayout() {
        slots = []
        boxes = []
        var y: CGFloat = 0
        let inner = Self.width - 2 * Self.boxPad
        for row in rows {
            y += Self.titleHeight
            let top = y
            var lines: [ClosedRange<CGFloat>] = []
            var x = Self.boxPad
            var lineTop = top + Self.boxPad
            func place(_ width: CGFloat) -> NSRect {
                if x + width > Self.boxPad + inner, x > Self.boxPad {
                    lines.append(lineTop...(lineTop + lineHeight))
                    lineTop += lineHeight
                    x = Self.boxPad
                }
                defer { x += width }
                return NSRect(x: x, y: lineTop, width: width, height: lineHeight)
            }
            if row == .shown { anchorFrame = place(21 + 2 * Self.slotPad) }
            for (i, key) in arrangement[row].enumerated() {
                slots.append(Slot(key: key, row: row, index: i, pinned: false, frame: place(slotWidth(key))))
            }
            if row == .shown {
                for key in arrangement.pinned {
                    slots.append(Slot(key: key, row: row, index: arrangement.shown.count, pinned: true, frame: place(slotWidth(key))))
                }
            }
            lines.append(lineTop...(lineTop + lineHeight))
            let bottom = lineTop + lineHeight + Self.boxPad
            boxes.append(Box(row: row, frame: NSRect(x: 0, y: top, width: Self.width, height: bottom - top), lines: lines))
            y = bottom + Self.rowGap
        }
        setFrameSize(NSSize(width: Self.width, height: y - Self.rowGap + 2))
        invalidateIntrinsicContentSize()
        removeAllToolTips()
        for s in slots { addToolTip(s.frame, owner: self, userData: nil) }
        if rows.contains(.shown) { addToolTip(anchorFrame, owner: self, userData: nil) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Drawing

    private static func title(_ row: Row) -> String {
        switch row {
        case .shown: return L("Shown")
        case .hidden: return L("Hidden")
        case .always: return L("Always Hidden")
        }
    }

    private static func subtitle(_ row: Row) -> String {
        switch row {
        case .shown: return L("always in the menu bar, right of the BarTap icon")
        case .hidden: return L("shown when you click the BarTap icon")
        case .always: return L("shown when you ⌥-click the BarTap icon")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let barColor = darkBar ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        for box in boxes {
            let title = NSMutableAttributedString(string: Self.title(box.row),
                                                  attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
            title.append(NSAttributedString(string: "  " + Self.subtitle(box.row),
                                            attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
            title.draw(at: NSPoint(x: 2, y: box.frame.minY - Self.titleHeight + 3))
            let r = box.frame.insetBy(dx: 0.5, dy: 0.5)
            barColor.setFill()
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            path.fill()
            if let t = target, t.row == box.row {
                NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            if !slots.contains(where: { $0.row == box.row }) && box.row != .shown {
                let hint = L("Drag icons here")
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
                let size = (hint as NSString).size(withAttributes: attrs)
                (hint as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
            }
        }
        if rows.contains(.shown) {
            let mark = Self.tinted(Icons.logoMark(mirrored: false), darkBar ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.4))
            mark.draw(in: NSRect(x: anchorFrame.midX - 10.5, y: anchorFrame.minY + 5 + (Self.iconHeight - 12) / 2, width: 21, height: 12),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for s in slots {
            let alpha: CGFloat = dragging?.key == s.key ? 0.25 : (s.pinned ? 0.45 : (isEnabled ? 1 : 0.6))
            drawIcon(s.key, in: s.frame, alpha: alpha)
            if touched.contains(s.key) && dragging?.key != s.key {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: s.frame.midX - 2, y: s.frame.maxY - 5, width: 4, height: 4)).fill()
            }
        }
        if let t = target, let caret = caretRect(t) {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: caret, xRadius: 1, yRadius: 1).fill()
        }
        if let d = dragging {
            let w = d.frame.width
            let r = NSRect(x: dragPoint.x - w / 2, y: dragPoint.y - lineHeight / 2, width: w, height: lineHeight)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            drawIcon(d.key, in: r, alpha: 0.95)
        }
    }

    private func drawIcon(_ key: String, in frame: NSRect, alpha: CGFloat) {
        let iconBox = NSRect(x: frame.minX, y: frame.minY + 5, width: frame.width, height: Self.iconHeight)
        if let img = images[key], img.size.height > 0 {
            let scale = min(1, Self.iconHeight / img.size.height)
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            img.draw(in: NSRect(x: iconBox.midX - size.width / 2, y: iconBox.midY - size.height / 2, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            return
        }
        guard let item = items[key] else { return }
        let side: CGFloat = 18
        item.icon.draw(in: NSRect(x: iconBox.midX - side / 2, y: iconBox.midY - side / 2, width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        if captions {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineBreakMode = .byTruncatingTail
            (item.appName as NSString).draw(in: NSRect(x: frame.minX + 1, y: iconBox.maxY + 2, width: frame.width - 2, height: Self.captionHeight),
                                            withAttributes: [.font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha), .paragraphStyle: p])
        }
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: Dropping

    /// Where a drop at `p` would go: the row under it and the gap nearest the pointer.
    private func dropTarget(at p: NSPoint) -> (row: Row, index: Int)? {
        guard let box = boxes.first(where: { $0.frame.insetBy(dx: -4, dy: -8).contains(p) }) else { return nil }
        let movable = slots.filter { $0.row == box.row && !$0.pinned }
        guard !movable.isEmpty else { return (box.row, 0) }
        // The line nearest the pointer, then the first icon on it whose centre is right of the pointer.
        let lineTops = Set(movable.map(\.frame.minY)).sorted()
        let line = lineTops.min { abs($0 + lineHeight / 2 - p.y) < abs($1 + lineHeight / 2 - p.y) } ?? lineTops[0]
        let onLine = movable.filter { $0.frame.minY == line }
        if let s = onLine.first(where: { $0.frame.midX > p.x }) { return (box.row, s.index) }
        return (box.row, (onLine.last?.index ?? -1) + 1)
    }

    private func caretRect(_ t: (row: Row, index: Int)) -> NSRect? {
        let movable = slots.filter { $0.row == t.row && !$0.pinned }
        if let s = movable.first(where: { $0.index == t.index }) {
            return NSRect(x: s.frame.minX - 1, y: s.frame.minY + 2, width: 2, height: lineHeight - 4)
        }
        if let s = movable.last {
            return NSRect(x: s.frame.maxX - 1, y: s.frame.minY + 2, width: 2, height: lineHeight - 4)
        }
        guard let box = boxes.first(where: { $0.row == t.row }) else { return nil }
        let x = t.row == .shown ? anchorFrame.maxX : box.frame.minX + Self.boxPad + 2
        return NSRect(x: x - 1, y: box.frame.minY + Self.boxPad + 2, width: 2, height: lineHeight - 4)
    }

    // MARK: Mouse

    private func slot(at p: NSPoint) -> Slot? { slots.first { $0.frame.contains(p) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let s = slot(at: p), !s.pinned { pressed = (s, p) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        if dragging == nil {
            guard hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 3 else { return }
            dragging = pressed.slot
            NSCursor.closedHand.push()
        }
        dragPoint = p
        target = dropTarget(at: p)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            if dragging != nil { NSCursor.pop() }
            pressed = nil
            dragging = nil
            target = nil
            needsDisplay = true
        }
        guard let d = dragging, let t = target else { return }
        // Dropped back where it was: nothing to do.
        if t.row == d.row && (t.index == d.index || t.index == d.index + 1) { return }
        onMove?(d.key, t.row, t.index)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, let s = slot(at: convert(event.locationInWindow, from: nil)), !s.pinned else { return nil }
        let menu = NSMenu()
        for row in rows where row != s.row {
            let item = NSMenuItem(title: String(format: L("Move to %@"), Self.title(row)), action: #selector(ClosureMenuTarget.fire(_:)), keyEquivalent: "")
            let target = ClosureMenuTarget { [weak self] in self?.onSend?(s.key, row) }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        return menu
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        for s in slots where !s.pinned { addCursorRect(s.frame, cursor: .openHand) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if anchorFrame.contains(point) { return L("The BarTap button: icons right of it are shown") }
        guard let s = slot(at: point), let item = items[s.key] else { return "" }
        let name = item.title == item.appName ? item.appName : "\(item.title) — \(item.appName)"
        return s.pinned ? name + "\n" + L("macOS keeps this at the right end") : name
    }
}

/// Keeps the editor in step with the menu bar while Settings › Layout is open, holds the user's
/// edits until Apply, and reports what Apply did. Every icon is revealed only for the few seconds
/// it takes to read the bar and capture the icons (when the page opens, after Apply, for a new
/// icon); on a bar too crowded to draw them all, BarTap's stats items shrink meanwhile. The rest of
/// the time the menu bar stays as the user set it, the same on every display, and the rows keep
/// that reading: an icon that is hidden or doesn't fit reports a stale place.
final class LayoutPaneModel {
    private weak var host: SettingsHost?
    let editor = LayoutEditorView()
    let status = NSTextField(wrappingLabelWithString: "")
    weak var applyButton: NSButton? { didSet { updateControls() } }
    weak var revertButton: NSButton? { didSet { updateControls() } }
    /// Shown only while Screen Recording is off.
    weak var permissionButton: NSButton? { didSet { permissionButton?.isHidden = ItemImages.permitted } }

    private var timer: Timer?
    private var items: [String: BarItem] = [:]
    private var images: [String: NSImage] = [:]
    private var live = LayoutArrangement()
    /// The user's edits; nil while the rows show the bar as it is.
    private var pending: LayoutArrangement?
    private var touched: Set<String> = []
    private var alwaysSection = false
    private var signature = ""
    /// Icons still without a captured image are tried again until then: apps whose icons were off
    /// screen can take a few seconds to draw them once revealed.
    private var retryUntil = Date.distantPast
    private var applying = false
    /// What the last Apply did, shown until the next edit.
    private var report: String?
    /// Every icon is revealed for capturing; and the icons tried that way (one that comes back
    /// blank must not reveal the bar again and again).
    private var revealing = false
    private var slimmed = false
    /// Readings are trusted once the bar has settled after revealing (or making room), and the bar
    /// goes back only after one such reading.
    private var settledAt = Date.distantFuture
    private var readSettled = false
    private var tried: Set<String> = []
    /// Displays that can't fit every shown icon, as a note (checked while icons are hidden).
    private var crowding: String?

    static let pinnedIdentifiers: Set<String> = ["com.apple.menuextra.controlcenter", "com.apple.menuextra.clock"]

    init(host: SettingsHost?) {
        self.host = host
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 560
        editor.onMove = { [weak self] key, row, index in
            self?.edit(key) { $0.move(key, to: row, at: index) }
        }
        editor.onSend = { [weak self] key, row in
            self?.edit(key) { $0.send(key, to: row) }
        }
    }

    func start() {
        signature = ""
        tried = []
        retryUntil = Date().addingTimeInterval(ItemImages.permitted ? 8 : 2)
        reveal(true)
        // Give the bar a moment to show everything before the first look.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if applying { host?.cancelLayoutApply() }
        reveal(false)
        Memory.returnFreedPages(after: 1.0)
    }

    private func reveal(_ on: Bool) {
        guard on != revealing else { return }
        revealing = on
        host?.revealForLayout(on)
        if on {
            settledAt = Date().addingTimeInterval(0.5)
            readSettled = false
            // Once the bar is out: if it can't draw every icon (beside the notch), make room.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.revealing, !self.slimmed, Self.crowded() else { return }
                self.slimmed = true
                self.host?.setStatsSlim(true)
                self.settledAt = Date().addingTimeInterval(0.7)
                self.readSettled = false
                self.signature = ""
                self.retryUntil = max(self.retryUntil, Date().addingTimeInterval(2))
            }
        } else if slimmed {
            slimmed = false
            host?.setStatsSlim(false)
        }
    }

    /// A display whose bar is drawn leaves some icons out: their windows sit in its bar, not drawn.
    static func crowded() -> Bool {
        let windows = SystemQueries.windows(onScreenOnly: false)
        return SystemQueries.screens(windows: windows).contains { s in
            guard !s.asleep, MenuBarGeometry.row(on: s, windows: windows).contains(where: \.isOnScreen) else { return false }
            return windows.contains {
                $0.layer == WindowLevel.status && !$0.isOnScreen && abs($0.bounds.minY - s.frame.minY) <= 1
                    && $0.bounds.width < separatorWidthThreshold && $0.bounds.midX > s.frame.minX && $0.bounds.midX < s.frame.maxX
            }
        }
    }

    // MARK: Editing

    private func edit(_ key: String, _ change: (inout LayoutArrangement) -> Void) {
        guard !applying else { return }
        var a = pending ?? live
        change(&a)
        touched.insert(key)
        pending = a == live ? nil : a
        if pending == nil { touched = [] }
        report = nil
        show()
    }

    func revert() {
        guard !applying else { return }
        pending = nil
        touched = []
        report = nil
        show()
    }

    func apply() {
        guard let host, let wanted = pending, !applying else { return }
        applying = true
        report = nil
        updateControls()
        status.stringValue = L("Arranging… Leave the mouse and keyboard alone for a moment: using them stops it.")
        let request = LayoutApplier.Request(arrangement: wanted, alwaysSection: alwaysSection, touched: touched)
        host.applyLayout(request, progress: { [weak self] k, n in
            self?.status.stringValue = String(format: L("Moving icon %d of %d… Using the mouse or keyboard stops it."), k, n)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.applying = false
            self.report = Self.describe(result)
            // Finished: the rows show the bar as it is now (icons macOS kept in place included).
            if result.finish == .done {
                self.pending = nil
                self.touched = []
            }
            // Read the new order while every icon is still out (an app's icons are numbered by position).
            self.tried = []
            self.retryUntil = Date().addingTimeInterval(ItemImages.permitted ? 4 : 2)
            self.reveal(true)
            self.signature = ""
            self.updateControls()
            self.status.stringValue = self.report ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
        })
    }

    static func describe(_ r: LayoutApplier.Report) -> String {
        var lines: [String] = []
        switch r.finish {
        case .done:
            lines.append(r.moves == 0 && r.stuck.isEmpty ? L("Nothing to move: the menu bar already matches.") : L("Done: the menu bar matches these rows."))
        case .interrupted:
            lines.append(r.left > 0 ? String(format: L("Stopped because the mouse or keyboard was used. Click Apply to finish (%d moves left)."), r.left)
                                    : L("Stopped because the mouse or keyboard was used. Click Apply to finish."))
        case .failed(let message):
            lines.append(message)
        }
        if !r.stuck.isEmpty {
            lines.append(String(format: L("macOS kept these where they were: %@. You can ⌘-drag them in the menu bar yourself."), r.stuck.joined(separator: ", ")))
        }
        if !r.notDrawn.isEmpty {
            lines.append(String(format: L("Not moved because they don't fit in the menu bar right now: %@. Make room (quit an app, or hide a few icons) and Apply again."),
                                r.notDrawn.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Showing

    static func arrangement(of items: [BarItem]) -> LayoutArrangement {
        var a = LayoutArrangement()
        for item in items {
            if item.section == .shown, let id = item.identifier, Self.pinnedIdentifiers.contains(id) {
                a.pinned.append(item.slotKey)
                continue
            }
            switch item.section {
            case .shown: a.shown.append(item.slotKey)
            case .hidden: a.hidden.append(item.slotKey)
            case .alwaysHidden: a.always.append(item.slotKey)
            }
        }
        return a
    }

    private func show() {
        editor.isEnabled = !applying
        editor.show(pending ?? live, items: items, images: images, touched: touched, alwaysSection: alwaysSection)
        updateControls()
        guard !applying else { return }
        var notes: [String] = []
        if let report { notes.append(report) }
        if let pending, report == nil {
            let anchors = Set(["‖", "│"] + live.pinned)
            let n = LayoutPlan.steps(current: live.order(alwaysSection: alwaysSection), wanted: pending.order(alwaysSection: alwaysSection), anchors: anchors).count
            notes.append(n == 1 ? L("1 move needed. Click Apply, then leave the mouse alone for a few seconds.")
                                : String(format: L("%d moves needed. Click Apply, then leave the mouse alone for a few seconds."), n))
        }
        if let crowding { notes.append(crowding) }
        if !ItemImages.permitted { notes.append(L("Icons show as their app's icon and name. Allow Screen Recording to see the icons themselves.")) }
        status.stringValue = notes.joined(separator: "\n")
    }

    /// BarTap's own stats items as BarTap draws them: always at hand, even when hidden or behind
    /// the notch (a capture needs the icon on screen).
    private func withOwnImages(_ images: [String: NSImage], items: [BarItem]) -> [String: NSImage] {
        guard let host else { return images }
        var out = images
        let dark = host.menuBarIsDark
        for item in items {
            guard let id = item.identifier, id.hasPrefix("bartap.stats."), let img = host.statsItemImage(id) else { continue }
            out[item.slotKey] = Self.barTinted(img, dark: dark)
        }
        return out
    }

    /// A template image in the menu bar's ink.
    static func barTinted(_ image: NSImage, dark: Bool) -> NSImage {
        guard image.isTemplate else { return image }
        let ink = dark ? NSColor.white : NSColor.black
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Hidden icons are hidden on every display alike (one divider for all), but a display too
    /// narrow for every shown icon leaves some out: macOS drops what doesn't fit. Names those
    /// displays, so the user can hide icons until every display shows the same.
    static func crowdedDisplays() -> String? {
        let windows = SystemQueries.windows(onScreenOnly: false)
        let short = MenuBarGeometry.shortRows(screens: SystemQueries.screens(windows: windows), windows: windows)
        guard !short.isEmpty else { return nil }
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        return short.map { d in
            String(format: L("%@ is too narrow for every shown icon: macOS leaves out %d there. Move icons to Hidden until it fits, and every display shows the same."),
                   names[d.screen.id] ?? L("A display"), d.missing)
        }.joined(separator: "\n")
    }

    private func updateControls() {
        applyButton?.isEnabled = pending != nil && !applying
        revertButton?.isEnabled = pending != nil && !applying
    }

    private func refresh() {
        guard let host, !applying else { return }
        // Done reading and capturing (or given up on slow icons): the bar goes back as the user had it.
        if revealing, Date() >= retryUntil, readSettled || Date() >= retryUntil.addingTimeInterval(5) { reveal(false) }
        guard AXCatalog.isTrusted else {
            editor.isHidden = true
            status.stringValue = L("Allow Accessibility (Settings › About) to see and arrange your menu bar here.")
            return
        }
        editor.isHidden = false
        let settled = revealing && Date() >= settledAt
        host.catalogSnapshot { [weak self] items in
            guard let self, !self.applying else { return }
            let always = host.settings.alwaysHiddenEnabled
            let sig = items.map { "\($0.slotKey)@\(Int($0.order / 4))/\($0.section.rawValue)" }.joined(separator: ",") + "\(always)"
            let missing = ItemImages.permitted && items.contains { ItemImages.cache[$0.slotKey] == nil }
            // A new icon, never captured: reveal everything once more, briefly.
            if ItemImages.permitted, !self.revealing, items.contains(where: { ItemImages.cache[$0.slotKey] == nil && !self.tried.contains($0.slotKey) }) {
                self.retryUntil = Date().addingTimeInterval(8)
                self.reveal(true)
                self.signature = ""
                return
            }
            if sig != self.signature, self.revealing { self.retryUntil = max(self.retryUntil, Date().addingTimeInterval(2)) }
            let crowding = host.barCollapsed && !self.revealing ? Self.crowdedDisplays() : nil
            guard sig != self.signature || (missing && self.revealing && Date() < self.retryUntil) || crowding != self.crowding
                    || (settled && !self.readSettled) else { return }
            self.crowding = crowding
            self.signature = sig
            self.items = Dictionary(items.map { ($0.slotKey, $0) }, uniquingKeysWith: { first, _ in first })
            // Places are read while every icon is out; in between, only icons coming and going change
            // the rows (a hidden icon, or one that doesn't fit, reports a stale place).
            let fresh = Self.arrangement(of: items)
            let live = settled || self.live == LayoutArrangement() ? fresh : self.live.merged(into: fresh)
            if settled { self.readSettled = true }
            if always != self.alwaysSection {
                // The rows themselves changed: start over from the bar.
                self.pending = nil
                self.touched = []
            }
            self.alwaysSection = always
            if let p = self.pending {
                let merged = p.merged(into: live)
                self.pending = merged == live ? nil : merged
                self.touched = self.touched.intersection(self.items.keys)
            }
            self.live = live
            self.images = self.withOwnImages(ItemImages.permitted ? ItemImages.cache : [:], items: items)
            self.editor.darkBar = host.menuBarIsDark
            self.permissionButton?.isHidden = ItemImages.permitted
            self.show()
            guard ItemImages.permitted else { return }
            // The bar has just changed: let it settle, then capture what is drawn (hidden icons keep
            // the image from when they were last out).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.signature == sig, !self.applying else { return }
                let revealed = self.revealing
                ItemImages.capture(items) { [weak self] images in
                    guard let self, self.signature == sig, !self.applying else { return }
                    if revealed { self.tried.formUnion(items.map(\.slotKey)) }
                    self.images = self.withOwnImages(images, items: items)
                    self.show()
                    if self.revealing, self.readSettled, !items.contains(where: { images[$0.slotKey] == nil }) { self.reveal(false) }
                }
            }
        }
    }
}
