import Foundation
import Observation

@Observable
@MainActor
final class MappingStore {
    var selectedControl: RemoteControl = .k1
    var selectedGesture: GestureKind = .tap
    var profileName = "Global"
    var mappings: [MappingKey: Mapping] = [:]
    private(set) var hidBindings: [RemoteControl: String] = [:]
    private(set) var learningControl: RemoteControl?
    private(set) var liveControl: RemoteControl?
    private(set) var lastActionResult: ActionExecutionResult?
    var showsInputOverlay: Bool {
        didSet {
            UserDefaults.standard.set(showsInputOverlay, forKey: inputOverlayDefaultsKey)
            inputOverlay.setEnabled(showsInputOverlay)
        }
    }
    let hid = HIDService()

    private let defaultsKey = "XPd.mappings.v1"
    private let hidBindingsKey = "XPd.hidBindings.v1"
    private let inputOverlayDefaultsKey = "XPd.showsInputOverlay.v1"
    private var liveInputGeneration = 0
    private var actionPressesInFlight: Set<RemoteControl> = []
    private let actionRunner = ActionRunner()
    @ObservationIgnored private lazy var inputOverlay = InputOverlayController()

    init() {
        showsInputOverlay = UserDefaults.standard.object(forKey: inputOverlayDefaultsKey) as? Bool ?? true
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

    func previewInputOverlay() {
        guard showsInputOverlay else { return }
        inputOverlay.pulse(
            control: selectedControl,
            tap: mapping(for: selectedControl, gesture: .tap),
            hold: mapping(for: selectedControl, gesture: .hold)
        )
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

    private func showOverlayPress(for control: RemoteControl) {
        guard showsInputOverlay else { return }
        inputOverlay.press(
            control: control,
            tap: mapping(for: control, gesture: .tap),
            hold: mapping(for: control, gesture: .hold)
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([MappingKey: Mapping].self, from: data) else { return }
        mappings = decoded
    }

    private func saveHIDBindings() {
        guard let data = try? JSONEncoder().encode(hidBindings) else { return }
        UserDefaults.standard.set(data, forKey: hidBindingsKey)
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
        .wheelCCW: "wheel:-"
    ]

    private static func migrateHIDSignature(_ signature: String) -> String {
        signature.replacingOccurrences(of: "r6:06 ", with: "r6:", options: .anchored)
    }
}
