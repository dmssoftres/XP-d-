import AppKit
import Foundation
import Observation

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

@Observable
@MainActor
final class MappingStore {
    typealias ActionExecutionOverride = @MainActor (
        _ mapping: Mapping,
        _ completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) -> Void

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

    var selectedControl: RemoteControl = .k1
    var selectedGesture: GestureKind = .tap
    var selectedMIDILayer: MIDIMappingLayer = .primary
    var profileName = "Global" {
        didSet {
            guard availableProfiles.contains(profileName) else {
                profileName = oldValue
                return
            }
            guard profileName != oldValue, !isReplacingConfiguration else { return }
            cancelPendingButtonGestures()
            resetMIDIState()
            saveActiveProfile(named: oldValue)
            activateProfile(named: profileName)
            defaults.set(profileName, forKey: profileNameDefaultsKey)
            saveAllProfiles()
        }
    }
    private(set) var mappings: [MappingKey: Mapping] = [:]
    private(set) var hidBindings: [RemoteControl: String] = [:]
    /// Optional labels for Standard-mode K buttons. MIDI profiles never
    /// populate this dictionary; titles are shared across gestures.
    private(set) var standardButtonTitles: [RemoteControl: String] = [:]
    private(set) var learningControl: RemoteControl?
    private(set) var liveControl: RemoteControl?
    private(set) var lastActionResult: ActionExecutionResult?
    private(set) var lastConfigurationResult: ConfigurationOperationResult = .idle
    private(set) var lastPersistenceResult: PersistenceResult = .idle
    private(set) var lastMIDIMessage: MIDIOutputService.SentMessage?
    private(set) var lastMIDIError: String?
    private(set) var lastMIDIStatus: String?
    private(set) var midiEndpointStatuses: [MIDIOutputPort: MIDIOutputService.EndpointStatus] = [:]
    private(set) var midiMonitorEvents: [MIDIOutputService.MonitorEvent] = []
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

    private struct ProfileState: Codable, Equatable {
        var mappings: [MappingKey: Mapping]
        var hidBindings: [RemoteControl: String]
        var standardButtonTitles: [RemoteControl: String]
        var realm: ProfileRealm
        var midiSettings: MIDIProfileSettings?

        init(
            mappings: [MappingKey: Mapping],
            hidBindings: [RemoteControl: String],
            standardButtonTitles: [RemoteControl: String] = [:],
            realm: ProfileRealm = .standard,
            midiSettings: MIDIProfileSettings? = nil
        ) {
            self.mappings = mappings
            self.hidBindings = hidBindings
            self.standardButtonTitles = standardButtonTitles
            self.realm = realm
            self.midiSettings = midiSettings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mappings = try container.decodeIfPresent([MappingKey: Mapping].self, forKey: .mappings) ?? [:]
            hidBindings = try container.decodeIfPresent([RemoteControl: String].self, forKey: .hidBindings) ?? [:]
            standardButtonTitles = try container.decodeIfPresent([RemoteControl: String].self, forKey: .standardButtonTitles) ?? [:]
            realm = try container.decodeIfPresent(ProfileRealm.self, forKey: .realm) ?? .standard
            midiSettings = try container.decodeIfPresent(MIDIProfileSettings.self, forKey: .midiSettings)
        }

        private enum CodingKeys: String, CodingKey {
            case mappings, hidBindings, standardButtonTitles, realm, midiSettings
        }
    }

    private struct PersistedProfile: Codable, Equatable {
        let name: String
        let state: ProfileState
    }

    private struct PersistedProfiles: Codable, Equatable {
        let version: Int
        let profiles: [PersistedProfile]
        let activeProfileName: String
        let activeRealm: ProfileRealm
        let lastStandardProfileName: String?
        let lastMIDIProfileName: String?
        let midiLocked: Bool
        let workspaceLockControl: RemoteControl

        init(
            version: Int,
            profiles: [PersistedProfile],
            activeProfileName: String,
            activeRealm: ProfileRealm = .standard,
            lastStandardProfileName: String? = nil,
            lastMIDIProfileName: String? = nil,
            midiLocked: Bool = false,
            workspaceLockControl: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl
        ) {
            self.version = version
            self.profiles = profiles
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
            activeProfileName = try container.decodeIfPresent(String.self, forKey: .activeProfileName) ?? "Global"
            activeRealm = try container.decodeIfPresent(ProfileRealm.self, forKey: .activeRealm) ?? .standard
            lastStandardProfileName = try container.decodeIfPresent(String.self, forKey: .lastStandardProfileName)
            lastMIDIProfileName = try container.decodeIfPresent(String.self, forKey: .lastMIDIProfileName)
            midiLocked = try container.decodeIfPresent(Bool.self, forKey: .midiLocked) ?? false
            workspaceLockControl = try container.decodeIfPresent(RemoteControl.self, forKey: .workspaceLockControl)
                ?? XPdConfiguration.defaultWorkspaceLockControl
        }

        private enum CodingKeys: String, CodingKey {
            case version, profiles, activeProfileName, activeRealm
            case lastStandardProfileName, lastMIDIProfileName, midiLocked, workspaceLockControl
        }
    }

    private let defaults: UserDefaults
    private let profilesDefaultsKey = "XPd.profiles.v5"
    private let previousProfilesDefaultsKey = "XPd.profiles.v4"
    private let legacyProfilesDefaultsKey = "XPd.profiles.v3"
    private let legacyLegacyProfilesDefaultsKey = "XPd.profiles.v2"
    private let profilesMigrationKey = "XPd.profiles.v5.migrated"
    private let defaultsKey = "XPd.mappings.v1"
    private let hidBindingsKey = "XPd.hidBindings.v1"
    private let profileNameDefaultsKey = "XPd.profileName.v1"
    private let inputOverlayDefaultsKey = "XPd.showsInputOverlay.v1"
    private let inputOverlayDurationDefaultsKey = "XPd.inputOverlayDuration.v1"
    private let wheelSensitivityDefaultsKey = "XPd.wheelSensitivity.v1"
    private var profileStates: [String: ProfileState] = [:]
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
    private var midiControlLayers: [RemoteControl: Int] = [:]
    private var centerFnHoldTask: Task<Void, Never>?
    private var centerFnHoldGeneration = 0
    /// The keyboard-shortcut editor temporarily owns K-button input while it
    /// records a sequence.  Keeping this at the store/HID boundary prevents a
    /// captured press from also executing its configured mapping.
    private var shortcutCaptureHandler: ((RemoteControl) -> Void)?
    private let midiOutputService: MIDIOutputService
    private let midiCommandTail = MIDICommandTail()
    private let midiShutdownGate = MIDIShutdownGate()
    private let actionRunner = ActionRunner()
    private let actionExecutionOverride: ActionExecutionOverride?
    private let buttonGestureRecognizer: ButtonGestureRecognizer
    @ObservationIgnored private lazy var inputOverlay = InputOverlayController(displayDuration: inputOverlayDuration)
    @ObservationIgnored private let terminationObserver = MIDIShutdownObserver()

    init(
        userDefaults: UserDefaults = .standard,
        startHardware: Bool = true,
        gestureSchedule: @escaping ButtonGestureRecognizer.Schedule = ButtonGestureRecognizer.productionSchedule,
        actionExecutionOverride: ActionExecutionOverride? = nil,
        midiOutputService: MIDIOutputService? = nil
    ) {
        defaults = userDefaults
        hid = HIDService(startHardware: startHardware)
        buttonGestureRecognizer = ButtonGestureRecognizer(schedule: gestureSchedule)
        self.actionExecutionOverride = actionExecutionOverride
        self.midiOutputService = midiOutputService ?? MIDIOutputService(defaults: userDefaults)

        let savedProfile = defaults.string(forKey: profileNameDefaultsKey)
        showsInputOverlay = defaults.object(forKey: inputOverlayDefaultsKey) as? Bool ?? true
        let savedDuration = defaults.object(forKey: inputOverlayDurationDefaultsKey) as? Double ?? 4
        inputOverlayDuration = Self.closestInputOverlayDuration(to: savedDuration)
        let savedWheelSensitivity = defaults.object(forKey: wheelSensitivityDefaultsKey) as? Double
            ?? WheelScrollSettings.defaultSensitivity
        wheelSensitivity = WheelScrollSettings.clamped(savedWheelSensitivity)

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
        saveAllProfiles()

        hid.onInput = { [weak self] signature in
            self?.handleHIDInput(signature)
        }
        hid.onDisconnect = { [weak self] in
            self?.cancelPendingButtonGestures()
            self?.resetMIDIState(force: true)
            self?.refreshMIDIEndpointStatus()
            self?.closeProfileSelector()
        }
        buttonGestureRecognizer.onGesture = { [weak self] control, gesture in
            self?.recognizedButtonGesture(control: control, gesture: gesture)
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
            MainActor.assumeIsolated { self?.requestMIDIShutdown() }
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

    func mapping(for control: RemoteControl, gesture: GestureKind) -> Mapping {
        mappings[MappingKey(control: control, gesture: gesture)] ?? Mapping()
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
    func inheritedTapApplication(for control: RemoteControl) -> Result<String, MappingResolutionError> {
        let tap = mapping(for: control, gesture: .tap)
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
    func resolvedMapping(for control: RemoteControl, gesture: GestureKind) -> Result<Mapping, MappingResolutionError> {
        let mapping = mapping(for: control, gesture: gesture)
        guard (gesture == .hold || gesture == .doubleTap),
              mapping.action.isApplicationAction,
              mapping.usesTapApplication else {
            return .success(mapping)
        }

        switch inheritedTapApplication(for: control) {
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

    func update(_ mapping: Mapping, for control: RemoteControl, gesture: GestureKind) {
        mappings[MappingKey(control: control, gesture: gesture)] = mapping
        save()
    }

    func beginKeyboardShortcutCapture(onRemoteButton: @escaping (RemoteControl) -> Void) {
        cancelLearning()
        cancelPendingButtonGestures()
        closeProfileSelector()
        shortcutCaptureHandler = onRemoteButton
    }

    func endKeyboardShortcutCapture() {
        shortcutCaptureHandler = nil
    }

    /// Executes a mapping after resolving any same-control Tap inheritance.
    /// Hold/Double gesture recognition remains intentionally outside this
    /// method; current HID input calls it for Tap only.
    func executeMapping(
        for control: RemoteControl,
        gesture: GestureKind,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        switch resolvedMapping(for: control, gesture: gesture) {
        case let .success(mapping):
            if let actionExecutionOverride {
                actionExecutionOverride(mapping, completion)
            } else {
                actionRunner.execute(mapping: mapping, completion: completion)
            }
        case let .failure(error):
            completion(.failure(error.localizedDescription))
        }
    }

    /// Adds a profile with an independent copy of the default mapping/HID
    /// state and activates it so it is immediately ready for editing.
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
        closeProfileSelector()
        resetMIDIState(force: true)
        saveActiveProfile()
        profileStates[name] = ProfileState(
            mappings: Self.defaultProfileState().mappings,
            hidBindings: Self.defaultProfileState().hidBindings,
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

        closeProfileSelector()
        saveActiveProfile()
        guard let state = profileStates.removeValue(forKey: existingName) else {
            throw ProfileError.profileNotFound(existingName)
        }

        profileStates[name] = state
        availableProfiles[profileIndex] = name
        if lastStandardProfileName == existingName { lastStandardProfileName = name }
        if lastMIDIProfileName == existingName { lastMIDIProfileName = name }

        if profileName == existingName {
            isReplacingConfiguration = true
            profileName = name
            isReplacingConfiguration = false
            defaults.set(name, forKey: profileNameDefaultsKey)
            syncMIDIOverlay()
        }

        saveAllProfiles()
        return name
    }

    /// Deletes an inactive or active profile. Global is intentionally
    /// protected because it is the required fallback profile.
    func deleteProfile(named name: String) throws {
        guard name != "Global" else { throw ProfileError.cannotDeleteGlobal }
        guard availableProfiles.contains(name), profileStates[name] != nil else {
            throw ProfileError.profileNotFound(name)
        }

        closeProfileSelector()
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
        cancelPendingButtonGestures()
        learningControl = selectedControl
        liveControl = nil
    }

    func cancelLearning() {
        learningControl = nil
    }

    func clearHIDBinding(for control: RemoteControl) {
        hidBindings.removeValue(forKey: control)
        saveHIDBindings()
    }

    func hidBinding(for control: RemoteControl) -> String? {
        hidBindings[control]
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
                hidBindings: Self.hidBindingEntries(from: state.hidBindings),
                realm: state.realm,
                midiSettings: state.midiSettings,
                standardButtonTitles: Self.standardButtonTitleEntries(from: state.standardButtonTitles)
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
            workspaceLockControl: workspaceLockControl
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
                importedMappings[MappingKey(control: entry.control, gesture: entry.gesture)] = entry.mapping
            }

            var importedHIDBindings: [RemoteControl: String] = [:]
            for entry in profile.hidBindings {
                importedHIDBindings[entry.control] = entry.signature
            }
            var importedStandardButtonTitles: [RemoteControl: String] = [:]
            for entry in profile.standardButtonTitles {
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    importedStandardButtonTitles[entry.control] = title
                }
            }
            importedStates[profile.name] = ProfileState(
                mappings: importedMappings,
                hidBindings: importedHIDBindings,
                standardButtonTitles: importedStandardButtonTitles,
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

        cancelPendingButtonGestures()
        resetMIDIState(force: true)
        isReplacingConfiguration = true
        profileStates = importedStates
        availableProfiles = configuration.profiles.map(\.name)
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
            tap: overlayMapping(for: selectedControl, gesture: .tap),
            hold: overlayMapping(for: selectedControl, gesture: .hold),
            doubleTap: overlayMapping(for: selectedControl, gesture: .doubleTap)
        )
    }

    func overlayMapping(for control: RemoteControl, gesture: GestureKind) -> Mapping {
        switch resolvedMapping(for: control, gesture: gesture) {
        case .success(let resolved):
            return resolved
        case .failure:
            let unresolved = mapping(for: control, gesture: gesture)
            return Mapping(action: unresolved.action)
        }
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

    private func handleHIDInput(_ signature: String?) {
        liveInputGeneration += 1
        let generation = liveInputGeneration

        if let shortcutCaptureHandler {
            guard let signature,
                  let matched = hidBindings.first(where: { $0.value == signature })?.key,
                  matched.isMIDIButton else {
                return
            }
            shortcutCaptureHandler(matched)
            return
        }

        guard let signature else {
            if activeRealm == .midi, let liveControl {
                if liveControl == .wheelCenter, fnControl == .wheelCenter {
                    finishCenterMIDIInteraction()
                } else {
                    handleMIDIControlRelease(liveControl)
                }
                self.liveControl = nil
                return
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
            let conflicts = hidBindings.compactMap { control, binding in
                control != learningControl && binding == signature ? control : nil
            }
            for control in conflicts {
                hidBindings.removeValue(forKey: control)
            }
            hidBindings[learningControl] = signature
            selectedControl = learningControl
            liveControl = learningControl
            self.learningControl = nil
            saveHIDBindings()
            showOverlayPress(for: learningControl)
            return
        }

        guard let matched = hidBindings.first(where: { $0.value == signature })?.key else { return }
        if let displacedControl = liveControl, displacedControl != matched {
            if activeRealm == .midi {
                handleMIDIControlRelease(displacedControl)
            } else {
                buttonGestureRecognizer.cancel(displacedControl)
                if showsInputOverlay, !displacedControl.isWheelRotation {
                    inputOverlay.release(control: displacedControl)
                }
            }
        }
        selectedControl = matched
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
            handleMIDIControlPress(matched)
            return
        }

        if matched.isWheelRotation {
            actionRunner.scroll(
                direction: matched == .wheelCW ? .down : .up,
                sensitivity: wheelSensitivity
            ) { [weak self] result in
                self?.lastActionResult = result
            }
            releaseWheelAfterDelay(generation: generation)
            return
        }

        showOverlayPress(for: matched)
        buttonGestureRecognizer.press(matched)
    }

    private func recognizedButtonGesture(control: RemoteControl, gesture: GestureKind) {
        if showsInputOverlay {
            inputOverlay.recognize(control: control, gesture: gesture)
        }
        executeMapping(for: control, gesture: gesture) { [weak self] result in
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
            self.syncMIDIOverlay(layer: .function)
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
            syncMIDIOverlay()
            return
        }
        isWheelCenterHeld = false
        confirmProfileSelection()
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
            syncMIDIOverlay(
                layer: layer,
                control: control,
                summary: midiWheelOverlaySummary(mapping, control: control)
            )
            enqueueMIDICommand { service in
                await service.wheel(direction, mapping: mapping)
            }
            return
        }

        if control == fnControl {
            fnIsActive = true
            activeMIDIControls.insert(control)
            midiControlLayers[control] = 2
            syncMIDIOverlay(layer: .function)
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
        syncMIDIOverlay(
            layer: layer,
            control: control,
            summary: midiButtonOverlaySummary(mapping, control: control)
        )
        let origin = MIDIOutputService.Origin(control.rawValue, layer: layerNumber)
        enqueueMIDICommand { service in
            await service.sendButton(mapping, origin: origin)
        }
    }

    private func handleMIDIControlRelease(_ control: RemoteControl) {
        guard activeMIDIControls.contains(control) else {
            if control.isWheelRotation {
                syncMIDIOverlay()
            }
            return
        }
        let layer = midiControlLayers[control] ?? (fnIsActive ? 2 : 1)
        if control == fnControl {
            releaseMIDIControl(control, layer: 2)
            fnIsActive = false
            enqueueMIDICommand { service in
                await service.releaseLayer(2)
            }
            syncMIDIOverlay()
        } else {
            releaseMIDIControl(control, layer: layer)
            syncMIDIOverlay(
                layer: fnIsActive ? .function : .primary,
                control: nil,
                summary: nil
            )
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
        selectedControl = control
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

    private func showOverlayPress(for control: RemoteControl) {
        guard showsInputOverlay else { return }
        inputOverlay.press(
            control: control,
            tap: overlayMapping(for: control, gesture: .tap),
            hold: overlayMapping(for: control, gesture: .hold),
            doubleTap: overlayMapping(for: control, gesture: .doubleTap)
        )
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

    /// Keeps the persistent lock card in sync with the active realm while
    /// leaving profile-selector presentation in the model's higher-priority
    /// slot. Trigger details are deliberately ephemeral and are cleared on
    /// release or any MIDI reset.
    private func syncMIDIOverlay(
        layer: MIDIMappingLayer? = nil,
        control: RemoteControl? = nil,
        summary: String? = nil
    ) {
        guard activeRealm == .midi else {
            inputOverlay.clearMIDI()
            return
        }
        inputOverlay.showMIDI(
            profileName: profileName,
            layer: layer ?? (fnIsActive ? .function : .primary),
            control: control,
            summary: summary
        )
    }

    private func midiButtonOverlaySummary(
        _ mapping: MIDIButtonMapping,
        control: RemoteControl
    ) -> String {
        let prefix = control.overlayLabel
        switch mapping.kind {
        case .note:
            return prefix + " · Note " + String(mapping.note) + " · Ch " + String(mapping.channel) + " · Vel " + String(mapping.velocity)
        case .cc:
            return prefix + " · CC " + String(mapping.controller) + " · Ch " + String(mapping.channel) + " · " + String(mapping.pressValue)
        case .program:
            return prefix + " · PC " + String(mapping.program) + " · Ch " + String(mapping.channel)
        case .chord:
            return prefix + " · Chord " + mapping.chord.map(String.init).joined(separator: ",") + " · Ch " + String(mapping.channel)
        case .noAction:
            return prefix + " · No action"
        }
    }

    private func midiWheelOverlaySummary(
        _ mapping: MIDIWheelMapping,
        control: RemoteControl
    ) -> String {
        let direction = control == .wheelCW ? "↷" : "↶"
        switch mapping.kind {
        case .relativeCC:
            return direction + " · CC " + String(mapping.controller) + " · Ch " + String(mapping.channel)
        case .absoluteCC:
            return direction + " · Absolute CC " + String(mapping.controller) + " · Ch " + String(mapping.channel)
        case .pitchBendNudgeReturn:
            return direction + " · Pitch Bend · Ch " + String(mapping.channel)
        case .transpose:
            return direction + " · Transpose · " + String(mapping.transposeSemitones) + " st"
        case .drumBank:
            return direction + " · Drum Bank · " + String(mapping.drumBankStep)
        case .noAction:
            return direction + " · No action"
        }
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
        syncMIDIOverlay(
            layer: layer,
            control: direction == .clockwise ? .wheelCW : .wheelCCW,
            summary: status
        )
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
            hidBindings: hidBindings,
            standardButtonTitles: activeRealm == .standard ? standardButtonTitles : [:],
            realm: activeRealm,
            midiSettings: activeRealm == .midi ? midiSettings : nil
        )
    }

    private func activateProfile(named name: String) {
        let previousRealm = activeRealm
        guard let state = profileStates[name] else {
            mappings = [:]
            hidBindings = [:]
            standardButtonTitles = [:]
            activeRealm = .standard
            midiSettings = nil
            syncMIDIOverlay()
            return
        }
        mappings = state.mappings
        hidBindings = state.hidBindings
        standardButtonTitles = state.standardButtonTitles
        activeRealm = state.realm
        midiSettings = state.midiSettings
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
        do {
            let persisted = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    guard let state = profileStates[name] else { return nil }
                    return PersistedProfile(name: name, state: state)
                },
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

    private func loadOrMigrateProfiles() -> Bool {
        if let data = defaults.data(forKey: profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.currentVersion,
           isValidPersistedProfiles(decoded) {
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = Dictionary(uniqueKeysWithValues: decoded.profiles.map { ($0.name, $0.state) })
            loadedProfileName = decoded.activeProfileName
            loadedActiveRealm = decoded.activeRealm
            loadedLastStandardProfileName = decoded.lastStandardProfileName
            loadedLastMIDIProfileName = decoded.lastMIDIProfileName
            loadedMIDIIsLocked = decoded.midiLocked
            loadedWorkspaceLockControl = decoded.workspaceLockControl
            defaults.set(true, forKey: profilesMigrationKey)
            return false
        }

        // v4 persisted the current dynamic profile/realm shape but predates
        // Standard button titles. ProfileState's compatibility decoder gives
        // every migrated state an empty title dictionary, then saveAllProfiles
        // writes the explicit v5 payload.
        if let data = defaults.data(forKey: previousProfilesDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
           decoded.version == XPdConfiguration.preTitlesVersion {
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = Dictionary(uniqueKeysWithValues: decoded.profiles.map { profile in
                (
                    profile.name,
                    ProfileState(
                        mappings: profile.state.mappings,
                        hidBindings: profile.state.hidBindings,
                        standardButtonTitles: [:],
                        realm: profile.state.realm,
                        midiSettings: profile.state.midiSettings
                    )
                )
            })
            let upgraded = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    profileStates[name].map { PersistedProfile(name: name, state: $0) }
                },
                activeProfileName: decoded.activeProfileName,
                activeRealm: decoded.activeRealm,
                lastStandardProfileName: decoded.lastStandardProfileName,
                lastMIDIProfileName: decoded.lastMIDIProfileName,
                midiLocked: decoded.midiLocked,
                workspaceLockControl: decoded.workspaceLockControl
            )
            guard isValidPersistedProfiles(upgraded) else {
                availableProfiles = XPdConfiguration.defaultProfileNames
                profileStates = Self.defaultProfileStates()
                return false
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
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = Dictionary(uniqueKeysWithValues: decoded.profiles.map { profile in
                (profile.name, ProfileState(mappings: profile.state.mappings, hidBindings: profile.state.hidBindings))
            })
            guard isValidPersistedProfiles(
                PersistedProfiles(
                    version: XPdConfiguration.currentVersion,
                    profiles: availableProfiles.compactMap { name in
                        profileStates[name].map { PersistedProfile(name: name, state: $0) }
                    },
                    activeProfileName: decoded.activeProfileName
                )
            ) else {
                availableProfiles = XPdConfiguration.defaultProfileNames
                profileStates = Self.defaultProfileStates()
                return false
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
            defaults.set(true, forKey: profilesMigrationKey)
            saveAllProfiles()
            return false
        }

        // The marker prevents a later launch from re-reading legacy values if
        // the new payload was removed or became unreadable after migration.
        if defaults.bool(forKey: profilesMigrationKey) {
            profileStates = Self.defaultProfileStates()
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
        defaults.set(true, forKey: profilesMigrationKey)
        saveAllProfiles()
        return migratedLegacyState
    }

    private func isValidPersistedProfiles(_ persisted: PersistedProfiles) -> Bool {
        guard persisted.version == XPdConfiguration.currentVersion else { return false }
        let configuration = XPdConfiguration(
            profiles: persisted.profiles.map { profile in
                XPdConfiguration.Profile(
                    name: profile.name,
                    mappings: Self.mappingEntries(from: profile.state.mappings),
                    hidBindings: Self.hidBindingEntries(from: profile.state.hidBindings),
                    realm: profile.state.realm,
                    midiSettings: profile.state.midiSettings,
                    standardButtonTitles: profile.state.standardButtonTitles.map {
                        XPdConfiguration.StandardButtonTitleEntry(control: $0.key, title: $0.value)
                    }
                )
            },
            profileName: persisted.activeProfileName,
            showsInputOverlay: showsInputOverlay,
            activeRealm: persisted.activeRealm,
            lastStandardProfileName: persisted.lastStandardProfileName,
            lastMIDIProfileName: persisted.lastMIDIProfileName,
            midiLocked: persisted.midiLocked,
            workspaceLockControl: persisted.workspaceLockControl
        )
        return (try? configuration.validate()) != nil
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
        let mappings = [MappingKey(control: .k1, gesture: .tap): Mapping(action: .openApplication, command: "ChatGPT")]
        return ProfileState(mappings: mappings, hidBindings: defaultHIDBindings)
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

    private static func mappingEntries(from mappings: [MappingKey: Mapping]) -> [XPdConfiguration.MappingEntry] {
        RemoteControl.allCases.flatMap { control in
            GestureKind.allCases.map { gesture in
                let key = MappingKey(control: control, gesture: gesture)
                return XPdConfiguration.MappingEntry(
                    control: control,
                    gesture: gesture,
                    mapping: mappings[key] ?? Mapping()
                )
            }
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

    private static func hidBindingEntries(from bindings: [RemoteControl: String]) -> [XPdConfiguration.HIDBindingEntry] {
        bindings.map { control, signature in
            XPdConfiguration.HIDBindingEntry(control: control, signature: signature)
        }
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
}
