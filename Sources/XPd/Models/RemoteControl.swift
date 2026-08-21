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
    /// When set on a Hold or Double application action, resolve the target
    /// from this control's current Tap mapping instead of storing a second
    /// application command.  The explicit decoder keeps older persisted
    /// mappings source- and data-compatible by treating the missing key as
    /// false.
    var usesTapApplication: Bool = false

    private enum CodingKeys: String, CodingKey {
        case action
        case command
        case usesTapApplication
    }

    init(
        action: ActionKind = .openApplication,
        command: String = "",
        usesTapApplication: Bool = false
    ) {
        self.action = action
        self.command = command
        self.usesTapApplication = usesTapApplication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(ActionKind.self, forKey: .action) ?? .openApplication
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        usesTapApplication = try container.decodeIfPresent(Bool.self, forKey: .usesTapApplication) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(command, forKey: .command)
        try container.encode(usesTapApplication, forKey: .usesTapApplication)
    }
}
