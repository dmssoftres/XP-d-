import Foundation

/// A single keyboard chord.  The physical key code is persisted so the
/// shortcut remains tied to the key that was recorded, while the display
/// string preserves the user's keyboard-layout-aware label for the editor.
struct KeyboardShortcut: Codable, Equatable {
    enum Modifier: String, CaseIterable, Codable, Hashable {
        case command
        case control
        case option
        case shift
        case function

        var symbol: String {
            switch self {
            case .command: return "⌘"
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .function: return "fn"
            }
        }
    }

    let keyCode: UInt16
    /// Modifiers are a set rather than a sequence: a shortcut is one
    /// simultaneous chord, and this collection is normalized by
    /// `orderedModifiers` whenever it is displayed or encoded.
    let modifiers: Set<Modifier>
    let displayString: String

    init(keyCode: UInt16, modifiers: Set<Modifier>, displayString: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }

    var orderedModifiers: [Modifier] {
        Self.modifierOrder.filter { modifiers.contains($0) }
    }

    static let modifierOrder: [Modifier] = [.command, .control, .option, .shift, .function]

    /// Hardware virtual key codes for the standard F1…F12 keys. These are
    /// explicit because function keys are keys, not modifier flags.
    static let functionKeyLabels: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    static var functionKeyCodes: Set<UInt16> {
        Set(functionKeyLabels.keys)
    }

    static func functionKeyLabel(for keyCode: UInt16) -> String? {
        functionKeyLabels[keyCode]
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case displayString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decodeIfPresent(Set<Modifier>.self, forKey: .modifiers) ?? []
        // A missing display string is tolerated for forward/backward data
        // compatibility.  The key code and modifiers remain available for
        // execution; a newly captured shortcut always writes this field.
        displayString = try container.decodeIfPresent(String.self, forKey: .displayString) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(orderedModifiers, forKey: .modifiers)
        try container.encode(displayString, forKey: .displayString)
    }
}
