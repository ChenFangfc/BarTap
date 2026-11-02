import AppKit

/// Moves other apps' menu bar icons the only way macOS allows: a ⌘-drag, as the user would make
/// it (Accessibility can't: every icon's position is read-only). It runs only when the user clicks
/// Apply in Settings › Layout, never on its own, and stops as soon as the user moves the mouse,
/// clicks or types. The pointer is hidden during a move and put back where it was. No event taps,
/// no cursor warps, no keyboard events. This is the one place BarTap creates input events
/// (scripts/build.sh checks that).
final class IconMover {
    /// A menu bar icon as drawn on the display used for the move.
    struct Spot: Equatable { let window: UInt32; let frame: CGRect }

    enum Outcome: Equatable { case moved, interrupted }

    private let queue = DispatchQueue(label: "bartap.mover", qos: .userInitiated)
    /// The system's own event state: a drag only counts when the window server sees the button down.
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Seconds since the last mouse or keyboard input (our own moves count too).
    static func idleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    /// ⌘-drags the icon at `from` and drops it at `drop` (screen points, top-left origin). Calls
    /// back on the main thread. The user's own input is checked before each move (our events count
    /// as input too, so not during one); a move takes about 0.4 s.
    func drag(from: Spot, to drop: CGPoint, completion: @escaping (Outcome) -> Void) {
        queue.async { [source] in
            // The user is using the mouse or keyboard: they come first.
            guard Self.idleSeconds() > 0.25 else { DispatchQueue.main.async { completion(.interrupted) }; return }
            let saved = CGEvent(source: nil)?.location ?? .zero
            let display = CGMainDisplayID()
            CGDisplayHideCursor(display)
            func post(_ type: CGEventType, _ p: CGPoint, command: Bool = true) {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
                e.flags = command ? .maskCommand : []
                if command {
                    // Aim at the icon's window even while the (hidden) pointer travels.
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(from.window))
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(from.window))
                }
                e.post(tap: .cghidEventTap)
            }
            let start = CGPoint(x: from.frame.midX, y: from.frame.midY)
            post(.leftMouseDown, start)
            usleep(60_000)
            let steps = 12
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: start.x + (drop.x - start.x) * t, y: start.y + (drop.y - start.y) * t))
                usleep(16_000)
            }
            usleep(40_000)
            post(.leftMouseUp, drop)
            usleep(80_000)
            // Back where it was, as an ordinary move: a warp would hold up the user's own mouse for a moment.
            post(.mouseMoved, saved, command: false)
            CGDisplayShowCursor(display)
            DispatchQueue.main.async { completion(.moved) }
        }
    }
}
