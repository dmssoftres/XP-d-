import Foundation

enum RemoteControl: String, CaseIterable, Codable, Identifiable {
    case k1 = "K1", k2 = "K2", k3 = "K3", k4 = "K4", k5 = "K5"
    case k6 = "K6", k7 = "K7", k8 = "K8", k9 = "K9", k10 = "K10"
    case wheelCCW = "Wheel CCW"
    case wheelCW = "Wheel CW"
    case wheelCenter = "Wheel Center"

    var id: String { rawValue }
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
    case macOSShortcut = "Run macOS Shortcut"
    case appleScript = "Run AppleScript"
    case shellCommand = "Run shell command"
    case mediaControl = "Media control"
    case windowDisplay = "Window / display action"
    case switchProfile = "Switch profile"
    case noAction = "No action"

    var id: String { rawValue }
}

struct MappingKey: Hashable, Codable {
    let control: RemoteControl
    let gesture: GestureKind
}

struct Mapping: Codable, Equatable {
    var action: ActionKind = .openApplication
    var command: String = ""
}
