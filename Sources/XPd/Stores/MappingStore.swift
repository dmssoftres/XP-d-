import Foundation
import Observation

@Observable
final class MappingStore {
    var selectedControl: RemoteControl = .k1
    var selectedGesture: GestureKind = .tap
    var profileName = "Global"
    var mappings: [MappingKey: Mapping] = [:]
    let hid = HIDService()

    private let defaultsKey = "XPd.mappings.v1"

    init() {
        load()
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

    private func save() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([MappingKey: Mapping].self, from: data) else { return }
        mappings = decoded
    }
}
