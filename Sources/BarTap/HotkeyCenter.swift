import AppKit
import Carbon.HIToolbox
import BarTapCore

/// Global hotkeys via Carbon's RegisterEventHotKey: no Accessibility or Input Monitoring needed,
/// and no event tap (so we can never swallow or delay anyone else's keystrokes).
final class HotkeyCenter {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private(set) var failed: Set<HotkeyAction> = []
    private var suspended = false
    private var lastBindings: [(HotkeyAction, KeyCombo, () -> Void)] = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private static func id(for action: HotkeyAction) -> UInt32 {
        UInt32(HotkeyAction.allCases.firstIndex(of: action)! + 1)
    }

    /// Replaces every registration. Returns the actions whose combo is already taken system-wide.
    @discardableResult
    func apply(_ bindings: [(HotkeyAction, KeyCombo, () -> Void)]) -> Set<HotkeyAction> {
        lastBindings = bindings
        unregisterAll()
        failed = []
        guard !suspended else { return failed }
        var seen = Set<KeyCombo>()
        for (action, combo, handler) in bindings {
            guard combo.isValid, !seen.contains(combo) else { failed.insert(action); continue }
            seen.insert(combo)
            let hid = Self.id(for: action)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x4254_4150), id: hid),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[hid] = ref
                handlers[hid] = handler
            } else {
                failed.insert(action)
            }
        }
        return failed
    }

    /// While the user records a new shortcut, existing ones must not fire.
    func setSuspended(_ on: Bool) {
        suspended = on
        if on { unregisterAll() } else { apply(lastBindings) }
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    /// Key name for the user's current keyboard layout (falls back to ANSI names).
    static func keyName(_ keyCode: UInt32) -> String {
        if KeyCombo.specialKeyNames[keyCode] != nil || KeyCombo.functionKeyNames[keyCode] != nil {
            return KeyCombo.name(for: keyCode)
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return KeyCombo.name(for: keyCode)
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return KeyCombo.name(for: keyCode) }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    static func display(_ combo: KeyCombo) -> String { combo.display(keyName: keyName(combo.keyCode)) }
}
