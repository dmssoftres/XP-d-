import Foundation
import Observation

@Observable
@MainActor
final class MappingStore {
    static let availableProfiles = XPdConfiguration.availableProfileNames

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

    var selectedControl: RemoteControl = .k1
    var selectedGesture: GestureKind = .tap
    var profileName = "Global" {
        didSet {
            guard Self.availableProfiles.contains(profileName) else {
                profileName = oldValue
                return
            }
            guard profileName != oldValue, !isReplacingConfiguration else { return }
            saveActiveProfile(named: oldValue)
            activateProfile(named: profileName)
            defaults.set(profileName, forKey: profileNameDefaultsKey)
            lastPersistenceResult = .saved
        }
    }
    private(set) var mappings: [MappingKey: Mapping] = [:]
    private(set) var hidBindings: [RemoteControl: String] = [:]
    private(set) var learningControl: RemoteControl?
    private(set) var liveControl: RemoteControl?
    private(set) var lastActionResult: ActionExecutionResult?
    private(set) var lastConfigurationResult: ConfigurationOperationResult = .idle
    private(set) var lastPersistenceResult: PersistenceResult = .idle
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

    static let inputOverlayDurationOptions: [Double] = [2, 4, 6, 8]

    private struct ProfileState: Codable, Equatable {
        var mappings: [MappingKey: Mapping]
        var hidBindings: [RemoteControl: String]
    }

    private let defaults: UserDefaults
    private let profilesDefaultsKey = "XPd.profiles.v2"
    private let profilesMigrationKey = "XPd.profiles.v2.migrated"
    private let defaultsKey = "XPd.mappings.v1"
    private let hidBindingsKey = "XPd.hidBindings.v1"
    private let profileNameDefaultsKey = "XPd.profileName.v1"
    private let inputOverlayDefaultsKey = "XPd.showsInputOverlay.v1"
    private let inputOverlayDurationDefaultsKey = "XPd.inputOverlayDuration.v1"
    private let wheelSensitivityDefaultsKey = "XPd.wheelSensitivity.v1"
    private var profileStates: [String: ProfileState] = [:]
    private var liveInputGeneration = 0
    private var isProfileSelectorVisible = false
    private var pendingProfileName: String?
    private var actionPressesInFlight: Set<RemoteControl> = []
    private var isReplacingConfiguration = false
    private let actionRunner = ActionRunner()
    @ObservationIgnored private lazy var inputOverlay = InputOverlayController(displayDuration: inputOverlayDuration)

    init(userDefaults: UserDefaults = .standard, startHardware: Bool = true) {
        defaults = userDefaults
        hid = HIDService(startHardware: startHardware)

        let savedProfile = defaults.string(forKey: profileNameDefaultsKey)
        profileName = Self.availableProfiles.contains(savedProfile ?? "") ? savedProfile! : "Global"
        showsInputOverlay = defaults.object(forKey: inputOverlayDefaultsKey) as? Bool ?? true
        let savedDuration = defaults.object(forKey: inputOverlayDurationDefaultsKey) as? Double ?? 4
        inputOverlayDuration = Self.closestInputOverlayDuration(to: savedDuration)
        let savedWheelSensitivity = defaults.object(forKey: wheelSensitivityDefaultsKey) as? Double
            ?? WheelScrollSettings.defaultSensitivity
        wheelSensitivity = WheelScrollSettings.clamped(savedWheelSensitivity)

        let migratedLegacyState = loadOrMigrateProfiles()
        if migratedLegacyState {
            isReplacingConfiguration = true
            profileName = "Global"
            isReplacingConfiguration = false
            defaults.set(profileName, forKey: profileNameDefaultsKey)
        }
        activateProfile(named: profileName)

        hid.onInput = { [weak self] signature in
            self?.handleHIDInput(signature)
        }
    }

    func mapping(for control: RemoteControl, gesture: GestureKind) -> Mapping {
        mappings[MappingKey(control: control, gesture: gesture)] ?? Mapping()
    }

    func update(_ mapping: Mapping, for control: RemoteControl, gesture: GestureKind) {
        mappings[MappingKey(control: control, gesture: gesture)] = mapping
        save()
    }

    func learnSelectedControl() {
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

    /// Returns the current configuration as deterministic, pretty-printed
    /// JSON data. File panels and filesystem access belong to the UI layer.
    func exportConfiguration() -> Data? {
        let profiles = Self.availableProfiles.compactMap { name -> XPdConfiguration.Profile? in
            guard let state = profileStates[name] else { return nil }
            return XPdConfiguration.Profile(
                name: name,
                mappings: Self.mappingEntries(from: state.mappings),
                hidBindings: Self.hidBindingEntries(from: state.hidBindings)
            )
        }
        let configuration = XPdConfiguration(
            profiles: profiles,
            profileName: profileName,
            showsInputOverlay: showsInputOverlay
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
            importedStates[profile.name] = ProfileState(
                mappings: importedMappings,
                hidBindings: importedHIDBindings
            )
        }

        // The model validation above requires the exact profile set, but keep
        // this guard adjacent to replacement as a second atomicity barrier.
        guard Set(importedStates.keys) == Set(Self.availableProfiles) else {
            lastConfigurationResult = .failed(
                operation: .import,
                message: "Configuration does not contain the required profiles."
            )
            return false
        }

        isReplacingConfiguration = true
        profileStates = importedStates
        profileName = configuration.profileName
        activateProfile(named: configuration.profileName)
        isReplacingConfiguration = false

        learningControl = nil
        liveControl = nil
        actionPressesInFlight.removeAll()
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
            tap: mapping(for: selectedControl, gesture: .tap),
            hold: mapping(for: selectedControl, gesture: .hold),
            doubleTap: mapping(for: selectedControl, gesture: .doubleTap)
        )
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

        guard let signature else {
            actionPressesInFlight.removeAll()
            if let liveControl, showsInputOverlay {
                inputOverlay.release(control: liveControl)
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
            actionPressesInFlight.insert(learningControl)
            self.learningControl = nil
            saveHIDBindings()
            showOverlayPress(for: learningControl)

            if learningControl == .wheelCW || learningControl == .wheelCCW {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    self?.actionPressesInFlight.remove(learningControl)
                }
            }
            return
        }

        guard let matched = hidBindings.first(where: { $0.value == signature })?.key else { return }
        selectedControl = matched
        liveControl = matched

        if matched == .wheelCenter {
            toggleProfileSelector()
            return
        }

        if isProfileSelectorVisible, matched == .wheelCW || matched == .wheelCCW {
            rotateProfile(matched == .wheelCW ? 1 : -1)
            liveControl = nil
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

        if !actionPressesInFlight.contains(matched) {
            actionPressesInFlight.insert(matched)
            let mapping = mapping(for: matched, gesture: .tap)
            actionRunner.execute(mapping: mapping) { [weak self] result in
                self?.lastActionResult = result
            }
        }

        // Wheel rotation reports do not expose a held state in the UI.
        if matched == .wheelCW || matched == .wheelCCW {
            if showsInputOverlay {
                inputOverlay.release(control: matched)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.liveInputGeneration == generation else { return }
                self.actionPressesInFlight.remove(matched)
                self.liveControl = nil
            }
        }
    }

    private func releaseWheelAfterDelay(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, self.liveInputGeneration == generation else { return }
            self.liveControl = nil
        }
    }

    private func toggleProfileSelector() {
        if isProfileSelectorVisible {
            if let pendingProfileName {
                profileName = pendingProfileName
            }
            isProfileSelectorVisible = false
            pendingProfileName = nil
            inputOverlay.hideProfileSelector()
            liveControl = nil
        } else {
            isProfileSelectorVisible = true
            pendingProfileName = profileName
            inputOverlay.showProfileSelector(
                profiles: Self.availableProfiles,
                selectedProfile: profileName
            )
        }
    }

    private func rotateProfile(_ direction: Int) {
        guard !Self.availableProfiles.isEmpty else { return }
        let highlightedProfile = pendingProfileName ?? profileName
        let currentIndex = Self.availableProfiles.firstIndex(of: highlightedProfile) ?? 0
        let count = Self.availableProfiles.count
        let nextIndex = (currentIndex + direction + count) % count
        pendingProfileName = Self.availableProfiles[nextIndex]
        inputOverlay.showProfileSelector(
            profiles: Self.availableProfiles,
            selectedProfile: pendingProfileName ?? profileName
        )
    }

    private func showOverlayPress(for control: RemoteControl) {
        guard showsInputOverlay else { return }
        inputOverlay.press(
            control: control,
            tap: mapping(for: control, gesture: .tap),
            hold: mapping(for: control, gesture: .hold),
            doubleTap: mapping(for: control, gesture: .doubleTap)
        )
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
        guard Self.availableProfiles.contains(name) else { return }
        profileStates[name] = ProfileState(mappings: mappings, hidBindings: hidBindings)
    }

    private func activateProfile(named name: String) {
        guard let state = profileStates[name] else {
            mappings = [:]
            hidBindings = [:]
            return
        }
        mappings = state.mappings
        hidBindings = state.hidBindings
    }

    private func saveAllProfiles() {
        do {
            let data = try JSONEncoder().encode(profileStates)
            defaults.set(data, forKey: profilesDefaultsKey)
            defaults.set(true, forKey: profilesMigrationKey)
            lastPersistenceResult = .saved
        } catch {
            lastPersistenceResult = .failed("Could not save profiles: \(error.localizedDescription)")
        }
    }

    private func loadOrMigrateProfiles() -> Bool {
        if let data = defaults.data(forKey: profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: ProfileState].self, from: data),
           Set(decoded.keys) == Set(Self.availableProfiles) {
            profileStates = decoded
            defaults.set(true, forKey: profilesMigrationKey)
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
        defaults.set(true, forKey: profilesMigrationKey)
        saveAllProfiles()
        return migratedLegacyState
    }

    private static func defaultProfileStates() -> [String: ProfileState] {
        let mappings = [MappingKey(control: .k1, gesture: .tap): Mapping(action: .openApplication, command: "ChatGPT")]
        let bindings = defaultHIDBindings
        return Dictionary(uniqueKeysWithValues: availableProfiles.map { name in
            (name, ProfileState(mappings: mappings, hidBindings: bindings))
        })
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
