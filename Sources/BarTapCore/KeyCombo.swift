import Foundation

/// A global hotkey: virtual key code + Carbon modifier mask.
public struct KeyCombo: Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let cmd: UInt32 = 0x0100      // cmdKey
    public static let shift: UInt32 = 0x0200    // shiftKey
    public static let option: UInt32 = 0x0800   // optionKey
    public static let control: UInt32 = 0x1000  // controlKey
    public static let allModifiers = cmd | shift | option | control

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & KeyCombo.allModifiers
    }

    /// "keyCode:modifiers", the UserDefaults representation.
    public init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: k, modifiers: m)
        guard isValid else { return nil }
    }

    public var storage: String { "\(keyCode):\(modifiers)" }

    public var isFunctionKey: Bool { KeyCombo.functionKeyNames[keyCode] != nil }

    /// Plain letters without modifiers would hijack typing, so require a modifier unless it is an F-key.
    public var isValid: Bool {
        keyCode <= 0x7F && (isFunctionKey || modifiers & (KeyCombo.cmd | KeyCombo.option | KeyCombo.control) != 0)
    }

    public var modifierSymbols: String {
        var s = ""
        if modifiers & KeyCombo.control != 0 { s += "⌃" }
        if modifiers & KeyCombo.option != 0 { s += "⌥" }
        if modifiers & KeyCombo.shift != 0 { s += "⇧" }
        if modifiers & KeyCombo.cmd != 0 { s += "⌘" }
        return s
    }

    /// Display string using the ANSI layout; the app may substitute a layout-aware key name.
    public func display(keyName: String? = nil) -> String {
        modifierSymbols + (keyName ?? KeyCombo.name(for: keyCode))
    }

    public static func name(for keyCode: UInt32) -> String {
        if let n = specialKeyNames[keyCode] { return n }
        if let n = functionKeyNames[keyCode] { return n }
        if let n = ansiKeyNames[keyCode] { return n }
        return String(format: "#%02X", keyCode)
    }

    public static let functionKeyNames: [UInt32: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    public static let specialKeyNames: [UInt32: String] = [
        0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟", 0x4C: "⌤",
    ]

    public static let ansiKeyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C",
        0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-",
        0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M",
        0x2F: ".", 0x32: "`",
    ]
}
