import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingStoreModifierBindingTests: XCTestCase {
    private let factoryK8Signature = "r6:01 1D 00 00 00 00 00"
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

    func testPersistedDesignatedK10MissingBindingDisablesAndPersistsWithoutLosingLayers() throws {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k10, enabled: true))
        let layerMapping = Mapping(action: .openApplication, command: "saved K10 layer")
        source.update(
            layerMapping,
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )
        try mutatePersistedProfiles { state in
            state["hidBindings"] = try removingBinding(for: .k10, from: state["hidBindings"])
        }

        let restored = makeStore()
        XCTAssertEqual(restored.profileName, "Global")
        XCTAssertFalse(restored.isRemoteModifier(.k10))
        XCTAssertNil(restored.hidBinding(for: .k10))
        XCTAssertEqual(
            restored.mapping(for: .k8, gesture: .tap, modifierControls: [.k10]),
            layerMapping
        )

        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isRemoteModifier(.k10))
        XCTAssertNil(reloaded.hidBinding(for: .k10))
        XCTAssertEqual(
            reloaded.mapping(for: .k8, gesture: .tap, modifierControls: [.k10]),
            layerMapping
        )
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

    func testLearningBoundK8InputForK10FailsWithoutStealingEitherBinding() {
        let source = makeStore()
        source.selectedControl = .k10
        source.learnSelectedControl()

        source.simulateHIDInputForTesting(factoryK8Signature)

        XCTAssertNil(source.learningControl)
        XCTAssertEqual(source.hidBinding(for: .k8), factoryK8Signature)
        XCTAssertEqual(source.hidBinding(for: .k10), factoryK10Signature)
        XCTAssertEqual(
            source.lastHIDLearningResult,
            .failure("That input is already assigned to K8. Clear it there before learning it for K10.")
        )

        let restored = makeStore()
        XCTAssertEqual(restored.hidBinding(for: .k8), factoryK8Signature)
        XCTAssertEqual(restored.hidBinding(for: .k10), factoryK10Signature)
    }

    func testStoreAuditsAllLearnedKInputCollisions() {
        let source = makeStore()

        XCTAssertEqual(
            Set(source.standardHIDCollisions()),
            Set([
                HIDKeyboardReportCollision(firstControl: .k1, hiddenControl: .k5),
                HIDKeyboardReportCollision(firstControl: .k2, hiddenControl: .k5),
                HIDKeyboardReportCollision(firstControl: .k7, hiddenControl: .k5),
                HIDKeyboardReportCollision(firstControl: .k8, hiddenControl: .k5),
                HIDKeyboardReportCollision(firstControl: .k10, hiddenControl: .k4),
                HIDKeyboardReportCollision(firstControl: .k10, hiddenControl: .k5),
                HIDKeyboardReportCollision(firstControl: .k10, hiddenControl: .k8)
            ])
        )
        XCTAssertTrue(source.standardHIDRolloverCollisions().isEmpty)
    }

    func testStoreAuditsRolloverCapacityForParseableMultiKeyBindings() {
        let source = makeStore()
        for control in RemoteControl.allCases where control.isMIDIButton {
            source.clearHIDBinding(for: control)
        }

        learn("r6:00 04 05 06 07 00 00", for: .k1, in: source)
        learn("r6:00 08 09 0A 0B 00 00", for: .k2, in: source)

        XCTAssertEqual(
            source.standardHIDRolloverCollisions(),
            [
                HIDKeyboardReportRolloverCollision(
                    firstControl: .k1,
                    secondControl: .k2,
                    combinedOrdinaryKeyCount: 8
                )
            ]
        )
    }

    func testStandardCompatibilityAuditsAreEmptyInMIDIProfile() throws {
        let source = makeStore()
        _ = try source.addMIDIProfile(named: "MIDI")

        XCTAssertEqual(source.standardHIDCollisions(), [])
        XCTAssertEqual(source.standardHIDRolloverCollisions(), [])
    }

    func testDisconnectCancelsPendingLearningBeforeNextInput() {
        let source = makeStore()
        source.selectedControl = .k10
        source.learnSelectedControl()

        source.hid.simulateDisconnectForTesting()

        XCTAssertNil(source.learningControl)
        XCTAssertEqual(
            source.lastHIDLearningResult,
            .failure("Learning canceled because the remote disconnected.")
        )

        source.simulateHIDInputForTesting(factoryK8Signature)

        XCTAssertEqual(source.liveControl, .k8)
        XCTAssertEqual(source.hidBinding(for: .k8), factoryK8Signature)
        XCTAssertEqual(source.hidBinding(for: .k10), factoryK10Signature)
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

    func testDormantSavedLayersRemainDiscoverableAndSelectedUntilDeleted() {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k3, enabled: true))
        XCTAssertTrue(source.setRemoteModifier(.k4, enabled: true))
        source.update(
            Mapping(action: .openApplication, command: "K3 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k3]
        )
        source.update(
            Mapping(action: .openApplication, command: "K3 + K4 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k3, .k4]
        )
        source.selectedControl = .k8
        source.selectedMappingModifiers = [.k3, .k4]

        XCTAssertTrue(source.setRemoteModifier(.k4, enabled: false))

        XCTAssertEqual(source.selectedMappingModifiers, [.k3, .k4])
        XCTAssertEqual(source.standardModifierLayers(for: .k8), [[.k3], [.k3, .k4]])

        XCTAssertTrue(source.deleteMapping(
            for: .k8,
            gesture: .tap,
            modifierControls: [.k3, .k4]
        ))
        XCTAssertEqual(source.standardModifierLayers(for: .k8), [[.k3]])
    }

    func testExactModifierLayerStoresGesturesIndependentlyFromBaseAndOtherLayers() {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k3, enabled: true))
        XCTAssertTrue(source.setRemoteModifier(.k4, enabled: true))

        let baseMappings: [GestureKind: Mapping] = [
            .tap: Mapping(action: .openApplication, command: "base tap"),
            .hold: Mapping(action: .openApplication, command: "base hold"),
            .doubleTap: Mapping(action: .openApplication, command: "base double")
        ]
        let k3Mappings: [GestureKind: Mapping] = [
            .tap: Mapping(action: .openApplication, command: "K3 tap"),
            .hold: Mapping(action: .openApplication, command: "K3 hold"),
            .doubleTap: Mapping(action: .openApplication, command: "K3 double")
        ]
        let k4Mappings: [GestureKind: Mapping] = [
            .tap: Mapping(action: .openApplication, command: "K4 tap"),
            .hold: Mapping(action: .openApplication, command: "K4 hold"),
            .doubleTap: Mapping(action: .openApplication, command: "K4 double")
        ]

        for (gesture, mapping) in baseMappings {
            source.update(mapping, for: .k8, gesture: gesture)
        }
        for (gesture, mapping) in k3Mappings {
            source.update(mapping, for: .k8, gesture: gesture, modifierControls: [.k3])
        }
        for (gesture, mapping) in k4Mappings {
            source.update(mapping, for: .k8, gesture: gesture, modifierControls: [.k4])
        }

        for (gesture, mapping) in baseMappings {
            XCTAssertEqual(source.mapping(for: .k8, gesture: gesture), mapping)
        }
        for (gesture, mapping) in k3Mappings {
            XCTAssertEqual(
                source.mapping(for: .k8, gesture: gesture, modifierControls: [.k3]),
                mapping
            )
        }
        for (gesture, mapping) in k4Mappings {
            XCTAssertEqual(
                source.mapping(for: .k8, gesture: gesture, modifierControls: [.k4]),
                mapping
            )
        }

        XCTAssertTrue(source.deleteMapping(
            for: .k8,
            gesture: .hold,
            modifierControls: [.k3]
        ))
        XCTAssertEqual(
            source.mapping(for: .k8, gesture: .tap, modifierControls: [.k3]),
            k3Mappings[.tap]
        )
        XCTAssertEqual(
            source.mapping(for: .k8, gesture: .doubleTap, modifierControls: [.k3]),
            k3Mappings[.doubleTap]
        )
        XCTAssertEqual(
            source.mapping(for: .k8, gesture: .hold, modifierControls: [.k3]),
            Mapping()
        )
        XCTAssertEqual(
            source.mapping(for: .k8, gesture: .hold),
            baseMappings[.hold]
        )
        XCTAssertEqual(
            source.mapping(for: .k8, gesture: .hold, modifierControls: [.k4]),
            k4Mappings[.hold]
        )

        let restored = makeStore()
        XCTAssertEqual(
            restored.mapping(for: .k8, gesture: .tap, modifierControls: [.k3]),
            k3Mappings[.tap]
        )
        XCTAssertEqual(
            restored.mapping(for: .k8, gesture: .doubleTap, modifierControls: [.k3]),
            k3Mappings[.doubleTap]
        )
        XCTAssertEqual(
            restored.mapping(for: .k8, gesture: .hold, modifierControls: [.k3]),
            Mapping()
        )
        XCTAssertEqual(
            restored.mapping(for: .k8, gesture: .hold, modifierControls: [.k4]),
            k4Mappings[.hold]
        )
    }

    func testEnablingUnboundK10FailsWithoutRestoringFactorySignature() {
        let source = makeStore()
        source.clearHIDBinding(for: .k10)

        let restored = makeStore()
        XCTAssertFalse(restored.isRemoteModifier(.k10))
        XCTAssertNil(restored.hidBinding(for: .k10))

        XCTAssertFalse(restored.setRemoteModifier(.k10, enabled: true))
        XCTAssertFalse(restored.isRemoteModifier(.k10))
        XCTAssertNil(restored.hidBinding(for: .k10))
        XCTAssertEqual(
            restored.lastActionResult,
            .failure("Learn K10's HID input in Status & Input before enabling it as a modifier.")
        )
        XCTAssertNil(makeStore().hidBinding(for: .k10))
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private func learn(_ signature: String, for control: RemoteControl, in store: MappingStore) {
        store.selectedControl = control
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(signature)
        XCTAssertEqual(store.hidBinding(for: control), signature)
    }

    private typealias JSONDictionary = [String: Any]

    private func mutatePersistedProfiles(
        _ mutate: (inout JSONDictionary) throws -> Void
    ) throws {
        let data = try XCTUnwrap(defaults.data(forKey: "XPd.profiles.v8"))
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
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: "XPd.profiles.v8")
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
