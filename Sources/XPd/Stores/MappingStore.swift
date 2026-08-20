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
    let hid = HIDService()

    private let defaultsKey = "XPd.mappings.v1"
    private let hidBindingsKey = "XPd.hidBindings.v1"

    init() {
        load()
        loadHIDBindings()
        if hidBindings[.wheelCW] == nil {
            hidBindings[.wheelCW] = "wheel:+"
        }
        if hidBindings[.wheelCCW] == nil {
            hidBindings[.wheelCCW] = "wheel:-"
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

    private func handleHIDInput(_ signature: String?) {
        guard let signature else {
            liveControl = nil
            return
        }

        if let learningControl {
            hidBindings[learningControl] = signature
            selectedControl = learningControl
            liveControl = learningControl
            self.learningControl = nil
            saveHIDBindings()
            return
        }

        guard let matched = hidBindings.first(where: { $0.value == signature })?.key else { return }
        selectedControl = matched
        liveControl = matched
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
}
