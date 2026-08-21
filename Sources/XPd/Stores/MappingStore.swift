import Foundation
import Observation

@Observable
@MainActor
final class MappingStore {
    static let availableProfiles = ["Global", "Finder", "Logic Pro"]

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
            UserDefaults.standard.set(profileName, forKey: profileNameDefaultsKey)
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
            UserDefaults.standard.set(showsInputOverlay, forKey: inputOverlayDefaultsKey)
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
            UserDefaults.standard.set(inputOverlayDuration, forKey: inputOverlayDurationDefaultsKey)
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
            UserDefaults.standard.set(wheelSensitivity, forKey: wheelSensitivityDefaultsKey)
            lastPersistenceResult = .saved
        }
    }
    let hid = HIDService()

    static let inputOverlayDurationOptions: [Double] = [2, 4, 6, 8]

    private let defaultsKey = "XPd.mappings.v1"
    private let hidBindingsKey = "XPd.hidBindings.v1"
    private let profileNameDefaultsKey = "XPd.profileName.v1"
    private let inputOverlayDefaultsKey = "XPd.showsInputOverlay.v1"
    private let inputOverlayDurationDefaultsKey = "XPd.inputOverlayDuration.v1"
    private let wheelSensitivityDefaultsKey = "XPd.wheelSensitivity.v1"
    private var liveInputGeneration = 0
    private var isProfileSelectorVisible = false
    private var pendingProfileName: String?
    private var actionPressesInFlight: Set<RemoteControl> = []
    private let actionRunner = ActionRunner()
    @ObservationIgnored private lazy var inputOverlay = InputOverlayController(displayDuration: inputOverlayDuration)

    init() {
        profileName = UserDefaults.standard.string(forKey: profileNameDefaultsKey) ?? "Global"
        showsInputOverlay = UserDefaults.standard.object(forKey: inputOverlayDefaultsKey) as? Bool ?? true
        let savedDuration = UserDefaults.standard.object(forKey: inputOverlayDurationDefaultsKey) as? Double ?? 4
        inputOverlayDuration = Self.closestInputOverlayDuration(to: savedDuration)
        let savedWheelSensitivity = UserDefaults.standard.object(forKey: wheelSensitivityDefaultsKey) as? Double
            ?? WheelScrollSettings.defaultSensitivity
        wheelSensitivity = WheelScrollSettings.clamped(savedWheelSensitivity)
        load()
        loadHIDBindings()
        hidBindings = hidBindings.mapValues(Self.migrateHIDSignature)
        for (control, signature) in Self.defaultHIDBindings
        where hidBindings[control] == nil && !hidBindings.values.contains(signature) {
            hidBindings[control] = signature
        }
        saveHIDBindings()
        hid.onInput = { [weak self] signature in
            self?.handleHIDInput(signature)
        }
        if mappings.isEmpty {
            mappings[MappingKey(control: .k1, gesture: .tap)] = Mapping(action: .openApplication, command: "ChatGPT")
            save()
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

    /// Returns the current configuration as deterministic, pretty-printed
    /// JSON data. File panels and filesystem access belong to the UI layer.
    func exportConfiguration() -> Data? {
        let configuration = XPdConfiguration(
            mappings: RemoteControl.allCases.flatMap { control in
                GestureKind.allCases.map { gesture in
                    XPdConfiguration.MappingEntry(
                        control: control,
                        gesture: gesture,
                        mapping: mapping(for: control, gesture: gesture)
                    )
                }
            },
            hidBindings: hidBindings.map { control, signature in
                XPdConfiguration.HIDBindingEntry(control: control, signature: signature)
            },
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
    /// state. The replacement is synchronous on the main actor, so observers
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

        var importedMappings: [MappingKey: Mapping] = [:]
        for entry in configuration.mappings {
            importedMappings[MappingKey(control: entry.control, gesture: entry.gesture)] = entry.mapping
        }

        var importedHIDBindings: [RemoteControl: String] = [:]
        for entry in configuration.hidBindings {
            importedHIDBindings[entry.control] = entry.signature
        }

        learningControl = nil
        liveControl = nil
        actionPressesInFlight.removeAll()
        mappings = importedMappings
        hidBindings = importedHIDBindings
        profileName = configuration.profileName
        showsInputOverlay = configuration.showsInputOverlay
        save()
        saveHIDBindings()

        lastConfigurationResult = .succeeded(
            operation: .import,
            detail: "Imported \(configuration.mappings.count) mappings and \(configuration.hidBindings.count) HID bindings."
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
        do {
            let data = try JSONEncoder().encode(mappings)
            UserDefaults.standard.set(data, forKey: defaultsKey)
            lastPersistenceResult = .saved
        } catch {
            lastPersistenceResult = .failed("Could not save mappings: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([MappingKey: Mapping].self, from: data) else { return }
        mappings = decoded
    }

    private static func configurationErrorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "Configuration could not be read."
    }

    private func saveHIDBindings() {
        do {
            let data = try JSONEncoder().encode(hidBindings)
            UserDefaults.standard.set(data, forKey: hidBindingsKey)
            lastPersistenceResult = .saved
        } catch {
            lastPersistenceResult = .failed("Could not save HID bindings: \(error.localizedDescription)")
        }
    }

    private func loadHIDBindings() {
        guard let data = UserDefaults.standard.data(forKey: hidBindingsKey),
              let decoded = try? JSONDecoder().decode([RemoteControl: String].self, from: data) else { return }
        hidBindings = decoded
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
