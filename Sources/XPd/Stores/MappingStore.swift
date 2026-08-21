import Foundation
import Observation

@Observable
@MainActor
final class MappingStore {
    private(set) var availableProfiles: [String] = XPdConfiguration.defaultProfileNames

    enum ProfileError: LocalizedError, Equatable {
        case invalidName(String)
        case duplicateName(String)
        case profileNotFound(String)
        case cannotDeleteGlobal

        var errorDescription: String? {
            switch self {
            case let .invalidName(name):
                return "Profile names must be trimmed, non-empty, and at most 40 characters: \(name)."
            case let .duplicateName(name):
                return "A profile named \(name) already exists."
            case let .profileNotFound(name):
                return "Profile not found: \(name)."
            case .cannotDeleteGlobal:
                return "The Global profile cannot be deleted."
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
    var profileName = "Global" {
        didSet {
            guard availableProfiles.contains(profileName) else {
                profileName = oldValue
                return
            }
            guard profileName != oldValue, !isReplacingConfiguration else { return }
            saveActiveProfile(named: oldValue)
            activateProfile(named: profileName)
            defaults.set(profileName, forKey: profileNameDefaultsKey)
            saveAllProfiles()
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

    private struct PersistedProfile: Codable, Equatable {
        let name: String
        let state: ProfileState
    }

    private struct PersistedProfiles: Codable, Equatable {
        let version: Int
        let profiles: [PersistedProfile]
        let activeProfileName: String
    }

    private let defaults: UserDefaults
    private let profilesDefaultsKey = "XPd.profiles.v3"
    private let legacyProfilesDefaultsKey = "XPd.profiles.v2"
    private let profilesMigrationKey = "XPd.profiles.v3.migrated"
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
    private var loadedProfileName: String?
    private let actionRunner = ActionRunner()
    @ObservationIgnored private lazy var inputOverlay = InputOverlayController(displayDuration: inputOverlayDuration)

    init(userDefaults: UserDefaults = .standard, startHardware: Bool = true) {
        defaults = userDefaults
        hid = HIDService(startHardware: startHardware)

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
        isReplacingConfiguration = true
        profileName = restoredProfile
        isReplacingConfiguration = false
        defaults.set(profileName, forKey: profileNameDefaultsKey)
        activateProfile(named: profileName)
        saveAllProfiles()

        hid.onInput = { [weak self] signature in
            self?.handleHIDInput(signature)
        }
    }

    func mapping(for control: RemoteControl, gesture: GestureKind) -> Mapping {
        mappings[MappingKey(control: control, gesture: gesture)] ?? Mapping()
    }

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
            actionRunner.execute(mapping: mapping, completion: completion)
        case let .failure(error):
            completion(.failure(error.localizedDescription))
        }
    }

    /// Adds a profile with an independent copy of the default mapping/HID
    /// state and activates it so it is immediately ready for editing.
    @discardableResult
    func addProfile(named rawName: String) throws -> String {
        let name = try validatedNewProfileName(rawName)
        closeProfileSelector()
        profileStates[name] = Self.defaultProfileState()
        availableProfiles.append(name)
        isReplacingConfiguration = true
        profileName = name
        isReplacingConfiguration = false
        activateProfile(named: name)
        defaults.set(profileName, forKey: profileNameDefaultsKey)
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
        let profiles = availableProfiles.compactMap { name -> XPdConfiguration.Profile? in
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

        isReplacingConfiguration = true
        profileStates = importedStates
        availableProfiles = configuration.profiles.map(\.name)
        profileName = configuration.profileName
        activateProfile(named: configuration.profileName)
        isReplacingConfiguration = false

        learningControl = nil
        liveControl = nil
        actionPressesInFlight.removeAll()
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
            executeMapping(for: matched, gesture: .tap) { [weak self] result in
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
            closeProfileSelector()
        } else {
            isProfileSelectorVisible = true
            pendingProfileName = profileName
            inputOverlay.showProfileSelector(
                profiles: availableProfiles,
                selectedProfile: profileName
            )
        }
    }

    private func rotateProfile(_ direction: Int) {
        guard !availableProfiles.isEmpty else { return }
        let highlightedProfile = pendingProfileName ?? profileName
        let currentIndex = availableProfiles.firstIndex(of: highlightedProfile) ?? 0
        let count = availableProfiles.count
        let nextIndex = (currentIndex + direction + count) % count
        pendingProfileName = availableProfiles[nextIndex]
        inputOverlay.showProfileSelector(
            profiles: availableProfiles,
            selectedProfile: pendingProfileName ?? profileName
        )
    }

    private func closeProfileSelector() {
        isProfileSelectorVisible = false
        pendingProfileName = nil
        inputOverlay.hideProfileSelector()
        liveControl = nil
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
            let persisted = PersistedProfiles(
                version: XPdConfiguration.currentVersion,
                profiles: availableProfiles.compactMap { name in
                    guard let state = profileStates[name] else { return nil }
                    return PersistedProfile(name: name, state: state)
                },
                activeProfileName: profileName
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
           isValidPersistedProfiles(decoded) {
            availableProfiles = decoded.profiles.map(\.name)
            profileStates = Dictionary(uniqueKeysWithValues: decoded.profiles.map { ($0.name, $0.state) })
            loadedProfileName = decoded.activeProfileName
            defaults.set(true, forKey: profilesMigrationKey)
            return false
        }

        // Version 2 persisted profile state as a dictionary with the exact
        // historical three-profile set. Restore that canonical order while
        // preserving every stored mapping and HID binding.
        if let data = defaults.data(forKey: legacyProfilesDefaultsKey),
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
                    hidBindings: Self.hidBindingEntries(from: profile.state.hidBindings)
                )
            },
            profileName: persisted.activeProfileName,
            showsInputOverlay: showsInputOverlay
        )
        return (try? configuration.validate()) != nil
    }

    private func validatedNewProfileName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else {
            throw ProfileError.invalidName(rawName)
        }
        let foldedName = XPdConfiguration.profileNameComparisonKey(name)
        guard !availableProfiles.contains(where: {
            XPdConfiguration.profileNameComparisonKey($0) == foldedName
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
