import Foundation
import XCTest
@testable import XPd

@MainActor
final class StandardF13F22PresetTests: XCTestCase {
    private final class ScheduledItem {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }

    @MainActor
    private final class TestScheduler {
        private(set) var now: TimeInterval = 0
        private var items: [ScheduledItem] = []

        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> GestureScheduledAction {
            let item = ScheduledItem(deadline: now + delay, action: action)
            items.append(item)
            return GestureScheduledAction { item.isCancelled = true }
        }

        func advance(by interval: TimeInterval) {
            let target = now + interval
            while let next = items
                .filter({ !$0.isCancelled && $0.deadline <= target })
                .min(by: { $0.deadline < $1.deadline }) {
                items.removeAll { $0 === next }
                now = next.deadline
                next.action()
            }
            now = target
        }
    }

    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.StandardF13F22PresetTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPresetProvidesTenDistinctReport6IdentitiesAndBothK10K5Orders() {
        let store = makeStore()
        let rawBindings = store.hidBindings
        let presetBindings = MappingStore.standardF13F22HIDBindings

        XCTAssertEqual(presetBindings.count, 10)
        XCTAssertEqual(
            Set(presetBindings.values),
            Set((0x68...0x71).map { String(format: "r6:00 %02X 00 00 00 00 00", $0) })
        )
        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        XCTAssertTrue(store.usesStandardF13F22Preset)
        XCTAssertEqual(store.hidBindings, rawBindings, "The preset must not rewrite the shared device layout.")
        XCTAssertEqual(store.standardHIDCollisions(), [])
        XCTAssertEqual(store.standardHIDRolloverCollisions(), [])

        for control in RemoteControl.allCases.filter(\.isMIDIButton) {
            let signature = try! XCTUnwrap(presetBindings[control])
            XCTAssertEqual(store.hidBinding(for: control), signature)
            store.simulateHIDInputForTesting(signature)
            XCTAssertEqual(store.selectedControl, control)
            store.simulateHIDInputForTesting(nil)
        }

        // A K10-first report followed by K10+K5 must resolve the new K5
        // identity instead of treating it as hidden inside K10.
        store.setRemoteModifier(.k10, enabled: true)
        let k10 = presetBindings[.k10]!
        let k5 = presetBindings[.k5]!
        let composite = report6CompositeSignature(k10, k5)
        store.simulateHIDInputForTesting(k10)
        store.simulateHIDInputForTesting(composite)
        XCTAssertEqual(store.selectedControl, .k5)
        store.simulateHIDInputForTesting(nil)

        // Reset the cycle, then prove the reverse physical order works too.
        store.simulateHIDInputForTesting(k5)
        store.simulateHIDInputForTesting(composite)
        XCTAssertEqual(store.selectedControl, .k10)
        store.simulateHIDInputForTesting(nil)
    }

    func testPresetSelectionPersistsSeparatelyAndPreservesWheelCenterAndProfilePayload() throws {
        let store = makeStore()
        let rawBindings = store.hidBindings
        let wheelBindings = [
            RemoteControl.wheelCCW: store.hidBinding(for: .wheelCCW),
            .wheelCW: store.hidBinding(for: .wheelCW),
            .wheelCenter: store.hidBinding(for: .wheelCenter)
        ]
        let profilePayloadBefore = try exportedProfilePayload(from: store, named: "Global")
        let persistedProfilesBefore = defaults.data(forKey: "XPd.profiles.v9")

        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        XCTAssertEqual(store.hidBindings, rawBindings)
        XCTAssertEqual(
            [
                RemoteControl.wheelCCW: store.hidBinding(for: .wheelCCW),
                .wheelCW: store.hidBinding(for: .wheelCW),
                .wheelCenter: store.hidBinding(for: .wheelCenter)
            ],
            wheelBindings
        )
        XCTAssertEqual(
            try exportedProfilePayload(from: store, named: "Global"),
            profilePayloadBefore,
            "The Standard preset selection must not rewrite the profile payload."
        )
        XCTAssertEqual(
            defaults.data(forKey: "XPd.profiles.v9"),
            persistedProfilesBefore,
            "The shared layout/profile payload must remain byte-for-byte unchanged."
        )

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.usesStandardF13F22Preset)
        XCTAssertEqual(reloaded.hidBindings, rawBindings)
        XCTAssertEqual(reloaded.hidBinding(for: .k1), MappingStore.standardF13F22HIDBindings[.k1])
        XCTAssertEqual(reloaded.hidBinding(for: .wheelCenter), wheelBindings[.wheelCenter]!)
    }

    func testPresetIsRejectedInMIDIWithoutTouchingMIDIStateOrPersistence() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "MIDI")
        let midiPayloadBefore = try exportedProfilePayload(from: store, named: "MIDI")
        let rawBindings = store.hidBindings
        let persistedProfilesBefore = defaults.data(forKey: "XPd.profiles.v9")

        store.simulateMIDIControlPressForTesting(.k10)
        XCTAssertTrue(store.isFnLayerActive)
        let midiPayloadWhileHeld = try exportedProfilePayload(from: store, named: "MIDI")

        XCTAssertFalse(store.setStandardF13F22PresetEnabled(true))
        XCTAssertFalse(store.usesStandardF13F22Preset)
        XCTAssertTrue(store.isFnLayerActive)
        XCTAssertEqual(store.hidBindings, rawBindings)
        XCTAssertEqual(try exportedProfilePayload(from: store, named: "MIDI"), midiPayloadWhileHeld)
        XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v9"), persistedProfilesBefore)

        // Enable only after returning to Standard, then verify MIDI still
        // resolves the old shared device identity rather than F22.
        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        XCTAssertTrue(store.usesStandardF13F22Preset)
        XCTAssertEqual(try exportedProfilePayload(from: store, named: "MIDI"), midiPayloadBefore)
        XCTAssertEqual(store.hidBindings, rawBindings)

        XCTAssertTrue(store.selectProfile("MIDI"))
        XCTAssertFalse(store.isFnLayerActive)
        store.simulateHIDInputForTesting(MappingStore.standardF13F22HIDBindings[.k10]!)
        XCTAssertFalse(store.isFnLayerActive, "MIDI must not consume the Standard preset overlay.")
        store.simulateHIDInputForTesting(rawBindings[.k10])
        XCTAssertTrue(store.isFnLayerActive, "MIDI must continue using the shared raw layout.")
    }

    func testPresetCannotBeUsedToStartManualStandardLearning() {
        let store = makeStore()
        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        let rawBindings = store.hidBindings

        store.beginLearningAllHIDControls()
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, rawBindings)
        XCTAssertTrue(store.lastHIDLearningResult?.message.contains("Disable the F13–F22 preset") == true)
    }

    func testPresetRequiresCurrentConnectionLiveEvidenceAndInvalidatesOnDisable() {
        let store = makeStore()
        let rawK10 = store.hidBindings[.k10]!
        let presetK5 = MappingStore.standardF13F22HIDBindings[.k5]!

        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)
        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)

        // A saved/factory report is not evidence for the selected preset.
        store.simulateHIDInputForTesting(rawK10)
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)

        // One exact report-6 preset identity is enough for the fast path's
        // connection-scoped evidence; this does not claim all ten keys ran.
        store.simulateHIDInputForTesting(presetK5)
        XCTAssertTrue(store.isStandardF13F22PresetLiveVerified)

        XCTAssertTrue(store.setStandardF13F22PresetEnabled(false))
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)
        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)
    }

    func testPresetLiveEvidenceDoesNotSurviveDisconnectOrStandardMIDILifecycle() throws {
        let store = makeStore()
        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        store.simulateHIDInputForTesting(MappingStore.standardF13F22HIDBindings[.k1]!)
        XCTAssertTrue(store.isStandardF13F22PresetLiveVerified)

        _ = try store.addMIDIProfile(named: "MIDI")
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)
        XCTAssertTrue(store.usesStandardF13F22Preset)

        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertTrue(store.usesStandardF13F22Preset)
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)

        store.simulateHIDInputForTesting(MappingStore.standardF13F22HIDBindings[.k1]!)
        XCTAssertTrue(store.isStandardF13F22PresetLiveVerified)
        store.hid.simulateDisconnectForTesting()
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)
    }

    func testPresetK10ModifierAndK5LayerExecutesExactlyOnceForBothOrdersAndPartialReleases() {
        let orders: [[RemoteControl]] = [
            [.k10, .k5],
            [.k5, .k10]
        ]
        let partialReleases: [RemoteControl] = [.k10, .k5]

        for order in orders {
            for remainingControl in partialReleases {
                let scheduler = TestScheduler()
                var executed: [String] = []
                let store = makeStore(scheduler: scheduler) { mapping, completion in
                    executed.append(mapping.command)
                    completion(.success(mapping.command))
                }
                XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
                XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
                store.update(
                    Mapping(action: .openApplication, command: "base"),
                    for: .k5,
                    gesture: .tap
                )
                store.update(
                    Mapping(action: .openApplication, command: "layer"),
                    for: .k5,
                    gesture: .tap,
                    modifierControls: [.k10]
                )

                let firstSignature = MappingStore.standardF13F22HIDBindings[order[0]]!
                let secondSignature = MappingStore.standardF13F22HIDBindings[order[1]]!
                let composite = report6CompositeSignature(firstSignature, secondSignature)
                let remainingSignature = MappingStore.standardF13F22HIDBindings[remainingControl]!

                store.simulateHIDInputForTesting(firstSignature)
                store.simulateHIDInputForTesting(composite)
                store.simulateHIDInputForTesting(remainingSignature)
                store.simulateHIDInputForTesting(nil)
                scheduler.advance(by: 0.21)

                XCTAssertEqual(
                    executed,
                    ["layer"],
                    "order=" + order.map(\.rawValue).joined(separator: ",")
                        + ", remaining=" + remainingControl.rawValue
                )
            }
        }
    }

    func testPresetJSONRoundTripUsesOptionalTopLevelFieldAndLegacyDefaultsSafely() throws {
        let store = makeStore()
        let legacyData = try XCTUnwrap(store.exportConfiguration())
        let legacyRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        XCTAssertNil(legacyRoot["standardF13F22PresetEnabled"])
        XCTAssertNil(try XPdConfiguration.decode(legacyData).standardF13F22PresetEnabled)

        XCTAssertTrue(store.setStandardF13F22PresetEnabled(true))
        let selectedData = try XCTUnwrap(store.exportConfiguration())
        let selectedRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: selectedData) as? [String: Any]
        )
        XCTAssertEqual(selectedRoot["standardF13F22PresetEnabled"] as? Bool, true)
        XCTAssertEqual(
            try XPdConfiguration.decode(selectedData).standardF13F22PresetEnabled,
            true
        )

        // Importing an older document safely disables the optional Standard
        // resolver choice instead of retaining the target's stale selection.
        XCTAssertTrue(store.importConfiguration(legacyData))
        XCTAssertFalse(store.usesStandardF13F22Preset)

        XCTAssertTrue(store.importConfiguration(selectedData))
        XCTAssertTrue(store.usesStandardF13F22Preset)
        XCTAssertFalse(store.isStandardF13F22PresetLiveVerified)
        XCTAssertEqual(try XCTUnwrap(store.exportConfiguration()), selectedData)

        // A malformed optional field must fail before any replacement and
        // preserve the currently selected Standard preset.
        var malformedRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: selectedData) as? [String: Any]
        )
        malformedRoot["standardF13F22PresetEnabled"] = "yes"
        let malformedData = try JSONSerialization.data(withJSONObject: malformedRoot)
        XCTAssertFalse(store.importConfiguration(malformedData))
        XCTAssertTrue(store.usesStandardF13F22Preset)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private func makeStore(
        scheduler: TestScheduler,
        execute: @escaping MappingStore.ActionExecutionOverride
    ) -> MappingStore {
        MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            actionExecutionOverride: execute
        )
    }

    private func report6CompositeSignature(_ first: String, _ second: String) -> String {
        let firstReport = HIDKeyboardReport(signature: first)!
        let secondReport = HIDKeyboardReport(signature: second)!
        let merged = firstReport.merged(with: secondReport)!
        let usages = merged.keyUsages.sorted()
        let padded = usages + Array(repeating: 0, count: HIDKeyboardReport.bootKeyboardOrdinaryKeyCapacity - usages.count)
        return String(
            format: "r6:%02X %@",
            merged.modifierByte,
            padded.map { String(format: "%02X", $0) }.joined(separator: " ")
        )
    }

    private func exportedProfilePayload(from store: MappingStore, named name: String) throws -> Data {
        let configuration = try XCTUnwrap(store.exportConfiguration())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: configuration) as? [String: Any])
        let profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        let profile = try XCTUnwrap(profiles.first { $0["name"] as? String == name })
        return try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    }
}
