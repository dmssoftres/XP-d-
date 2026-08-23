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

    /// Standard-mode layer modifiers are limited to physical K buttons;
    /// wheels and the center control cannot be assigned this role.
    var isModifierEligible: Bool {
        isMIDIButton
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

    /// Actions that hand user-authored text to another process.  These are
    /// intentionally opt-in because importing or editing a mapping must not
    /// silently arm executable automation.
    var isProcessBackedAutomation: Bool {
        switch self {
        case .macOSShortcut, .appleScript, .shellCommand:
            true
        default:
            false
        }
    }

    var automationDisplayName: String {
        switch self {
        case .macOSShortcut: "macOS Shortcut"
        case .appleScript: "AppleScript"
        case .shellCommand: "shell command"
        default: rawValue
        }
    }
}

/// Fixed choices stored in `Mapping.command` for Media control mappings. The
/// raw values are deliberately user-readable so existing overlays and JSON
/// exports remain understandable without a schema change.
enum MediaControlAction: String, CaseIterable, Identifiable {
    case playPause = "Play / pause"
    case nextTrack = "Next track"
    case previousTrack = "Previous track"
    case volumeUp = "Volume up"
    case volumeDown = "Volume down"
    case mute = "Mute"

    var id: String { rawValue }
}

/// Fixed choices stored in `Mapping.command` for Window / display mappings.
enum WindowDisplayAction: String, CaseIterable, Identifiable {
    case minimize = "Minimize frontmost window"
    case toggleFullScreen = "Toggle full screen"
    case hideApplication = "Hide frontmost application"
    case sleepDisplays = "Sleep displays"

    var id: String { rawValue }
}

struct MappingKey: Hashable, Codable {
    let control: RemoteControl
    let gesture: GestureKind
    /// An empty set is the original/base mapping. A non-empty value selects
    /// the exact alternate layer for the designated K-button modifiers.
    let modifierControls: Set<RemoteControl>

    init(
        control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) {
        self.control = control
        self.gesture = gesture
        self.modifierControls = modifierControls
    }

    private enum CodingKeys: String, CodingKey {
        case control, gesture, modifierControls, modifierControl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(RemoteControl.self, forKey: .control)
        gesture = try container.decode(GestureKind.self, forKey: .gesture)
        if let controls = try container.decodeIfPresent(Set<RemoteControl>.self, forKey: .modifierControls) {
            modifierControls = controls
        } else if let legacyControl = try container.decodeIfPresent(RemoteControl.self, forKey: .modifierControl) {
            // A short-lived single-control shape was used by an earlier
            // development build; accepting it costs nothing and keeps those
            // local mappings usable.
            modifierControls = [legacyControl]
        } else {
            modifierControls = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(control, forKey: .control)
        try container.encode(gesture, forKey: .gesture)
        try container.encode(
            RemoteControl.allCases.filter { modifierControls.contains($0) },
            forKey: .modifierControls
        )
    }
}

struct Mapping: Codable, Equatable {
    var action: ActionKind = .openApplication
    var command: String = ""
    /// Dedicated storage keeps user-authored automation content available
    /// while the active editor temporarily uses command for a typed
    /// action such as Media control or Switch profile.
    var macOSShortcutContent: String?
    var appleScriptContent: String?
    var shellCommandContent: String?
    /// Process-backed automation is inert until the user explicitly enables
    /// it in the inspector. Missing values decode as false for legacy files.
    var automationEnabled: Bool = false
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
    /// An optional ordinary macOS key required by the remote trigger.  This
    /// complements the legacy F-key field above without changing its JSON
    /// shape, so v6 data migrates losslessly while new keys remain explicit.
    var remoteTriggerKeyCode: UInt16?
    /// Keyboard-layout-aware label captured with `remoteTriggerKeyCode`.
    /// Runtime matching uses the code; this value is display-only.
    var remoteTriggerKeyDisplay: String?
    /// When set on a Hold or Double application action, resolve the target
    /// from this control's current Tap mapping instead of storing a second
    /// application command.  The explicit decoder keeps older persisted
    /// mappings source- and data-compatible by treating the missing key as
    /// false.
    var usesTapApplication: Bool = false

    private enum CodingKeys: String, CodingKey {
        case action
        case command
        case macOSShortcutContent
        case appleScriptContent
        case shellCommandContent
        case automationEnabled
        case keyboardShortcut
        case remoteTriggerModifiers
        case remoteTriggerFunctionKey
        case remoteTriggerKeyCode
        case remoteTriggerKeyDisplay
        case usesTapApplication
    }

    init(
        action: ActionKind = .openApplication,
        command: String = "",
        macOSShortcutContent: String? = nil,
        appleScriptContent: String? = nil,
        shellCommandContent: String? = nil,
        automationEnabled: Bool = false,
        keyboardShortcut: KeyboardShortcut? = nil,
        remoteTriggerModifiers: Set<KeyboardShortcut.Modifier> = [],
        remoteTriggerFunctionKey: UInt16? = nil,
        remoteTriggerKeyCode: UInt16? = nil,
        remoteTriggerKeyDisplay: String? = nil,
        usesTapApplication: Bool = false
    ) {
        self.action = action
        self.command = command
        self.macOSShortcutContent = macOSShortcutContent
        self.appleScriptContent = appleScriptContent
        self.shellCommandContent = shellCommandContent
        self.automationEnabled = automationEnabled
        self.keyboardShortcut = keyboardShortcut
        self.remoteTriggerModifiers = remoteTriggerModifiers
        self.remoteTriggerFunctionKey = remoteTriggerFunctionKey
        self.remoteTriggerKeyCode = remoteTriggerKeyCode
        self.remoteTriggerKeyDisplay = remoteTriggerKeyDisplay
        self.usesTapApplication = usesTapApplication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(ActionKind.self, forKey: .action) ?? .openApplication
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        macOSShortcutContent = try container.decodeIfPresent(String.self, forKey: .macOSShortcutContent)
        appleScriptContent = try container.decodeIfPresent(String.self, forKey: .appleScriptContent)
        shellCommandContent = try container.decodeIfPresent(String.self, forKey: .shellCommandContent)
        automationEnabled = try container.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? false
        keyboardShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut)
        remoteTriggerModifiers = try container.decodeIfPresent(
            Set<KeyboardShortcut.Modifier>.self,
            forKey: .remoteTriggerModifiers
        ) ?? []
        remoteTriggerFunctionKey = try container.decodeIfPresent(UInt16.self, forKey: .remoteTriggerFunctionKey)
        remoteTriggerKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .remoteTriggerKeyCode)
        remoteTriggerKeyDisplay = try container.decodeIfPresent(String.self, forKey: .remoteTriggerKeyDisplay)
        usesTapApplication = try container.decodeIfPresent(Bool.self, forKey: .usesTapApplication) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(macOSShortcutContent, forKey: .macOSShortcutContent)
        try container.encodeIfPresent(appleScriptContent, forKey: .appleScriptContent)
        try container.encodeIfPresent(shellCommandContent, forKey: .shellCommandContent)
        try container.encode(automationEnabled, forKey: .automationEnabled)
        try container.encodeIfPresent(keyboardShortcut, forKey: .keyboardShortcut)
        try container.encode(
            KeyboardShortcut.modifierOrder.filter { remoteTriggerModifiers.contains($0) },
            forKey: .remoteTriggerModifiers
        )
        try container.encodeIfPresent(remoteTriggerFunctionKey, forKey: .remoteTriggerFunctionKey)
        try container.encodeIfPresent(remoteTriggerKeyCode, forKey: .remoteTriggerKeyCode)
        try container.encodeIfPresent(remoteTriggerKeyDisplay, forKey: .remoteTriggerKeyDisplay)
        try container.encode(usesTapApplication, forKey: .usesTapApplication)
    }

    /// Returns a copy suitable for an explicit action-picker transition.
    /// Command content is preserved unless the chosen action is one of the
    /// fixed-choice editors and the stored value is invalid. In every case,
    /// changing the action disarms process-backed automation.
    func selectingAction(_ action: ActionKind, profileName: String? = nil) -> Self {
        var updated = self
        updated.stashActiveProcessCommand()
        updated.action = action
        updated.automationEnabled = false

        if action.isProcessBackedAutomation {
            updated.command = updated.savedProcessCommand(for: action) ?? ""
        } else if let defaultCommand = Self.defaultCommand(
            for: action,
            profileName: profileName,
            replacingInvalid: true,
            currentCommand: updated.command
        ) {
            updated.command = defaultCommand
        }
        return updated
    }

    /// Returns a copy after command text was deliberately edited. Keeping
    /// the command is important for review workflows, but executable actions
    /// must be re-enabled explicitly after any edit.
    func editingCommand(_ command: String) -> Self {
        var updated = self
        updated.command = command
        updated.updateActiveProcessContent()
        updated.automationEnabled = false
        return updated
    }

    private mutating func stashActiveProcessCommand() {
        updateActiveProcessContent()
    }

    private mutating func updateActiveProcessContent() {
        switch action {
        case .macOSShortcut:
            macOSShortcutContent = command
        case .appleScript:
            appleScriptContent = command
        case .shellCommand:
            shellCommandContent = command
        default:
            break
        }
    }

    private func savedProcessCommand(for action: ActionKind) -> String? {
        switch action {
        case .macOSShortcut:
            macOSShortcutContent
        case .appleScript:
            appleScriptContent
        case .shellCommand:
            shellCommandContent
        default:
            nil
        }
    }

    static func defaultCommand(
        for action: ActionKind,
        profileName: String?,
        replacingInvalid: Bool,
        currentCommand: String
    ) -> String? {
        switch action {
        case .mediaControl:
            guard replacingInvalid, MediaControlAction(rawValue: currentCommand) == nil else { return nil }
            return MediaControlAction.playPause.rawValue
        case .windowDisplay:
            guard replacingInvalid, WindowDisplayAction(rawValue: currentCommand) == nil else { return nil }
            return WindowDisplayAction.minimize.rawValue
        case .switchProfile:
            guard replacingInvalid, let profileName, !profileName.isEmpty else { return nil }
            return profileName
        default:
            return nil
        }
    }

    var needsAutomationReview: Bool {
        action.isProcessBackedAutomation && !automationEnabled
    }
}
