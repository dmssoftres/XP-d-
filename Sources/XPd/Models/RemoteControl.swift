import Foundation
import UniformTypeIdentifiers

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

/// The fixed presentation palette for Standard-mode K modifiers. Raw values
/// are part of the portable and local configuration formats; keep their
/// spelling stable when changing the SwiftUI treatment.
enum ModifierColor: String, CaseIterable, Codable, Identifiable {
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case cyan = "cyan"
    case blue = "blue"
    case purple = "purple"
    case pink = "pink"
    case red = "red"

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

enum GestureKind: String, CaseIterable, Codable, Identifiable {
    case tap = "Tap"
    case hold = "Hold"
    case doubleTap = "Double"

    var id: String { rawValue }
}

enum ComboMode: String, Codable {
    /// Current behavior. Modifier-first and destination-first pairing rely
    /// on physical simultaneity alone.
    case hold
    /// Opt-in per-mapping sequential recognition: modifier press+release
    /// then destination press (or the reverse order) within the configured
    /// window fires the exact layer once. Standard realm only.
    case sequence
}

enum ActionKind: String, CaseIterable, Codable, Identifiable {
    case keyboardShortcut = "Keyboard shortcut"
    case typeText = "Type text"
    case openLink = "Open link or file"
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

    var editorLabel: String {
        self == .noAction ? "Empty" : rawValue
    }

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

/// Limits for the Type text action: the editor accepts at most
/// `maximumLength` characters and typing posts at most `chunkLength` UTF-16
/// units per keyboard event (the CGEvent Unicode string limit).
enum TypeTextLimits {
    static let maximumLength = 2_000
    static let chunkLength = 20
}

/// What an "Open link or file" mapping points to. Only web pages, e-mail
/// addresses and files/folders on this Mac are allowed (owner decision);
/// a bare domain such as `example.com` is treated as a web page.
enum OpenLinkTarget: Equatable {
    case web(URL)
    case mail(URL)
    case file(URL)

    enum Problem: Error, Equatable {
        case empty
        case unsupported(String)
        case missingFile(String)
        /// Apps, scripts and link files run or redirect when opened; they
        /// belong to Open application / Run shell command, which have their
        /// own approval rules.
        case runnable(String)
    }

    /// Extensions that run code or jump to an arbitrary link when opened.
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh",
        "py", "pl", "rb", "js", "jar", "scpt", "scptd", "applescript", "workflow",
        "shortcut", "action", "webloc", "inetloc", "fileloc", "pkg", "mpkg"
    ]

    /// Document-like endings that must not be read as a bare web domain.
    private static let fileLikeEndings: Set<String> = [
        "pdf", "doc", "docx", "txt", "rtf", "pages", "key", "numbers", "xls", "xlsx",
        "ppt", "pptx", "csv", "jpg", "jpeg", "png", "heic", "gif", "mov", "mp4", "zip", "md"
    ]

    static func isRunnableFile(_ url: URL) -> Bool {
        if runnableExtensions.contains(url.pathExtension.lowercased()) { return true }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isExecutableKey])
        if let type = values?.contentType,
           type.conforms(to: .application) || type.conforms(to: .executable) || type.conforms(to: .script) {
            return true
        }
        return values?.isRegularFile == true && values?.isExecutable == true
    }

    var url: URL {
        switch self {
        case let .web(url), let .mail(url), let .file(url): url
        }
    }

    static func resolve(
        _ rawCommand: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isRunnable: (URL) -> Bool = OpenLinkTarget.isRunnableFile
    ) -> Result<OpenLinkTarget, Problem> {
        func file(_ url: URL, shown: String) -> Result<OpenLinkTarget, Problem> {
            guard fileExists(url.path) else { return .failure(.missingFile(shown)) }
            guard !isRunnable(url) else { return .failure(.runnable(shown)) }
            return .success(.file(url))
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .failure(.empty) }

        if command.hasPrefix("/") || command.hasPrefix("~") {
            let path = (command as NSString).expandingTildeInPath
            return file(URL(fileURLWithPath: path), shown: command)
        }

        if let url = URL(string: command), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard url.host?.isEmpty == false else { return .failure(.unsupported(command)) }
                return .success(.web(url))
            case "mailto":
                return .success(.mail(url))
            case "file":
                return file(url, shown: url.path)
            default:
                // "example.com:8080" parses with scheme "example.com"; only
                // a dotted, space-free word may be read as a bare domain.
                break
            }
        }

        if !command.contains(" "), !command.contains("://"),
           command.contains("."), !command.hasPrefix("."),
           let url = URL(string: "https://" + command),
           let host = url.host, host.contains("."),
           let ending = host.split(separator: ".").last.map({ String($0).lowercased() }),
           ending.count >= 2, ending.allSatisfy(\.isLetter),
           !fileLikeEndings.contains(ending), !runnableExtensions.contains(ending) {
            return .success(.web(url))
        }
        return .failure(.unsupported(command))
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
    case toggleXPd = "Show / hide XP[d]"
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
    var action: ActionKind = .noAction
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
    /// Standard-only per-mapping sequential recognition choice. The field is
    /// omitted from the encoded form when it holds the default so legacy
    /// payloads stay byte-stable and MIDI profiles never gain the key.
    var comboMode: ComboMode = .hold
    /// Sequence recognition window in milliseconds. Only meaningful when
    /// `comboMode == .sequence`; always kept within the supported range.
    var sequenceWindowMs: Int {
        get { rawSequenceWindowMs }
        set { rawSequenceWindowMs = Self.clampedSequenceWindowMs(newValue) }
    }

    static let defaultSequenceWindowMs = 500
    static let sequenceWindowMsRange = 200...2000

    private var rawSequenceWindowMs: Int = Mapping.defaultSequenceWindowMs

    static func clampedSequenceWindowMs(_ value: Int) -> Int {
        min(max(value, sequenceWindowMsRange.lowerBound), sequenceWindowMsRange.upperBound)
    }

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
        case comboMode
        case sequenceWindowMs
    }

    init(
        action: ActionKind = .noAction,
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
        usesTapApplication: Bool = false,
        comboMode: ComboMode = .hold,
        sequenceWindowMs: Int = Mapping.defaultSequenceWindowMs
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
        self.comboMode = comboMode
        self.sequenceWindowMs = sequenceWindowMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(ActionKind.self, forKey: .action) ?? .noAction
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
        comboMode = try container.decodeIfPresent(ComboMode.self, forKey: .comboMode) ?? .hold
        sequenceWindowMs = try container.decodeIfPresent(
            Int.self,
            forKey: .sequenceWindowMs
        ) ?? Mapping.defaultSequenceWindowMs
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
        if comboMode != .hold {
            try container.encode(comboMode, forKey: .comboMode)
        }
        if comboMode == .sequence {
            try container.encode(sequenceWindowMs, forKey: .sequenceWindowMs)
        }
    }

    /// Returns a copy suitable for an explicit action-picker transition.
    /// Command content is preserved unless the chosen action is one of the
    /// fixed-choice editors and the stored value is invalid. In every case,
    /// changing the action disarms process-backed automation.
    func selectingAction(_ action: ActionKind, profileName: String? = nil) -> Self {
        guard action != .noAction else { return Mapping(action: .noAction) }

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
        case .typeText, .openLink:
            // Never carry a previous script, app path, profile name or text
            // into a new target (it could be typed or opened).
            return replacingInvalid ? "" : nil
        default:
            return nil
        }
    }

    var needsAutomationReview: Bool {
        action.isProcessBackedAutomation && !automationEnabled
    }
}
