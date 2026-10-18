import Foundation

/// A global shortcut: a virtual key code plus Carbon modifier flags. Saved as text such as
/// "ctrl+opt+n" so settings files stay readable; shown with the macOS glyphs (⌃⌥N).
public struct KeyCombo: Equatable, Hashable {
    public static let command: UInt32 = 0x0100, shift: UInt32 = 0x0200, option: UInt32 = 0x0800, control: UInt32 = 0x1000

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init?(keyCode: UInt32, modifiers: UInt32) {
        guard Self.names[keyCode] != nil else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
    }

    /// A global shortcut must include ⌃, ⌥ or ⌘, so plain typing and ⇧-typing are never captured.
    public var isAllowedGlobally: Bool { modifiers & (Self.control | Self.option | Self.command) != 0 }

    public init?(_ text: String) {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers |= Self.control
            case "opt", "option", "alt": modifiers |= Self.option
            case "shift": modifiers |= Self.shift
            case "cmd", "command": modifiers |= Self.command
            default:
                guard key == nil, let code = Self.names.first(where: { $0.value.lowercased() == part })?.key else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        self.init(keyCode: key, modifiers: modifiers)
    }

    public var text: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("ctrl") }
        if modifiers & Self.option != 0 { parts.append("opt") }
        if modifiers & Self.shift != 0 { parts.append("shift") }
        if modifiers & Self.command != 0 { parts.append("cmd") }
        parts.append(Self.names[keyCode]!.lowercased())
        return parts.joined(separator: "+")
    }

    /// Menu-style display in Apple's modifier order: ⌃⌥⇧⌘.
    public var display: String {
        var result = ""
        if modifiers & Self.control != 0 { result += "⌃" }
        if modifiers & Self.option != 0 { result += "⌥" }
        if modifiers & Self.shift != 0 { result += "⇧" }
        if modifiers & Self.command != 0 { result += "⌘" }
        return result + (Self.glyphs[keyCode] ?? Self.names[keyCode]!)
    }

    /// ANSI virtual key codes (Carbon `kVK_*`), named for the US layout.
    static let names: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        let letters: [(String, UInt32)] = [("A", 0x00), ("S", 0x01), ("D", 0x02), ("F", 0x03), ("H", 0x04), ("G", 0x05), ("Z", 0x06), ("X", 0x07),
            ("C", 0x08), ("V", 0x09), ("B", 0x0B), ("Q", 0x0C), ("W", 0x0D), ("E", 0x0E), ("R", 0x0F), ("Y", 0x10), ("T", 0x11),
            ("O", 0x1F), ("U", 0x20), ("I", 0x22), ("P", 0x23), ("L", 0x25), ("J", 0x26), ("K", 0x28), ("N", 0x2D), ("M", 0x2E)]
        let digits: [(String, UInt32)] = [("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("9", 0x19), ("7", 0x1A), ("8", 0x1C), ("0", 0x1D)]
        let other: [(String, UInt32)] = [("Space", 0x31), ("Return", 0x24), ("Tab", 0x30), ("Minus", 0x1B), ("Equal", 0x18),
            ("Comma", 0x2B), ("Period", 0x2F), ("Slash", 0x2C), ("Semicolon", 0x29), ("Quote", 0x27), ("Backslash", 0x2A),
            ("LeftBracket", 0x21), ("RightBracket", 0x1E), ("Grave", 0x32),
            ("Left", 0x7B), ("Right", 0x7C), ("Down", 0x7D), ("Up", 0x7E),
            ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76), ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64),
            ("F9", 0x65), ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F)]
        for (name, code) in letters + digits + other { table[code] = name }
        return table
    }()

    static let glyphs: [UInt32: String] = [0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x1B: "-", 0x18: "=", 0x2B: ",", 0x2F: ".", 0x2C: "/",
        0x29: ";", 0x27: "'", 0x2A: "\\", 0x21: "[", 0x1E: "]", 0x32: "`", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"]
}
