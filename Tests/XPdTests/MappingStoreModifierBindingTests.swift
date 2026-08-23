import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingStoreModifierBindingTests: XCTestCase {
    private let factoryK10Signature = "r6:03 1D 00 00 00 00 00"

    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MappingStoreModifierBindingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPersistedDesignatedK10MissingBindingRepairsAndPersistsAcrossReload() throws {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k10, enabled: true))
        try mutatePersistedProfiles { state in
            state["hidBindings"] = try removingBinding(for: .k10, from: state["hidBindings"])
        }

        let restored = makeStore()
        XCTAssertEqual(restored.profileName, "Global")
        XCTAssertTrue(restored.isRemoteModifier(.k10))
        XCTAssertEqual(restored.hidBinding(for: .k10), factoryK10Signature)

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.isRemoteModifier(.k10))
        XCTAssertEqual(reloaded.hidBinding(for: .k10), factoryK10Signature)
    }

    func testRepairDoesNotStealFactorySignatureOwnedByAnotherControl() throws {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k10, enabled: true))
        try mutatePersistedProfiles { state in
            var bindings = try bindingPairs(from: state["hidBindings"])
            bindings = removingBinding(for: .k10, from: bindings)
            bindings.append(RemoteControl.k8.rawValue)
            bindings.append(factoryK10Signature)
            state["hidBindings"] = bindings
        }

        let restored = makeStore()
        XCTAssertNil(restored.hidBinding(for: .k10))
        XCTAssertEqual(restored.hidBinding(for: .k8), factoryK10Signature)

        let reloaded = makeStore()
        XCTAssertNil(reloaded.hidBinding(for: .k10))
        XCTAssertEqual(reloaded.hidBinding(for: .k8), factoryK10Signature)
    }

    func testExplicitCustomK10BindingIsPreserved() {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k10, enabled: true))
        source.selectedControl = .k10
        source.learnSelectedControl()
        source.simulateHIDInputForTesting("custom-k10")

        let restored = makeStore()
        XCTAssertTrue(restored.isRemoteModifier(.k10))
        XCTAssertEqual(restored.hidBinding(for: .k10), "custom-k10")
    }

    func testClearingUnrelatedNonModifierRemainsCleared() {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k10, enabled: true))
        source.clearHIDBinding(for: .k8)

        let restored = makeStore()
        XCTAssertNil(restored.hidBinding(for: .k8))
        XCTAssertEqual(restored.hidBinding(for: .k10), factoryK10Signature)
    }

    func testClearingDesignatedK10DisablesModifierAndPreservesSavedLayer() {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k10, enabled: true))
        let layerMapping = Mapping(action: .openApplication, command: "saved K10 layer")
        source.update(
            layerMapping,
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        source.clearHIDBinding(for: .k10)

        XCTAssertFalse(source.isRemoteModifier(.k10))
        XCTAssertNil(source.hidBinding(for: .k10))
        XCTAssertEqual(
            source.mapping(for: .k8, gesture: .tap, modifierControls: [.k10]),
            layerMapping
        )

        let restored = makeStore()
        XCTAssertFalse(restored.isRemoteModifier(.k10))
        XCTAssertNil(restored.hidBinding(for: .k10))
        XCTAssertEqual(
            restored.mapping(for: .k8, gesture: .tap, modifierControls: [.k10]),
            layerMapping
        )
    }

    func testEnablingUnboundK10RepairsWhenFactorySignatureIsFree() {
        let source = makeStore()
        source.clearHIDBinding(for: .k10)

        let restored = makeStore()
        XCTAssertFalse(restored.isRemoteModifier(.k10))
        XCTAssertNil(restored.hidBinding(for: .k10))

        XCTAssertTrue(restored.setRemoteModifier(.k10, enabled: true))
        XCTAssertEqual(restored.hidBinding(for: .k10), factoryK10Signature)
        XCTAssertEqual(makeStore().hidBinding(for: .k10), factoryK10Signature)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private typealias JSONDictionary = [String: Any]

    private func mutatePersistedProfiles(
        _ mutate: (inout JSONDictionary) throws -> Void
    ) throws {
        let data = try XCTUnwrap(defaults.data(forKey: "XPd.profiles.v7"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        var profiles = try XCTUnwrap(root["profiles"] as? [JSONDictionary])
        guard let globalIndex = profiles.firstIndex(where: { $0["name"] as? String == "Global" }) else {
            XCTFail("Persisted fixture is missing the Global profile")
            return
        }
        var state = try XCTUnwrap(profiles[globalIndex]["state"] as? JSONDictionary)
        try mutate(&state)
        profiles[globalIndex]["state"] = state
        root["profiles"] = profiles
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: "XPd.profiles.v7")
    }

    private func bindingPairs(from value: Any?) throws -> [Any] {
        let pairs = try XCTUnwrap(value as? [Any])
        XCTAssertEqual(pairs.count % 2, 0)
        return pairs
    }

    private func removingBinding(for control: RemoteControl, from value: Any?) throws -> [Any] {
        removingBinding(for: control, from: try bindingPairs(from: value))
    }

    private func removingBinding(for control: RemoteControl, from pairs: [Any]) -> [Any] {
        var result: [Any] = []
        for index in stride(from: 0, to: pairs.count, by: 2) {
            guard let key = pairs[index] as? String else { continue }
            if key != control.rawValue {
                result.append(pairs[index])
                result.append(pairs[index + 1])
            }
        }
        return result
    }
}
