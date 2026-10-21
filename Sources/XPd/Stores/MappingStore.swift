import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

private final class MIDIShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRequested = false

    func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasRequested else { return false }
        hasRequested = true
        return true
    }
}

private final class MIDIShutdownObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
}

private final class MIDICommandTail: @unchecked Sendable {
    var task: Task<Void, Never>?
}

private final class MIDIMonitorRelay: @unchecked Sendable {
    weak var store: MappingStore?

    init(store: MappingStore) {
        self.store = store
    }

    func receive(_ event: MIDIOutputService.MonitorEvent) {
        Task { @MainActor [weak self] in
            self?.store?.recordMIDIEvent(event)
        }
    }
}

/// A presentation-only summary of an application action configured for a
/// Standard K control.  This deliberately has no Codable conformance: route
/// summaries are derived from the persisted mappings immediately before they
/// are shown.
struct StandardApplicationRoute: Equatable, Identifiable {
    let target: String
    let gesture: GestureKind
    let modifierControls: Set<RemoteControl>
    let targetIdentity: String
    var isSequenceCombo: Bool = false

    var id: String {
        let modifiers = RemoteControl.allCases
            .filter { modifierControls.contains($0) }
            .map(\.rawValue)
            .joined(separator: "+")
        return "\(modifiers)|\(targetIdentity)"
    }

    var isBase: Bool { modifierControls.isEmpty }

    init(
        target: String,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        targetIdentity: String? = nil,
        isSequenceCombo: Bool = false
    ) {
        self.target = target
        self.gesture = gesture
        self.modifierControls = modifierControls
        self.targetIdentity = targetIdentity ?? Self.normalizedTargetIdentity(target)
        self.isSequenceCombo = isSequenceCombo
    }

    static func normalizedTargetIdentity(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.contains("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path.lowercased()
        }
        return expanded.lowercased()
    }
}

/// A presentation-only summary of a configured non-application action on one
/// exact Standard K-button layer. Gesture-specific actions are intentionally
/// deduplicated by `MappingStore.standardNonApplicationRoutes(for:)`.
struct StandardNonApplicationRoute: Equatable, Identifiable {
    let modifierControls: Set<RemoteControl>
    var isSequenceCombo: Bool = false

    var id: String {
        let modifiers = RemoteControl.allCases
            .filter { modifierControls.contains($0) }
            .map(\.rawValue)
            .joined(separator: "+")
        return modifiers.isEmpty ? "base" : modifiers
    }

    var isBase: Bool { modifierControls.isEmpty }
}

enum MappingClipboardOperation: Equatable {
    case copy
    case cut
}

struct MappingClipboardLocation: Equatable {
    let profileName: String
    let control: RemoteControl
    let gesture: GestureKind
    let modifierControls: Set<RemoteControl>

    init(
        profileName: String,
        control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) {
        self.profileName = profileName
        self.control = control
        self.gesture = gesture
        self.modifierControls = modifierControls
    }

    var key: MappingKey {
        MappingKey(control: control, gesture: gesture, modifierControls: modifierControls)
    }
}

struct MappingClipboardState: Equatable {
    let operation: MappingClipboardOperation
    let source: MappingClipboardLocation
    let rawSourceMapping: Mapping
    let portableMapping: Mapping
}

struct MappingDestinationSnapshot: Equatable {
    let location: MappingClipboardLocation
    let expectedMapping: Mapping
}

enum MappingClipboardResult: Equatable {
    case succeeded
    case unavailable
    case invalidDestination
    case destinationOccupied
    case destinationChanged
    case sameLocation
    case staleSource
    case invalidSource
}

@Observable
@MainActor
final class MappingStore {
    typealias ActionExecutionOverride = @MainActor (
        _ mapping: Mapping,
        _ completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) -> Void
    typealias RemoteModifierProvider = @MainActor () -> Set<KeyboardShortcut.Modifier>
    typealias RemoteFunctionKeyProvider = @MainActor () -> Set<UInt16>
    typealias RemoteKeyProvider = @MainActor (_ configuredKeyCodes: Set<UInt16>) -> Set<UInt16>
    typealias MainWindowToggle = @MainActor () -> ActionExecutionResult
    typealias RunModeTransition = @MainActor (_ enabled: Bool) -> ActionExecutionResult

    private(set) var availableProfiles: [String] = XPdConfiguration.defaultProfileNames

    enum ProfileError: LocalizedError, Equatable {
        case invalidName(String)
        case duplicateName(String)
        case profileNotFound(String)
        case cannotRenameGlobal
        case cannotDeleteGlobal
        case noMIDIProfile
        case invalidMIDIProfile(String)

        var errorDescription: String? {
            switch self {
            case let .invalidName(name):
                return "Profile names must be trimmed, non-empty, and at most 40 characters: \(name)."
            case let .duplicateName(name):
                return "A profile named \(name) already exists."
            case let .profileNotFound(name):
                return "Profile not found: \(name)."
            case .cannotRenameGlobal:
                return "The Global profile cannot be renamed."
            case .cannotDeleteGlobal:
                return "The Global profile cannot be deleted."
            case .noMIDIProfile:
                return "Create a MIDI profile before entering MIDI Lock."
            case let .invalidMIDIProfile(message):
                return message
            }
        }
    }

    enum PersistenceResult: Equatable {
        case idle
        case saved
        case failed(String)

        var message: String? {
            switch self {
            case .idle:
                return nil
            case .saved:
                return "Saved automatically"
            case let .failed(message):
                return message
            }
        }

        var succeeded: Bool {
            if case .saved = self { return true }
            return false
        }
    }

    enum MappingResolutionError: LocalizedError, Equatable {
        case tapMappingMustBeApplication
        case tapApplicationMissing

        var errorDescription: String? {
            switch self {
            case .tapMappingMustBeApplication:
                return "Tap must use Open application or Toggle application before it can be inherited."
            case .tapApplicationMissing:
                return "Tap does not contain a valid application target."
            }
        }
    }

    var selectedControl: RemoteControl = .k1 {
        didSet { sanitizeSelectedMappingModifier() }
    }
    var selectedGesture: GestureKind = .tap
    /// The alternate Standard-mode layer currently being edited. An empty
    /// set is the base layer; non-empty values are sanitized against the
    /// active profile's designated modifier set whenever selection changes.
    var selectedMappingModifiers: Set<RemoteControl> = [] {
        didSet { sanitizeSelectedMappingModifier() }
    }
    var selectedMIDILayer: MIDIMappingLayer = .primary
    var profileName = "Global" {
        didSet {
            guard availableProfiles.contains(profileName) else {
                profileName = oldValue
                return
            }
            guard profileName != oldValue, !isReplacingConfiguration else { return }
            cancelPendingButtonGestures()
            cancelLearning()
            resetMIDIState()
            saveActiveProfile(named: oldValue)
            activateProfile(named: profileName)
            defaults.set(profileName, forKey: profileNameDefaultsKey)
            saveAllProfiles()
        }
    }
    private(set) var mappings: [MappingKey: Mapping] = [:]
    /// HID identities belong to the physical remote, not to a profile. The
    /// profile state below retains a legacy `hidBindings` decode slot only so
    /// v2-v8 payloads can be migrated without data loss; all live routing
    /// reads the active hardware layout.
    private(set) var hardwareLayouts: [XPdConfiguration.HardwareLayout] = []
    private(set) var activeHardwareLayoutID: String = ""
    var activeHardwareLayoutName: String {
        hardwareLayouts.first(where: { $0.id == activeHardwareLayoutID })?.name ?? ""
    }
    private(set) var hidBindings: [RemoteControl: String] = [:]
    /// K buttons designated as dual-role Standard-mode modifiers. The set is
    /// profile-scoped persisted designation. Controls whose current hardware
    /// layout has no learned input remain designated, but are unavailable at
    /// runtime until that layout learns them again.
    private(set) var remoteModifierControls: Set<RemoteControl> = []
    /// Profile-scoped presentation metadata for eligible K controls. This is
    /// independent of designation so the selected colour survives a later
    /// disable/re-enable cycle even though inactive controls hide the palette.
    private(set) var modifierColors: [RemoteControl: ModifierColor] = [:]
    /// Optional labels for Standard-mode K buttons. MIDI profiles never
    /// populate this dictionary; titles are shared across gestures.
    private(set) var standardButtonTitles: [RemoteControl: String] = [:]
    private(set) var learningControl: RemoteControl?
    private(set) var learningAllControl: RemoteControl?
    private(set) var learningAllProgress: Int = 0
    private(set) var isLearningAll = false
    private(set) var isLearningAllAwaitingRelease = false
    /// Session-only feedback for Standard K-layer configuration. This never
    /// enters a profile or hardware-layout payload; it is visible only while
    /// the captured button is awaiting its release boundary.
    private(set) var learningAllCapturedSignature: String?
    /// Whether Standard input should resolve K1–K10 through the canonical
    /// report-6 F13–F22 identities. This is a Standard-only resolver choice,
    /// persisted independently of the shared device-level hardware layout so
    /// enabling it cannot rewrite MIDI's physical input map.
    private(set) var usesStandardF13F22Preset = false
    /// Mirrors `HIDService`: true only after the remote acknowledged driver
    /// mode. While true, K1–K10 resolve through the verified driver-mode bit
    /// order in both realms instead of the learned layout.
    private(set) var isBluetoothDriverModeActive = false
    /// Connection-scoped evidence that the connected remote has emitted one
    /// exact report-6 F13–F22 preset identity while Standard is active. The
    /// persisted selection is not evidence that the remote was programmed.
    private(set) var isStandardF13F22PresetLiveVerified = false
    /// Connection-scoped evidence that the active layout has passed the
    /// Standard K10→K5 and K5→K10 live combined-state checks. It is never
    /// persisted because saved signatures alone cannot establish rollover
    /// behavior after reconnecting the remote.
    private(set) var isStandardKLayerLiveVerified = false
    /// Session-only instruction for the two live combined-state checks that
    /// follow the ten individual K captures.
    private(set) var standardKLayerVerificationPrompt: String?
    private(set) var lastHIDLearningResult: ActionExecutionResult?
    private(set) var liveControl: RemoteControl?
    private(set) var lastActionResult: ActionExecutionResult?
    private(set) var isRunMode = false
    private(set) var lastConfigurationResult: ConfigurationOperationResult = .idle
    private(set) var lastPersistenceResult: PersistenceResult = .idle
    private(set) var lastMIDIMessage: MIDIOutputService.SentMessage?
    private(set) var lastMIDIError: String?
    private(set) var lastMIDIStatus: String?
    private(set) var midiEndpointStatuses: [MIDIOutputPort: MIDIOutputService.EndpointStatus] = [:]
    private(set) var midiMonitorEvents: [MIDIOutputService.MonitorEvent] = []
    /// A session-only action-card clipboard. It deliberately never enters the
    /// persisted profile payload or the macOS general pasteboard.
    private(set) var mappingClipboard: MappingClipboardState?
    var showsInputOverlay: Bool {
        didSet {
            defaults.set(showsInputOverlay, forKey: inputOverlayDefaultsKey)
            inputOverlay.setEnabled(showsInputOverlay)
            lastPersistenceResult = .saved
        }
    }
    var inputOverlayDuration: Double {
        didSet {
            let supportedDuration = Self.closestInputOverlayDuration(to: inputOverlayDuration)
            if supportedDuration != inputOverlayDuration {
                inputOverlayDuration = supportedDuration
                return
            }
            defaults.set(inputOverlayDuration, forKey: inputOverlayDurationDefaultsKey)
            inputOverlay.setDisplayDuration(inputOverlayDuration)
            lastPersistenceResult = .saved
        }
    }
    var wheelSensitivity: Double {
        didSet {
            let clamped = WheelScrollSettings.clamped(wheelSensitivity)
            if clamped != wheelSensitivity {
                wheelSensitivity = clamped
                return
            }
            defaults.set(wheelSensitivity, forKey: wheelSensitivityDefaultsKey)
            lastPersistenceResult = .saved
        }
    }
    /// Delay before a designated Standard-mode K modifier executes its
    /// standalone Base Tap action. The value is global (not profile-scoped)
    /// because it describes how the physical remote should arbitrate a
    /// modifier press, and is intentionally kept outside the profile schema.
    var standardModifierHoldThreshold: TimeInterval {
        didSet {
            let normalized = Self.normalizedStandardModifierHoldThreshold(standardModifierHoldThreshold)
            if normalized != standardModifierHoldThreshold {
                standardModifierHoldThreshold = normalized
                return
            }
            defaults.set(standardModifierHoldThreshold, forKey: standardModifierHoldThresholdDefaultsKey)
            lastPersistenceResult = .saved
        }
    }
    let hid: HIDService

    /// The active profile's persisted realm.  Standard profiles retain the
    /// original ActionRunner path; MIDI profiles own their typed MIDI state.
    private(set) var activeRealm: ProfileRealm = .standard
    var profileRealm: ProfileRealm { activeRealm }
    /// Read-only UI state for the overlay/menu presentation. The Fn layer is
    /// strictly momentary and is cleared by every MIDI cleanup path.
    var isFnLayerActive: Bool { fnIsActive }
    var activeRealmProfileStatus: String {
        let realmLabel = activeRealm == .midi ? "MIDI" : "Standard"
        return realmLabel + " · " + profileName
    }
    var midiLocked: Bool = false
    var workspaceLockControl: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl
    var currentMIDISettings: MIDIProfileSettings? {
        guard activeRealm == .midi else { return nil }
        return midiSettings
    }
    var midiSettings: MIDIProfileSettings?

    /// Session-only expressive offsets. They intentionally live outside the
    /// persisted profile schema and reset whenever the MIDI workspace is
    /// replaced or cleaned up.
    private var midiTransposeOffsets: [MIDIMappingLayer: Int] = [.primary: 0, .function: 0]
    private var midiDrumBankOffsets: [MIDIMappingLayer: Int] = [.primary: 0, .function: 0]

    var availableProfilesInActiveRealm: [String] {
        availableProfiles.filter { profileStates[$0]?.realm == activeRealm }
    }
    var midiProfiles: [String] {
        availableProfiles.filter { profileStates[$0]?.realm == .midi }
    }
    var standardProfiles: [String] {
        availableProfiles.filter { profileStates[$0]?.realm == .standard }
    }

    func profileRealm(for name: String) -> ProfileRealm? { profileStates[name]?.realm }

    @discardableResult
    func setWorkspaceLockControl(_ control: RemoteControl) -> Bool {
        guard control.isMIDIButton else {
            lastActionResult = .failure("Workspace lock control must be a K button.")
            return false
        }
        workspaceLockControl = control
        saveAllProfiles()
        return true
    }

    static let inputOverlayDurationOptions: [Double] = [2, 4, 6, 8]
    static let defaultStandardModifierHoldThreshold: TimeInterval = 0.5

    private struct ProfileState: Codable, Equatable {
        var mappings: [MappingKey: Mapping]
        var hidBindings: [RemoteControl: String]
        var standardButtonTitles: [RemoteControl: String]
        var remoteModifierControls: Set<RemoteControl>
        var modifierColors: [RemoteControl: ModifierColor]
        var realm: ProfileRealm
        var midiSettings: MIDIProfileSettings?

        init(
            mappings: [MappingKey: Mapping],
            hidBindings: [RemoteControl: String],
            standardButtonTitles: [RemoteControl: String] = [:],
            remoteModifierControls: Set<RemoteControl> = [],
            modifierColors: [RemoteControl: ModifierColor] = [:],
            realm: ProfileRealm = .standard,
            midiSettings: MIDIProfileSettings? = nil
        ) {
            self.mappings = mappings
            self.hidBindings = hidBindings
            self.standardButtonTitles = standardButtonTitles
            self.remoteModifierControls = remoteModifierControls
            self.modifierColors = modifierColors
            self.realm = realm
            self.midiSettings = midiSettings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mappings = try container.decodeIfPresent([MappingKey: Mapping].self, forKey: .mappings) ?? [:]
            hidBindings = try container.decodeIfPresent([RemoteControl: String].self, forKey: .hidBindings) ?? [:]
            standardButtonTitles = try container.decodeIfPresent([RemoteControl: String].self, forKey: .standardButtonTitles) ?? [:]
            remoteModifierControls = try container.decodeIfPresent(Set<RemoteControl>.self, forKey: .remoteModifierControls) ?? []
            modifierColors = try container.decodeIfPresent([RemoteControl: ModifierColor].self, forKey: .modifierColors) ?? [:]
            realm = try container.decodeIfPresent(ProfileRealm.self, forKey: .realm) ?? .standard
            midiSettings = try container.decodeIfPresent(MIDIProfileSettings.self, forKey: .midiSettings)
        }

        private enum CodingKeys: String, CodingKey {
            case mappings, hidBindings, standardButtonTitles, remoteModifierControls, modifierColors, realm, midiSettings
        }

        /// Current persisted profile payloads deliberately omit the legacy
        /// per-profile HID field. The decoder above remains permissive so a
        /// v2-v8 payload can still be read and grouped into hardware layouts.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mappings, forKey: .mappings)
            try container.encode(standardButtonTitles, forKey: .standardButtonTitles)
            try container.encode(remoteModifierControls, forKey: .remoteModifierControls)
            try container.encode(modifierColors, forKey: .modifierColors)
            try container.encode(realm, forKey: .realm)
            try container.encodeIfPresent(midiSettings, forKey: .midiSettings)
        }
    }

    private struct PersistedProfile: Codable, Equatable {
        let name: String
        let state: ProfileState
    }

    /// The local defaults payload uses a small private representation so the
    /// app can retain v8 backups even while the portable XPdConfiguration
    /// model moves to top-level HardwareLayout records.
    private struct PersistedHardwareLayout: Codable, Equatable {
        let id: String
        let name: String
        let bindings: [RemoteControl: String]
    }

    private struct PersistedProfiles: Codable, Equatable {
        let version: Int
        let profiles: [PersistedProfile]
        let hardwareLayouts: [PersistedHardwareLayout]
        let activeHardwareLayoutID: String?
        let activeProfileName: String
        let activeRealm: ProfileRealm
        let lastStandardProfileName: String?
        let lastMIDIProfileName: String?
        let midiLocked: Bool
        let workspaceLockControl: RemoteControl

        init(
            version: Int,
            profiles: [PersistedProfile],
            hardwareLayouts: [PersistedHardwareLayout] = [],
            activeHardwareLayoutID: String? = nil,
            activeProfileName: String,
            activeRealm: ProfileRealm = .standard,
            lastStandardProfileName: String? = nil,
            lastMIDIProfileName: String? = nil,
            midiLocked: Bool = false,
            workspaceLockControl: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl
        ) {
            self.version = version
            self.profiles = profiles
            self.hardwareLayouts = hardwareLayouts
            self.activeHardwareLayoutID = activeHardwareLayoutID
            self.activeProfileName = activeProfileName
            self.activeRealm = activeRealm
            self.lastStandardProfileName = lastStandardProfileName
            self.lastMIDIProfileName = lastMIDIProfileName
            self.midiLocked = midiLocked
            self.workspaceLockControl = workspaceLockControl
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            profiles = try container.decodeIfPresent([PersistedProfile].self, forKey: .profiles) ?? []
            hardwareLayouts = try container.decodeIfPresent([PersistedHardwareLayout].self, forKey: .hardwareLayouts) ?? []
            activeHardwareLayoutID = try container.decodeIfPresent(String.self, forKey: .activeHardwareLayoutID)
            activeProfileName = try container.decodeIfPresent(String.self, forKey: .activeProfileName) ?? "Global"
            activeRealm = try container.decodeIfPresent(ProfileRealm.self, forKey: .activeRealm) ?? .standard
            lastStandardProfileName = try container.decodeIfPresent(String.self, forKey: .lastStandardProfileName)
            lastMIDIProfileName = try container.decodeIfPresent(String.self, forKey: .lastMIDIProfileName)
            midiLocked = try container.decodeIfPresent(Bool.self, forKey: .midiLocked) ?? false
            workspaceLockControl = try container.decodeIfPresent(RemoteControl.self, forKey: .workspaceLockControl)
                ?? XPdConfiguration.defaultWorkspaceLockControl
        }

        private enum CodingKeys: String, CodingKey {
            case version, profiles, hardwareLayouts, activeHardwareLayoutID, activeProfileName, activeRealm
            case lastStandardProfileName, lastMIDIProfileName, midiLocked, workspaceLockControl
        }
    }

    private let defaults: UserDefaults
    private let profilesDefaultsKey = "XPd.profiles.v9"
    private let previousProfilesDefaultsKey = "XPd.profiles.v8"
    private let preModifierColorsProfilesDefaultsKey = "XPd.profiles.v7"
    private let preRemoteTriggerKeysProfilesDefaultsKey = "XPd.profiles.v6"
    private let preRemoteLayersProfilesDefaultsKey = "XPd.profiles.v5"
    private let preTitlesProfilesDefaultsKey = "XPd.profiles.v4"
    private let legacyProfilesDefaultsKey = "XPd.profiles.v3"
    private let legacyLegacyProfilesDefaultsKey = "XPd.profiles.v2"
    private let profilesMigrationKey = "XPd.profiles.v6.migrated"
    private let defaultsKey = "XPd.mappings.v1"
    private let hidBindingsKey = "XPd.hidBindings.v1"
    private let profileNameDefaultsKey = "XPd.profileName.v1"
    private let inputOverlayDefaultsKey = "XPd.showsInputOverlay.v1"
    private let inputOverlayDurationDefaultsKey = "XPd.inputOverlayDuration.v1"
    private let wheelSensitivityDefaultsKey = "XPd.wheelSensitivity.v1"
    private let standardModifierHoldThresholdDefaultsKey = "XPd.standardModifierHoldThreshold.v1"
    private let standardF13F22PresetDefaultsKey = "XPd.standardF13F22Preset.v1"
    private var profileStates: [String: ProfileState] = [:]
    private var learningAllCandidate: [RemoteControl: String] = [:]
    private var learningAllCaptured: [RemoteControl: String] = [:]
    private var learningAllEncoding: HIDKeyboardReport.Encoding?
    private var learningAllLayoutID: String?
    private enum StandardKLayerVerificationStage {
        case none
        case awaitingFirst
        case awaitingComposite
        case awaitingFinalRelease
    }
    private var learningAllVerificationStage: StandardKLayerVerificationStage = .none
    private var learningAllVerificationOrderIndex = 0
    private var learningAllVerificationFirstSignature: String?
    private var learningAllVerificationFirstReport: HIDKeyboardReport?
    private var learningAllVerificationSecondReport: HIDKeyboardReport?
    private var learningAllVerificationCompositeReport: HIDKeyboardReport?
    /// A selected hardware layout may not expose every persisted modifier.
    /// Keep that availability separate from the saved designation so merely
    /// switching layouts cannot erase the user's Standard-layer design.
    private var unavailableRemoteModifierControls: Set<RemoteControl> = []
    private var shouldPersistProfilesAfterLoad = true
    private var liveInputGeneration = 0
    private var isProfileSelectorVisible = false
    private var isWheelCenterHeld = false
    private var pendingProfileName: String?
    private var profileSelectorTimeoutTask: Task<Void, Never>?
    private var profileSelectorTimeoutGeneration = 0
    private var isReplacingConfiguration = false
    private var loadedProfileName: String?
    private var loadedActiveRealm: ProfileRealm = .standard
    private var loadedLastStandardProfileName: String?
    private var loadedLastMIDIProfileName: String?
    private var loadedMIDIIsLocked = false
    private var loadedWorkspaceLockControl: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl
    private var lastStandardProfileName: String?
    private var lastMIDIProfileName: String?
    private var fnIsActive = false
    private var activeMIDIControls: Set<RemoteControl> = []
    /// Report 6 is a complete boot-keyboard snapshot. Track its resolved K
    /// controls independently so a changed two-key snapshot releases only
    /// the removed key while preserving the note that remains physically held.
    private var activeMIDIReport6Controls: Set<RemoteControl> = []
    /// Report-2 is a complete K-button state snapshot rather than the
    /// report-6 single-control stream. Keep its held set separate so a
    /// neutral report-2 release cannot release an unrelated report-6 MIDI
    /// control, and repeated snapshots do not duplicate MIDI presses.
    private var activeMIDIReport2Controls: Set<RemoteControl> = []
    private var midiControlLayers: [RemoteControl: Int] = [:]
    private var centerFnHoldTask: Task<Void, Never>?
    private var centerFnHoldGeneration = 0
    private let midiOutputService: MIDIOutputService
    private let midiCommandTail = MIDICommandTail()
    private let midiShutdownGate = MIDIShutdownGate()
    private let actionRunner = ActionRunner()
    private let modifierArbitrationLogger = Logger(
        subsystem: "com.dmssoftres.xpd",
        category: "ModifierArbitration"
    )
    private let actionExecutionOverride: ActionExecutionOverride?
    private let mainWindowToggle: MainWindowToggle?
    private let runModeTransition: RunModeTransition?
    private let gestureSchedule: ButtonGestureRecognizer.Schedule
    private let remoteModifierProvider: RemoteModifierProvider
    private let remoteFunctionKeyProvider: RemoteFunctionKeyProvider
    private let remoteKeyProvider: RemoteKeyProvider
    private let buttonGestureRecognizer: ButtonGestureRecognizer
    /// Standard-mode K-button cycles can contain one non-modifier primary
    /// plus any number of designated K modifiers. Report 6 still has one
    /// generic release boundary; retain a separate report-6 snapshot set so
    /// partial releases can reconcile a changed keyboard state before the
    /// generic release boundary arrives. Report 2 is a complete state
    /// snapshot and keeps its active set until the next snapshot or
    /// F0/all-zero boundary.
    private var activeStandardControls: Set<RemoteControl> = []
    private var activeStandardReport6Controls: Set<RemoteControl> = []
    private var activeStandardReport2Controls: Set<RemoteControl> = []
    private var activeStandardKeyboardModifiers: [RemoteControl: Set<KeyboardShortcut.Modifier>] = [:]
    private var activeStandardFunctionKeys: [RemoteControl: Set<UInt16>] = [:]
    private var activeStandardKeyboardKeys: [RemoteControl: Set<UInt16>] = [:]
    private var activeStandardGestureIdentity: ButtonGestureIdentity?
    private var activeStandardModifierHoldTasks: [RemoteControl: GestureScheduledAction] = [:]
    /// A lone modifier becomes eligible for its standalone Base Tap when this
    /// threshold is reached, but remains layer-eligible until physical
    /// release. The Base Tap is committed only at release if no destination
    /// participated in the cycle.
    private var activeStandardModifierThresholdReached: Set<RemoteControl> = []
    private var activeStandardModifierBaseSuppressed = false
    private var activeStandardModifierGeneration = 0
    private var ambiguousStandardCycles: Set<RemoteControl> = []
    /// One pending per-combo sequential recognition window per source key.
    /// A released lone Standard modifier defers its solo Base commit here
    /// until the configured window expires without destination participation.
    /// The timers are scheduled through the same injected `gestureSchedule`
    /// as the standalone threshold, keeping tests deterministic.
    private struct DeferredStandardSoloSequence {
        let identity: ButtonGestureIdentity
        let generation: Int
        let task: GestureScheduledAction
    }
    private var activeStandardDeferredSoloSequences: [RemoteControl: DeferredStandardSoloSequence] = [:]
    /// A freshly pressed lone Standard destination may be completed by a
    /// designated modifier within this window (destination-first order).
    private struct DestinationStandardSequenceWindow {
        let generation: Int
        let task: GestureScheduledAction
    }
    private var activeStandardDestinationSequenceWindows: [RemoteControl: DestinationStandardSequenceWindow] = [:]
    /// Generation guard for both window kinds. Unlike the modifier-cycle
    /// generation it is only bumped by explicit cancellation so a released
    /// modifier's pending window can survive its own release boundary.
    private var activeStandardSequenceGeneration = 0
    private var isRemoteTriggerCaptureActive = false
    private var remoteTriggerModifierCaptureHandler: ((RemoteControl) -> Void)?
    @ObservationIgnored private lazy var inputOverlay = InputOverlayController(displayDuration: inputOverlayDuration)
    @ObservationIgnored private let terminationObserver = MIDIShutdownObserver()

    private static func currentRemoteModifierSet() -> Set<KeyboardShortcut.Modifier> {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers = Set<KeyboardShortcut.Modifier>()
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }

    private static func currentRemoteFunctionKeySet() -> Set<UInt16> {
        KeyboardShortcut.functionKeyCodes.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
    }

    /// Read only the ordinary key codes that are actually configured as
    /// remote-trigger conditions. This keeps the input observation scope
    /// bounded instead of scanning the whole keyboard.
    private static func currentRemoteKeySet(_ configuredKeyCodes: Set<UInt16>) -> Set<UInt16> {
        configuredKeyCodes.filter { keyCode in
            !KeyboardShortcut.functionKeyCodes.contains(keyCode)
                && !KeyboardShortcut.isModifierKeyCode(keyCode)
                && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        startHardware: Bool = true,
        gestureSchedule: @escaping ButtonGestureRecognizer.Schedule = ButtonGestureRecognizer.productionSchedule,
        actionExecutionOverride: ActionExecutionOverride? = nil,
        midiOutputService: MIDIOutputService? = nil,
        remoteModifierProvider: @escaping RemoteModifierProvider = MappingStore.currentRemoteModifierSet,
        remoteFunctionKeyProvider: @escaping RemoteFunctionKeyProvider = MappingStore.currentRemoteFunctionKeySet,
        remoteKeyProvider: @escaping RemoteKeyProvider = MappingStore.currentRemoteKeySet,
        mainWindowToggle: MainWindowToggle? = nil,
        runModeTransition: RunModeTransition? = nil
    ) {
        defaults = userDefaults
        hid = HIDService(startHardware: startHardware)
        self.gestureSchedule = gestureSchedule
        buttonGestureRecognizer = ButtonGestureRecognizer(schedule: gestureSchedule)
        self.actionExecutionOverride = actionExecutionOverride
        self.mainWindowToggle = mainWindowToggle
        self.runModeTransition = runModeTransition
        self.midiOutputService = midiOutputService ?? MIDIOutputService(defaults: userDefaults)
        self.remoteModifierProvider = remoteModifierProvider
        self.remoteFunctionKeyProvider = remoteFunctionKeyProvider
        self.remoteKeyProvider = remoteKeyProvider

        let savedProfile = defaults.string(forKey: profileNameDefaultsKey)
        showsInputOverlay = defaults.object(forKey: inputOverlayDefaultsKey) as? Bool ?? true
        let savedDuration = defaults.object(forKey: inputOverlayDurationDefaultsKey) as? Double ?? 4
        inputOverlayDuration = Self.closestInputOverlayDuration(to: savedDuration)
        let savedWheelSensitivity = defaults.object(forKey: wheelSensitivityDefaultsKey) as? Double
            ?? WheelScrollSettings.defaultSensitivity
        wheelSensitivity = WheelScrollSettings.clamped(savedWheelSensitivity)
        let savedModifierHoldThreshold = defaults.object(forKey: standardModifierHoldThresholdDefaultsKey) as? Double
            ?? Self.defaultStandardModifierHoldThreshold
        standardModifierHoldThreshold = Self.normalizedStandardModifierHoldThreshold(savedModifierHoldThreshold)
        usesStandardF13F22Preset = defaults.bool(forKey: standardF13F22PresetDefaultsKey)

        let migratedLegacyState = loadOrMigrateProfiles()
        let restoredProfile = migratedLegacyState
            ? "Global"
            : (loadedProfileName ?? savedProfile).flatMap { availableProfiles.contains($0) ? $0 : nil } ?? "Global"
        activeRealm = loadedActiveRealm
        lastStandardProfileName = loadedLastStandardProfileName
        lastMIDIProfileName = loadedLastMIDIProfileName
        midiLocked = loadedMIDIIsLocked
        workspaceLockControl = loadedWorkspaceLockControl.isMIDIButton
            ? loadedWorkspaceLockControl
            : XPdConfiguration.defaultWorkspaceLockControl
        isReplacingConfiguration = true
        profileName = restoredProfile
        isReplacingConfiguration = false
        defaults.set(profileName, forKey: profileNameDefaultsKey)
        activateProfile(named: profileName)
        if shouldPersistProfilesAfterLoad {
            saveAllProfiles()
        }

        hid.onInput = { [weak self] signature in
            self?.handleHIDInput(signature)
        }
        hid.onBluetoothDriverModeChange = { [weak self] isActive in
            self?.bluetoothDriverModeChanged(isActive)
        }
        hid.onDisconnect = { [weak self] in
            if let self, self.isLearningAll {
                self.failLearningAll(
                    self.standardKLayerLearningCancellationMessage("the remote disconnected")
                )
            } else if self?.learningControl != nil {
                self?.lastHIDLearningResult = .failure("Learning canceled because the remote disconnected.")
            }
            self?.invalidateStandardKLayerLiveVerification()
            self?.invalidateStandardF13F22PresetLiveVerification()
            self?.cancelLearning()
            self?.cancelPendingButtonGestures()
            self?.resetMIDIState(force: true)
            self?.refreshMIDIEndpointStatus()
            self?.closeProfileSelector()
        }
        buttonGestureRecognizer.onGesture = { [weak self] identity, gesture in
            self?.recognizedButtonGesture(identity: identity, gesture: gesture)
        }
        let midiService = self.midiOutputService
        let monitorRelay = MIDIMonitorRelay(store: self)
        midiCommandTail.task = Task {
            await midiService.setMonitorSink { [monitorRelay] event in
                monitorRelay.receive(event)
            }
        }
        refreshMIDIEndpointStatus()
        syncMIDIOverlay()
        terminationObserver.token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hid.prepareForTermination()
                self?.requestMIDIShutdown()
            }
        }
    }

    deinit {
        if let token = terminationObserver.token {
            NotificationCenter.default.removeObserver(token)
        }
        guard midiShutdownGate.request() else { return }
        let previous = midiCommandTail.task
        let service = midiOutputService
        Task {
            if let previous { await previous.value }
            _ = await service.resetForShutdown()
        }
    }

    func mapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) -> Mapping {
        mappings[MappingKey(control: control, gesture: gesture, modifierControls: modifierControls)] ?? Mapping()
    }

    @discardableResult
    func setRunMode(_ enabled: Bool) -> Bool {
        guard enabled != isRunMode else { return true }

        guard let runModeTransition else {
            isRunMode = enabled
            return true
        }

        let result = runModeTransition(enabled)
        lastActionResult = result
        guard result.succeeded else { return false }
        isRunMode = enabled
        return true
    }

    /// Returns the application routes that can currently be presented on a
    /// Standard K button. Base routes are ordered by gesture and deduplicated
    /// by normalized target. Alternate layers are ordered by their exact
    /// modifier set, then gesture, and are deduplicated within that set.
    /// Hold/Double inheritance is resolved here so the view never presents a
    /// stale or invalid command.
    func standardApplicationRoutes(for control: RemoteControl) -> [StandardApplicationRoute] {
        guard activeRealm == .standard, control.isMIDIButton else { return [] }

        var routes: [StandardApplicationRoute] = []
        var baseTargets = Set<String>()

        for gesture in GestureKind.allCases {
            guard let route = applicationRoute(
                for: control,
                gesture: gesture,
                modifierControls: []
            ) else { continue }
            guard baseTargets.insert(route.targetIdentity).inserted else { continue }
            routes.append(route)
        }

        let layerSets = Set(
            mappings.keys.compactMap { key -> Set<RemoteControl>? in
                guard key.control == control,
                      !key.modifierControls.isEmpty,
                      isExecutableApplicationLayer(key.modifierControls, for: control) else {
                    return nil
                }
                return key.modifierControls
            }
        )

        for modifierControls in layerSets.sorted(by: orderedModifierSets) {
            var layerTargets = Set<String>()
            for gesture in GestureKind.allCases {
                guard let route = applicationRoute(
                    for: control,
                    gesture: gesture,
                    modifierControls: modifierControls
                ) else { continue }
                guard layerTargets.insert(route.targetIdentity).inserted else { continue }
                routes.append(route)
            }
        }

        return routes
    }

    /// Returns one presentation route for every exact Standard K-button layer
    /// containing a currently executable non-application action. Gesture
    /// differences on one layer are intentionally deduplicated. Inactive or
    /// invalid modifier layers are omitted, matching application-route
    /// presentation and runtime resolution semantics.
    func standardNonApplicationRoutes(for control: RemoteControl) -> [StandardNonApplicationRoute] {
        guard activeRealm == .standard, control.isMIDIButton else { return [] }

        var routes: [StandardNonApplicationRoute] = []
        if hasConfiguredNonApplicationAction(for: control, modifierControls: []) {
            routes.append(StandardNonApplicationRoute(modifierControls: []))
        }

        let layerSets = Set(
            mappings.keys.compactMap { key -> Set<RemoteControl>? in
                guard key.control == control,
                      !key.modifierControls.isEmpty,
                      isExecutableApplicationLayer(key.modifierControls, for: control) else {
                    return nil
                }
                return key.modifierControls
            }
        )

        for modifierControls in layerSets.sorted(by: orderedModifierSets)
            where hasConfiguredNonApplicationAction(for: control, modifierControls: modifierControls) {
            routes.append(
                StandardNonApplicationRoute(
                    modifierControls: modifierControls,
                    isSequenceCombo: layerHasSequenceComboMapping(control, modifierControls: modifierControls)
                )
            )
        }

        return routes
    }

    private func layerHasSequenceComboMapping(
        _ control: RemoteControl,
        modifierControls: Set<RemoteControl>
    ) -> Bool {
        mappings.contains { key, mapping in
            key.control == control
                && key.modifierControls == modifierControls
                && mapping.comboMode == .sequence
        }
    }

    /// Saved non-Base layers for one Standard destination. Dormant layers are
    /// intentionally included so the inspector can keep them visible after a
    /// modifier designation is disabled, until their actions are deleted.
    func standardModifierLayers(for control: RemoteControl) -> [Set<RemoteControl>] {
        guard activeRealm == .standard, control.isMIDIButton else { return [] }
        let layers = Set(mappings.compactMap { key, mapping -> Set<RemoteControl>? in
            guard key.control == control,
                  !key.modifierControls.isEmpty,
                  mapping != Mapping() else {
                return nil
            }
            return key.modifierControls
        })
        return layers.sorted(by: orderedModifierSets)
    }

    /// Whether this Standard K button contains a currently executable mapping
    /// for XP[d]'s own show/hide action, across Base or an enabled modifier
    /// layer. This is presentation-only state for the hardware-button badge.
    func hasMainWindowToggleMapping(for control: RemoteControl) -> Bool {
        guard activeRealm == .standard, control.isMIDIButton else { return false }

        return mappings.keys.contains { key in
            guard key.control == control,
                  key.modifierControls.isEmpty
                    || isExecutableApplicationLayer(key.modifierControls, for: control),
                  case let .success(mapping) = resolvedMapping(
                    for: control,
                    gesture: key.gesture,
                    modifierControls: key.modifierControls
                  ) else {
                return false
            }
            return mapping.action == .windowDisplay
                && mapping.command == WindowDisplayAction.toggleXPd.rawValue
        }
    }

    private func applicationRoute(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl>
    ) -> StandardApplicationRoute? {
        guard modifierControls.isEmpty || isExecutableApplicationLayer(modifierControls, for: control) else {
            return nil
        }

        guard case let .success(mapping) = resolvedMapping(
            for: control,
            gesture: gesture,
            modifierControls: modifierControls
        ), mapping.action.isApplicationAction else {
            return nil
        }

        let target = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return StandardApplicationRoute(
            target: target,
            gesture: gesture,
            modifierControls: modifierControls,
            targetIdentity: nil,
            isSequenceCombo: mapping.comboMode == .sequence
        )
    }

    private func hasConfiguredNonApplicationAction(
        for control: RemoteControl,
        modifierControls: Set<RemoteControl>
    ) -> Bool {
        GestureKind.allCases.contains { gesture in
            guard case let .success(mapping) = resolvedMapping(
                for: control,
                gesture: gesture,
                modifierControls: modifierControls
            ) else {
                return false
            }

            guard mapping.action != .noAction,
                  !mapping.action.isApplicationAction,
                  !(mapping.action == .windowDisplay
                    && mapping.command == WindowDisplayAction.toggleXPd.rawValue) else {
                return false
            }

            guard InputOverlayPresentation(mapping: mapping).isConfigured else {
                return false
            }

            if mapping.action == .keyboardShortcut {
                guard let shortcut = mapping.keyboardShortcut,
                      !shortcut.displayString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      shortcut.keyCode <= 127 else {
                    return false
                }
            }

            return true
        }
    }

    private func isExecutableApplicationLayer(
        _ modifierControls: Set<RemoteControl>,
        for destination: RemoteControl
    ) -> Bool {
        activeRealm == .standard
            && !modifierControls.isEmpty
            && modifierControls.allSatisfy {
                $0 != destination
                    && $0.isModifierEligible
                    && isRemoteModifier($0)
            }
    }

    private func orderedModifierSets(
        _ lhs: Set<RemoteControl>,
        _ rhs: Set<RemoteControl>
    ) -> Bool {
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        let lhsOrder = RemoteControl.allCases.enumerated()
            .filter { lhs.contains($0.element) }
            .map(\.offset)
        let rhsOrder = RemoteControl.allCases.enumerated()
            .filter { rhs.contains($0.element) }
            .map(\.offset)
        return lhsOrder.lexicographicallyPrecedes(rhsOrder)
    }

    /// The ordinary keyboard keys that can affect Standard trigger matching
    /// in the active profile. The provider samples only this bounded set on a
    /// remote K press.
    private var configuredRemoteTriggerKeyCodes: Set<UInt16> {
        Set(mappings.values.compactMap(\.remoteTriggerKeyCode))
    }

    /// Returns the currently designated Standard-mode K-button modifiers.
    /// MIDI profiles and non-button controls always expose an empty set.
    func isRemoteModifier(_ control: RemoteControl) -> Bool {
        activeRealm == .standard
            && remoteModifierControls.contains(control)
            && !unavailableRemoteModifierControls.contains(control)
    }

    /// Returns the profile-scoped colour that should be shown for a K
    /// modifier. Explicit assignments are retained even while the control is
    /// disabled; an unassigned control gets the same least-used suggestion
    /// that enabling it will persist.
    func modifierColor(for control: RemoteControl) -> ModifierColor {
        guard activeRealm == .standard, control.isModifierEligible else {
            return .orange
        }
        return modifierColors[control] ?? suggestedModifierColor(excluding: control)
    }

    /// Alias kept deliberately small for callers that want to make the
    /// effective-vs-explicit distinction clear at the call site.
    func effectiveModifierColor(for control: RemoteControl) -> ModifierColor {
        modifierColor(for: control)
    }

    @discardableResult
    func setModifierColor(_ color: ModifierColor, for control: RemoteControl) -> Bool {
        guard activeRealm == .standard, control.isModifierEligible else { return false }
        guard modifierColors[control] != color else { return true }
        modifierColors[control] = color
        save()
        return true
    }

    @discardableResult
    func setModifierColor(for control: RemoteControl, color: ModifierColor) -> Bool {
        setModifierColor(color, for: control)
    }

    private func suggestedModifierColor(excluding control: RemoteControl?) -> ModifierColor {
        let activeControls = remoteModifierControls
            .subtracting(unavailableRemoteModifierControls)
            .filter { $0 != control }
        let counts = Dictionary(
            uniqueKeysWithValues: ModifierColor.allCases.map { color in
                (
                    color,
                    activeControls.reduce(into: 0) { count, activeControl in
                        let activeColor = modifierColors[activeControl] ?? .orange
                        if activeColor == color { count += 1 }
                    }
                )
            }
        )
        return ModifierColor.allCases.min {
            let lhsCount = counts[$0] ?? 0
            let rhsCount = counts[$1] ?? 0
            return lhsCount < rhsCount
        } ?? .orange
    }

    @discardableResult
    func setRemoteModifier(_ control: RemoteControl, enabled: Bool) -> Bool {
        guard activeRealm == .standard, control.isModifierEligible else { return false }
        guard remoteModifierControls.contains(control) != enabled else { return true }
        cancelPendingButtonGestures()
        if enabled {
            guard let binding = effectiveStandardHIDBindings[control],
                  !binding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastActionResult = .failure(
                    "Learn \(control.rawValue)'s HID input in Status & Input before enabling it as a modifier."
                )
                return false
            }
            remoteModifierControls.insert(control)
            unavailableRemoteModifierControls.remove(control)
            if modifierColors[control] == nil {
                // Compute before this control participates in the active set;
                // this matches the store's deterministic suggested colour.
                modifierColors[control] = suggestedModifierColor(excluding: control)
            }
            if selectedControl == control {
                selectedGesture = .tap
                selectedMappingModifiers = []
            }
        } else {
            remoteModifierControls.remove(control)
            unavailableRemoteModifierControls.remove(control)
        }
        sanitizeSelectedMappingModifier()
        save()
        return true
    }

    /// Temporarily consumes remote input while the unified chord editor is
    /// recording. Only designated K buttons are delivered as optional
    /// modifier conditions; the selected destination is never replaced.
    func beginRemoteTriggerCapture(onRemoteModifier: @escaping (RemoteControl) -> Void) {
        cancelLearning()
        cancelPendingButtonGestures()
        closeProfileSelector()
        remoteTriggerModifierCaptureHandler = onRemoteModifier
        isRemoteTriggerCaptureActive = true
    }

    func endRemoteTriggerCapture() {
        remoteTriggerModifierCaptureHandler = nil
        isRemoteTriggerCaptureActive = false
    }

    /// Returns the optional title for a Standard-mode K button. Titles are
    /// intentionally hidden while a MIDI profile is active and never apply to
    /// wheel controls.
    func standardButtonTitle(for control: RemoteControl) -> String {
        guard activeRealm == .standard, control.isMIDIButton else { return "" }
        return standardButtonTitles[control] ?? ""
    }

    /// Persists an optional Standard-mode title shared by the button's
    /// Tap/Hold/Double mappings. Empty or whitespace-only values remove the
    /// entry; invalid controls are ignored, while values over 24 trimmed
    /// characters are bounded before persistence.
    func updateStandardButtonTitle(_ title: String, for control: RemoteControl) {
        guard activeRealm == .standard, control.isMIDIButton else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.prefix(24))
        if bounded.isEmpty {
            standardButtonTitles.removeValue(forKey: control)
        } else {
            standardButtonTitles[control] = bounded
        }
        save()
    }

    // MARK: MIDI profile state

    func midiButtonMapping(for control: RemoteControl, layer: MIDIMappingLayer = .primary) -> MIDIButtonMapping {
        guard let settings = midiSettings else { return MIDIButtonMapping() }
        let entries = layer == .primary ? settings.primaryButtons : settings.functionButtons
        return entries.first(where: { $0.control == control })?.mapping ?? MIDIButtonMapping()
    }

    func primaryButtonMapping(for control: RemoteControl) -> MIDIButtonMapping {
        midiButtonMapping(for: control, layer: .primary)
    }

    func midiMapping(for control: RemoteControl, layer: MIDIMappingLayer = .primary) -> MIDIButtonMapping {
        midiButtonMapping(for: control, layer: layer)
    }

    func effectiveMIDIButtonMappingForTesting(
        for control: RemoteControl,
        layer: MIDIMappingLayer = .primary
    ) -> MIDIButtonMapping {
        adjustedMIDIButtonMapping(midiButtonMapping(for: control, layer: layer), layer: layer)
    }

    func functionButtonMapping(for control: RemoteControl) -> MIDIButtonMapping {
        midiButtonMapping(for: control, layer: .function)
    }

    func updateMIDIButtonMapping(
        _ mapping: MIDIButtonMapping,
        for control: RemoteControl,
        layer: MIDIMappingLayer = .primary
    ) {
        guard activeRealm == .midi, control.isMIDIButton else { return }
        guard (try? mapping.validate()) != nil else {
            lastMIDIError = "Invalid MIDI button mapping."
            return
        }
        resetMIDIState()
        var settings = midiSettings ?? MIDIProfileSettings()
        if layer == .primary {
            settings.primaryButtons.removeAll { $0.control == control }
            settings.primaryButtons.append(.init(control: control, mapping: mapping))
        } else {
            settings.functionButtons.removeAll { $0.control == control }
            settings.functionButtons.append(.init(control: control, mapping: mapping))
        }
        midiSettings = settings
        saveMIDIState()
    }

    func updatePrimaryButtonMapping(_ mapping: MIDIButtonMapping, for control: RemoteControl) {
        updateMIDIButtonMapping(mapping, for: control, layer: .primary)
    }

    func updateFunctionButtonMapping(_ mapping: MIDIButtonMapping, for control: RemoteControl) {
        updateMIDIButtonMapping(mapping, for: control, layer: .function)
    }

    func updateMIDIButton(_ mapping: MIDIButtonMapping, for control: RemoteControl, layer: MIDIMappingLayer = .primary) {
        updateMIDIButtonMapping(mapping, for: control, layer: layer)
    }

    func midiWheelMapping(for layer: MIDIMappingLayer = .primary) -> MIDIWheelMapping {
        layer == .primary ? midiSettings?.primaryWheel ?? MIDIWheelMapping() : midiSettings?.functionWheel ?? MIDIWheelMapping(kind: .absoluteCC, controller: 1)
    }

    func primaryWheelMapping() -> MIDIWheelMapping { midiWheelMapping(for: .primary) }
    func functionWheelMapping() -> MIDIWheelMapping { midiWheelMapping(for: .function) }
    func wheelMapping(for layer: MIDIMappingLayer = .primary) -> MIDIWheelMapping { midiWheelMapping(for: layer) }

    func updateMIDIWheelMapping(_ mapping: MIDIWheelMapping, layer: MIDIMappingLayer = .primary) {
        guard activeRealm == .midi else { return }
        guard (try? mapping.validate()) != nil else {
            lastMIDIError = "Invalid MIDI wheel mapping."
            return
        }
        resetMIDIState()
        var settings = midiSettings ?? MIDIProfileSettings()
        if layer == .primary { settings.primaryWheel = mapping } else { settings.functionWheel = mapping }
        midiSettings = settings
        saveMIDIState()
    }

    func updatePrimaryWheelMapping(_ mapping: MIDIWheelMapping) { updateMIDIWheelMapping(mapping, layer: .primary) }
    func updateFunctionWheelMapping(_ mapping: MIDIWheelMapping) { updateMIDIWheelMapping(mapping, layer: .function) }
    func updateWheelMapping(_ mapping: MIDIWheelMapping, layer: MIDIMappingLayer = .primary) { updateMIDIWheelMapping(mapping, layer: layer) }

    @discardableResult
    func updateMIDIPracticeFnControl(_ control: RemoteControl?) -> Bool {
        guard activeRealm == .midi else { return false }
        if let control, !control.isMIDIEligibleFnControl {
            lastMIDIError = MIDIValidationError.invalidFnControl(control).localizedDescription
            return false
        }
        var settings = midiSettings ?? MIDIProfileSettings()
        guard settings.fnControl != control else { return true }
        resetMIDIState(force: true)
        settings.fnControl = control
        midiSettings = settings
        saveMIDIState()
        return true
    }

    func updateFnAssignment(_ control: RemoteControl?) -> Bool {
        updateMIDIPracticeFnControl(control)
    }

    func setFnControl(_ control: RemoteControl?) -> Bool { updateMIDIPracticeFnControl(control) }

    /// Updates the persisted center-as-Fn hold threshold. The model's valid
    /// range is 0.10...3.0 seconds; UI edits are clamped before the complete
    /// MIDI settings object is validated and autosaved.
    @discardableResult
    func updateMIDIHoldThreshold(_ threshold: TimeInterval) -> Bool {
        guard activeRealm == .midi else { return false }
        guard threshold.isFinite else {
            lastMIDIError = "Fn hold threshold must be finite."
            return false
        }
        var settings = midiSettings ?? MIDIProfileSettings()
        settings.fnHoldThreshold = max(0.10, min(3.0, threshold))
        guard (try? settings.validate()) != nil else {
            lastMIDIError = "Invalid Fn hold threshold."
            return false
        }
        midiSettings = settings
        saveMIDIState()
        return true
    }

    func setMIDIHoldThreshold(_ threshold: TimeInterval) -> Bool {
        updateMIDIHoldThreshold(threshold)
    }

    var fnControl: RemoteControl? { midiSettings?.fnControl }

    func refreshMIDIEndpointStatus() {
        Task { [weak self] in
            guard let self else { return }
            let statuses = await midiOutputService.endpointStatus()
            let message = await midiOutputService.lastMessage
            let error = await midiOutputService.lastError
            self.midiEndpointStatuses = statuses
            self.lastMIDIMessage = message
            self.lastMIDIError = error
        }
    }

    var midiEndpointStatus: [MIDIOutputPort: MIDIOutputService.EndpointStatus] { midiEndpointStatuses }
    var endpointStatuses: [MIDIOutputPort: MIDIOutputService.EndpointStatus] { midiEndpointStatuses }
    var lastMessage: MIDIOutputService.SentMessage? { lastMIDIMessage }
    var lastError: String? { lastMIDIError }
    var midiStatus: String? { lastMIDIStatus }

    func clearMIDIMonitor() {
        midiMonitorEvents.removeAll()
    }

    func midiTransposeOffset(for layer: MIDIMappingLayer = .primary) -> Int {
        midiTransposeOffsets[layer, default: 0]
    }

    func midiDrumBankOffset(for layer: MIDIMappingLayer = .primary) -> Int {
        midiDrumBankOffsets[layer, default: 0]
    }

    func panicMIDI() {
        enqueueMIDICommand { service in
            await service.panic()
        }
        fnIsActive = false
        activeMIDIControls.removeAll()
        activeMIDIReport6Controls.removeAll()
        activeMIDIReport2Controls.removeAll()
        midiControlLayers.removeAll()
        resetSessionOffsets()
        syncMIDIOverlay()
    }

    func panic() { panicMIDI() }
    func panicMIDIOutput() { panicMIDI() }
    func sendTestMIDIMessage(for control: RemoteControl, layer: MIDIMappingLayer = .primary) {
        sendMIDITestMessage(for: control, layer: layer)
    }

    func sendMIDITestMessage(for control: RemoteControl, layer: MIDIMappingLayer = .primary) {
        guard activeRealm == .midi, control.isMIDIButton else { return }
        let mapping = adjustedMIDIButtonMapping(
            midiButtonMapping(for: control, layer: layer),
            layer: layer
        )
        let origin = MIDIOutputService.Origin("test:\(control.rawValue)", layer: layer == .primary ? 1 : 2)
        enqueueMIDICommand { service in
            let result = await service.sendButton(mapping, origin: origin)
            _ = await service.release(origin: origin)
            return result
        }
    }

    func selectProfile(_ name: String) -> Bool {
        guard let state = profileStates[name] else {
            lastActionResult = .failure(ProfileError.profileNotFound(name).localizedDescription)
            return false
        }
        closeProfileSelector()
        midiLocked = state.realm == .midi
        profileName = name
        return true
    }

    func selectProfile(named name: String) -> Bool { selectProfile(name) }
    func setActiveProfile(_ name: String) -> Bool { selectProfile(name) }

    @discardableResult
    func toggleWorkspace() -> Bool {
        let targetRealm: ProfileRealm = activeRealm == .midi ? .standard : .midi
        guard let target = rememberedProfile(in: targetRealm) ?? availableProfiles.first(where: { profileStates[$0]?.realm == targetRealm }) else {
            lastActionResult = .failure(ProfileError.noMIDIProfile.localizedDescription)
            return false
        }
        closeProfileSelector()
        resetMIDIState(force: true)
        midiLocked = targetRealm == .midi
        profileName = target
        activeRealm = targetRealm
        saveAllProfiles()
        return true
    }

    func toggleMIDIWorkspace() -> Bool { toggleWorkspace() }

    /// Returns the application target currently configured for a control's
    /// Tap mapping.  The target is intentionally read on demand so Hold and
    /// Double mappings follow later Tap edits without copying stale data.
    func inheritedTapApplication(
        for control: RemoteControl,
        modifierControls: Set<RemoteControl> = []
    ) -> Result<String, MappingResolutionError> {
        let tap = mapping(for: control, gesture: .tap, modifierControls: modifierControls)
        guard tap.action.isApplicationAction else {
            return .failure(.tapMappingMustBeApplication)
        }

        let command = tap.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .failure(.tapApplicationMissing)
        }
        return .success(command)
    }

    /// Resolves an action mapping immediately before execution.  Only Hold
    /// and Double application actions can opt into Tap inheritance; all other
    /// mappings are returned unchanged for backward compatibility.
    func resolvedMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) -> Result<Mapping, MappingResolutionError> {
        let mapping = mapping(for: control, gesture: gesture, modifierControls: modifierControls)
        guard (gesture == .hold || gesture == .doubleTap),
              mapping.action.isApplicationAction,
              mapping.usesTapApplication else {
            return .success(mapping)
        }

        switch inheritedTapApplication(for: control, modifierControls: modifierControls) {
        case let .success(command):
            var resolved = mapping
            resolved.command = command
            // The command is now concrete; do not ask an execution-only
            // caller to resolve the same mapping again.
            resolved.usesTapApplication = false
            return .success(resolved)
        case let .failure(error):
            return .failure(error)
        }
    }

    // MARK: Action-card clipboard

    var hasMappingClipboard: Bool {
        mappingClipboard != nil
    }

    func mappingClipboardOperation(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> MappingClipboardOperation? {
        let location = MappingClipboardLocation(
            profileName: profileName ?? self.profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )
        guard mappingClipboard?.source == location else { return nil }
        return mappingClipboard?.operation
    }

    func canCopyMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        portableMapping(at: makeMappingLocation(
            profileName: profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )) != nil
    }

    func canCutMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        canCopyMapping(
            for: control,
            gesture: gesture,
            modifierControls: modifierControls,
            profileName: profileName
        )
    }

    /// The Paste button remains enabled over an occupied destination so the
    /// UI can ask for an explicit replacement confirmation. This method only
    /// answers whether a valid clipboard payload exists for the destination.
    func canPasteMapping(
        to control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        guard let clipboard = mappingClipboard else { return false }
        let destination = makeMappingLocation(
            profileName: profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )
        guard isStandardProfile(destination.profileName) else { return false }
        guard clipboard.source != destination else {
            return false
        }
        if clipboard.operation == .cut,
           mapping(at: clipboard.source) != clipboard.rawSourceMapping {
            return false
        }
        return clipboard.portableMapping != Mapping()
    }

    func destinationHasMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        mapping(at: makeMappingLocation(
            profileName: profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )) != Mapping()
    }

    func mappingDestinationSnapshot(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> MappingDestinationSnapshot {
        let location = makeMappingLocation(
            profileName: profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )
        return MappingDestinationSnapshot(
            location: location,
            expectedMapping: mapping(at: location)
        )
    }

    @discardableResult
    func copyMapping(
        from control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        let source = makeMappingLocation(
            profileName: profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )
        guard let portable = portableMapping(at: source) else {
            lastActionResult = .failure("This action cannot be copied until its application target is complete.")
            return false
        }
        mappingClipboard = MappingClipboardState(
            operation: .copy,
            source: source,
            rawSourceMapping: mapping(at: source),
            portableMapping: portable
        )
        lastActionResult = .success("Action copied")
        return true
    }

    @discardableResult
    func cutMapping(
        from control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        let source = makeMappingLocation(
            profileName: profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )
        let raw = mapping(at: source)
        guard let portable = portableMapping(at: source) else {
            lastActionResult = .failure("This action cannot be moved until its application target is complete.")
            return false
        }
        guard raw != Mapping() else { return false }
        mappingClipboard = MappingClipboardState(
            operation: .cut,
            source: source,
            rawSourceMapping: raw,
            portableMapping: portable
        )
        lastActionResult = .success("Action marked to move")
        return true
    }

    @discardableResult
    func pasteMapping(
        to control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil,
        replacingExisting: Bool = false
    ) -> MappingClipboardResult {
        let destination = mappingDestinationSnapshot(
            for: control,
            gesture: gesture,
            modifierControls: modifierControls,
            profileName: profileName
        )
        return pasteMapping(to: destination, replacingExisting: replacingExisting)
    }

    @discardableResult
    func pasteMapping(
        to destination: MappingDestinationSnapshot,
        replacingExisting: Bool = false
    ) -> MappingClipboardResult {
        guard let clipboard = mappingClipboard else {
            lastActionResult = .failure("There is no copied action to paste.")
            return .unavailable
        }
        guard isStandardProfile(destination.location.profileName) else {
            lastActionResult = .failure("Choose a Standard profile before pasting an action.")
            return .invalidDestination
        }
        guard mapping(at: destination.location) == destination.expectedMapping else {
            lastActionResult = .failure("The destination changed, so choose Paste again.")
            return .destinationChanged
        }
        guard clipboard.source != destination.location else {
            lastActionResult = .failure("Choose a different destination before pasting this moved action.")
            return .sameLocation
        }
        guard clipboard.portableMapping != Mapping() else {
            mappingClipboard = nil
            lastActionResult = .failure("The copied action is no longer valid.")
            return .invalidSource
        }
        if clipboard.operation == .cut,
           mapping(at: clipboard.source) != clipboard.rawSourceMapping {
            mappingClipboard = nil
            lastActionResult = .failure("The moved action changed, so the pending move was canceled.")
            return .staleSource
        }

        guard replacingExisting || destination.expectedMapping == Mapping() else {
            return .destinationOccupied
        }

        cancelPendingButtonGestures()
        var pasted = clipboard.portableMapping
        if clipboard.operation == .copy, pasted.action.isProcessBackedAutomation {
            pasted.automationEnabled = false
        }

        let previousDestination = destination.expectedMapping
        guard writeMapping(pasted, at: destination.location) else {
            lastActionResult = .failure("The destination is no longer available.")
            return .invalidDestination
        }
        if clipboard.operation == .cut, !clearMapping(at: clipboard.source) {
            restoreMapping(previousDestination, at: destination.location)
            lastActionResult = .failure("The moved action source is no longer available.")
            return .staleSource
        }
        save()
        if clipboard.operation == .cut {
            mappingClipboard = nil
        }
        lastActionResult = .success("Action pasted")
        return .succeeded
    }

    @discardableResult
    func deleteMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        profileName: String? = nil
    ) -> Bool {
        let destination = mappingDestinationSnapshot(
            for: control,
            gesture: gesture,
            modifierControls: modifierControls,
            profileName: profileName
        )
        return deleteMapping(for: destination)
    }

    @discardableResult
    func deleteMapping(for destination: MappingDestinationSnapshot) -> Bool {
        guard isStandardProfile(destination.location.profileName),
              mapping(at: destination.location) == destination.expectedMapping,
              destination.expectedMapping != Mapping() else { return false }
        cancelPendingButtonGestures()
        guard clearMapping(at: destination.location) else { return false }
        if mappingClipboard?.operation == .cut, mappingClipboard?.source == destination.location {
            mappingClipboard = nil
        }
        save()
        lastActionResult = .success("Action deleted")
        return true
    }

    private func makeMappingLocation(
        profileName: String?,
        control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl>
    ) -> MappingClipboardLocation {
        MappingClipboardLocation(
            profileName: profileName ?? self.profileName,
            control: control,
            gesture: gesture,
            modifierControls: modifierControls
        )
    }

    private func isStandardProfile(_ name: String) -> Bool {
        profileStates[name]?.realm == .standard
    }

    private func mapping(at location: MappingClipboardLocation) -> Mapping {
        if location.profileName == profileName {
            return mappings[location.key] ?? Mapping()
        }
        return profileStates[location.profileName]?.mappings[location.key] ?? Mapping()
    }

    private func portableMapping(at location: MappingClipboardLocation) -> Mapping? {
        guard isStandardProfile(location.profileName) else { return nil }
        let raw = mapping(at: location)
        guard raw != Mapping() else { return nil }

        // An application action without a concrete target cannot be moved
        // safely. Inherited targets are validated below against the source
        // Tap mapping before they become portable.
        if raw.action.isApplicationAction,
           !raw.usesTapApplication,
           raw.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        if raw.usesTapApplication {
            guard (location.gesture == .hold || location.gesture == .doubleTap),
                  raw.action.isApplicationAction else {
                return nil
            }
            let tapLocation = MappingClipboardLocation(
                profileName: location.profileName,
                control: location.control,
                gesture: .tap,
                modifierControls: location.modifierControls
            )
            let tap = mapping(at: tapLocation)
            let command = tap.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tap.action.isApplicationAction, !command.isEmpty else { return nil }
            var resolved = raw
            resolved.command = command
            resolved.usesTapApplication = false
            return resolved
        }
        return raw
    }

    @discardableResult
    private func clearMapping(at location: MappingClipboardLocation) -> Bool {
        if location.profileName == profileName {
            mappings.removeValue(forKey: location.key)
            return true
        }
        guard var state = profileStates[location.profileName] else { return false }
        state.mappings.removeValue(forKey: location.key)
        profileStates[location.profileName] = state
        return true
    }

    @discardableResult
    private func writeMapping(_ mapping: Mapping, at location: MappingClipboardLocation) -> Bool {
        guard isStandardProfile(location.profileName) else { return false }
        if location.profileName == profileName {
            mappings[location.key] = mapping
            return true
        }
        if var state = profileStates[location.profileName] {
            state.mappings[location.key] = mapping
            profileStates[location.profileName] = state
            return true
        }
        return false
    }

    @discardableResult
    private func restoreMapping(_ mapping: Mapping, at location: MappingClipboardLocation) -> Bool {
        if mapping == Mapping() {
            guard isStandardProfile(location.profileName) else { return false }
            if location.profileName == profileName {
                mappings.removeValue(forKey: location.key)
                return true
            }
            guard var state = profileStates[location.profileName] else { return false }
            state.mappings.removeValue(forKey: location.key)
            profileStates[location.profileName] = state
            return true
        }
        return writeMapping(mapping, at: location)
    }

    func update(
        _ mapping: Mapping,
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) {
        let sanitizedModifiers = sanitizedMappingModifiers(modifierControls, for: control)
        mappings[MappingKey(control: control, gesture: gesture, modifierControls: sanitizedModifiers)] = mapping
        save()
    }

    /// Executes a mapping after resolving any same-control Tap inheritance.
    /// Hold/Double gesture recognition remains intentionally outside this
    /// method; current HID input calls it for Tap only.
    func executeMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = [],
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        switch resolvedMapping(for: control, gesture: gesture, modifierControls: modifierControls) {
        case let .success(mapping):
            if let actionExecutionOverride {
                actionExecutionOverride(mapping, completion)
            } else if mapping.action == .windowDisplay,
                      mapping.command == WindowDisplayAction.toggleXPd.rawValue {
                guard let mainWindowToggle else {
                    completion(.failure("XP[d] window action is unavailable"))
                    return
                }
                completion(mainWindowToggle())
            } else if mapping.action == .switchProfile {
                let target = Self.normalizedProfileTarget(mapping.command)
                guard !target.isEmpty else {
                    completion(.failure("Choose a profile first"))
                    return
                }
                guard selectProfile(target) else {
                    completion(.failure(ProfileError.profileNotFound(target).localizedDescription))
                    return
                }
                completion(.success("Switched to \(target)"))
            } else {
                actionRunner.execute(mapping: mapping, completion: completion)
            }
        case let .failure(error):
            completion(.failure(error.localizedDescription))
        }
    }

    private func sanitizedMappingModifiers(
        _ modifierControls: Set<RemoteControl>,
        for control: RemoteControl
    ) -> Set<RemoteControl> {
        guard activeRealm == .standard, control.isModifierEligible else { return [] }
        return modifierControls
            .intersection(remoteModifierControls.subtracting(unavailableRemoteModifierControls))
            .subtracting([control])
    }

    private func sanitizeSelectedMappingModifier() {
        let sanitized: Set<RemoteControl>
        if activeRealm == .standard, selectedControl.isModifierEligible {
            sanitized = Set(selectedMappingModifiers.filter {
                $0 != selectedControl && $0.isModifierEligible
            })
        } else {
            sanitized = []
        }
        guard sanitized != selectedMappingModifiers else { return }
        selectedMappingModifiers = sanitized
    }

    /// Adds a profile with an independent copy of the mapping state and
    /// activates it so it is immediately ready for editing. HID identity is
    /// deliberately taken from the active hardware layout and is never
    /// seeded from a profile default.
    @discardableResult
    func addProfile(named rawName: String) throws -> String {
        try addProfile(named: rawName, realm: .standard, midiSettings: nil)
    }

    @discardableResult
    func addProfile(
        named rawName: String,
        realm: ProfileRealm,
        midiSettings: MIDIProfileSettings? = nil
    ) throws -> String {
        let name = try validatedNewProfileName(rawName)
        let resolvedMIDISettings: MIDIProfileSettings?
        if realm == .midi {
            let candidate = midiSettings ?? Self.defaultMIDIProfileSettings()
            do { try candidate.validate() } catch {
                throw ProfileError.invalidMIDIProfile(Self.configurationErrorMessage(for: error))
            }
            resolvedMIDISettings = candidate
        } else {
            resolvedMIDISettings = nil
        }
        cancelLearning()
        cancelPendingButtonGestures()
        closeProfileSelector()
        resetMIDIState(force: true)
        saveActiveProfile()
        profileStates[name] = ProfileState(
            mappings: Self.defaultProfileState().mappings,
            hidBindings: [:],
            realm: realm,
            midiSettings: resolvedMIDISettings
        )
        availableProfiles.append(name)
        isReplacingConfiguration = true
        profileName = name
        isReplacingConfiguration = false
        activateProfile(named: name)
        activeRealm = realm
        midiLocked = realm == .midi
        defaults.set(profileName, forKey: profileNameDefaultsKey)
        saveAllProfiles()
        return name
    }

    @discardableResult
    func addMIDIProfile(
        named name: String,
        settings: MIDIProfileSettings? = nil
    ) throws -> String {
        try addProfile(named: name, realm: .midi, midiSettings: settings)
    }

    @discardableResult
    func addMIDIProfile(named name: String, template: MIDIProfileTemplate) throws -> String {
        try addProfile(
            named: name,
            realm: .midi,
            midiSettings: Self.midiProfileSettings(for: template)
        )
    }

    /// Renames a profile in place without changing its order, realm, mappings,
    /// HID bindings, or active MIDI session state. Global remains the stable
    /// migration and fallback identity.
    @discardableResult
    func renameProfile(named existingName: String, to rawName: String) throws -> String {
        guard existingName != "Global" else { throw ProfileError.cannotRenameGlobal }
        guard let profileIndex = availableProfiles.firstIndex(of: existingName),
              profileStates[existingName] != nil else {
            throw ProfileError.profileNotFound(existingName)
        }

        let name = try validatedProfileName(rawName, excluding: existingName)
        guard name != existingName else { return existingName }

        cancelLearning()
        closeProfileSelector()
        saveActiveProfile()
        guard let state = profileStates.removeValue(forKey: existingName) else {
            throw ProfileError.profileNotFound(existingName)
        }

        profileStates[name] = state
        availableProfiles[profileIndex] = name
        retargetSwitchProfileMappings(from: existingName, to: name)
        if lastStandardProfileName == existingName { lastStandardProfileName = name }
        if lastMIDIProfileName == existingName { lastMIDIProfileName = name }

        if profileName == existingName {
            isReplacingConfiguration = true
            profileName = name
            isReplacingConfiguration = false
            defaults.set(name, forKey: profileNameDefaultsKey)
            syncMIDIOverlay()
        }

        if let clipboard = mappingClipboard, clipboard.source.profileName == existingName {
            let source = MappingClipboardLocation(
                profileName: name,
                control: clipboard.source.control,
                gesture: clipboard.source.gesture,
                modifierControls: clipboard.source.modifierControls
            )
            mappingClipboard = MappingClipboardState(
                operation: clipboard.operation,
                source: source,
                rawSourceMapping: clipboard.rawSourceMapping,
                portableMapping: clipboard.portableMapping
            )
        }

        saveAllProfiles()
        return name
    }

    private static func normalizedProfileTarget(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func retargetSwitchProfileMappings(from oldName: String, to newName: String) {
        let normalizedOldName = Self.normalizedProfileTarget(oldName)
        func retargeted(_ source: [MappingKey: Mapping]) -> [MappingKey: Mapping] {
            source.mapValues { mapping in
                guard mapping.action == .switchProfile,
                      Self.normalizedProfileTarget(mapping.command) == normalizedOldName else {
                    return mapping
                }
                var updated = mapping
                updated.command = newName
                return updated
            }
        }

        mappings = retargeted(mappings)
        for profile in Array(profileStates.keys) {
            guard var state = profileStates[profile] else { continue }
            state.mappings = retargeted(state.mappings)
            profileStates[profile] = state
        }
    }

    /// Deletes an inactive or active profile. Global is intentionally
    /// protected because it is the required fallback profile.
    func deleteProfile(named name: String) throws {
        guard name != "Global" else { throw ProfileError.cannotDeleteGlobal }
        guard availableProfiles.contains(name), profileStates[name] != nil else {
            throw ProfileError.profileNotFound(name)
        }

        cancelLearning()
        cancelPendingButtonGestures()
        closeProfileSelector()
        if mappingClipboard?.source.profileName == name {
            mappingClipboard = nil
        }
        if profileName == name {
            resetMIDIState(force: true)
            isReplacingConfiguration = true
            profileName = "Global"
            isReplacingConfiguration = false
            activateProfile(named: "Global")
            defaults.set(profileName, forKey: profileNameDefaultsKey)
        }

        availableProfiles.removeAll { $0 == name }
        profileStates.removeValue(forKey: name)
        saveAllProfiles()
    }

    func learnSelectedControl() {
        guard !isBluetoothDriverModeActive else {
            lastHIDLearningResult = .failure(
                "Controls are recognised automatically in Bluetooth driver mode. Turn driver mode off to relearn them."
            )
            return
        }
        guard !(activeRealm == .standard && usesStandardF13F22Preset) else {
            lastHIDLearningResult = .failure(
                "Disable the F13–F22 preset before manually changing Standard hardware bindings."
            )
            return
        }
        if selectedControl.isMIDIButton {
            invalidateStandardKLayerLiveVerification()
        }
        cancelPendingButtonGestures()
        cancelLearningAllState()
        lastHIDLearningResult = nil
        learningControl = selectedControl
        liveControl = nil
    }

    /// Starts input learning for the selected K button in a MIDI profile.
    /// MIDI mappings remain in the profile's typed settings; this operation
    /// replaces the selected control's identity in the active device layout.
    func learnSelectedMIDIControl() {
        guard activeRealm == .midi, selectedControl.isMIDIButton else {
            lastHIDLearningResult = .failure("Select a MIDI K button before relearning its input.")
            return
        }
        learnSelectedControl()
    }

    func cancelLearning() {
        if isLearningAll {
            invalidateStandardKLayerLiveVerification()
        }
        learningControl = nil
        cancelLearningAllState()
    }

    /// Starts an atomic Standard-only K1…K10 configuration and verification
    /// workflow. The existing layout is copied into a session-only candidate
    /// so wheel/center bindings and all non-K inputs remain untouched until
    /// the complete set validates. MIDI state is deliberately not reset or
    /// changed: this workflow is unavailable in the MIDI workspace.
    func beginLearningAllHIDControls() {
        guard activeRealm == .standard else {
            lastHIDLearningResult = .failure(
                "Configure Standard K layers is available only in the Standard workspace. MIDI input, mappings, and settings were not changed."
            )
            return
        }
        guard !usesStandardF13F22Preset else {
            lastHIDLearningResult = .failure(
                "Disable the F13–F22 preset before manually configuring Standard K layers."
            )
            return
        }
        guard !isBluetoothDriverModeActive else {
            lastHIDLearningResult = .failure(
                "K buttons are recognised automatically in Bluetooth driver mode. Turn driver mode off to configure Standard K layers."
            )
            return
        }
        invalidateStandardKLayerLiveVerification()
        cancelPendingButtonGestures()
        learningControl = nil
        lastHIDLearningResult = nil
        learningAllCandidate = hidBindings
        learningAllCaptured = [:]
        learningAllEncoding = nil
        learningAllLayoutID = activeHardwareLayoutID
        learningAllProgress = 0
        learningAllControl = Self.hardwareLearningControls.first
        isLearningAll = learningAllControl != nil
        learningAllCapturedSignature = nil
        liveControl = nil
    }

    /// Selects an explicitly named physical layout. Runtime gesture, MIDI,
    /// and in-flight learning state is cleared before the new binding set is
    /// exposed, so no old control can leak into the new layout.
    @discardableResult
    func selectHardwareLayout(id: String) -> Bool {
        guard hardwareLayouts.contains(where: { $0.id == id }) else {
            lastActionResult = .failure("Hardware layout not found: \(id).")
            return false
        }
        if isLearningAll {
            failLearningAll(
                standardKLayerLearningCancellationMessage("the hardware layout was selected")
            )
        } else {
            invalidateStandardKLayerLiveVerification()
        }
        guard activeHardwareLayoutID != id else { return true }
        cancelPendingButtonGestures()
        cancelLearning()
        resetMIDIState(force: true)
        closeProfileSelector()
        activeHardwareLayoutID = id
        refreshActiveHardwareLayoutBindings()
        saveAllProfiles()
        return true
    }

    func clearHIDBinding(for control: RemoteControl) {
        guard !isBluetoothDriverModeActive else {
            lastHIDLearningResult = .failure(
                "Controls are recognised automatically in Bluetooth driver mode. Turn driver mode off to change their bindings."
            )
            return
        }
        guard !(activeRealm == .standard && usesStandardF13F22Preset) else {
            lastHIDLearningResult = .failure(
                "Disable the F13–F22 preset before manually changing Standard hardware bindings."
            )
            return
        }
        if remoteModifierControls.contains(control) {
            cancelPendingButtonGestures()
        }
        var updated = hidBindings
        updated.removeValue(forKey: control)
        updateActiveHardwareLayoutBindings(updated)
        if remoteModifierControls.remove(control) != nil {
            unavailableRemoteModifierControls.remove(control)
            sanitizeSelectedMappingModifier()
            save()
        } else {
            saveHIDBindings()
        }
    }

    func hidBinding(for control: RemoteControl) -> String? {
        effectiveStandardHIDBindings[control]
    }

    /// The bindings Standard currently uses for K-input resolution. The
    /// optional F13–F22 preset overlays only K1–K10; wheel rotation, wheel
    /// center, and every other physical binding continue to come from the
    /// active device-level layout.
    var effectiveStandardHIDBindings: [RemoteControl: String] {
        guard activeRealm == .standard else { return hidBindings }
        if isBluetoothDriverModeActive {
            return effectiveMIDIHIDBindings
        }
        guard usesStandardF13F22Preset else { return hidBindings }
        var effective = hidBindings
        effective.merge(Self.standardF13F22HIDBindings) { _, preset in preset }
        return effective
    }

    /// MIDI's K resolution: the learned layout, with K1–K10, the wheel, and
    /// the center replaced by the identities `HIDService` emits for them while
    /// Bluetooth driver mode is active.
    var effectiveMIDIHIDBindings: [RemoteControl: String] {
        guard isBluetoothDriverModeActive else { return hidBindings }
        var effective = hidBindings
        effective.merge(Self.bluetoothDriverModeHIDBindings) { _, driverMode in driverMode }
        return effective
    }

    /// K1…K10 as report-2 one-hot identities in the order verified live on
    /// 2026-10-21 (K1 = bit 0 … K10 = bit 9), plus the wheel and center
    /// signatures emitted for driver-mode packets.
    static let bluetoothDriverModeHIDBindings: [RemoteControl: String] =
        Dictionary(uniqueKeysWithValues: hardwareLearningControls.enumerated().map { index, control in
            (control, ShortcutRemoteDriverModeDecoder.keySignature(mask: UInt16(1) << index))
        }).merging([
            .wheelCW: "wheel:+",
            .wheelCCW: "wheel:-",
            .wheelCenter: "wheel:center"
        ]) { key, _ in key }

    private func bluetoothDriverModeChanged(_ isActive: Bool) {
        guard isBluetoothDriverModeActive != isActive else { return }
        // The physical identity of every K changes with the mode, so no
        // in-flight gesture, learning, or MIDI hold may cross the switch.
        cancelPendingButtonGestures()
        if isLearningAll {
            failLearningAll(
                standardKLayerLearningCancellationMessage("Bluetooth driver mode changed")
            )
        } else if learningControl != nil {
            lastHIDLearningResult = .failure("Learning canceled because Bluetooth driver mode changed.")
        }
        cancelLearning()
        resetMIDIState(force: true)
        isBluetoothDriverModeActive = isActive
        invalidateStandardKLayerLiveVerification()
        refreshModifierAvailability()
    }

    /// Selects the deterministic Standard F13–F22 resolver. The selection is
    /// stored in its own UserDefaults key, not in the shared hardware layout
    /// or any profile payload. Calling this from MIDI is rejected before any
    /// state, output, or persistence operation can occur.
    @discardableResult
    func setStandardF13F22PresetEnabled(_ enabled: Bool) -> Bool {
        guard activeRealm == .standard else {
            lastActionResult = .failure(
                "The F13–F22 preset is available only in the Standard workspace. MIDI input, mappings, settings, and held state were not changed."
            )
            return false
        }
        guard !isLearningAll else {
            lastActionResult = .failure(
                "Finish or cancel Standard K-layer configuration before changing the F13–F22 preset."
            )
            return false
        }
        guard usesStandardF13F22Preset != enabled else { return true }

        // Switching the resolver while a Standard cycle is active would leave
        // the old physical identity in flight. Cancel only Standard gesture
        // state; MIDI state is not touched by this Standard-only setting.
        cancelPendingButtonGestures()
        cancelLearning()
        usesStandardF13F22Preset = enabled
        defaults.set(enabled, forKey: standardF13F22PresetDefaultsKey)
        invalidateStandardF13F22PresetLiveVerification()
        invalidateStandardKLayerLiveVerification()
        refreshModifierAvailability()
        lastPersistenceResult = .saved
        return true
    }

    private static let hardwareLearningControls: [RemoteControl] =
        RemoteControl.allCases.filter(\.isMIDIButton)

    /// Canonical report-6 keyboard usages for the owner's Standard preset:
    /// K1→F13 through K10→F22. The report-6 prefix is shared by all keys;
    /// the usage byte is the physical identity.
    static let standardF13F22HIDBindings: [RemoteControl: String] =
        Dictionary(uniqueKeysWithValues: hardwareLearningControls.enumerated().map { index, control in
            (control, String(format: "r6:00 %02X 00 00 00 00 00", 0x68 + index))
        })

    private func cancelLearningAllState() {
        learningAllCandidate = [:]
        learningAllCaptured = [:]
        learningAllEncoding = nil
        learningAllLayoutID = nil
        learningAllVerificationStage = .none
        learningAllVerificationOrderIndex = 0
        learningAllVerificationFirstSignature = nil
        learningAllVerificationFirstReport = nil
        learningAllVerificationSecondReport = nil
        learningAllVerificationCompositeReport = nil
        learningAllCapturedSignature = nil
        standardKLayerVerificationPrompt = nil
        isLearningAllAwaitingRelease = false
        learningAllControl = nil
        learningAllProgress = 0
        isLearningAll = false
    }

    private func updateActiveHardwareLayoutBindings(_ bindings: [RemoteControl: String]) {
        invalidateStandardKLayerLiveVerification()
        guard let index = hardwareLayouts.firstIndex(where: { $0.id == activeHardwareLayoutID }) else {
            hidBindings = bindings
            refreshModifierAvailability()
            return
        }
        let normalized = Self.normalizedHIDBindings(bindings)
        hardwareLayouts[index] = Self.makeHardwareLayout(
            id: hardwareLayouts[index].id,
            name: hardwareLayouts[index].name,
            bindings: normalized
        )
        hidBindings = normalized
        refreshModifierAvailability()
    }

    private func refreshActiveHardwareLayoutBindings() {
        guard let layout = hardwareLayouts.first(where: { $0.id == activeHardwareLayoutID }) else {
            hidBindings = [:]
            refreshModifierAvailability()
            return
        }
        hidBindings = Self.bindingDictionary(from: layout.bindings)
        refreshModifierAvailability()
    }

    private func refreshModifierAvailability() {
        let bindings = effectiveStandardHIDBindings
        unavailableRemoteModifierControls = remoteModifierControls.filter { control in
            guard let binding = bindings[control] else { return true }
            return binding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func failLearningAll(_ message: String) {
        invalidateStandardKLayerLiveVerification()
        cancelLearningAllState()
        lastHIDLearningResult = .failure(message)
    }

    private func captureLearningAllInput(_ signature: String) {
        guard isLearningAll else { return }
        guard let report = HIDKeyboardReport(signature: signature) else {
            if learningAllVerificationStage == .none {
                failLearningAll("Configure Standard K layers rejected a malformed HID report. Press one K button.")
            } else {
                failStandardKLayerVerification("received a malformed HID report")
            }
            return
        }

        let normalizedSignature = Self.normalizedHIDSignature(signature)
        if report.encoding == .report2OneHot, report.oneHotMask == 0 {
            completeLearningAllRelease()
            return
        }
        if learningAllVerificationStage != .none {
            captureStandardKLayerVerificationInput(
                report,
                normalizedSignature: normalizedSignature
            )
            return
        }

        guard let control = learningAllControl else { return }
        if isLearningAllAwaitingRelease {
            if learningAllCaptured[control] == normalizedSignature {
                return
            }
            failLearningAll("Release the current K button before pressing the next one.")
            return
        }
        switch report.encoding {
        case .report2OneHot:
            guard report.isCompatibleIndividualBinding else {
                failLearningAll("Configure Standard K layers rejected a report-2 release or composite. Press one K button.")
                return
            }
        case .report6BootKeyboard:
            guard report.modifierByte != 0 || !report.keyUsages.isEmpty else {
                failLearningAll("Configure Standard K layers rejected an empty report-6 input. Press one K button.")
                return
            }
        }

        if let learningAllEncoding, learningAllEncoding != report.encoding {
            failLearningAll("Configure Standard K layers rejected mixed report encodings. Capture all K buttons from one HID collection.")
            return
        }
        if learningAllCaptured.values.contains(normalizedSignature) {
            failLearningAll("Configure Standard K layers rejected a duplicate HID input. Each K button must have a distinct report.")
            return
        }

        learningAllEncoding = report.encoding
        learningAllCaptured[control] = normalizedSignature
        learningAllCandidate[control] = normalizedSignature
        learningAllCapturedSignature = normalizedSignature
        learningAllProgress += 1
        isLearningAllAwaitingRelease = true
    }

    private func completeLearningAllRelease() {
        if learningAllVerificationStage != .none {
            completeStandardKLayerVerificationRelease()
            return
        }
        guard isLearningAll, isLearningAllAwaitingRelease else { return }
        isLearningAllAwaitingRelease = false
        learningAllCapturedSignature = nil

        guard learningAllProgress < Self.hardwareLearningControls.count else {
            let KControls = Set(Self.hardwareLearningControls)
            let captured = learningAllCandidate.filter { KControls.contains($0.key) }
            guard captured.count == KControls.count,
                  captured.values.count == Set(captured.values).count else {
                failLearningAll("Configure Standard K layers could not produce ten distinct K bindings. The prior hardware layout was preserved.")
                return
            }
            let maskingCollisions = HIDKeyboardReportCollisionAnalyzer.collisions(among: captured)
            guard maskingCollisions.isEmpty else {
                failLearningAll(standardKLayerMaskingFailureMessage(maskingCollisions))
                return
            }
            guard HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(among: captured).isEmpty else {
                failLearningAll("Configure Standard K layers rejected a keyboard rollover collision. The prior hardware layout was preserved.")
                return
            }
            beginStandardKLayerLiveVerification()
            return
        }

        learningAllControl = Self.hardwareLearningControls[learningAllProgress]
    }

    private static let standardKLayerVerificationOrders: [[RemoteControl]] = [
        [.k10, .k5],
        [.k5, .k10]
    ]

    private var standardKLayerVerificationOrder: [RemoteControl]? {
        Self.standardKLayerVerificationOrders.indices.contains(learningAllVerificationOrderIndex)
            ? Self.standardKLayerVerificationOrders[learningAllVerificationOrderIndex]
            : nil
    }

    private var standardKLayerVerificationOrderDescription: String {
        guard let order = standardKLayerVerificationOrder else { return "K10 then K5" }
        return "\(order[0].rawValue) held, then \(order[1].rawValue)"
    }

    private func beginStandardKLayerLiveVerification() {
        guard learningAllLayoutID == activeHardwareLayoutID else {
            failLearningAll("Configure Standard K layers was canceled because the hardware layout changed. The prior hardware layout was preserved.")
            return
        }
        learningAllVerificationOrderIndex = 0
        prepareStandardKLayerVerificationOrder()
    }

    private func prepareStandardKLayerVerificationOrder() {
        guard let order = standardKLayerVerificationOrder,
              let firstSignature = learningAllCandidate[order[0]],
              let firstReport = HIDKeyboardReport(signature: firstSignature),
              let secondSignature = learningAllCandidate[order[1]],
              let secondReport = HIDKeyboardReport(signature: secondSignature),
              let compositeReport = firstReport.merged(with: secondReport),
              compositeReport != firstReport else {
            failLearningAll("Configure Standard K layers could not prepare live verification for \(standardKLayerVerificationOrderDescription). The prior hardware layout was preserved.")
            return
        }

        learningAllControl = nil
        learningAllCapturedSignature = nil
        isLearningAllAwaitingRelease = false
        learningAllVerificationFirstSignature = Self.normalizedHIDSignature(firstSignature)
        learningAllVerificationFirstReport = firstReport
        learningAllVerificationSecondReport = secondReport
        learningAllVerificationCompositeReport = compositeReport
        learningAllVerificationStage = .awaitingFirst
        standardKLayerVerificationPrompt = "Live verification \(learningAllVerificationOrderIndex + 1) of \(Self.standardKLayerVerificationOrders.count) · Hold \(order[0].rawValue), then press \(order[1].rawValue)."
    }

    private func captureStandardKLayerVerificationInput(
        _ report: HIDKeyboardReport,
        normalizedSignature: String
    ) {
        guard learningAllLayoutID == activeHardwareLayoutID else {
            failStandardKLayerVerification("the hardware layout changed")
            return
        }
        guard let expectedFirstSignature = learningAllVerificationFirstSignature,
              let expectedFirstReport = learningAllVerificationFirstReport,
              let expectedSecondReport = learningAllVerificationSecondReport,
              let expectedCompositeReport = learningAllVerificationCompositeReport else {
            failStandardKLayerVerification("the verification state was incomplete")
            return
        }
        guard report.encoding == expectedFirstReport.encoding else {
            failStandardKLayerVerification("received a mixed HID encoding")
            return
        }

        switch learningAllVerificationStage {
        case .awaitingFirst:
            guard normalizedSignature == expectedFirstSignature else {
                failStandardKLayerVerification("expected \(standardKLayerVerificationOrderDescription) to begin with the saved \(standardKLayerVerificationOrder?.first?.rawValue ?? "K button") input")
                return
            }
            learningAllVerificationStage = .awaitingComposite
            standardKLayerVerificationPrompt = "Live verification \(learningAllVerificationOrderIndex + 1) of \(Self.standardKLayerVerificationOrders.count) · Keep \(standardKLayerVerificationOrder?[0].rawValue ?? "K10") held and press \(standardKLayerVerificationOrder?[1].rawValue ?? "K5")."

        case .awaitingComposite:
            if normalizedSignature == expectedFirstSignature {
                return
            }
            guard report == expectedCompositeReport, report != expectedFirstReport else {
                failStandardKLayerVerification("did not receive the expected distinct combined state for \(standardKLayerVerificationOrderDescription)")
                return
            }
            learningAllVerificationStage = .awaitingFinalRelease
            standardKLayerVerificationPrompt = "Live verification \(learningAllVerificationOrderIndex + 1) of \(Self.standardKLayerVerificationOrders.count) · Release both \(standardKLayerVerificationOrder?[0].rawValue ?? "K10") and \(standardKLayerVerificationOrder?[1].rawValue ?? "K5")."

        case .awaitingFinalRelease:
            if normalizedSignature == expectedFirstSignature
                || report == expectedSecondReport
                || report == expectedCompositeReport {
                return
            }
            failStandardKLayerVerification("received an unexpected partial state before both controls were released")

        case .none:
            return
        }
    }

    private func completeStandardKLayerVerificationRelease() {
        guard learningAllLayoutID == activeHardwareLayoutID else {
            failStandardKLayerVerification("the hardware layout changed")
            return
        }
        guard learningAllVerificationStage == .awaitingFinalRelease else {
            failStandardKLayerVerification("was released before the expected combined state was observed")
            return
        }

        learningAllVerificationOrderIndex += 1
        guard learningAllVerificationOrderIndex < Self.standardKLayerVerificationOrders.count else {
            guard learningAllLayoutID == activeHardwareLayoutID else {
                failStandardKLayerVerification("the hardware layout changed")
                return
            }
            updateActiveHardwareLayoutBindings(learningAllCandidate)
            saveHIDBindings()
            cancelLearningAllState()
            isStandardKLayerLiveVerified = true
            lastHIDLearningResult = .success("Configured and live-verified Standard K1–K10 layers in the active hardware layout.")
            return
        }

        prepareStandardKLayerVerificationOrder()
    }

    private func failStandardKLayerVerification(_ reason: String) {
        failLearningAll(
            "Configure Standard K layers live verification failed for \(standardKLayerVerificationOrderDescription): \(reason). The prior hardware layout was preserved."
        )
    }

    private func standardKLayerLearningCancellationMessage(_ reason: String) -> String {
        if learningAllVerificationStage != .none {
            return "Configure Standard K layers live verification failed for \(standardKLayerVerificationOrderDescription): \(reason). The prior hardware layout was preserved."
        }
        return "Configure Standard K layers was canceled because \(reason). The prior hardware layout was preserved."
    }

    private func invalidateStandardKLayerLiveVerification() {
        isStandardKLayerLiveVerified = false
    }

    private func invalidateStandardF13F22PresetLiveVerification() {
        isStandardF13F22PresetLiveVerified = false
    }

    private func observeStandardF13F22PresetInput(_ signature: String?) {
        guard activeRealm == .standard,
              usesStandardF13F22Preset,
              let signature,
              let report = HIDKeyboardReport(signature: signature),
              report.encoding == .report6BootKeyboard,
              report.isCompatibleIndividualBinding else {
            return
        }

        let normalizedSignature = Self.normalizedHIDSignature(signature)
        guard Self.standardF13F22HIDBindings.values.contains(normalizedSignature) else {
            return
        }

        // HIDService delivers this callback only after a live device report.
        // One exact preset identity proves the current connection emits the
        // selected report-6 contract; it does not claim that every key ran.
        isStandardF13F22PresetLiveVerified = true
    }

    private func standardKLayerMaskingFailureMessage(
        _ collisions: [HIDKeyboardReportCollision]
    ) -> String {
        let details = collisions.map {
            "\($0.firstControl.rawValue) held hides \($0.hiddenControl.rawValue)"
        }.joined(separator: "; ")
        return "Configure Standard K layers rejected masking collisions: \(details). The prior hardware layout was preserved. Configure unique inputs on the remote, then try again."
    }

    /// Reports order-specific Standard layer collisions for the selected
    /// destination. The analyzer only considers exact report-6 keyboard-state
    /// masking; it does not alter learned bindings or input routing.
    func standardModifierHIDCollisions(
        for destination: RemoteControl,
        modifierControls: Set<RemoteControl>
    ) -> [HIDKeyboardReportCollision] {
        guard activeRealm == .standard, destination.isMIDIButton else { return [] }
        return HIDKeyboardReportCollisionAnalyzer.collisions(
            for: destination,
            modifierControls: modifierControls,
            bindings: effectiveStandardHIDBindings
        )
    }

    /// Reports every order-specific masking collision among the learned
    /// report-6 keyboard states for K1–K10. This is inferred from persisted
    /// bindings and intentionally does not claim a live hardware observation.
    func standardHIDCollisions() -> [HIDKeyboardReportCollision] {
        guard activeRealm == .standard else { return [] }
        return HIDKeyboardReportCollisionAnalyzer.collisions(among: effectiveStandardHIDBindings)
    }

    /// Reports learned K pairs that exceed the six ordinary-key slots of the
    /// report-6 boot-keyboard collection. This is inferred from saved
    /// bindings and does not claim a live hardware observation.
    func standardHIDRolloverCollisions() -> [HIDKeyboardReportRolloverCollision] {
        guard activeRealm == .standard else { return [] }
        return HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(among: effectiveStandardHIDBindings)
    }

    /// Internal test seam for exercising HID-driven state transitions without
    /// hardware or permission prompts.
    func simulateHIDInputForTesting(_ signature: String?) {
        handleHIDInput(signature)
    }

    var isProfileSelectorVisibleForTesting: Bool {
        isProfileSelectorVisible
    }

    var pendingProfileNameForTesting: String? {
        pendingProfileName
    }

    var profileSelectorTimeoutGenerationForTesting: Int {
        profileSelectorTimeoutGeneration
    }

    var midiOverlayPresentationForTesting: MIDIOverlayPresentation? {
        inputOverlay.midiPresentationForTesting
    }

    func clearMIDIOverlayForTesting() {
        inputOverlay.clearMIDI()
    }

    func simulateProfileSelectorTimeoutForTesting() {
        guard isProfileSelectorVisible else { return }
        closeProfileSelector()
    }

    func waitForMIDICommandsForTesting() async {
        await midiCommandTail.task?.value
    }

    /// Returns the current configuration as deterministic, pretty-printed
    /// JSON data. File panels and filesystem access belong to the UI layer.
    func exportConfiguration() -> Data? {
        let profiles = availableProfiles.compactMap { name -> XPdConfiguration.Profile? in
            guard let state = profileStates[name] else { return nil }
            return XPdConfiguration.Profile(
                name: name,
                mappings: Self.mappingEntries(from: state.mappings),
                hidBindings: [],
                realm: state.realm,
                midiSettings: state.midiSettings,
                standardButtonTitles: Self.standardButtonTitleEntries(from: state.standardButtonTitles),
                remoteModifierControls: state.remoteModifierControls,
                modifierColors: Self.modifierColorEntries(from: state.modifierColors)
            )
        }
        let configuration = XPdConfiguration(
            profiles: profiles,
            profileName: profileName,
            showsInputOverlay: showsInputOverlay,
            activeRealm: activeRealm,
            lastStandardProfileName: lastStandardProfileName,
            lastMIDIProfileName: lastMIDIProfileName,
            midiLocked: midiLocked,
            workspaceLockControl: workspaceLockControl,
            hardwareLayouts: hardwareLayouts,
            activeHardwareLayoutID: activeHardwareLayoutID,
            standardF13F22PresetEnabled: usesStandardF13F22Preset ? true : nil
        )

        do {
            let data = try configuration.encodedData()
            lastConfigurationResult = .idle
            return data
        } catch {
            lastConfigurationResult = .failed(
                operation: .export,
                message: Self.configurationErrorMessage(for: error)
            )
            return nil
        }
    }

    /// Validates a complete document before changing any live or persisted
    /// state. Replacement is synchronous on the main actor, so observers
    /// cannot observe a partially imported configuration.
    @discardableResult
    func importConfiguration(_ data: Data) -> Bool {
        let configuration: XPdConfiguration
        do {
            configuration = try XPdConfiguration.decode(data)
        } catch {
            lastConfigurationResult = .failed(
                operation: .import,
                message: Self.configurationErrorMessage(for: error)
            )
            return false
        }

        var importedStates: [String: ProfileState] = [:]
        for profile in configuration.profiles {
            var importedMappings: [MappingKey: Mapping] = [:]
            for entry in profile.mappings {
                var mapping = entry.mapping
                // Portable configuration may contain executable action data,
                // but importing it must never arm that data automatically.
                // Preserve the action and command so the user can review and
                // explicitly enable it in the inspector.
                if mapping.action.isProcessBackedAutomation {
                    mapping.automationEnabled = false
                }
                importedMappings[MappingKey(
                    control: entry.control,
                    gesture: entry.gesture,
                    modifierControls: entry.modifierControls
                )] = mapping
            }

            var importedStandardButtonTitles: [RemoteControl: String] = [:]
            for entry in profile.standardButtonTitles {
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    importedStandardButtonTitles[entry.control] = title
                }
            }
            let importedModifierColors = Dictionary(uniqueKeysWithValues: profile.modifierColors.map {
                ($0.control, $0.color)
            })
            importedStates[profile.name] = ProfileState(
                mappings: importedMappings,
                hidBindings: [:],
                standardButtonTitles: importedStandardButtonTitles,
                remoteModifierControls: profile.remoteModifierControls,
                modifierColors: importedModifierColors,
                realm: profile.realm,
                midiSettings: profile.midiSettings
            )
        }

        // Keep this guard adjacent to replacement as a second atomicity
        // barrier. The model already validated Global, names, and active
        // profile, but this ensures no state is lost while converting.
        guard importedStates.count == configuration.profiles.count,
              importedStates["Global"] != nil,
              Set(importedStates.keys) == Set(configuration.profiles.map(\.name)) else {
            lastConfigurationResult = .failed(
                operation: .import,
                message: "Configuration contains invalid profile state."
            )
            return false
        }

        // A portable document can carry the Standard resolver selection, but
        // it cannot carry connection-scoped proof that this remote emitted
        // the expected report-6 inputs. Missing (legacy) values are safely
        // disabled and every import starts the new connection proof over.
        let importedStandardF13F22Preset = configuration.standardF13F22PresetEnabled ?? false

        if isLearningAll {
            failLearningAll(
                standardKLayerLearningCancellationMessage("the configuration was replaced")
            )
        } else {
            cancelLearning()
        }
        cancelPendingButtonGestures()
        resetMIDIState(force: true)
        isReplacingConfiguration = true
        mappingClipboard = nil
        profileStates = importedStates
        availableProfiles = configuration.profiles.map(\.name)
        installHardwareLayouts(
            configuration.hardwareLayouts,
            activeID: configuration.activeHardwareLayoutID
        )
        usesStandardF13F22Preset = importedStandardF13F22Preset
        defaults.set(importedStandardF13F22Preset, forKey: standardF13F22PresetDefaultsKey)
        invalidateStandardF13F22PresetLiveVerification()
        profileName = configuration.profileName
        activeRealm = configuration.activeRealm
        lastStandardProfileName = configuration.lastStandardProfileName
        lastMIDIProfileName = configuration.lastMIDIProfileName
        midiLocked = configuration.midiLocked
        workspaceLockControl = configuration.workspaceLockControl
        activateProfile(named: configuration.profileName)
        isReplacingConfiguration = false

        learningControl = nil
        liveControl = nil
        closeProfileSelector()
        showsInputOverlay = configuration.showsInputOverlay
        defaults.set(profileName, forKey: profileNameDefaultsKey)
        saveAllProfiles()

        lastConfigurationResult = .succeeded(
            operation: .import,
            detail: "Imported \(configuration.profiles.count) profiles."
        )
        return true
    }

    func configurationExportCompleted() {
        lastConfigurationResult = .succeeded(
            operation: .export,
            detail: "Configuration exported."
        )
    }

    func configurationFileOperationFailed(
        _ operation: ConfigurationOperation,
        error: Error
    ) {
        lastConfigurationResult = .failed(
            operation: operation,
            message: error.localizedDescription
        )
    }

    func previewInputOverlay() {
        guard showsInputOverlay else { return }
        inputOverlay.pulse(
            control: selectedControl,
            tap: overlayMapping(for: selectedControl, gesture: .tap, modifierControls: selectedMappingModifiers),
            hold: overlayMapping(for: selectedControl, gesture: .hold, modifierControls: selectedMappingModifiers),
            doubleTap: overlayMapping(for: selectedControl, gesture: .doubleTap, modifierControls: selectedMappingModifiers)
        )
    }

    func overlayMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) -> Mapping {
        switch resolvedMapping(for: control, gesture: gesture, modifierControls: modifierControls) {
        case .success(let resolved):
            return resolved
        case .failure:
            let unresolved = mapping(for: control, gesture: gesture, modifierControls: modifierControls)
            return Mapping(action: unresolved.action)
        }
    }

    /// Uses the same readiness definition as the input HUD so editor status
    /// indicators cannot disagree with the action presentation at runtime.
    func isMappingConfigured(
        for control: RemoteControl,
        gesture: GestureKind,
        modifierControls: Set<RemoteControl> = []
    ) -> Bool {
        InputOverlayPresentation(
            mapping: overlayMapping(
                for: control,
                gesture: gesture,
                modifierControls: modifierControls
            )
        ).isConfigured
    }

    func requestScrollingAccess() {
        if actionRunner.requestScrollingAccess() {
            lastActionResult = .success("Scrolling access is enabled")
        } else {
            lastActionResult = .failure("Enable XP[d] in Accessibility, then relaunch")
        }
    }

    func openAccessibilitySettings() {
        actionRunner.openAccessibilitySettings()
    }

    var canPostScrollEvents: Bool {
        actionRunner.canPostScrollEvents
    }

    var canControlApplicationWindows: Bool {
        actionRunner.canControlApplicationWindows
    }

    private func selectControlFromMappedInput(_ control: RemoteControl) {
        guard !isRunMode else { return }
        selectedControl = control
    }

    /// K-button learning must capture one physical control, not a
    /// report-2 snapshot containing several held controls or a release state.
    /// Legacy report-6 remains supported when it contains an actual keyboard
    /// state; its several key slots may represent one configured shortcut.
    private func individualKLearningValidationError(
        for signature: String,
        requiresParseableReport: Bool
    ) -> String? {
        guard let report = HIDKeyboardReport(signature: signature) else {
            // Existing Standard fixtures and imported legacy layouts may use
            // opaque test/compatibility signatures. Live report-2 and
            // report-6 input is always parseable and receives the strict
            // individual-boundary checks below; MIDI has always required a
            // parseable physical report.
            return requiresParseableReport
                ? "K learning requires a valid individual HID report. Press one K button on the remote."
                : nil
        }

        switch report.encoding {
        case .report2OneHot:
            guard let mask = report.oneHotMask, mask != 0 else {
                return "K learning requires one K button, not a report-2 release state."
            }
            guard report.isCompatibleIndividualBinding else {
                return "K learning rejected a multi-control report. Press only one K button at a time."
            }
        case .report6BootKeyboard:
            guard report.modifierByte != 0 || !report.keyUsages.isEmpty else {
                return "K learning requires a non-empty individual report-6 input. Press one K button."
            }
        }

        return nil
    }

    private func handleHIDInput(_ signature: String?) {
        liveInputGeneration += 1
        let generation = liveInputGeneration
        observeStandardF13F22PresetInput(signature)

        if isRemoteTriggerCaptureActive {
            // The unified Standard chord editor records optional K-button
            // modifiers without ever changing the fixed destination selected
            // in the inspector. All other HID input remains consumed while
            // the keyboard condition is being recorded.
            if let signature,
               let matched = effectiveStandardHIDBindings.first(where: { $0.value == signature })?.key,
               activeRealm == .standard,
               matched.isMIDIButton {
                remoteTriggerModifierCaptureHandler?(matched)
            }
            return
        }

        if isLearningAll {
            if let signature {
                captureLearningAllInput(signature)
            } else {
                completeLearningAllRelease()
            }
            return
        }

        guard let signature else {
            if activeRealm == .midi {
                if !activeMIDIReport6Controls.isEmpty {
                    let report6Controls = activeMIDIReport6Controls
                    releaseMIDIReport6Controls()
                    if let liveControl, report6Controls.contains(liveControl) {
                        self.liveControl = orderedMIDIControls(
                            activeMIDIReport2Controls,
                            fnFirst: false
                        ).last
                    }
                    return
                }
                let report2Controls = activeMIDIReport2Controls
                if !report2Controls.isEmpty {
                    // A nil callback is the report-6 collection's generic
                    // release boundary. It must not release a separate
                    // report-2 snapshot; release only a report-6 control
                    // currently represented by liveControl, if any.
                    if let liveControl, !report2Controls.contains(liveControl) {
                        handleMIDIControlRelease(liveControl)
                        self.liveControl = nil
                    }
                    return
                }

                if let liveControl {
                    if liveControl == .wheelCenter, fnControl == .wheelCenter {
                        finishCenterMIDIInteraction()
                    } else {
                        handleMIDIControlRelease(liveControl)
                    }
                    self.liveControl = nil
                    return
                }
            }
            if activeRealm == .standard {
                // Report 6 is now reconciled as a complete keyboard
                // snapshot. Its empty callback releases only the report-6
                // source; a report-2 snapshot may still be active and has
                // its own explicit F0/all-zero boundary.
                if !activeStandardReport6Controls.isEmpty {
                    releaseStandardReport6Controls()
                }
                if !activeStandardReport2Controls.isEmpty {
                    return
                }
                if !activeStandardControls.isEmpty {
                    releaseStandardCycle()
                    liveControl = nil
                    return
                }
            }
            if isWheelCenterHeld {
                isWheelCenterHeld = false
                confirmProfileSelection()
                return
            }
            if let liveControl {
                buttonGestureRecognizer.release(liveControl)
                if showsInputOverlay {
                    inputOverlay.release(control: liveControl)
                }
            }
            liveControl = nil
            return
        }

        if let learningControl {
            if learningControl.isMIDIButton,
               let error = individualKLearningValidationError(
                   for: signature,
                   requiresParseableReport: activeRealm == .midi
               ) {
                self.learningControl = nil
                lastHIDLearningResult = .failure(error)
                return
            }

            if let conflictingControl = hidBindings.first(where: { control, binding in
                control != learningControl && binding == signature
            })?.key {
                self.learningControl = nil
                lastHIDLearningResult = .failure(
                    "That input is already assigned to \(conflictingControl.rawValue). Clear it there before learning it for \(learningControl.rawValue)."
                )
                return
            }
            var updatedBindings = hidBindings
            updatedBindings[learningControl] = Self.normalizedHIDSignature(signature)
            updateActiveHardwareLayoutBindings(updatedBindings)
            selectedControl = learningControl
            liveControl = learningControl
            self.learningControl = nil
            saveHIDBindings()
            lastHIDLearningResult = .success("Learned input for \(learningControl.rawValue).")
            showOverlayPress(for: learningControl)
            return
        }

        let routingBindings = activeRealm == .standard
            ? effectiveStandardHIDBindings
            : effectiveMIDIHIDBindings

        if activeRealm == .standard,
           isStandardKLayerLiveVerified,
           let report = HIDKeyboardReport(signature: signature),
           report.encoding == .report2OneHot,
           report.isCompatibleIndividualBinding,
           !routingBindings.values.contains(Self.normalizedHIDSignature(signature)) {
            invalidateStandardKLayerLiveVerification()
            lastHIDLearningResult = .failure(
                "A live report-2 K input no longer matches the active layout. Standard K layers require live verification again."
            )
        }

        if activeRealm == .standard,
           let report = HIDKeyboardReport(signature: signature),
           report.isReport2OneHot {
            handleStandardReport2Snapshot(report: report, signature: signature)
            return
        }

        if activeRealm == .standard,
           let report = HIDKeyboardReport(signature: signature),
           report.encoding == .report6BootKeyboard {
            let exactControl = routingBindings.first(where: { $0.value == signature })?.key
            let isRawWheelReport = report.modifierByte == 0x01
                && (report.keyUsages == Set<UInt8>([0x56])
                    || report.keyUsages == Set<UInt8>([0x57]))
            let isNonEmptyKState = report.modifierByte != 0 || !report.keyUsages.isEmpty
            let exactKControl = routingBindings.first { control, binding in
                control.isMIDIButton && HIDKeyboardReport(signature: binding) == report
            }?.key
            let hasUniqueKDecomposition = Self.decomposedKeyboardControls(
                for: signature,
                bindings: routingBindings
            ) != nil
            if isStandardKLayerLiveVerified,
               isNonEmptyKState,
               !isRawWheelReport,
               exactKControl == nil,
               !hasUniqueKDecomposition {
                invalidateStandardKLayerLiveVerification()
                lastHIDLearningResult = .failure(
                    "A live report-6 K input no longer matches the active layout. Standard K layers require live verification again."
                )
                return
            }
            if !isRawWheelReport,
               exactControl?.isWheelRotation != true,
               exactControl != .wheelCenter {
                handleStandardReport6Snapshot(
                    report: report,
                    signature: signature,
                    exactControl: exactControl
                )
                return
            }
        }

        if activeRealm == .midi,
           let report = HIDKeyboardReport(signature: signature),
           report.isReport2OneHot {
            let exactControl = effectiveMIDIHIDBindings.first(where: { $0.value == signature })?.key
            handleMIDIReport2Snapshot(
                report: report,
                signature: signature,
                exactControl: exactControl
            )
            return
        }

        if activeRealm == .midi,
           let report = HIDKeyboardReport(signature: signature),
           report.encoding == .report6BootKeyboard {
            let exactControl = effectiveMIDIHIDBindings.first(where: { $0.value == signature })?.key
            handleMIDIReport6Snapshot(
                signature: signature,
                exactControl: exactControl
            )
            return
        }

        let resolvedControls: [RemoteControl]
        if let matched = routingBindings.first(where: { $0.value == signature })?.key {
            // An exact learned binding is authoritative. In particular, a
            // report that is already bound to K10 must never be expanded into
            // K10 plus a hidden K8 merely because their keyboard states
            // overlap.
            resolvedControls = [matched]
        } else if activeRealm == .standard,
                  let compositeControls = Self.decomposedStandardBitmaskControls(
                      for: signature,
                      bindings: routingBindings
                  ) {
            modifierArbitrationLogger.info(
                "composite bitmask input controls=\(compositeControls.map(\.rawValue).joined(separator: ","), privacy: .public)"
            )
            resolvedControls = compositeControls
        } else if activeRealm == .standard,
                  let compositeControls = Self.decomposedKeyboardControls(
                      for: signature,
                      bindings: routingBindings
                  ) {
            modifierArbitrationLogger.info(
                "composite keyboard input controls=\(compositeControls.map(\.rawValue).joined(separator: ","), privacy: .public)"
            )
            resolvedControls = compositeControls
        } else {
            return
        }

        if resolvedControls.count > 1 {
            // Composite keyboard states are a Standard-only fallback. Feed
            // each uniquely resolved physical control through the same state
            // machine used by ordinary K-button reports so modifier timing,
            // duplicate suppression, and release handling remain unchanged.
            guard activeRealm == .standard else { return }
            for control in resolvedControls {
                selectControlFromMappedInput(control)
                liveControl = control
                handleStandardKPress(control)
            }
            return
        }

        guard let matched = resolvedControls.first else { return }

        let previousLiveControl = liveControl
        selectControlFromMappedInput(matched)
        liveControl = matched

        if matched == .wheelCenter {
            if activeRealm == .midi, fnControl == .wheelCenter {
                beginCenterMIDIInteraction()
                return
            }
            isWheelCenterHeld = true
            openProfileSelector()
            return
        }

        if isProfileSelectorVisible, matched == workspaceLockControl {
            _ = toggleWorkspace()
            liveControl = nil
            return
        }

        if isProfileSelectorVisible, matched.isMIDIButton {
            // While the selector is open, every non-lock K button is
            // intentionally consumed so an accidental press cannot execute
            // the profile's normal mapping.
            closeProfileSelector()
            liveControl = nil
            return
        }

        if isProfileSelectorVisible, matched == .wheelCW || matched == .wheelCCW {
            rotateProfile(matched == .wheelCW ? 1 : -1)
            liveControl = nil
            return
        }

        if activeRealm == .midi {
            if let displacedControl = previousLiveControl, displacedControl != matched {
                // A report-6 control may arrive while report-2 still holds
                // its own K snapshot. Do not release the report-2 control
                // merely because report 6 displaced the presentation slot.
                if !activeMIDIReport2Controls.contains(displacedControl),
                   !activeMIDIReport6Controls.contains(displacedControl) {
                    handleMIDIControlRelease(displacedControl)
                }
            }
            handleMIDIControlPress(matched)
            return
        }

        if matched.isWheelRotation {
            // Wheel reports belong to report 6. Keep a separate report-2
            // snapshot cycle alive while the wheel detent and its generic
            // release are processed.
            if activeStandardReport2Controls.isEmpty {
                cancelStandardCycle()
            }
            actionRunner.scroll(
                direction: matched == .wheelCW ? .down : .up,
                sensitivity: wheelSensitivity
            ) { [weak self] result in
                self?.lastActionResult = result
            }
            releaseWheelAfterDelay(generation: generation)
            return
        }

        handleStandardKPress(matched)
    }

    /// Resolves an unmatched report-2 bitmask into its uniquely identified
    /// learned K controls. Report 2 is a state snapshot, so each individual
    /// binding must be a non-zero one-hot mask and the selected masks must
    /// cover the target exactly. Duplicate masks, unknown bits, and any other
    /// ambiguous cover fail closed rather than guessing a layer.
    static func decomposedStandardBitmaskControls(
        for signature: String,
        bindings: [RemoteControl: String]
    ) -> [RemoteControl]? {
        guard let target = HIDKeyboardReport(signature: signature),
              target.isReport2OneHot,
              let targetMask = target.oneHotMask,
              targetMask != 0 else {
            return nil
        }

        struct Candidate {
            let control: RemoteControl
            let mask: UInt16
        }

        let candidates = RemoteControl.allCases.compactMap { control -> Candidate? in
            guard control.isMIDIButton,
                  let binding = bindings[control],
                  let report = HIDKeyboardReport(signature: binding),
                  report.isReport2OneHot,
                  report.isCompatibleIndividualBinding,
                  let mask = report.oneHotMask,
                  mask & ~targetMask == 0 else {
                return nil
            }
            return Candidate(control: control, mask: mask)
        }

        guard candidates.count >= 2 else { return nil }

        // Search by increasing cover size. Keeping at most two matches is
        // enough to distinguish a unique decomposition from an ambiguous
        // one, while the ten-button remote keeps this bounded and simple.
        for size in 2...candidates.count {
            var matchingCovers: [[RemoteControl]] = []

            func visit(
                nextIndex: Int,
                selected: [Candidate],
                mask: UInt16
            ) {
                guard matchingCovers.count < 2 else { return }

                if selected.count == size {
                    guard mask == targetMask else { return }
                    matchingCovers.append(selected.map(\.control))
                    return
                }

                let remaining = size - selected.count
                guard candidates.count - nextIndex >= remaining else { return }

                for index in nextIndex..<candidates.count {
                    let candidate = candidates[index]
                    visit(
                        nextIndex: index + 1,
                        selected: selected + [candidate],
                        mask: mask | candidate.mask
                    )
                    guard matchingCovers.count < 2 else { return }
                }
            }

            visit(nextIndex: 0, selected: [], mask: 0)

            if matchingCovers.count == 1 {
                return matchingCovers[0]
            }
            if matchingCovers.count > 1 {
                return nil
            }
        }

        return nil
    }

    /// Resolves an unmatched report-6 keyboard state into a uniquely useful
    /// composite of learned K-button states. Exact bindings are resolved by
    /// the caller first and therefore never reach this fallback.
    ///
    /// A report such as Ctrl+O+N can be represented by K1 (Ctrl+O) and K2
    /// (Ctrl+N), while K5 (Ctrl) is a redundant subset. We choose only the
    /// minimum-cardinality covers and reject the report when more than one
    /// cover has that cardinality. This keeps generic modifier buttons from
    /// becoming spurious controls and fails closed for ambiguous input.
    static func decomposedKeyboardControls(
        for signature: String,
        bindings: [RemoteControl: String]
    ) -> [RemoteControl]? {
        guard let target = HIDKeyboardReport(signature: signature),
              target.modifierByte != 0 || !target.keyUsages.isEmpty else {
            return nil
        }

        struct Candidate {
            let control: RemoteControl
            let report: HIDKeyboardReport
        }

        let candidates = RemoteControl.allCases.compactMap { control -> Candidate? in
            guard control.isMIDIButton,
                  let binding = bindings[control],
                  let report = HIDKeyboardReport(signature: binding),
                  report.modifierByte != 0 || !report.keyUsages.isEmpty,
                  report.modifierByte & ~target.modifierByte == 0,
                  report.keyUsages.isSubset(of: target.keyUsages) else {
                return nil
            }
            return Candidate(control: control, report: report)
        }

        guard candidates.count >= 2 else { return nil }

        for size in 2...candidates.count {
            var matchingCovers: [[RemoteControl]] = []

            func visit(
                nextIndex: Int,
                selected: [Candidate],
                modifierByte: UInt8,
                keyUsages: Set<UInt8>
            ) {
                guard matchingCovers.count < 2 else { return }

                if selected.count == size {
                    guard modifierByte == target.modifierByte,
                          keyUsages == target.keyUsages else { return }
                    matchingCovers.append(selected.map(\.control))
                    return
                }

                let remaining = size - selected.count
                guard candidates.count - nextIndex >= remaining else { return }

                for index in nextIndex..<candidates.count {
                    let candidate = candidates[index]
                    let mergedKeys = keyUsages.union(candidate.report.keyUsages)
                    visit(
                        nextIndex: index + 1,
                        selected: selected + [candidate],
                        modifierByte: modifierByte | candidate.report.modifierByte,
                        keyUsages: mergedKeys
                    )
                    guard matchingCovers.count < 2 else { return }
                }
            }

            visit(nextIndex: 0, selected: [], modifierByte: 0, keyUsages: [])

            if matchingCovers.count == 1 {
                return matchingCovers[0]
            }
            if matchingCovers.count > 1 {
                return nil
            }
        }

        return nil
    }

    /// Routes report-6 keyboard snapshots in MIDI mode. Exact learned
    /// bindings remain authoritative; combined states must resolve uniquely
    /// to learned K buttons before their held-set diff can emit independent
    /// Note On and Note Off events.
    private func handleMIDIReport6Snapshot(
        signature: String,
        exactControl: RemoteControl?
    ) {
        let desiredControls: Set<RemoteControl>
        if let exactControl {
            desiredControls = [exactControl]
        } else if let decomposed = Self.decomposedKeyboardControls(
            for: signature,
            bindings: effectiveMIDIHIDBindings
        ) {
            desiredControls = Set(decomposed)
        } else {
            return
        }

        if isProfileSelectorVisible {
            if desiredControls.contains(workspaceLockControl) {
                _ = toggleWorkspace()
            } else {
                closeProfileSelector()
            }
            liveControl = nil
            return
        }

        updateMIDIReport6Controls(to: desiredControls)
    }

    private func updateMIDIReport6Controls(to desiredControls: Set<RemoteControl>) {
        let previousReport6Controls = activeMIDIReport6Controls
        let previousLiveControl = liveControl
        let liveControlBelongedToReport6 = previousLiveControl.map {
            previousReport6Controls.contains($0)
        } ?? false
        let removed = activeMIDIReport6Controls.subtracting(desiredControls)
        let added = desiredControls.subtracting(activeMIDIReport6Controls)

        for control in orderedMIDIControls(removed, fnFirst: false) {
            handleMIDIControlRelease(control)
            activeMIDIReport6Controls.remove(control)
        }

        for control in orderedMIDIControls(added, fnFirst: true) {
            handleMIDIControlPress(control)
            activeMIDIReport6Controls.insert(control)
        }

        if desiredControls.isEmpty {
            if liveControlBelongedToReport6 {
                liveControl = nil
            }
        } else if previousLiveControl == nil || liveControlBelongedToReport6 {
            liveControl = orderedMIDIControls(desiredControls, fnFirst: false).last
        }
    }

    private func releaseMIDIReport6Controls() {
        guard !activeMIDIReport6Controls.isEmpty else { return }
        for control in orderedMIDIControls(activeMIDIReport6Controls, fnFirst: false) {
            handleMIDIControlRelease(control)
        }
        activeMIDIReport6Controls.removeAll()
    }

    /// Routes a valid report-2 snapshot in Standard mode. Exact learned
    /// bindings remain authoritative; otherwise the snapshot must resolve to
    /// one unique set of individually learned one-hot controls. A changed
    /// snapshot rebuilds the in-flight K cycle so controls removed by the
    /// device cannot remain as stale modifiers or primaries.
    private func handleStandardReport2Snapshot(
        report: HIDKeyboardReport,
        signature: String
    ) {
        guard report.isReport2OneHot,
              let mask = report.oneHotMask else { return }

        if mask == 0 {
            activeStandardReport2Controls.removeAll()
            if !activeStandardControls.isEmpty {
                releaseStandardCycle()
            } else {
                cancelActiveStandardModifierHoldTasks(reason: "report-2-release-boundary")
                liveControl = nil
            }
            return
        }

        let exactControl = effectiveStandardHIDBindings.first(where: { $0.value == signature })?.key
        let desiredControls: Set<RemoteControl>
        if let exactControl {
            guard exactControl.isMIDIButton else { return }
            desiredControls = [exactControl]
        } else if let decomposed = Self.decomposedStandardBitmaskControls(
            for: signature,
            bindings: effectiveStandardHIDBindings
        ) {
            desiredControls = Set(decomposed)
        } else {
            // Unknown, partially learned, or ambiguous snapshots are
            // intentionally fail-closed and do not disturb the current set.
            return
        }

        if isProfileSelectorVisible {
            if desiredControls.contains(workspaceLockControl) {
                _ = toggleWorkspace()
            } else {
                closeProfileSelector()
            }
            activeStandardReport2Controls.removeAll()
            return
        }

        updateStandardReport2Controls(to: desiredControls)
    }

    private func updateStandardReport2Controls(
        to desiredControls: Set<RemoteControl>
    ) {
        guard activeStandardReport2Controls != desiredControls else { return }

        let previousReport2Controls = activeStandardReport2Controls
        let previousLiveControl = liveControl
        let liveControlBelongedToReport2 = previousLiveControl.map {
            previousReport2Controls.contains($0)
        } ?? false
        activeStandardReport2Controls = desiredControls

        let removedControls = previousReport2Controls.subtracting(desiredControls)
        let addedControls = desiredControls.subtracting(previousReport2Controls)
        let previousIdentity = activeStandardGestureIdentity

        // A lone modifier's standalone action is committed at the physical
        // release boundary, not by the threshold timer. Capture that
        // decision before removing the source controls and their keyboard
        // state below.
        commitStandaloneStandardModifierIfEligible(
            controls: activeStandardControls,
            removedControls: removedControls
        )

        // A report-2 snapshot can remove a destination while leaving its
        // modifier held. Release that destination through the gesture
        // recognizer so its layered Tap remains eligible, but suppress the
        // modifier's standalone Base action for the rest of this physical
        // cycle.
        if let previousIdentity,
           removedControls.contains(previousIdentity.control) {
            buttonGestureRecognizer.release(previousIdentity)
            activeStandardGestureIdentity = nil
        }

        for control in removedControls {
            if isRemoteModifier(control) {
                activeStandardModifierHoldTasks.removeValue(forKey: control)?.cancel()
                activeStandardModifierThresholdReached.remove(control)
            } else if activeStandardControls.contains(control) {
                activeStandardModifierBaseSuppressed = true
                cancelActiveStandardModifierHoldTasks(reason: "destination-release")
            }
            activeStandardControls.remove(control)
            activeStandardKeyboardModifiers.removeValue(forKey: control)
            activeStandardFunctionKeys.removeValue(forKey: control)
            activeStandardKeyboardKeys.removeValue(forKey: control)
            ambiguousStandardCycles.remove(control)
        }

        let removedModifierFromActiveGesture = previousIdentity?.modifierControls
            .contains(where: { removedControls.contains($0) }) == true
        if let previousIdentity,
           !removedControls.contains(previousIdentity.control),
           !removedModifierFromActiveGesture,
           activeStandardControls.contains(previousIdentity.control) {
            let modifiers = activeStandardControls.filter(isRemoteModifier)
            let updatedIdentity = ButtonGestureIdentity(
                control: previousIdentity.control,
                modifierControls: Set(modifiers),
                keyboardModifiers: activeStandardKeyboardModifiers[previousIdentity.control] ?? [],
                functionKeys: activeStandardFunctionKeys[previousIdentity.control] ?? [],
                keyboardKeys: activeStandardKeyboardKeys[previousIdentity.control] ?? []
            )
            if previousIdentity != updatedIdentity,
               buttonGestureRecognizer.reclassifyPress(
                   from: previousIdentity,
                   to: updatedIdentity
               ) {
                activeStandardGestureIdentity = updatedIdentity
            }
        }

        let orderedControls = RemoteControl.allCases.filter { addedControls.contains($0) }
        for control in orderedControls {
            selectControlFromMappedInput(control)
            handleStandardKPress(control)
            if previousLiveControl == nil || liveControlBelongedToReport2 {
                liveControl = control
            }
        }
    }

    /// Routes a valid report-6 boot-keyboard snapshot in Standard mode.
    /// Exact learned bindings remain authoritative; otherwise the snapshot
    /// must decompose uniquely into learned K controls. Unlike the legacy
    /// one-way press path, the source held set is reconciled so a changed
    /// snapshot releases a removed destination before accepting the next one.
    private func handleStandardReport6Snapshot(
        report: HIDKeyboardReport,
        signature: String,
        exactControl: RemoteControl?
    ) {
        guard report.encoding == .report6BootKeyboard else { return }

        let desiredControls: Set<RemoteControl>
        if let exactControl {
            guard exactControl.isMIDIButton else { return }
            if activeStandardReport6Controls.count > 1,
               activeStandardReport6Controls.contains(exactControl) {
                // An exact control already present in a composite snapshot
                // is the remaining report-6 state. This handles either
                // partial-release direction while preserving exact-control
                // accumulation when the prior snapshot had only one input.
                desiredControls = [exactControl]
            } else {
                desiredControls = activeStandardReport6Controls
                    .union([exactControl])
            }
        } else if let decomposed = Self.decomposedKeyboardControls(
            for: signature,
            bindings: effectiveStandardHIDBindings
        ) {
            desiredControls = Set(decomposed)
        } else {
            // Unknown, partially learned, or ambiguous snapshots are
            // intentionally fail-closed and do not disturb the current set.
            return
        }

        if isProfileSelectorVisible {
            if desiredControls.contains(workspaceLockControl) {
                _ = toggleWorkspace()
            } else {
                closeProfileSelector()
            }
            activeStandardReport6Controls.removeAll()
            return
        }

        updateStandardReport6Controls(to: desiredControls)
    }

    private func updateStandardReport6Controls(
        to desiredControls: Set<RemoteControl>
    ) {
        guard activeStandardReport6Controls != desiredControls else { return }

        let previousReport6Controls = activeStandardReport6Controls
        let previousLiveControl = liveControl
        let liveControlBelongedToReport6 = previousLiveControl.map {
            previousReport6Controls.contains($0)
        } ?? false
        activeStandardReport6Controls = desiredControls

        // A control held by report 2 is still physically active even when it
        // disappears from report 6. Keep the aggregate Standard state until
        // both source snapshots have released it.
        let removedControls = previousReport6Controls
            .subtracting(desiredControls)
            .filter { !activeStandardReport2Controls.contains($0) }
        let addedControls = desiredControls
            .subtracting(previousReport6Controls)
            .filter { !activeStandardControls.contains($0) }
        let previousIdentity = activeStandardGestureIdentity

        // A lone modifier's standalone action is committed at the physical
        // release boundary, not by the threshold timer. Capture that
        // decision before removing the source controls and their keyboard
        // state below.
        commitStandaloneStandardModifierIfEligible(
            controls: activeStandardControls,
            removedControls: removedControls
        )

        if let previousIdentity,
           removedControls.contains(previousIdentity.control) {
            buttonGestureRecognizer.release(previousIdentity)
            activeStandardGestureIdentity = nil
        }

        for control in removedControls {
            if isRemoteModifier(control) {
                activeStandardModifierHoldTasks.removeValue(forKey: control)?.cancel()
                activeStandardModifierThresholdReached.remove(control)
            } else if activeStandardControls.contains(control) {
                activeStandardModifierBaseSuppressed = true
                cancelActiveStandardModifierHoldTasks(reason: "destination-release")
            }
            activeStandardControls.remove(control)
            activeStandardKeyboardModifiers.removeValue(forKey: control)
            activeStandardFunctionKeys.removeValue(forKey: control)
            activeStandardKeyboardKeys.removeValue(forKey: control)
            ambiguousStandardCycles.remove(control)
        }

        let removedModifierFromActiveGesture = previousIdentity?.modifierControls
            .contains(where: { removedControls.contains($0) }) == true
        if let previousIdentity,
           !removedControls.contains(previousIdentity.control),
           !removedModifierFromActiveGesture,
           activeStandardControls.contains(previousIdentity.control) {
            let modifiers = activeStandardControls.filter(isRemoteModifier)
            let updatedIdentity = ButtonGestureIdentity(
                control: previousIdentity.control,
                modifierControls: Set(modifiers),
                keyboardModifiers: activeStandardKeyboardModifiers[previousIdentity.control] ?? [],
                functionKeys: activeStandardFunctionKeys[previousIdentity.control] ?? [],
                keyboardKeys: activeStandardKeyboardKeys[previousIdentity.control] ?? []
            )
            if previousIdentity != updatedIdentity,
               buttonGestureRecognizer.reclassifyPress(
                   from: previousIdentity,
                   to: updatedIdentity
               ) {
                activeStandardGestureIdentity = updatedIdentity
            }
        }

        let orderedControls = RemoteControl.allCases.filter { addedControls.contains($0) }
        for control in orderedControls {
            selectControlFromMappedInput(control)
            handleStandardKPress(control)
            if previousLiveControl == nil || liveControlBelongedToReport6 {
                liveControl = control
            }
        }

        if liveControlBelongedToReport6 {
            if desiredControls.isEmpty {
                liveControl = nil
            } else if let previousLiveControl,
                      !desiredControls.contains(previousLiveControl) {
                liveControl = RemoteControl.allCases.last {
                    desiredControls.contains($0)
                }
            }
        }
    }

    private func releaseStandardReport6Controls() {
        guard !activeStandardReport6Controls.isEmpty else { return }
        updateStandardReport6Controls(to: [])
    }

    /// Routes a Standard K-button press through the dual-role layer state
    /// machine. A designated K is held as a modifier candidate; exactly one
    /// non-designated K is the primary. Either press order may form an exact
    /// layer while the same report-6 cycle remains active. All designated K
    /// buttons may participate in that layer.
    private func handleStandardKPress(_ control: RemoteControl) {
        guard activeRealm == .standard, control.isMIDIButton else { return }
        guard !activeStandardControls.contains(control) else {
            modifierArbitrationLogger.debug(
                "input ignored control=\(control.rawValue, privacy: .public) reason=duplicate"
            )
            return
        }

        let startsNewCycle = activeStandardControls.isEmpty
        if startsNewCycle {
            activeStandardModifierGeneration &+= 1
            activeStandardModifierThresholdReached.removeAll()
            activeStandardModifierBaseSuppressed = false
        }

        modifierArbitrationLogger.info(
            "standard K input control=\(control.rawValue, privacy: .public) generation=\(self.activeStandardModifierGeneration, privacy: .public) active-count=\(self.activeStandardControls.count, privacy: .public) threshold-reached=\(self.activeStandardModifierThresholdReached.contains(control), privacy: .public) base-suppressed=\(self.activeStandardModifierBaseSuppressed, privacy: .public)"
        )

        activeStandardKeyboardModifiers[control] = remoteModifierProvider()
        activeStandardFunctionKeys[control] = remoteFunctionKeyProvider()
        activeStandardKeyboardKeys[control] = remoteKeyProvider(configuredRemoteTriggerKeyCodes)
        activeStandardControls.insert(control)

        let modifiers = activeStandardControls.filter(isRemoteModifier)
        let primaries = activeStandardControls.filter { !isRemoteModifier($0) }

        // Modifier-first sequence completion: a lone modifier released within
        // its deferred-solo window is completed by this destination press.
        if primaries.count == 1,
           modifiers.isEmpty,
           let primary = primaries.first,
           case let matched? = matchedStandardDeferredSoloSequence(for: primary) {
            modifierArbitrationLogger.info(
                "sequence fired order=modifier-first control=\(primary.rawValue, privacy: .public) modifier=\(matched.modifier.rawValue, privacy: .public) gesture=\(matched.gesture.rawValue, privacy: .public)"
            )
            suppressActiveStandardCycleAfterSequenceFire()
            let identity = ButtonGestureIdentity(
                control: primary,
                modifierControls: [matched.modifier],
                keyboardModifiers: remoteModifierProvider(),
                functionKeys: remoteFunctionKeyProvider(),
                keyboardKeys: remoteKeyProvider(configuredRemoteTriggerKeyCodes)
            )
            recognizedButtonGesture(identity: identity, gesture: matched.gesture)
            return
        }

        if primaries.isEmpty {
            if modifiers.count == 1,
               let modifier = modifiers.first {
                scheduleStandaloneStandardModifier(for: modifier)
            } else {
                // A modifier stack is intentionally fail-closed. If one
                // member is released before the other, the remaining member
                // must not later look like a standalone hold.
                if modifiers.count > 1 {
                    activeStandardModifierBaseSuppressed = true
                }
                cancelActiveStandardModifierHoldTasks(reason: "multiple-modifiers")
            }
            return
        }

        // The destination's participation is the decisive event. It
        // suppresses any standalone Base Tap even if the threshold callback
        // already marked the modifier eligible.
        activeStandardModifierBaseSuppressed = true
        cancelActiveStandardModifierHoldTasks(reason: "primary-joined")
        guard primaries.count <= 1 else {
            ambiguousStandardCycles.formUnion(primaries)
            cancelActiveStandardPrimaryGestures()
            return
        }
        guard let primary = primaries.first else { return }

        // Destination-first sequence completion: the modifier joining this
        // lone still-held destination within its window fires once and
        // consumes the rest of the physical cycle.
        if activeRealm == .standard,
           modifiers.count == 1,
           let modifier = modifiers.first,
           let pending = activeStandardDestinationSequenceWindows[primary],
           pending.generation == activeStandardSequenceGeneration,
           let gesture = standardSequenceLayerGesture(control: primary, modifier: modifier),
           activeStandardDestinationSequenceWindows.removeValue(forKey: primary) != nil {
            pending.task.cancel()
            modifierArbitrationLogger.info(
                "sequence fired order=destination-first control=\(primary.rawValue, privacy: .public) modifier=\(modifier.rawValue, privacy: .public) gesture=\(gesture.rawValue, privacy: .public)"
            )
            suppressActiveStandardCycleAfterSequenceFire()
            let identity = ButtonGestureIdentity(
                control: primary,
                modifierControls: [modifier],
                keyboardModifiers: remoteModifierProvider(),
                functionKeys: remoteFunctionKeyProvider(),
                keyboardKeys: remoteKeyProvider(configuredRemoteTriggerKeyCodes)
            )
            recognizedButtonGesture(identity: identity, gesture: gesture)
            return
        }

        if modifiers.isEmpty {
            armStandardDestinationSequenceWindowIfConfigured(for: primary)
        }

        let identity = ButtonGestureIdentity(
            control: primary,
            modifierControls: Set(modifiers),
            keyboardModifiers: activeStandardKeyboardModifiers[primary] ?? [],
            functionKeys: activeStandardFunctionKeys[primary] ?? [],
            keyboardKeys: activeStandardKeyboardKeys[primary] ?? []
        )
        // If a modifier joins after the destination press, move the still-held
        // gesture to the exact layer identity for this same report-6 cycle.
        // Modifier-first presses still begin directly with that identity.
        if let previousIdentity = activeStandardGestureIdentity,
           previousIdentity != identity {
            if buttonGestureRecognizer.reclassifyPress(from: previousIdentity, to: identity) {
                activeStandardGestureIdentity = identity
            }
        } else if activeStandardGestureIdentity == nil {
            buttonGestureRecognizer.press(identity)
            activeStandardGestureIdentity = identity
        }
    }

    private func scheduleStandaloneStandardModifier(for control: RemoteControl) {
        guard activeStandardModifierHoldTasks[control] == nil,
              activeStandardControls.count == 1,
              activeStandardModifierBaseSuppressed == false,
              activeStandardGestureIdentity == nil else { return }

        let keyboardModifiers = activeStandardKeyboardModifiers[control] ?? []
        let functionKeys = activeStandardFunctionKeys[control] ?? []
        let keyboardKeys = activeStandardKeyboardKeys[control] ?? []
        let identity = ButtonGestureIdentity(
            control: control,
            keyboardModifiers: keyboardModifiers,
            functionKeys: functionKeys,
            keyboardKeys: keyboardKeys
        )
        let generation = activeStandardModifierGeneration
        // Snapshot the setting at press time. A later UI edit affects only
        // subsequent modifier presses.
        let threshold = standardModifierHoldThreshold
        modifierArbitrationLogger.info(
            "standalone threshold scheduled control=\(control.rawValue, privacy: .public) threshold=\(threshold, privacy: .public) generation=\(generation, privacy: .public)"
        )
        activeStandardModifierHoldTasks[control] = gestureSchedule(threshold) { [weak self] in
            self?.markStandaloneStandardModifierThresholdReached(
                identity: identity,
                generation: generation
            )
        }
    }

    private func markStandaloneStandardModifierThresholdReached(
        identity: ButtonGestureIdentity,
        generation: Int
    ) {
        guard generation == activeStandardModifierGeneration,
              activeStandardControls.count == 1,
              activeStandardControls.contains(identity.control),
              isRemoteModifier(identity.control),
              activeStandardModifierBaseSuppressed == false,
              activeStandardGestureIdentity == nil else {
            modifierArbitrationLogger.info(
                "standalone threshold rejected control=\(identity.control.rawValue, privacy: .public) reason=state expected-generation=\(generation, privacy: .public) actual-generation=\(self.activeStandardModifierGeneration, privacy: .public) active-count=\(self.activeStandardControls.count, privacy: .public) base-suppressed=\(self.activeStandardModifierBaseSuppressed, privacy: .public) gesture-active=\(self.activeStandardGestureIdentity != nil, privacy: .public)"
            )
            return
        }

        modifierArbitrationLogger.info(
            "standalone threshold reached/eligible control=\(identity.control.rawValue, privacy: .public) generation=\(generation, privacy: .public)"
        )

        // The callback is deliberately side-effect free with respect to
        // mapped actions. The held modifier remains eligible for a later
        // destination; release commits Base only if no destination joined.
        activeStandardModifierThresholdReached.insert(identity.control)
        activeStandardModifierHoldTasks.removeValue(forKey: identity.control)
    }

    private func commitStandaloneStandardModifierIfEligible(
        controls: Set<RemoteControl>,
        removedControls: Set<RemoteControl>? = nil
    ) {
        guard let modifier = controls.first,
              controls.count == 1,
              removedControls.map({ $0.contains(modifier) }) ?? true,
              isRemoteModifier(modifier),
              activeStandardModifierBaseSuppressed == false,
              activeStandardGestureIdentity == nil else {
            return
        }

        // A quick tap is still a press+release under the per-combo sequence
        // contract, so any lone qualifying release arms the deferred-solo
        // window — early or post-threshold alike. Without a sequence mapping
        // the release falls through to the threshold-gated Base Tap commit.
        if armStandardDeferredSoloSequence(for: modifier) { return }

        guard activeStandardModifierThresholdReached.contains(modifier) else {
            modifierArbitrationLogger.info(
                "standalone release inert control=\(modifier.rawValue, privacy: .public) reason=sub-threshold"
            )
            return
        }

        let identity = ButtonGestureIdentity(
            control: modifier,
            keyboardModifiers: activeStandardKeyboardModifiers[modifier] ?? [],
            functionKeys: activeStandardFunctionKeys[modifier] ?? [],
            keyboardKeys: activeStandardKeyboardKeys[modifier] ?? []
        )
        activeStandardModifierThresholdReached.remove(modifier)
        modifierArbitrationLogger.info(
            "standalone Base Tap committed at release control=\(modifier.rawValue, privacy: .public)"
        )
        recognizedButtonGesture(identity: identity, gesture: .tap)
    }

    /// Returns the first gesture of a Standard sequence-mode layer mapping
    /// for the exact one-modifier layer. Multi-modifier stacks, unavailable
    /// modifiers, and non-K destinations fail closed here.
    private func standardSequenceLayerGesture(
        control: RemoteControl,
        modifier: RemoteControl
    ) -> GestureKind? {
        guard activeRealm == .standard,
              control.isMIDIButton,
              isRemoteModifier(modifier),
              control != modifier else {
            return nil
        }
        for gesture in GestureKind.allCases {
            if case let mapping? = mappings[MappingKey(
                control: control,
                gesture: gesture,
                modifierControls: [modifier]
            )], mapping.comboMode == .sequence {
                return gesture
            }
        }
        return nil
    }

    /// Arms the deferred solo window for a released lone Standard modifier
    /// that owns at least one sequence-mode destination layer. Returns false
    /// when no such mapping exists and the caller should commit solo Base
    /// immediately as before.
    private func armStandardDeferredSoloSequence(for modifier: RemoteControl) -> Bool {
        guard activeRealm == .standard else { return false }

        let windows = RemoteControl.allCases.compactMap { destination -> Int? in
            guard standardSequenceLayerGesture(control: destination, modifier: modifier) != nil else {
                return nil
            }
            return standardSequenceWindowMs(control: destination, modifier: modifier)
        }
        guard let shortestWindowMs = windows.min() else { return false }

        activeStandardDeferredSoloSequences.removeValue(forKey: modifier)?.task.cancel()
        activeStandardDestinationSequenceWindows.removeValue(forKey: modifier)?.task.cancel()
        let generation = activeStandardSequenceGeneration
        // Snapshots are taken before the release-boundary cleanup clears the
        // press-time keyboard state dictionaries.
        let identity = ButtonGestureIdentity(
            control: modifier,
            keyboardModifiers: activeStandardKeyboardModifiers[modifier] ?? [],
            functionKeys: activeStandardFunctionKeys[modifier] ?? [],
            keyboardKeys: activeStandardKeyboardKeys[modifier] ?? []
        )
        modifierArbitrationLogger.info(
            "sequence window armed kind=solo control=\(modifier.rawValue, privacy: .public) window=\(shortestWindowMs, privacy: .public) generation=\(generation, privacy: .public)"
        )
        activeStandardDeferredSoloSequences[modifier] = DeferredStandardSoloSequence(
            identity: identity,
            generation: generation,
            task: gestureSchedule(TimeInterval(shortestWindowMs) / 1000) { [weak self] in
                self?.expireStandardDeferredSoloSequence(for: modifier, generation: generation)
            }
        )
        return true
    }

    /// The shortest configured sequence window across one destination and
    /// modifier pair's sequence-mode gestures.
    private func standardSequenceWindowMs(
        control: RemoteControl,
        modifier: RemoteControl
    ) -> Int? {
        GestureKind.allCases.compactMap { gesture -> Int? in
            guard case let mapping? = mappings[MappingKey(
                control: control,
                gesture: gesture,
                modifierControls: [modifier]
            )], mapping.comboMode == .sequence else {
                return nil
            }
            return mapping.sequenceWindowMs
        }.min()
    }

    private func expireStandardDeferredSoloSequence(
        for modifier: RemoteControl,
        generation: Int
    ) {
        guard let entry = activeStandardDeferredSoloSequences[modifier],
              entry.generation == generation,
              activeStandardDeferredSoloSequences.removeValue(forKey: modifier) != nil else {
            return
        }
        entry.task.cancel()
        // A different physical cycle in flight means the solo decision can no
        // longer be attributed cleanly; fail closed instead of misfiring.
        guard activeStandardControls.isEmpty,
              activeStandardGestureIdentity == nil else {
            modifierArbitrationLogger.info(
                "sequence window skipped kind=solo control=\(modifier.rawValue, privacy: .public) reason=cycle-active"
            )
            return
        }
        modifierArbitrationLogger.info(
            "sequence window expired kind=solo control=\(modifier.rawValue, privacy: .public) commit=base-tap"
        )
        recognizedButtonGesture(identity: entry.identity, gesture: .tap)
    }

    /// Returns the pending deferred-solo completion matching this freshly
    /// pressed destination, consuming the window exactly once.
    private func matchedStandardDeferredSoloSequence(
        for destination: RemoteControl
    ) -> (modifier: RemoteControl, gesture: GestureKind)? {
        for modifier in RemoteControl.allCases {
            guard let pending = activeStandardDeferredSoloSequences[modifier],
                  pending.generation == activeStandardSequenceGeneration,
                  let gesture = standardSequenceLayerGesture(control: destination, modifier: modifier) else {
                continue
            }
            activeStandardDeferredSoloSequences.removeValue(forKey: modifier)?.task.cancel()
            return (modifier, gesture)
        }
        return nil
    }

    private func armStandardDestinationSequenceWindowIfConfigured(for primary: RemoteControl) {
        let windows = RemoteControl.allCases.compactMap { modifier -> Int? in
            guard standardSequenceLayerGesture(control: primary, modifier: modifier) != nil else {
                return nil
            }
            return standardSequenceWindowMs(control: primary, modifier: modifier)
        }
        guard let shortestWindowMs = windows.min() else { return }

        activeStandardDestinationSequenceWindows.removeValue(forKey: primary)?.task.cancel()
        let generation = activeStandardSequenceGeneration
        modifierArbitrationLogger.info(
            "sequence window armed kind=destination control=\(primary.rawValue, privacy: .public) window=\(shortestWindowMs, privacy: .public) generation=\(generation, privacy: .public)"
        )
        activeStandardDestinationSequenceWindows[primary] = DestinationStandardSequenceWindow(
            generation: generation,
            task: gestureSchedule(TimeInterval(shortestWindowMs) / 1000) { [weak self] in
                guard let self,
                      let window = self.activeStandardDestinationSequenceWindows[primary],
                      window.generation == generation,
                      self.activeStandardDestinationSequenceWindows.removeValue(forKey: primary) != nil else {
                    return
                }
                window.task.cancel()
                self.modifierArbitrationLogger.info(
                    "sequence window expired kind=destination control=\(primary.rawValue, privacy: .public)"
                )
            }
        )
    }

    /// Marks the current physical cycle consumed after a sequence fire so no
    /// hold-path or standalone path can repeat the same action.
    private func suppressActiveStandardCycleAfterSequenceFire() {
        activeStandardModifierBaseSuppressed = true
        let tasks = Array(activeStandardModifierHoldTasks.values)
        activeStandardModifierHoldTasks.removeAll()
        tasks.forEach { $0.cancel() }
        activeStandardModifierThresholdReached.removeAll()
        if let previousIdentity = activeStandardGestureIdentity {
            buttonGestureRecognizer.cancel(previousIdentity)
            activeStandardGestureIdentity = nil
        }
    }

    private func cancelActiveStandardSequenceWindows(reason: String) {
        let soloTasks = activeStandardDeferredSoloSequences.values.map(\.task)
        let destinationTasks = activeStandardDestinationSequenceWindows.values.map(\.task)
        guard !soloTasks.isEmpty || !destinationTasks.isEmpty else { return }
        activeStandardDeferredSoloSequences.removeAll()
        activeStandardDestinationSequenceWindows.removeAll()
        activeStandardSequenceGeneration &+= 1
        modifierArbitrationLogger.info(
            "sequence windows cancelled reason=\(reason, privacy: .public) count=\(soloTasks.count + destinationTasks.count, privacy: .public)"
        )
        (soloTasks + destinationTasks).forEach { $0.cancel() }
    }

    private func releaseStandardCycle() {
        let controls = activeStandardControls
        commitStandaloneStandardModifierIfEligible(controls: controls)
        activeStandardReport6Controls.removeAll()
        activeStandardReport2Controls.removeAll()
        modifierArbitrationLogger.info(
            "cycle reset reason=release-boundary controls=\(controls.count, privacy: .public) threshold-reached=\(self.activeStandardModifierThresholdReached.count, privacy: .public) base-suppressed=\(self.activeStandardModifierBaseSuppressed, privacy: .public)"
        )
        cancelActiveStandardModifierHoldTasks(reason: "release-boundary")
        activeStandardControls.removeAll()
        defer {
            activeStandardKeyboardModifiers.removeAll()
            activeStandardFunctionKeys.removeAll()
            activeStandardKeyboardKeys.removeAll()
            activeStandardGestureIdentity = nil
            activeStandardModifierThresholdReached.removeAll()
            activeStandardModifierBaseSuppressed = false
            activeStandardModifierGeneration &+= 1
            ambiguousStandardCycles.removeAll()
            liveControl = nil
        }

        let modifiers = controls.filter(isRemoteModifier)
        let primaries = controls.filter { !isRemoteModifier($0) }
        guard ambiguousStandardCycles.isEmpty,
              primaries.count == 1,
              modifiers.count <= remoteModifierControls
                  .subtracting(unavailableRemoteModifierControls)
                  .count else {
            cancelActiveStandardPrimaryGestures()
            return
        }

        if let identity = activeStandardGestureIdentity {
            buttonGestureRecognizer.release(identity)
        }
    }

    private func cancelActiveStandardPrimaryGestures() {
        if let identity = activeStandardGestureIdentity {
            buttonGestureRecognizer.cancel(identity)
            activeStandardGestureIdentity = nil
        }
    }

    private func cancelStandardCycle() {
        cancelActiveStandardPrimaryGestures()
        cancelActiveStandardModifierHoldTasks(reason: "cycle-cancelled")
        cancelActiveStandardSequenceWindows(reason: "cycle-cancelled")
        activeStandardControls.removeAll()
        activeStandardReport6Controls.removeAll()
        activeStandardReport2Controls.removeAll()
        activeStandardKeyboardModifiers.removeAll()
        activeStandardFunctionKeys.removeAll()
        activeStandardKeyboardKeys.removeAll()
        activeStandardModifierThresholdReached.removeAll()
        activeStandardModifierBaseSuppressed = false
        activeStandardModifierGeneration &+= 1
        ambiguousStandardCycles.removeAll()
    }

    private func cancelActiveStandardModifierHoldTasks(reason: String) {
        let tasks = Array(activeStandardModifierHoldTasks.values)
        activeStandardModifierHoldTasks.removeAll()
        if !tasks.isEmpty {
            modifierArbitrationLogger.info(
                "standalone threshold cancelled reason=\(reason, privacy: .public) count=\(tasks.count, privacy: .public) generation=\(self.activeStandardModifierGeneration, privacy: .public)"
            )
        }
        tasks.forEach { $0.cancel() }
    }

    private func recognizedButtonGesture(identity: ButtonGestureIdentity, gesture: GestureKind) {
        let control = identity.control
        let layer = identity.modifierControls
        guard mappings[MappingKey(control: control, gesture: gesture, modifierControls: layer)] != nil else {
            return
        }
        let mapping = mapping(for: control, gesture: gesture, modifierControls: layer)
        let expectedFunctionKeys = mapping.remoteTriggerFunctionKey.map { Set([$0]) } ?? []
        let expectedKeyboardKeys = mapping.remoteTriggerKeyCode.map { Set([$0]) } ?? []
        guard mapping.remoteTriggerModifiers == identity.keyboardModifiers,
              identity.functionKeys == expectedFunctionKeys,
              identity.keyboardKeys == expectedKeyboardKeys else { return }
        modifierArbitrationLogger.info(
            "gesture selected control=\(control.rawValue, privacy: .public) gesture=\(gesture.rawValue, privacy: .public) scope=\(layer.isEmpty ? "base" : "layer", privacy: .public) modifier-count=\(layer.count, privacy: .public)"
        )
        showOverlayPress(
            for: control,
            modifierControls: layer,
            isAlreadyReleased: gesture != .hold
        )
        if showsInputOverlay {
            inputOverlay.recognize(control: control, gesture: gesture)
        }
        executeMapping(for: control, gesture: gesture, modifierControls: layer) { [weak self] result in
            self?.lastActionResult = result
        }
    }

    private func beginCenterMIDIInteraction() {
        guard !isWheelCenterHeld else { return }
        isWheelCenterHeld = true
        openProfileSelector()
        centerFnHoldGeneration &+= 1
        let generation = centerFnHoldGeneration
        centerFnHoldTask?.cancel()
        let holdThreshold = midiSettings?.fnHoldThreshold ?? MIDIProfileSettings.defaultFnHoldThreshold
        centerFnHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(holdThreshold))
            guard let self, self.centerFnHoldGeneration == generation,
                  self.isWheelCenterHeld, self.activeRealm == .midi,
                  self.fnControl == .wheelCenter else { return }
            self.fnIsActive = true
            self.activeMIDIControls.insert(.wheelCenter)
            self.midiControlLayers[.wheelCenter] = 2
            self.isProfileSelectorVisible = false
            self.pendingProfileName = nil
            self.cancelProfileSelectorTimeout()
            self.inputOverlay.hideProfileSelector()
        }
    }

    private func finishCenterMIDIInteraction() {
        centerFnHoldGeneration &+= 1
        centerFnHoldTask?.cancel()
        centerFnHoldTask = nil
        if fnIsActive {
            releaseMIDIControl(.wheelCenter, layer: 2)
            fnIsActive = false
            isWheelCenterHeld = false
            return
        }
        isWheelCenterHeld = false
        confirmProfileSelection()
    }

    /// Routes one valid report-2 state snapshot in a MIDI profile. Exact
    /// learned bindings win over decomposition; otherwise every individual
    /// one-hot report-2 binding must form one unique cover of the snapshot.
    /// Ambiguous or partially learned masks leave the current MIDI state
    /// untouched and therefore fail closed.
    private func handleMIDIReport2Snapshot(
        report: HIDKeyboardReport,
        signature: String,
        exactControl: RemoteControl?
    ) {
        guard report.isReport2OneHot,
              let mask = report.oneHotMask,
              mask != 0 else {
            let report2Controls = activeMIDIReport2Controls
            releaseMIDIReport2Controls(report2Controls)
            if let liveControl, report2Controls.contains(liveControl) {
                self.liveControl = nil
            }
            return
        }

        let desiredControls: Set<RemoteControl>
        if let exactControl {
            guard exactControl.isMIDIButton else { return }
            desiredControls = [exactControl]
        } else if let decomposed = Self.decomposedStandardBitmaskControls(
            for: signature,
            bindings: effectiveMIDIHIDBindings
        ) {
            desiredControls = Set(decomposed)
        } else {
            return
        }

        if isProfileSelectorVisible {
            if desiredControls.contains(workspaceLockControl) {
                _ = toggleWorkspace()
            } else {
                closeProfileSelector()
            }
            liveControl = nil
            return
        }

        updateMIDIReport2Controls(to: desiredControls)
    }

    private func updateMIDIReport2Controls(to desiredControls: Set<RemoteControl>) {
        let previousReport2Controls = activeMIDIReport2Controls
        let previousLiveControl = liveControl
        let liveControlBelongedToReport2 = previousLiveControl.map {
            previousReport2Controls.contains($0)
        } ?? false
        let removed = activeMIDIReport2Controls.subtracting(desiredControls)
        let added = desiredControls.subtracting(activeMIDIReport2Controls)

        // Release destinations before Fn so their recorded layer remains
        // authoritative and the layer-wide MIDI release follows last.
        for control in orderedMIDIControls(removed, fnFirst: false) {
            handleMIDIControlRelease(control)
            activeMIDIReport2Controls.remove(control)
        }

        // Fn must be pressed first when it joins an already-held destination;
        // the newly added destination then selects its function-layer mapping.
        for control in orderedMIDIControls(added, fnFirst: true) {
            handleMIDIControlPress(control)
            activeMIDIReport2Controls.insert(control)
        }

        if desiredControls.isEmpty {
            if liveControlBelongedToReport2 {
                liveControl = nil
            }
        } else if previousLiveControl == nil || liveControlBelongedToReport2 {
            liveControl = orderedMIDIControls(desiredControls, fnFirst: false).last
        }
    }

    private func releaseMIDIReport2Controls(
        _ controls: Set<RemoteControl>? = nil
    ) {
        let report2Controls = controls ?? activeMIDIReport2Controls
        guard !report2Controls.isEmpty else { return }
        for control in orderedMIDIControls(report2Controls, fnFirst: false) {
            handleMIDIControlRelease(control)
        }
        activeMIDIReport2Controls.subtract(report2Controls)
    }

    private func orderedMIDIControls(
        _ controls: Set<RemoteControl>,
        fnFirst: Bool
    ) -> [RemoteControl] {
        var ordered = RemoteControl.allCases.filter { controls.contains($0) }
        guard let fnControl, controls.contains(fnControl) else { return ordered }
        ordered.removeAll { $0 == fnControl }
        if fnFirst {
            ordered.insert(fnControl, at: 0)
        } else {
            ordered.append(fnControl)
        }
        return ordered
    }

    private func handleMIDIControlPress(_ control: RemoteControl) {
        if control == .wheelCenter, fnControl == .wheelCenter {
            beginCenterMIDIInteraction()
            return
        }
        guard control.isMIDIButton || control.isWheelRotation else { return }
        if control.isWheelRotation {
            let layer: MIDIMappingLayer = fnIsActive ? .function : .primary
            let mapping = midiWheelMapping(for: layer)
            let direction: MIDIWheelDirection = control == .wheelCW ? .clockwise : .counterClockwise
            if updateSessionWheelOffset(direction: direction, mapping: mapping, layer: layer) {
                return
            }
            enqueueMIDICommand { service in
                await service.wheel(direction, mapping: mapping)
            }
            return
        }

        if control == fnControl {
            fnIsActive = true
            activeMIDIControls.insert(control)
            midiControlLayers[control] = 2
            return
        }

        let layer: MIDIMappingLayer = fnIsActive ? .function : .primary
        let layerNumber = layer == .primary ? 1 : 2
        let mapping = adjustedMIDIButtonMapping(
            midiButtonMapping(for: control, layer: layer),
            layer: layer
        )
        activeMIDIControls.insert(control)
        midiControlLayers[control] = layerNumber
        let origin = MIDIOutputService.Origin(control.rawValue, layer: layerNumber)
        enqueueMIDICommand { service in
            await service.sendButton(mapping, origin: origin)
        }
    }

    private func handleMIDIControlRelease(_ control: RemoteControl) {
        guard activeMIDIControls.contains(control) else {
            return
        }
        let layer = midiControlLayers[control] ?? (fnIsActive ? 2 : 1)
        if control == fnControl {
            releaseMIDIControl(control, layer: 2)
            fnIsActive = false
            enqueueMIDICommand { service in
                await service.releaseLayer(2)
            }
        } else {
            releaseMIDIControl(control, layer: layer)
        }
    }

    private func releaseMIDIControl(_ control: RemoteControl, layer: Int) {
        activeMIDIControls.remove(control)
        midiControlLayers.removeValue(forKey: control)
        let origin = MIDIOutputService.Origin(control.rawValue, layer: layer)
        enqueueMIDICommand { service in
            await service.release(origin: origin)
        }
    }

    /// Deterministic seams for tests and for future HID decoders that can
    /// provide an unambiguous press/release pair. These methods deliberately
    /// do not pretend the current generic HID release stream can identify
    /// arbitrary rollover order.
    func simulateMIDIControlPressForTesting(_ control: RemoteControl) {
        guard activeRealm == .midi else { return }
        selectControlFromMappedInput(control)
        handleMIDIControlPress(control)
    }

    func simulateMIDIControlReleaseForTesting(_ control: RemoteControl) {
        guard activeRealm == .midi else { return }
        if control == .wheelCenter, fnControl == .wheelCenter {
            finishCenterMIDIInteraction()
            return
        }
        handleMIDIControlRelease(control)
    }

    private func cancelPendingButtonGestures() {
        cancelStandardCycle()
        buttonGestureRecognizer.cancelAll()
        if let liveControl, showsInputOverlay, !liveControl.isWheelRotation {
            inputOverlay.release(control: liveControl)
        }
        liveControl = nil
    }

    private func releaseWheelAfterDelay(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, self.liveInputGeneration == generation else { return }
            self.liveControl = nil
        }
    }

    private func openProfileSelector() {
        cancelStandardCycle()
        guard !isProfileSelectorVisible else { return }
        let profiles = availableProfilesInActiveRealm
        guard !profiles.isEmpty else { return }
        isProfileSelectorVisible = true
        pendingProfileName = profileName
        inputOverlay.showProfileSelector(
            profiles: profiles,
            selectedProfile: profileName
        )
        restartProfileSelectorTimeout()
    }

    private func confirmProfileSelection() {
        guard isProfileSelectorVisible else { return }
        if let pendingProfileName {
            profileName = pendingProfileName
        }
        closeProfileSelector()
    }

    private func rotateProfile(_ direction: Int) {
        let profiles = availableProfilesInActiveRealm
        guard !profiles.isEmpty else { return }
        let highlightedProfile = pendingProfileName ?? profileName
        let currentIndex = profiles.firstIndex(of: highlightedProfile) ?? 0
        let count = profiles.count
        let nextIndex = (currentIndex + direction + count) % count
        pendingProfileName = profiles[nextIndex]
        inputOverlay.showProfileSelector(
            profiles: profiles,
            selectedProfile: pendingProfileName ?? profileName
        )
        restartProfileSelectorTimeout()
    }

    private func closeProfileSelector() {
        cancelProfileSelectorTimeout()
        centerFnHoldGeneration &+= 1
        centerFnHoldTask?.cancel()
        centerFnHoldTask = nil
        isProfileSelectorVisible = false
        isWheelCenterHeld = false
        pendingProfileName = nil
        inputOverlay.hideProfileSelector()
        liveControl = nil
        syncMIDIOverlay()
    }

    private func restartProfileSelectorTimeout() {
        cancelProfileSelectorTimeout()
        profileSelectorTimeoutGeneration &+= 1
        let generation = profileSelectorTimeoutGeneration
        profileSelectorTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.profileSelectorTimeoutGeneration == generation,
                  self.isProfileSelectorVisible else { return }
            self.closeProfileSelector()
        }
    }

    private func cancelProfileSelectorTimeout() {
        profileSelectorTimeoutGeneration &+= 1
        profileSelectorTimeoutTask?.cancel()
        profileSelectorTimeoutTask = nil
    }

    private func showOverlayPress(
        for control: RemoteControl,
        modifierControls: Set<RemoteControl> = [],
        isAlreadyReleased: Bool = false
    ) {
        guard showsInputOverlay else { return }
        let tap = overlayMapping(for: control, gesture: .tap, modifierControls: modifierControls)
        let hold = overlayMapping(for: control, gesture: .hold, modifierControls: modifierControls)
        let doubleTap = overlayMapping(for: control, gesture: .doubleTap, modifierControls: modifierControls)
        if isAlreadyReleased {
            inputOverlay.presentCompleted(control: control, tap: tap, hold: hold, doubleTap: doubleTap)
        } else {
            inputOverlay.press(control: control, tap: tap, hold: hold, doubleTap: doubleTap)
        }
    }

    private func saveMIDIState() {
        saveActiveProfile()
        saveAllProfiles()
        refreshMIDIEndpointStatus()
    }

    private func applyMIDIResult(_ result: Result<MIDIOutputService.StateResult, MIDIOutputService.ServiceError>) {
        switch result {
        case .success:
            lastMIDIError = nil
        case let .failure(error):
            lastMIDIError = error.localizedDescription
        }
        refreshMIDIEndpointStatus()
    }

    fileprivate func recordMIDIEvent(_ event: MIDIOutputService.MonitorEvent) {
        midiMonitorEvents.insert(event, at: 0)
        if midiMonitorEvents.count > 100 {
            midiMonitorEvents.removeLast(midiMonitorEvents.count - 100)
        }
    }

    private func enqueueMIDICommand(
        _ operation: @escaping (MIDIOutputService) async -> Result<MIDIOutputService.StateResult, MIDIOutputService.ServiceError>
    ) {
        let previous = midiCommandTail.task
        let service = midiOutputService
        midiCommandTail.task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            let result = await operation(service)
            self?.applyMIDIResult(result)
        }
    }

    private func requestMIDIShutdown() {
        guard midiShutdownGate.request() else { return }
        closeProfileSelector()
        resetMIDIState(force: true)
        enqueueMIDICommand { service in
            await service.resetForShutdown()
        }
    }

    /// Keeps explicit realm/profile feedback in sync with the active realm
    /// while leaving profile-selector presentation in the model's
    /// higher-priority slot. MIDI performance never calls this method.
    private func syncMIDIOverlay() {
        guard activeRealm == .midi else {
            inputOverlay.clearMIDI()
            return
        }
        inputOverlay.showMIDI(
            profileName: profileName,
            layer: fnIsActive ? .function : .primary
        )
    }

    /// Applies the two stateful performance wheel modes locally. The output
    /// service owns MIDI wire encoding, while the store owns profile-session
    /// musical offsets because they change which note a later button press
    /// should emit.
    @discardableResult
    private func updateSessionWheelOffset(
        direction: MIDIWheelDirection,
        mapping: MIDIWheelMapping,
        layer: MIDIMappingLayer
    ) -> Bool {
        guard mapping.kind == .transpose || mapping.kind == .drumBank else { return false }
        let directionSign = (direction == .clockwise ? 1 : -1) * (mapping.reversedDirection ? -1 : 1)
        let current: Int
        let proposed: Int
        let status: String
        switch mapping.kind {
        case .transpose:
            current = midiTransposeOffsets[layer, default: 0]
            proposed = current + directionSign * mapping.transposeSemitones
            let next = clampedSessionOffset(proposed, layer: layer)
            midiTransposeOffsets[layer] = next
            status = "Transpose offset " + signedValue(next) + " st · " + layer.rawValue
        case .drumBank:
            current = midiDrumBankOffsets[layer, default: 0]
            proposed = current + directionSign * mapping.drumBankStep
            let next = clampedDrumBankOffset(proposed, layer: layer)
            midiDrumBankOffsets[layer] = next
            status = "Drum Bank " + signedValue(next) + " · " + layer.rawValue
        default:
            return false
        }
        lastMIDIStatus = status
        return true
    }

    private func clampedSessionOffset(_ proposed: Int, layer: MIDIMappingLayer) -> Int {
        let notes = baseNoteValues(for: layer)
        guard let minimum = notes.min(), let maximum = notes.max() else {
            return max(-127, min(127, proposed))
        }
        let lowerBound = -minimum
        let upperBound = 127 - maximum
        return max(lowerBound, min(upperBound, proposed))
    }

    private func clampedDrumBankOffset(_ proposed: Int, layer: MIDIMappingLayer) -> Int {
        let notes = baseNoteValues(for: layer)
        guard let minimum = notes.min(), let maximum = notes.max() else {
            return max(-12, min(12, proposed))
        }
        let lowerBank = -(minimum / 10)
        let upperBank = (127 - maximum) / 10
        return max(lowerBank, min(upperBank, proposed))
    }

    private func baseNoteValues(for layer: MIDIMappingLayer) -> [Int] {
        guard let settings = midiSettings else { return [] }
        let entries = layer == .primary ? settings.primaryButtons : settings.functionButtons
        return entries.flatMap { entry in
            switch entry.mapping.kind {
            case .note:
                return [entry.mapping.note]
            case .chord:
                return entry.mapping.chord
            case .cc, .program, .noAction:
                return []
            }
        }
    }

    private func adjustedMIDIButtonMapping(
        _ mapping: MIDIButtonMapping,
        layer: MIDIMappingLayer
    ) -> MIDIButtonMapping {
        let offset = midiTransposeOffsets[layer, default: 0]
            + midiDrumBankOffsets[layer, default: 0] * 10
        guard offset != 0 else { return mapping }
        var adjusted = mapping
        switch adjusted.kind {
        case .note:
            adjusted.note = shiftedMIDIValue(adjusted.note, by: offset)
        case .chord:
            adjusted.chord = adjusted.chord.map { shiftedMIDIValue($0, by: offset) }
        case .cc, .program, .noAction:
            break
        }
        return adjusted
    }

    private func shiftedMIDIValue(_ value: Int, by offset: Int) -> Int {
        max(0, min(127, value + offset))
    }

    private func signedValue(_ value: Int) -> String {
        value >= 0 ? "+" + String(value) : String(value)
    }

    private func resetSessionOffsets() {
        midiTransposeOffsets = [.primary: 0, .function: 0]
        midiDrumBankOffsets = [.primary: 0, .function: 0]
        lastMIDIStatus = nil
    }

    private func resetMIDIState(force: Bool = false) {
        if isProfileSelectorVisible {
            closeProfileSelector()
        } else {
            cancelProfileSelectorTimeout()
        }
        centerFnHoldGeneration &+= 1
        centerFnHoldTask?.cancel()
        centerFnHoldTask = nil
        let hadMIDIState = fnIsActive || !activeMIDIControls.isEmpty
        fnIsActive = false
        activeMIDIControls.removeAll()
        activeMIDIReport6Controls.removeAll()
        activeMIDIReport2Controls.removeAll()
        midiControlLayers.removeAll()
        resetSessionOffsets()
        syncMIDIOverlay()
        guard force || hadMIDIState || activeRealm == .midi else { return }
        enqueueMIDICommand { service in
            await service.resetForProfileChange()
        }
    }

    private func rememberedProfile(in realm: ProfileRealm) -> String? {
        let remembered = realm == .midi ? lastMIDIProfileName : lastStandardProfileName
        guard let remembered, profileStates[remembered]?.realm == realm else { return nil }
        return remembered
    }

    private func save() {
        saveActiveProfile()
        saveAllProfiles()
    }

    private func saveHIDBindings() {
        saveActiveProfile()
        saveAllProfiles()
    }

    private func saveActiveProfile() {
        saveActiveProfile(named: profileName)
    }

    private func saveActiveProfile(named name: String) {
        guard availableProfiles.contains(name) else { return }
        profileStates[name] = ProfileState(
            mappings: mappings,
            // Legacy decode compatibility only. Current persistence writes
            // hardwareLayouts at the top level and ProfileState.encode omits
            // this field entirely.
            hidBindings: [:],
            standardButtonTitles: activeRealm == .standard ? standardButtonTitles : [:],
            remoteModifierControls: activeRealm == .standard ? remoteModifierControls : [],
            modifierColors: activeRealm == .standard ? modifierColors : [:],
            realm: activeRealm,
            midiSettings: activeRealm == .midi ? midiSettings : nil
        )
    }

    private func activateProfile(named name: String) {
        let previousRealm = activeRealm
        guard let state = profileStates[name] else {
            mappings = [:]
            refreshActiveHardwareLayoutBindings()
            standardButtonTitles = [:]
            remoteModifierControls = []
            unavailableRemoteModifierControls = []
            modifierColors = [:]
            selectedMappingModifiers = []
            activeRealm = .standard
            if previousRealm != activeRealm {
                invalidateStandardF13F22PresetLiveVerification()
            }
            midiSettings = nil
            syncMIDIOverlay()
            return
        }
        mappings = state.mappings
        refreshActiveHardwareLayoutBindings()
        standardButtonTitles = state.standardButtonTitles
        remoteModifierControls = state.remoteModifierControls.filter(\.isModifierEligible)
        refreshModifierAvailability()
        modifierColors = state.modifierColors.filter { $0.key.isModifierEligible }
        selectedMappingModifiers = []
        activeRealm = state.realm
        if previousRealm != activeRealm {
            // The preset is Standard-only. Returning from MIDI must require
            // fresh evidence in the Standard resolver, even on the same HID
            // connection, so the UI never carries a stale cross-realm claim.
            invalidateStandardF13F22PresetLiveVerification()
        }
        refreshModifierAvailability()
        midiSettings = state.midiSettings
        if !unavailableRemoteModifierControls.isEmpty {
            let controls = RemoteControl.allCases
                .filter { unavailableRemoteModifierControls.contains($0) }
                .map(\.rawValue)
                .joined(separator: ", ")
            lastActionResult = .failure(
                "Modifier designation for \(controls) is unavailable in this hardware layout because a learned HID input is missing. Learn each input in Status & Input to reactivate it."
            )
        }
        if activeRealm == .midi {
            lastMIDIProfileName = name
            midiLocked = true
        } else {
            lastStandardProfileName = name
            midiLocked = false
        }
        syncMIDIOverlay()
        if previousRealm == .midi, activeRealm == .standard {
            inputOverlay.showStatusNotice(
                title: "XP[d] UNLOCKED",
                message: "Standard mappings active",
                systemImage: "lock.open"
            )
        }
    }

    private func saveAllProfiles() {
        guard shouldPersistProfilesAfterLoad else { return }
        do {
            let persisted = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    guard let state = profileStates[name] else { return nil }
                    return PersistedProfile(name: name, state: state)
                },
                hardwareLayouts: hardwareLayouts.map { layout in
                    PersistedHardwareLayout(
                        id: layout.id,
                        name: layout.name,
                        bindings: Self.bindingDictionary(from: layout.bindings)
                    )
                },
                activeHardwareLayoutID: activeHardwareLayoutID,
                activeProfileName: profileName,
                activeRealm: activeRealm,
                lastStandardProfileName: lastStandardProfileName,
                lastMIDIProfileName: lastMIDIProfileName,
                midiLocked: midiLocked,
                workspaceLockControl: workspaceLockControl
            )
            let data = try JSONEncoder().encode(persisted)
            defaults.set(data, forKey: profilesDefaultsKey)
            defaults.set(true, forKey: profilesMigrationKey)
            lastPersistenceResult = .saved
        } catch {
            lastPersistenceResult = .failed("Could not save profiles: \(error.localizedDescription)")
        }
    }

    private func installHardwareLayouts(
        _ layouts: [XPdConfiguration.HardwareLayout],
        activeID: String?
    ) {
        invalidateStandardKLayerLiveVerification()
        let normalized = layouts.map { layout in
            Self.makeHardwareLayout(
                id: layout.id,
                name: layout.name,
                bindings: Self.normalizedHIDBindings(Self.bindingDictionary(from: layout.bindings))
            )
        }
        hardwareLayouts = normalized.isEmpty
            ? [Self.makeHardwareLayout(id: Self.defaultHardwareLayoutID, name: "Default remote", bindings: Self.defaultHIDBindings)]
            : normalized
        activeHardwareLayoutID = activeID.flatMap { id in
            hardwareLayouts.contains(where: { $0.id == id }) ? id : nil
        } ?? hardwareLayouts.first?.id ?? Self.defaultHardwareLayoutID
        refreshActiveHardwareLayoutBindings()
    }

    private func installHardwareLayoutsFromPersisted(
        _ layouts: [PersistedHardwareLayout],
        activeID: String?,
        profileName: String,
        states: [String: ProfileState]
    ) {
        if !layouts.isEmpty {
            installHardwareLayouts(
                layouts.map {
                    Self.makeHardwareLayout(id: $0.id, name: $0.name, bindings: $0.bindings)
                },
                activeID: activeID
            )
            return
        }
        installHardwareLayoutsFromLegacyProfiles(states, activeProfileName: profileName)
    }

    /// Exact normalized equality is the migration key. Every divergent
    /// per-profile binding set becomes a named layout; identical sets are
    /// represented once, with the active profile's set selecting the active
    /// layout deterministically.
    private func installHardwareLayoutsFromLegacyProfiles(
        _ states: [String: ProfileState],
        activeProfileName: String
    ) {
        var layouts: [(origin: String, bindings: [RemoteControl: String])] = []
        for profileName in availableProfiles {
            let bindings = Self.normalizedHIDBindings(states[profileName]?.hidBindings ?? [:])
            guard !layouts.contains(where: { Self.bindingSetsEqual($0.bindings, bindings) }) else { continue }
            layouts.append((profileName, bindings))
        }
        if layouts.isEmpty {
            layouts = [("Default remote", Self.defaultHIDBindings)]
        }

        let activeBindings = Self.normalizedHIDBindings(states[activeProfileName]?.hidBindings ?? [:])
        let converted = layouts.map { item in
            Self.makeHardwareLayout(
                id: Self.stableHardwareLayoutID(for: item.bindings),
                name: "Migrated from \(item.origin)",
                bindings: item.bindings
            )
        }
        let activeID = converted.first(where: {
            Self.bindingSetsEqual(Self.bindingDictionary(from: $0.bindings), activeBindings)
        })?.id
        installHardwareLayouts(converted, activeID: activeID)
    }

    private func loadOrMigrateProfiles() -> Bool {
        // A present v9 payload is authoritative. Never fall back to an older
        // backup when it is corrupt: doing so could silently roll the user
        // back to stale state and overwrite the only newer bytes.
        if let data = defaults.data(forKey: profilesDefaultsKey) {
            guard let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
                  decoded.version == XPdConfiguration.currentVersion,
                  Self.hasValidOriginalHardwareLayoutBindings(decoded.hardwareLayouts),
                  isValidPersistedProfiles(decoded),
                  let decodedStates = Self.uniqueProfileStates(from: decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not read the saved v9 configuration. Its original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            installHardwareLayoutsFromPersisted(
                decoded.hardwareLayouts,
                activeID: decoded.activeHardwareLayoutID,
                profileName: decoded.activeProfileName,
                states: profileStates
            )
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            defaults.set(true, forKey: profilesMigrationKey)
            return false
        }

        // v8 is the last profile-owned HID schema. Preserve all profile
        // metadata, then group its exact binding sets into top-level layouts.
        // The v8 payload remains untouched if this conversion cannot be
        // validated and written as v9.
        if let data = defaults.data(forKey: previousProfilesDefaultsKey) {
            guard let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
                  decoded.version == XPdConfiguration.preHardwareLayoutsVersion,
                  let decodedStates = Self.uniqueProfileStates(from: decoded.profiles),
                  Self.hasValidOriginalLegacyHIDBindings(decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v8 configuration. The original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: decoded.activeProfileName)
            let upgraded = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    profileStates[name].map { PersistedProfile(name: name, state: $0) }
                },
                hardwareLayouts: hardwareLayouts.map {
                    PersistedHardwareLayout(
                        id: $0.id,
                        name: $0.name,
                        bindings: Self.bindingDictionary(from: $0.bindings)
                    )
                },
                activeHardwareLayoutID: activeHardwareLayoutID,
                activeProfileName: decoded.activeProfileName,
                activeRealm: decoded.activeRealm,
                lastStandardProfileName: decoded.lastStandardProfileName,
                lastMIDIProfileName: decoded.lastMIDIProfileName,
                midiLocked: decoded.midiLocked,
                workspaceLockControl: decoded.workspaceLockControl
            )
            guard isValidPersistedProfiles(upgraded) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v8 configuration. The original data was left unchanged."
                )
            }
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            saveAllProfiles()
            return false
        }

        // v7 already contains exact K layers and remote modifier designations
        // but predates modifier colours. Preserve any state fields present and
        // assign Orange to every designated control without an assignment.
        if let data = defaults.data(forKey: preModifierColorsProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.preModifierColorsVersion {
            guard let decodedStates = Self.uniqueProfileStates(from: decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v7 configuration. The original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            for name in availableProfiles {
                guard var state = profileStates[name] else { continue }
                var colors = state.modifierColors
                for modifier in state.remoteModifierControls where colors[modifier] == nil {
                    colors[modifier] = .orange
                }
                state.modifierColors = colors
                profileStates[name] = state
            }
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: decoded.activeProfileName)
            let upgraded = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    profileStates[name].map { PersistedProfile(name: name, state: $0) }
                },
                hardwareLayouts: hardwareLayouts.map {
                    PersistedHardwareLayout(
                        id: $0.id,
                        name: $0.name,
                        bindings: Self.bindingDictionary(from: $0.bindings)
                    )
                },
                activeHardwareLayoutID: activeHardwareLayoutID,
                activeProfileName: decoded.activeProfileName,
                activeRealm: decoded.activeRealm,
                lastStandardProfileName: decoded.lastStandardProfileName,
                lastMIDIProfileName: decoded.lastMIDIProfileName,
                midiLocked: decoded.midiLocked,
                workspaceLockControl: decoded.workspaceLockControl
            )
            guard isValidPersistedProfiles(upgraded) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v7 configuration. The original data was left unchanged."
                )
            }
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            saveAllProfiles()
            return false
        }

        // v6 already contains exact K layers and legacy keyboard/F-key trigger
        // gates. Copy the decoded state and assign Orange to any designated
        // modifiers before writing the v8 payload so no state is lost.
        if let data = defaults.data(forKey: preRemoteTriggerKeysProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.preRemoteTriggerKeysVersion {
            guard let decodedStates = Self.uniqueProfileStates(from: decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v6 configuration. The original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            for name in availableProfiles {
                guard var state = profileStates[name] else { continue }
                var colors = state.modifierColors
                for modifier in state.remoteModifierControls where colors[modifier] == nil {
                    colors[modifier] = .orange
                }
                state.modifierColors = colors
                profileStates[name] = state
            }
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: decoded.activeProfileName)
            let upgraded = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    profileStates[name].map { PersistedProfile(name: name, state: $0) }
                },
                hardwareLayouts: hardwareLayouts.map {
                    PersistedHardwareLayout(
                        id: $0.id,
                        name: $0.name,
                        bindings: Self.bindingDictionary(from: $0.bindings)
                    )
                },
                activeHardwareLayoutID: activeHardwareLayoutID,
                activeProfileName: decoded.activeProfileName,
                activeRealm: decoded.activeRealm,
                lastStandardProfileName: decoded.lastStandardProfileName,
                lastMIDIProfileName: decoded.lastMIDIProfileName,
                midiLocked: decoded.midiLocked,
                workspaceLockControl: decoded.workspaceLockControl
            )
            guard isValidPersistedProfiles(upgraded) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v6 configuration. The original data was left unchanged."
                )
            }
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            saveAllProfiles()
            return false
        }

        // v5 persisted the current dynamic profile/realm/title shape but
        // predates remote modifier designations. ProfileState's compatibility
        // decoder gives every migrated state an empty modifier set, then
        // saveAllProfiles writes the explicit v7 payload.
        if let data = defaults.data(forKey: preRemoteLayersProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.preRemoteLayersVersion {
            guard let decodedStates = Self.uniqueProfileStates(from: decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v5 configuration. The original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            for name in availableProfiles {
                guard var state = profileStates[name] else { continue }
                state.remoteModifierControls = []
                state.modifierColors = [:]
                profileStates[name] = state
            }
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: decoded.activeProfileName)
            let upgraded = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    profileStates[name].map { PersistedProfile(name: name, state: $0) }
                },
                hardwareLayouts: hardwareLayouts.map {
                    PersistedHardwareLayout(
                        id: $0.id,
                        name: $0.name,
                        bindings: Self.bindingDictionary(from: $0.bindings)
                    )
                },
                activeHardwareLayoutID: activeHardwareLayoutID,
                activeProfileName: decoded.activeProfileName,
                activeRealm: decoded.activeRealm,
                lastStandardProfileName: decoded.lastStandardProfileName,
                lastMIDIProfileName: decoded.lastMIDIProfileName,
                midiLocked: decoded.midiLocked,
                workspaceLockControl: decoded.workspaceLockControl
            )
            guard isValidPersistedProfiles(upgraded) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v5 configuration. The original data was left unchanged."
                )
            }
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            saveAllProfiles()
            return false
        }

        // v4 had the current realm shape but predates Standard button titles.
        if let data = defaults.data(forKey: preTitlesProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.preTitlesVersion {
            guard let decodedStates = Self.uniqueProfileStates(from: decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v4 configuration. The original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            for name in availableProfiles {
                guard var state = profileStates[name] else { continue }
                state.standardButtonTitles = [:]
                state.remoteModifierControls = []
                state.modifierColors = [:]
                profileStates[name] = state
            }
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: decoded.activeProfileName)
            let upgraded = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    profileStates[name].map { PersistedProfile(name: name, state: $0) }
                },
                hardwareLayouts: hardwareLayouts.map {
                    PersistedHardwareLayout(
                        id: $0.id,
                        name: $0.name,
                        bindings: Self.bindingDictionary(from: $0.bindings)
                    )
                },
                activeHardwareLayoutID: activeHardwareLayoutID,
                activeProfileName: decoded.activeProfileName,
                activeRealm: decoded.activeRealm,
                lastStandardProfileName: decoded.lastStandardProfileName,
                lastMIDIProfileName: decoded.lastMIDIProfileName,
                midiLocked: decoded.midiLocked,
                workspaceLockControl: decoded.workspaceLockControl
            )
            guard isValidPersistedProfiles(upgraded) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v4 configuration. The original data was left unchanged."
                )
            }
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            saveAllProfiles()
            return false
        }

        // v3 persisted dynamic profiles had the same mapping/HID shape but
        // no realm or MIDI fields. Decode them through the compatibility
        // defaults in ProfileState and explicitly upgrade every profile to
        // the standard realm.
        if let data = defaults.data(forKey: legacyProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.previousVersion {
            guard let decodedStates = Self.uniqueProfileStates(from: decoded.profiles) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v3 configuration. The original data was left unchanged."
                )
            }
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = decodedStates
            for name in availableProfiles {
                guard var state = profileStates[name] else { continue }
                state.standardButtonTitles = [:]
                state.remoteModifierControls = []
                state.modifierColors = [:]
                state.realm = .standard
                state.midiSettings = nil
                profileStates[name] = state
            }
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: decoded.activeProfileName)
            guard isValidPersistedProfiles(
                PersistedProfiles(
                    version: XPdConfiguration.currentVersion,
                    profiles: availableProfiles.compactMap { name in
                        profileStates[name].map { PersistedProfile(name: name, state: $0) }
                    },
                    hardwareLayouts: hardwareLayouts.map {
                        PersistedHardwareLayout(
                            id: $0.id,
                            name: $0.name,
                            bindings: Self.bindingDictionary(from: $0.bindings)
                        )
                    },
                    activeHardwareLayoutID: activeHardwareLayoutID,
                    activeProfileName: decoded.activeProfileName
                )
            ) else {
                return failLocalProfilesLoad(
                    "Could not migrate the saved v3 configuration. The original data was left unchanged."
                )
            }
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = .standard
            loadedLastStandardProfileName = decoded.activeProfileName
            loadedLastMIDIProfileName = nil
            loadedMIDIIsLocked = false
            loadedWorkspaceLockControl = .k3
            saveAllProfiles()
            return false
        }

        // Version 2 persisted profile state as a dictionary with the exact
        // historical three-profile set. Restore that canonical order while
        // preserving every stored mapping and HID binding.
        if let data = defaults.data(forKey: legacyLegacyProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: ProfileState].self, from: data),
           let migrated = migrateLegacyPersistedProfiles(decoded) {
            availableProfiles = migrated.order
            profileStates = migrated.states
            let legacyActiveProfile = defaults.string(forKey: profileNameDefaultsKey)
                .flatMap { availableProfiles.contains($0) ? $0 : nil } ?? "Global"
            loadedProfileName = legacyActiveProfile
            installHardwareLayoutsFromLegacyProfiles(
                profileStates,
                activeProfileName: legacyActiveProfile
            )
            defaults.set(true, forKey: profilesMigrationKey)
            saveAllProfiles()
            return false
        }

        // The marker prevents a later launch from re-reading legacy values if
        // the new payload was removed or became unreadable after migration.
        if defaults.bool(forKey: profilesMigrationKey) {
            profileStates = Self.defaultProfileStates()
            availableProfiles = XPdConfiguration.defaultProfileNames
            installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: "Global")
            return false
        }

        var migratedProfiles = Self.defaultProfileStates()
        var migratedLegacyState = false
        if let data = defaults.data(forKey: defaultsKey),
           let legacyMappings = try? JSONDecoder().decode([MappingKey: Mapping].self, from: data) {
            migratedProfiles["Global"]?.mappings = legacyMappings
            migratedLegacyState = true
        }
        if let data = defaults.data(forKey: hidBindingsKey),
           let legacyBindings = try? JSONDecoder().decode([RemoteControl: String].self, from: data) {
            var globalBindings = legacyBindings.mapValues(Self.migrateHIDSignature)
            for (control, signature) in Self.defaultHIDBindings
            where globalBindings[control] == nil && !globalBindings.values.contains(signature) {
                globalBindings[control] = signature
            }
            migratedProfiles["Global"]?.hidBindings = globalBindings
            migratedLegacyState = true
        }

        profileStates = migratedProfiles
        availableProfiles = XPdConfiguration.defaultProfileNames
        installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: "Global")
        defaults.set(true, forKey: profilesMigrationKey)
        saveAllProfiles()
        return migratedLegacyState
    }

    private func isValidPersistedProfiles(_ persisted: PersistedProfiles) -> Bool {
        guard persisted.version == XPdConfiguration.currentVersion,
              !persisted.hardwareLayouts.isEmpty,
              let activeHardwareLayoutID = persisted.activeHardwareLayoutID,
              !activeHardwareLayoutID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              persisted.hardwareLayouts.contains(where: { $0.id == activeHardwareLayoutID }) else {
            return false
        }
        let configuration = XPdConfiguration(
            profiles: persisted.profiles.map { profile in
                XPdConfiguration.Profile(
                    name: profile.name,
                    mappings: Self.mappingEntries(from: profile.state.mappings),
                    hidBindings: [],
                    realm: profile.state.realm,
                    midiSettings: profile.state.midiSettings,
                    standardButtonTitles: profile.state.standardButtonTitles.map {
                        XPdConfiguration.StandardButtonTitleEntry(control: $0.key, title: $0.value)
                    },
                    remoteModifierControls: profile.state.remoteModifierControls,
                    modifierColors: Self.modifierColorEntries(from: profile.state.modifierColors)
                )
            },
            profileName: persisted.activeProfileName,
            showsInputOverlay: showsInputOverlay,
            activeRealm: persisted.activeRealm,
            lastStandardProfileName: persisted.lastStandardProfileName,
            lastMIDIProfileName: persisted.lastMIDIProfileName,
            midiLocked: persisted.midiLocked,
            workspaceLockControl: persisted.workspaceLockControl,
            hardwareLayouts: persisted.hardwareLayouts.map {
                Self.makeHardwareLayout(id: $0.id, name: $0.name, bindings: $0.bindings)
            },
            activeHardwareLayoutID: activeHardwareLayoutID
        )
        return (try? configuration.validate()) != nil
    }

    private static func uniqueProfileStates(
        from profiles: [PersistedProfile]
    ) -> [String: ProfileState]? {
        var states: [String: ProfileState] = [:]
        for profile in profiles {
            guard states[profile.name] == nil else { return nil }
            states[profile.name] = profile.state
        }
        return states
    }

    /// Local v8 stores profile-owned HID dictionaries. Validate the exact
    /// decoded values before whitespace/repeated-prefix normalization so an
    /// invalid entry cannot disappear while layouts are grouped.
    private static func hasValidOriginalLegacyHIDBindings(
        _ profiles: [PersistedProfile]
    ) -> Bool {
        profiles.allSatisfy { hasValidOriginalHIDBindingValues($0.state.hidBindings) }
    }

    /// Schema v9 owns HID identity at the layout level. Validate those raw
    /// values before `makeHardwareLayout` normalizes them, otherwise an empty
    /// string could be silently discarded and a corrupt v9 payload rewritten.
    private static func hasValidOriginalHardwareLayoutBindings(
        _ layouts: [PersistedHardwareLayout]
    ) -> Bool {
        layouts.allSatisfy { hasValidOriginalHIDBindingValues($0.bindings) }
    }

    private static func hasValidOriginalHIDBindingValues(
        _ bindings: [RemoteControl: String]
    ) -> Bool {
        var rawSignatures = Set<String>()
        var normalizedSignatures = Set<String>()
        for signature in bindings.values {
            guard !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rawSignatures.insert(signature).inserted else {
                return false
            }
            let normalized = normalizedHIDSignature(signature)
            guard !normalized.isEmpty,
                  normalizedSignatures.insert(normalized).inserted else {
                return false
            }
        }
        return true
    }

    /// A corrupt local payload must remain recoverable. Keep its bytes and
    /// make the in-memory fallback non-persisting until the user explicitly
    /// repairs preferences outside this launch.
    private func failLocalProfilesLoad(_ message: String) -> Bool {
        shouldPersistProfilesAfterLoad = false
        lastPersistenceResult = .failed(message)
        availableProfiles = XPdConfiguration.defaultProfileNames
        profileStates = Self.defaultProfileStates()
        installHardwareLayoutsFromLegacyProfiles(profileStates, activeProfileName: "Global")
        return false
    }

    private func validatedNewProfileName(_ rawName: String) throws -> String {
        try validatedProfileName(rawName, excluding: nil)
    }

    private func validatedProfileName(_ rawName: String, excluding excludedName: String?) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else {
            throw ProfileError.invalidName(rawName)
        }
        let foldedName = XPdConfiguration.profileNameComparisonKey(name)
        guard !availableProfiles.contains(where: {
            $0 != excludedName && XPdConfiguration.profileNameComparisonKey($0) == foldedName
        }) else {
            throw ProfileError.duplicateName(name)
        }
        return name
    }

    private func migrateLegacyPersistedProfiles(
        _ decoded: [String: ProfileState]
    ) -> (order: [String], states: [String: ProfileState])? {
        let order = XPdConfiguration.defaultProfileNames
        guard Set(decoded.keys) == Set(order) else { return nil }
        return (order: order, states: decoded)
    }

    private static func defaultProfileStates() -> [String: ProfileState] {
        Dictionary(uniqueKeysWithValues: XPdConfiguration.defaultProfileNames.map { ($0, defaultProfileState()) })
    }

    private static func defaultProfileState() -> ProfileState {
        ProfileState(mappings: [:], hidBindings: defaultHIDBindings)
    }

    private static func defaultMIDIProfileSettings() -> MIDIProfileSettings {
        let primary = (1...10).map { index in
            MIDIButtonMappingEntry(
                control: RemoteControl.allCases[index - 1],
                mapping: MIDIButtonMapping(
                    kind: .note,
                    outputPort: .performance,
                    channel: 1,
                    note: 35 + index,
                    velocity: 100,
                    releaseVelocity: 0,
                    interaction: .momentary,
                    label: "K\(index)"
                )
            )
        }
        return MIDIProfileSettings(
            fnControl: .k10,
            primaryButtons: primary,
            functionButtons: [],
            primaryWheel: MIDIWheelMapping(kind: .pitchBendNudgeReturn, outputPort: .performance),
            functionWheel: MIDIWheelMapping(kind: .absoluteCC, outputPort: .control, controller: 1)
        )
    }

    private static func midiProfileSettings(for template: MIDIProfileTemplate) -> MIDIProfileSettings {
        switch template {
        case .performancePads:
            return defaultMIDIProfileSettings()
        case .abletonController:
            let primary = (1...10).map { index in
                MIDIButtonMappingEntry(
                    control: RemoteControl.allCases[index - 1],
                    mapping: MIDIButtonMapping(
                        kind: .cc,
                        outputPort: .control,
                        channel: 16,
                        controller: 19 + index,
                        pressValue: 127,
                        releaseValue: 0,
                        interaction: .momentary,
                        label: "Ableton K\(index)"
                    )
                )
            }
            let function = (1...10).map { index in
                MIDIButtonMappingEntry(
                    control: RemoteControl.allCases[index - 1],
                    mapping: MIDIButtonMapping(
                        kind: .note,
                        outputPort: .control,
                        channel: 16,
                        note: 117 + index,
                        velocity: 127,
                        releaseVelocity: 0,
                        interaction: .momentary,
                        label: "Ableton Fn K\(index)"
                    )
                )
            }
            return MIDIProfileSettings(
                fnControl: .k10,
                primaryButtons: primary,
                functionButtons: function,
                primaryWheel: MIDIWheelMapping(
                    kind: .relativeCC,
                    outputPort: .control,
                    channel: 16,
                    controller: 16,
                    relativeEncoding: .twosComplement,
                    clockwiseValue: 1,
                    counterClockwiseValue: 127,
                    label: "Ableton Encoder"
                ),
                functionWheel: MIDIWheelMapping(
                    kind: .relativeCC,
                    outputPort: .control,
                    channel: 16,
                    controller: 17,
                    relativeEncoding: .twosComplement,
                    clockwiseValue: 1,
                    counterClockwiseValue: 127,
                    label: "Ableton Fn Encoder"
                )
            )
        }
    }

    private static func mappingEntries(from mappings: [MappingKey: Mapping]) -> [XPdConfiguration.MappingEntry] {
        var keys = Set<MappingKey>()
        for control in RemoteControl.allCases {
            for gesture in GestureKind.allCases {
                keys.insert(MappingKey(control: control, gesture: gesture))
            }
        }
        keys.formUnion(mappings.keys)
        return keys.sorted { lhs, rhs in
            let lhsControl = RemoteControl.allCases.firstIndex(of: lhs.control) ?? Int.max
            let rhsControl = RemoteControl.allCases.firstIndex(of: rhs.control) ?? Int.max
            if lhsControl != rhsControl { return lhsControl < rhsControl }
            let lhsGesture = GestureKind.allCases.firstIndex(of: lhs.gesture) ?? Int.max
            let rhsGesture = GestureKind.allCases.firstIndex(of: rhs.gesture) ?? Int.max
            if lhsGesture != rhsGesture { return lhsGesture < rhsGesture }
            let lhsModifiers = RemoteControl.allCases.filter { lhs.modifierControls.contains($0) }
            let rhsModifiers = RemoteControl.allCases.filter { rhs.modifierControls.contains($0) }
            return lhsModifiers.map(\.rawValue).joined() < rhsModifiers.map(\.rawValue).joined()
        }.map { key in
            XPdConfiguration.MappingEntry(
                control: key.control,
                gesture: key.gesture,
                mapping: mappings[key] ?? Mapping(),
                modifierControls: key.modifierControls
            )
        }
    }

    private static func standardButtonTitleEntries(
        from titles: [RemoteControl: String]
    ) -> [XPdConfiguration.StandardButtonTitleEntry] {
        let controlIndex: (RemoteControl) -> Int = {
            RemoteControl.allCases.firstIndex(of: $0) ?? Int.max
        }
        return titles
            .filter { control, title in
                control.isMIDIButton && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { lhs, rhs in
                controlIndex(lhs.key) < controlIndex(rhs.key)
            }
            .map { control, title in
                XPdConfiguration.StandardButtonTitleEntry(
                    control: control,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private static func modifierColorEntries(
        from colors: [RemoteControl: ModifierColor]
    ) -> [XPdConfiguration.ModifierColorEntry] {
        colors
            .filter { $0.key.isModifierEligible }
            .sorted {
                let lhs = RemoteControl.allCases.firstIndex(of: $0.key) ?? Int.max
                let rhs = RemoteControl.allCases.firstIndex(of: $1.key) ?? Int.max
                return lhs < rhs
            }
            .map {
                XPdConfiguration.ModifierColorEntry(control: $0.key, color: $0.value)
            }
    }

    private static func hidBindingEntries(from bindings: [RemoteControl: String]) -> [XPdConfiguration.HIDBindingEntry] {
        bindings.map { control, signature in
            XPdConfiguration.HIDBindingEntry(control: control, signature: signature)
        }
    }

    private static let defaultHardwareLayoutID = "default-remote"

    private static func bindingDictionary(
        from entries: [XPdConfiguration.HIDBindingEntry]
    ) -> [RemoteControl: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.control, $0.signature) })
    }

    private static func makeHardwareLayout(
        id: String,
        name: String,
        bindings: [RemoteControl: String]
    ) -> XPdConfiguration.HardwareLayout {
        XPdConfiguration.HardwareLayout(
            id: id,
            name: name,
            bindings: hidBindingEntries(from: normalizedHIDBindings(bindings))
        )
    }

    private static func normalizedHIDBindings(
        _ bindings: [RemoteControl: String]
    ) -> [RemoteControl: String] {
        bindings.reduce(into: [:]) { result, pair in
            let signature = normalizedHIDSignature(pair.value)
            guard !signature.isEmpty else { return }
            result[pair.key] = signature
        }
    }

    private static func normalizedHIDSignature(_ signature: String) -> String {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // HIDService already emits canonical uppercase hex. Preserve that
        // spelling in live state and exports; normalization here is limited
        // to the historical repeated report-6 prefix and surrounding space.
        return migrateHIDSignature(trimmed)
    }

    private static func bindingSetsEqual(
        _ lhs: [RemoteControl: String],
        _ rhs: [RemoteControl: String]
    ) -> Bool {
        normalizedHIDBindings(lhs) == normalizedHIDBindings(rhs)
    }

    private static func stableHardwareLayoutID(
        for bindings: [RemoteControl: String]
    ) -> String {
        let canonical = RemoteControl.allCases.compactMap { control in
            bindings[control].map { "\(control.rawValue)=\(normalizedHIDSignature($0))" }
        }.joined(separator: "|")
        // FNV-1a keeps IDs deterministic without introducing a crypto
        // dependency into the local preferences format.
        var hash: UInt64 = 14695981039346656037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "layout-\(String(hash, radix: 16))"
    }

    private static func configurationErrorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "Configuration could not be read."
    }

    /// ACK05 plug-and-play shortcuts documented by XPPen. Learned bindings are
    /// loaded first and therefore always take precedence over these defaults.
    private static let defaultHIDBindings: [RemoteControl: String] = [
        .k1: "r6:01 12 00 00 00 00 00",
        .k2: "r6:01 11 00 00 00 00 00",
        .k3: "r6:00 3E 00 00 00 00 00",
        .k4: "r6:02 00 00 00 00 00 00",
        .k5: "r6:01 00 00 00 00 00 00",
        .k6: "r6:04 00 00 00 00 00 00",
        .k7: "r6:01 16 00 00 00 00 00",
        .k8: "r6:01 1D 00 00 00 00 00",
        .k9: "r6:00 2C 00 00 00 00 00",
        .k10: "r6:03 1D 00 00 00 00 00",
        .wheelCW: "wheel:+",
        .wheelCCW: "wheel:-",
        .wheelCenter: "wheel:center"
    ]

    private static func migrateHIDSignature(_ signature: String) -> String {
        signature.replacingOccurrences(of: "r6:06 ", with: "r6:", options: .anchored)
    }

    private static func closestInputOverlayDuration(to duration: Double) -> Double {
        inputOverlayDurationOptions.min(by: { abs($0 - duration) < abs($1 - duration) }) ?? 4
    }

    static func normalizedStandardModifierHoldThreshold(_ threshold: Double) -> Double {
        guard threshold.isFinite else { return defaultStandardModifierHoldThreshold }
        let clamped = min(max(threshold, 0.2), 1.5)
        return (clamped * 10).rounded() / 10
    }
}
