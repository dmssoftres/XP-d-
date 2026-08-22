import Foundation

enum RemoteControl: String, CaseIterable, Codable, Identifiable {
    case k1 = "K1", k2 = "K2", k3 = "K3", k4 = "K4", k5 = "K5"
    case k6 = "K6", k7 = "K7", k8 = "K8", k9 = "K9", k10 = "K10"
    case wheelCCW = "Wheel CCW"
    case wheelCW = "Wheel CW"
    case wheelCenter = "Wheel Center"

    var id: String { rawValue }

    var isWheelRotation: Bool {
        self == .wheelCW || self == .wheelCCW
    }
}

enum GestureKind: String, CaseIterable, Codable, Identifiable {
    case tap = "Tap"
    case hold = "Hold"
    case doubleTap = "Double"

    var id: String { rawValue }
}

enum ActionKind: String, CaseIterable, Codable, Identifiable {
    case keyboardShortcut = "Keyboard shortcut"
    case openApplication = "Open application"
    case toggleApplication = "Toggle application"
    case macOSShortcut = "Run macOS Shortcut"
    case appleScript = "Run AppleScript"
    case shellCommand = "Run shell command"
    case mediaControl = "Media control"
    case windowDisplay = "Window / display action"
    case switchProfile = "Switch profile"
    case noAction = "No action"

    var id: String { rawValue }

    var isApplicationAction: Bool {
        self == .openApplication || self == .toggleApplication
    }
}

struct MappingKey: Hashable, Codable {
    let control: RemoteControl
    let gesture: GestureKind
}

struct Mapping: Codable, Equatable {
    var action: ActionKind = .openApplication
    var command: String = ""
    /// Structured keyboard-chord data.  `command` remains the display value
    /// and legacy storage field so older configuration files continue to
    /// render, while only mappings with this value are executable as a
    /// captured shortcut.
    var keyboardShortcut: KeyboardShortcut?
    /// Modifiers that must be held when the physical remote control is
    /// pressed. This is independent from `keyboardShortcut`: the former
    /// selects the remote trigger chord, while the latter is the keyboard
    /// chord sent to the target application.
    var remoteTriggerModifiers: Set<KeyboardShortcut.Modifier> = []
    /// An optional held F1…F12 key required by the remote trigger. Function
    /// keys are stored separately because they are ordinary keys, not flags.
    var remoteTriggerFunctionKey: UInt16?
    /// When set on a Hold or Double application action, resolve the target
    /// from this control's current Tap mapping instead of storing a second
    /// application command.  The explicit decoder keeps older persisted
    /// mappings source- and data-compatible by treating the missing key as
    /// false.
    var usesTapApplication: Bool = false

    private enum CodingKeys: String, CodingKey {
        case action
        case command
        case keyboardShortcut
        case remoteTriggerModifiers
        case remoteTriggerFunctionKey
        case usesTapApplication
    }

    init(
        action: ActionKind = .openApplication,
        command: String = "",
        keyboardShortcut: KeyboardShortcut? = nil,
        remoteTriggerModifiers: Set<KeyboardShortcut.Modifier> = [],
        remoteTriggerFunctionKey: UInt16? = nil,
        usesTapApplication: Bool = false
    ) {
        self.action = action
        self.command = command
        self.keyboardShortcut = keyboardShortcut
        self.remoteTriggerModifiers = remoteTriggerModifiers
        self.remoteTriggerFunctionKey = remoteTriggerFunctionKey
        self.usesTapApplication = usesTapApplication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(ActionKind.self, forKey: .action) ?? .openApplication
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        keyboardShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut)
        remoteTriggerModifiers = try container.decodeIfPresent(
            Set<KeyboardShortcut.Modifier>.self,
            forKey: .remoteTriggerModifiers
        ) ?? []
        remoteTriggerFunctionKey = try container.decodeIfPresent(UInt16.self, forKey: .remoteTriggerFunctionKey)
        usesTapApplication = try container.decodeIfPresent(Bool.self, forKey: .usesTapApplication) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(keyboardShortcut, forKey: .keyboardShortcut)
        try container.encode(
            KeyboardShortcut.modifierOrder.filter { remoteTriggerModifiers.contains($0) },
            forKey: .remoteTriggerModifiers
        )
        try container.encodeIfPresent(remoteTriggerFunctionKey, forKey: .remoteTriggerFunctionKey)
        try container.encode(usesTapApplication, forKey: .usesTapApplication)
    }
}
