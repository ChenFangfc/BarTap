import AppKit
import BarTapCore

enum LayoutHandle { case hidden, always }

/// Settings › Layout: the menu bar's icons in order, left to right, with BarTap's dividers as
/// handles. Dragging │ chooses which icons are hidden (those left of it), dragging ‖ which are
/// always hidden. Icons show as captured from the menu bar (Screen Recording) or as their app's
/// icon with a name underneath, so two icons of one app can be told apart.
final class LayoutStripView: NSView, NSViewToolTipOwner {
    private struct Slot { let item: BarItem; let image: NSImage?; var frame: NSRect }

    private var slots: [Slot] = []
    private var hiddenGap = 0
    private var alwaysGap: Int?
    private var handleX: [LayoutHandle: CGFloat] = [:]
    private var dragging: LayoutHandle?
    private var dragX: CGFloat = 0
    private var captions = false
    var darkBar = false { didSet { needsDisplay = true } }
    /// A handle was dropped on gap n (n icons left of it).
    var onMove: ((LayoutHandle, Int) -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }

    private static let margin: CGFloat = 10
    private static let barTop: CGFloat = 18
    private static let barHeight: CGFloat = 30
    private static let iconHeight: CGFloat = 20
    private static let slotPad: CGFloat = 5
    private static let handleWidth: CGFloat = 16
    private static let captionHeight: CGFloat = 14

    override var isFlipped: Bool { true }

    func show(items: [BarItem], images: [String: NSImage], alwaysSection: Bool) {
        captions = images.isEmpty
        slots = items.map { Slot(item: $0, image: images[$0.slotKey], frame: .zero) }
        hiddenGap = items.filter { $0.section != .shown }.count
        alwaysGap = alwaysSection ? items.filter { $0.section == .alwaysHidden }.count : nil
        relayout()
    }

    private func slotWidth(_ s: Slot) -> CGFloat {
        if let img = s.image, img.size.height > 0 {
            return img.size.width * min(1, Self.iconHeight / img.size.height) + 2 * Self.slotPad
        }
        let caption = captions ? min(64, (s.item.title as NSString).size(withAttributes: [.font: Self.captionFont]).width) : 0
        return max(Self.iconHeight, caption) + 2 * Self.slotPad
    }

    private static let captionFont = NSFont.systemFont(ofSize: 9)

    private func relayout() {
        var x = Self.margin
        handleX.removeAll()
        for i in 0...slots.count {
            if i == alwaysGap { handleX[.always] = x + Self.handleWidth / 2; x += Self.handleWidth }
            if i == hiddenGap { handleX[.hidden] = x + Self.handleWidth / 2; x += Self.handleWidth }
            guard i < slots.count else { break }
            let w = slotWidth(slots[i])
            slots[i].frame = NSRect(x: x, y: Self.barTop, width: w, height: Self.barHeight)
            x += w
        }
        let height = Self.barTop + Self.barHeight + (captions ? Self.captionHeight + 4 : 6)
        setFrameSize(NSSize(width: x + Self.margin, height: height))
        invalidateIntrinsicContentSize()
        removeAllToolTips()
        for s in slots { addToolTip(s.frame, owner: self, userData: nil) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { frame.size }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: Self.margin / 2, y: Self.barTop, width: bounds.width - Self.margin, height: Self.barHeight)
        (darkBar ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7).fill()

        // Sections: tinted ranges, titled above.
        let gaps = previewGaps()
        let ranges: [(String, Range<Int>, CGFloat)] = [
            (L("Always Hidden"), 0..<(gaps.always ?? 0), 0.22),
            (L("Hidden"), (gaps.always ?? 0)..<gaps.hidden, 0.12),
            (L("Shown"), gaps.hidden..<slots.count, 0),
        ]
        for (title, range, tint) in ranges where !range.isEmpty {
            let r = NSRect(x: slots[range.lowerBound].frame.minX, y: Self.barTop + 2,
                           width: slots[range.upperBound - 1].frame.maxX - slots[range.lowerBound].frame.minX, height: Self.barHeight - 4)
            if tint > 0 {
                (darkBar ? NSColor.white : NSColor.black).withAlphaComponent(tint * 0.6).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (title as NSString).size(withAttributes: attrs)
            if size.width <= r.width + 20 {
                (title as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: 2), withAttributes: attrs)
            }
        }

        for (i, s) in slots.enumerated() {
            let moving = gaps.hidden != hiddenGap && (min(gaps.hidden, hiddenGap)..<max(gaps.hidden, hiddenGap)).contains(i)
                || gaps.always != alwaysGap && (min(gaps.always ?? 0, alwaysGap ?? 0)..<max(gaps.always ?? 0, alwaysGap ?? 0)).contains(i)
            let alpha: CGFloat = moving ? 0.45 : 1
            if let img = s.image, img.size.height > 0 {
                let scale = min(1, Self.iconHeight / img.size.height)
                let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
                img.draw(in: NSRect(x: s.frame.midX - size.width / 2, y: s.frame.midY - size.height / 2, width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            } else {
                let icon = s.item.icon
                let side = Self.iconHeight
                icon.draw(in: NSRect(x: s.frame.midX - side / 2, y: s.frame.midY - side / 2, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                if captions {
                    let p = NSMutableParagraphStyle()
                    p.alignment = .center
                    p.lineBreakMode = .byTruncatingTail
                    (s.item.title as NSString).draw(in: NSRect(x: s.frame.minX, y: s.frame.maxY + 3, width: s.frame.width, height: Self.captionHeight),
                                                    withAttributes: [.font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p])
                }
            }
        }

        for (handle, x) in handleX {
            let drawX = dragging == handle ? dragX : x
            drawHandle(handle, at: drawX)
        }
    }

    private func drawHandle(_ handle: LayoutHandle, at x: CGFloat) {
        let color = isEnabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        color.setFill()
        let top = Self.barTop - 3, height = Self.barHeight + 6
        let lines: [CGFloat] = handle == .always ? [-2.5, 2.5] : [0]
        for dx in lines {
            NSBezierPath(roundedRect: NSRect(x: x + dx - 1.25, y: top, width: 2.5, height: height), xRadius: 1.25, yRadius: 1.25).fill()
        }
        // A grip in the middle, so the handle reads as draggable.
        NSBezierPath(roundedRect: NSRect(x: x - 5, y: Self.barTop + Self.barHeight / 2 - 5, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
    }

    // MARK: Dragging

    /// Gap under the pointer while dragging (n icons left of it), kept on its side of the other handle.
    private func gap(at x: CGFloat, for handle: LayoutHandle) -> Int {
        let n = slots.filter { $0.frame.midX < x }.count
        switch handle {
        case .hidden: return max(n, alwaysGap ?? 0)
        case .always: return min(n, hiddenGap)
        }
    }

    private func previewGaps() -> (hidden: Int, always: Int?) {
        guard let d = dragging else { return (hiddenGap, alwaysGap) }
        let g = gap(at: dragX, for: d)
        return d == .hidden ? (g, alwaysGap) : (hiddenGap, g)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragging = handleX.min { abs($0.value - p.x) < abs($1.value - p.x) }
            .flatMap { abs($0.value - p.x) <= Self.handleWidth ? $0.key : nil }
        dragX = p.x
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging != nil else { return }
        dragX = min(max(convert(event.locationInWindow, from: nil).x, Self.margin), bounds.width - Self.margin)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = dragging else { return }
        let g = gap(at: dragX, for: d)
        dragging = nil
        needsDisplay = true
        if g != (d == .hidden ? hiddenGap : alwaysGap) { onMove?(d, g) }
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        for x in handleX.values {
            addCursorRect(NSRect(x: x - Self.handleWidth / 2, y: Self.barTop - 3, width: Self.handleWidth, height: Self.barHeight + 6), cursor: .resizeLeftRight)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let s = slots.first(where: { $0.frame.contains(point) }) else { return "" }
        return s.item.title == s.item.appName ? s.item.appName : "\(s.item.title) — \(s.item.appName)"
    }
}

/// Keeps the strip in step with the menu bar while Settings › Layout is open: every icon is
/// revealed meanwhile (so it can be seen, captured and ⌘-dragged), and the strip follows changes.
final class LayoutPaneModel {
    private weak var host: SettingsHost?
    let strip = LayoutStripView()
    let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var items: [BarItem] = []
    private var signature = ""
    /// Icons still without a captured image are tried again until then: apps whose icons were off
    /// screen can take a few seconds to draw them once revealed.
    private var retryUntil = Date.distantPast
    private var moving = false
    /// The gap asked for by the last drag, checked against where the divider ended up.
    private var requested: (handle: LayoutHandle, gap: Int)?
    /// Shown only while Screen Recording is off.
    weak var permissionButton: NSButton? { didSet { permissionButton?.isHidden = ItemImages.permitted } }

    init(host: SettingsHost?) {
        self.host = host
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 520
        strip.onMove = { [weak self] handle, gap in self?.move(handle, to: gap) }
    }

    func start() {
        host?.layoutPaneVisible(true)
        signature = ""
        retryUntil = Date().addingTimeInterval(8)
        // Give the bar a moment to show everything before the first look.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        host?.layoutPaneVisible(false)
        Memory.returnFreedPages(after: 1.0)
    }

    private func refresh() {
        guard let host, !moving else { return }
        guard AXCatalog.isTrusted else {
            strip.isHidden = true
            status.stringValue = L("Allow Accessibility (Settings › About) to see and arrange your menu bar here.")
            return
        }
        strip.isHidden = false
        host.catalogSnapshot { [weak self] items in
            guard let self, !self.moving else { return }
            let alwaysSection = host.settings.alwaysHiddenEnabled
            let sig = items.map { "\($0.slotKey)@\(Int($0.order / 4))/\($0.section.rawValue)" }.joined(separator: ",") + "\(alwaysSection)"
            let missing = ItemImages.permitted && items.contains { ItemImages.cache[$0.slotKey] == nil }
            if sig != self.signature { self.retryUntil = max(self.retryUntil, Date().addingTimeInterval(8)) }
            guard sig != self.signature || (missing && Date() < self.retryUntil) else { return }
            self.signature = sig
            self.items = items
            self.strip.darkBar = host.menuBarIsDark
            self.strip.show(items: items, images: ItemImages.permitted ? ItemImages.cache : [:], alwaysSection: alwaysSection)
            var notes: [String] = []
            if let r = self.requested {
                self.requested = nil
                let got = r.handle == .hidden ? items.filter { $0.section != .shown }.count : items.filter { $0.section == .alwaysHidden }.count
                if got != r.gap { notes.append(L("macOS put the divider next to the spot you chose: it has the last word on the order (some apps keep their icons together, and the BarTap icon must stay visible on every display). Drag it again to fine-tune.")) }
            }
            if !ItemImages.permitted { notes.append(L("Icons show as their app's icon and name. Allow Screen Recording to see the icons themselves.")) }
            self.status.stringValue = notes.joined(separator: "\n")
            self.permissionButton?.isHidden = ItemImages.permitted
            guard ItemImages.permitted else { return }
            // The bar has just changed: let it settle, then capture what is drawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.signature == sig else { return }
                ItemImages.capture(items) { [weak self] images in
                    guard let self, self.signature == sig else { return }
                    self.strip.show(items: items, images: images, alwaysSection: alwaysSection)
                }
            }
        }
    }

    private func move(_ handle: LayoutHandle, to gap: Int) {
        guard let host, !moving else { return }
        moving = true
        requested = (handle, gap)
        strip.isEnabled = false
        status.stringValue = L("Moving the divider…")
        host.moveDivider(handle, toGap: gap, items: items) { [weak self] ok in
            guard let self else { return }
            // BarTap's items are back and checked; look again.
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.5 : 0)) { [weak self] in
                guard let self else { return }
                self.moving = false
                self.strip.isEnabled = true
                if !ok { self.requested = nil }
                self.status.stringValue = ok ? "" : L("Couldn't place the divider there. Try a neighbouring spot, or ⌘-drag the BarTap icon in the menu bar.")
                self.signature = ""
                self.refresh()
            }
        }
    }
}
