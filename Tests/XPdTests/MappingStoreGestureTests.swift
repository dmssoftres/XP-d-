import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingStoreGestureTests: XCTestCase {
    private final class ScheduledItem {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }

    private final class ModifierState: @unchecked Sendable {
        var value: Set<KeyboardShortcut.Modifier>

        init(_ value: Set<KeyboardShortcut.Modifier>) {
            self.value = value
        }
    }

    private final class FunctionKeyState: @unchecked Sendable {
        var value: Set<UInt16>

        init(_ value: Set<UInt16>) {
            self.value = value
        }
    }

    private final class KeyboardKeyState: @unchecked Sendable {
        var value: Set<UInt16>

        init(_ value: Set<UInt16>) {
            self.value = value
        }
    }

    @MainActor
    private final class TestScheduler {
        private(set) var now: TimeInterval = 0
        private var items: [ScheduledItem] = []

        var pendingDeadlines: [TimeInterval] {
            items
                .filter { !$0.isCancelled }
                .map(\.deadline)
                .sorted()
        }

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
        suiteName = "XPdTests.MappingStoreGestureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testHIDTapHoldAndDoubleExecuteTheirOwnMappings() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        configureGestureCommands(in: store)

        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)

        store.simulateHIDInputForTesting(k1Signature)
        scheduler.advance(by: 0.50)
        store.simulateHIDInputForTesting(nil)

        pressAndReleaseK1(store)
        scheduler.advance(by: 0.10)
        pressAndReleaseK1(store)

        XCTAssertEqual(executed, ["tap", "hold", "double"])
    }

    func testInheritedHoldResolvesLatestTapApplicationAtRecognitionTime() {
        let scheduler = TestScheduler()
        var executed: [Mapping] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping)
            completion(.success(mapping.command))
        }
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "stale", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )

        store.simulateHIDInputForTesting(k1Signature)
        store.update(Mapping(action: .openApplication, command: "Calculator"), for: .k1, gesture: .tap)
        scheduler.advance(by: 0.50)

        XCTAssertEqual(executed.map(\.command), ["Calculator"])
        XCTAssertEqual(executed.first?.action, .toggleApplication)
    }

    func testProfileChangeImportAndDisconnectCancelPendingTap() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(Mapping(action: .openApplication, command: "tap"), for: .k1, gesture: .tap)

        pressAndReleaseK1(store)
        store.profileName = "Finder"
        scheduler.advance(by: 1)

        store.profileName = "Global"
        pressAndReleaseK1(store)
        let data = try XCTUnwrap(store.exportConfiguration())
        XCTAssertTrue(store.importConfiguration(data))
        scheduler.advance(by: 1)

        pressAndReleaseK1(store)
        store.hid.simulateDisconnectForTesting()
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testRepeatedDownReportDoesNotDuplicateHold() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        configureGestureCommands(in: store)

        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(k1Signature)
        scheduler.advance(by: 0.50)
        scheduler.advance(by: 1)
        store.simulateHIDInputForTesting(nil)

        XCTAssertEqual(executed, ["hold"])
    }

    func testRemoteTriggerRequiresExactModifierMatch() {
        let modifierState = ModifierState([.command, .shift])
        var executed: [String] = []
        let scheduler = TestScheduler()
        let store = makeStore(
            scheduler: scheduler,
            remoteModifierProvider: { modifierState.value }
        ) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(
            Mapping(
                action: .openApplication,
                command: "command-shift",
                remoteTriggerModifiers: [.command, .shift]
            ),
            for: .k1,
            gesture: .tap
        )

        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["command-shift"])

        modifierState.value = []
        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["command-shift"])
    }

    func testRemoteTriggerModifierSnapshotSurvivesDelayedGesture() {
        let modifierState = ModifierState([.option, .function])
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(
            scheduler: scheduler,
            remoteModifierProvider: { modifierState.value }
        ) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(
            Mapping(
                action: .openApplication,
                command: "option-function",
                remoteTriggerModifiers: [.option, .function]
            ),
            for: .k1,
            gesture: .tap
        )

        store.simulateHIDInputForTesting(k1Signature)
        modifierState.value = []
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["option-function"])
    }

    func testRemoteTriggerRequiresExactHeldFunctionKey() {
        let functionKeyState = FunctionKeyState([118]) // F4
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(
            scheduler: scheduler,
            remoteFunctionKeyProvider: { functionKeyState.value }
        ) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(
            Mapping(
                action: .openApplication,
                command: "F4 remote trigger",
                remoteTriggerFunctionKey: 118
            ),
            for: .k4,
            gesture: .tap
        )

        store.simulateHIDInputForTesting("r6:02 00 00 00 00 00 00")
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["F4 remote trigger"])

        functionKeyState.value = []
        store.simulateHIDInputForTesting("r6:02 00 00 00 00 00 00")
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["F4 remote trigger"])
    }

    func testRemoteTriggerRequiresExactOrdinaryKey() {
        let keyState = KeyboardKeyState([40])
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(
            scheduler: scheduler,
            remoteKeyProvider: { _ in keyState.value }
        ) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(
            Mapping(
                action: .openApplication,
                command: "ordinary key",
                remoteTriggerKeyCode: 40,
                remoteTriggerKeyDisplay: "K"
            ),
            for: .k4,
            gesture: .tap
        )

        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["ordinary key"])

        keyState.value = []
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["ordinary key"])
    }

    func testRemoteTriggerOrdinaryKeySnapshotSurvivesDelayedGesture() {
        let keyState = KeyboardKeyState([40])
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(
            scheduler: scheduler,
            remoteKeyProvider: { _ in keyState.value }
        ) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(
            Mapping(
                action: .openApplication,
                command: "captured ordinary key",
                remoteTriggerKeyCode: 40,
                remoteTriggerKeyDisplay: "K"
            ),
            for: .k1,
            gesture: .tap
        )

        store.simulateHIDInputForTesting(k1Signature)
        keyState.value = []
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["captured ordinary key"])
    }

    func testDesignatedModifierWorksInEitherPressOrder() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "base"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "K3 layer"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3]
        )

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K3 layer", "K3 layer"])
    }

    func testModifierReleasedBeforeThresholdMakesLaterPrimaryNormal() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "base"), for: .k8, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "K10 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.49)
        store.simulateHIDInputForTesting(nil)
        XCTAssertTrue(executed.isEmpty)
        scheduler.advance(by: 0.30)

        store.simulateHIDInputForTesting(k8Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["base"])
    }

    func testQuickStandaloneModifierReleaseDoesNothing() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)

        store.simulateHIDInputForTesting(k10Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)

        scheduler.advance(by: 1)
        XCTAssertTrue(executed.isEmpty)
    }

    func testStandaloneModifierThresholdOnlyEnablesReleaseTap() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)

        scheduler.advance(by: 0.01)
        XCTAssertTrue(executed.isEmpty)

        // Crossing the threshold leaves K10 eligible for a late destination.
        scheduler.advance(by: 1)
        XCTAssertTrue(executed.isEmpty)

        // With no destination participation, release commits the standalone
        // action exactly once.
        store.simulateHIDInputForTesting(nil)
        XCTAssertEqual(executed, ["K10 tap"])
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["K10 tap"])
    }

    func testModifierHoldThresholdIsSnapshottedAtPress() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)

        store.standardModifierHoldThreshold = 0.8
        store.simulateHIDInputForTesting(k10Signature)
        store.standardModifierHoldThreshold = 0.2
        scheduler.advance(by: 0.79)
        XCTAssertTrue(executed.isEmpty)
        scheduler.advance(by: 0.01)
        XCTAssertTrue(executed.isEmpty)
        store.simulateHIDInputForTesting(nil)
        XCTAssertEqual(executed, ["K10 tap"])
    }

    func testModifierFirstK10ThenK8BeforeThresholdUsesOnlyExactLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K10 layer"), for: .k8, gesture: .tap, modifierControls: [.k10])

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.49)
        store.simulateHIDInputForTesting(k8Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 layer"])
    }

    func testDestinationFirstK8ThenK10InSameCycleUsesOnlyExactLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K10 base"), for: .k10, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "K10+K8 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        // The designated modifier may arrive after the destination while both
        // remain in the same physical report-6 cycle. No standalone modifier
        // timer exists when the destination began the cycle.
        store.simulateHIDInputForTesting(k8Signature)
        scheduler.advance(by: 0.10)
        store.simulateHIDInputForTesting(k10Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10+K8 layer"])
    }

    func testDuplicateK10ReportsDoNotRestartTimerOrBlockValidK8Layer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 base"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "K10+K8 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.24)
        // A repeated HID down packet is not a second physical press and must
        // leave the original 0.5-second standalone deadline untouched.
        store.simulateHIDInputForTesting(k10Signature)
        XCTAssertEqual(scheduler.pendingDeadlines, [0.5])

        scheduler.advance(by: 0.25)
        store.simulateHIDInputForTesting(k8Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10+K8 layer"])
    }

    func testPrimaryAtThresholdStillCreatesLayerWithoutBaseLeakage() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        XCTAssertTrue(executed.isEmpty)

        // A destination arriving exactly at the threshold still joins the
        // held modifier and selects the exact layer.
        store.simulateHIDInputForTesting(k8Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["layer"])
    }

    func testPrimaryAfterThresholdStillCreatesLayerUntilReportRelease() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "layer"), for: .k8, gesture: .tap, modifierControls: [.k10])

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.51)
        store.simulateHIDInputForTesting(k8Signature)
        scheduler.advance(by: 0.1)
        XCTAssertTrue(executed.isEmpty)

        // K8 remains eligible after the threshold; the report-6 release closes
        // the cycle and the exact layered Tap is the only action.
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["layer"])
    }

    func testModifierHoldThresholdPersistsAndNormalizes() {
        let scheduler = TestScheduler()
        let store = makeStore(scheduler: scheduler) { _, completion in
            completion(.success("unused"))
        }

        XCTAssertEqual(store.standardModifierHoldThreshold, 0.5)
        store.standardModifierHoldThreshold = 0.94
        XCTAssertEqual(store.standardModifierHoldThreshold, 0.9)
        store.standardModifierHoldThreshold = .nan
        XCTAssertEqual(store.standardModifierHoldThreshold, 0.5)
        store.standardModifierHoldThreshold = 9
        XCTAssertEqual(store.standardModifierHoldThreshold, 1.5)

        let restored = makeStore(scheduler: scheduler) { _, completion in
            completion(.success("unused"))
        }
        XCTAssertEqual(restored.standardModifierHoldThreshold, 1.5)

        defaults.set(Double.nan, forKey: "XPd.standardModifierHoldThreshold.v1")
        let restoredFromNonFinite = makeStore(scheduler: scheduler) { _, completion in
            completion(.success("unused"))
        }
        XCTAssertEqual(restoredFromNonFinite.standardModifierHoldThreshold, 0.5)

        restoredFromNonFinite.standardModifierHoldThreshold = 0.1
        XCTAssertEqual(restoredFromNonFinite.standardModifierHoldThreshold, 0.2)
    }

    func testHeldSecondModifierDoesNotLetFirstModifierTapFire() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k4Signature)
        scheduler.advance(by: 1)
        XCTAssertTrue(executed.isEmpty)

        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 1)
        XCTAssertTrue(executed.isEmpty)
    }

    func testLaterPrimaryAfterEarlyModifierReleaseUsesBase() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "base"), for: .k1, gesture: .tap)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["base"])
    }

    func testHeldModifierThresholdCancelsOnProfileChange() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        store.profileName = "Finder"
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testHeldModifierThresholdCancelsOnWheelCenterProfileSelectorEntry() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        store.simulateHIDInputForTesting("wheel:center")
        scheduler.advance(by: 1)

        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertTrue(executed.isEmpty)
    }

    func testHeldModifierThresholdCancelsWhenAddingProfileReplacesActiveState() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)

        XCTAssertEqual(try store.addProfile(named: "Scratch"), "Scratch")
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testHeldModifierThresholdCancelsWhenDeletingActiveProfile() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        XCTAssertEqual(try store.addProfile(named: "Scratch"), "Scratch")
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)

        try store.deleteProfile(named: "Scratch")
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testThresholdEligibilityCancelsOnImportAndDisconnect() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        let exported = try XCTUnwrap(store.exportConfiguration())
        XCTAssertTrue(store.importConfiguration(exported))
        scheduler.advance(by: 1)
        store.simulateHIDInputForTesting(nil)
        XCTAssertTrue(executed.isEmpty)

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        store.hid.simulateDisconnectForTesting()
        scheduler.advance(by: 1)
        store.simulateHIDInputForTesting(nil)

        XCTAssertTrue(executed.isEmpty)
    }

    func testStackedDesignatedModifiersResolveExactLayerInEitherOrder() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(Mapping(action: .openApplication, command: "stacked"), for: .k1, gesture: .tap, modifierControls: [.k3, .k4])

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["stacked", "stacked"])
    }

    func testFastBaseThenK3LayerRemainTwoIndependentTaps() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        configureLayerTransitionCommands(in: store)

        pressAndReleaseK1(store)
        scheduler.advance(by: 0.10)
        // Primary-first deliberately exercises in-cycle reclassification.
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["base tap", "K3 tap"])
    }

    func testFastK3LayerThenBaseRemainTwoIndependentTaps() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        configureLayerTransitionCommands(in: store)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.10)
        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K3 tap", "base tap"])
    }

    func testFastK3ThenStackedLayerRemainTwoIndependentTaps() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(
            Mapping(action: .openApplication, command: "K3 tap"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3]
        )
        store.update(
            Mapping(action: .openApplication, command: "stacked tap"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3, .k4]
        )

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.10)
        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K3 tap", "stacked tap"])
    }

    func testFastKeyboardGateChangeDoesNotCreateHybridDouble() {
        let modifierState = ModifierState([.command])
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(
            scheduler: scheduler,
            remoteModifierProvider: { modifierState.value }
        ) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(
            Mapping(
                action: .openApplication,
                command: "command tap",
                remoteTriggerModifiers: [.command]
            ),
            for: .k1,
            gesture: .tap
        )
        store.update(
            Mapping(
                action: .openApplication,
                command: "command double",
                remoteTriggerModifiers: [.command]
            ),
            for: .k1,
            gesture: .doubleTap
        )

        pressAndReleaseK1(store)
        scheduler.advance(by: 0.10)
        modifierState.value = [.option]
        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["command tap"])
    }

    func testLayerRequiresExactDesignatedModifierSet() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(Mapping(action: .openApplication, command: "only K3"), for: .k1, gesture: .tap, modifierControls: [.k3])

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertTrue(executed.isEmpty)
    }

    func testTwoDesignatedModifiersWithoutPrimaryAreConsumed() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(Mapping(action: .openApplication, command: "k3"), for: .k3, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "k4"), for: .k4, gesture: .tap)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testUndeclaredKButtonRetainsNormalGestureBehavior() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(Mapping(action: .openApplication, command: "normal hold"), for: .k3, gesture: .hold)

        store.simulateHIDInputForTesting(k3Signature)
        scheduler.advance(by: 0.50)
        store.simulateHIDInputForTesting(nil)

        XCTAssertEqual(executed, ["normal hold"])
    }

    func testRemoteTriggerConditionDoesNotRetargetDestinationKButton() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(Mapping(action: .openApplication, command: "normal"), for: .k1, gesture: .tap)

        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["normal"])
    }

    func testRemoteTriggerCaptureReportsKModifiersWithoutExecutingThem() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        var captured: [RemoteControl] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.beginRemoteTriggerCapture { control in
            captured.append(control)
        }

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        store.endRemoteTriggerCapture()
        scheduler.advance(by: 1)

        XCTAssertEqual(captured, [.k3, .k1])
        XCTAssertTrue(executed.isEmpty)
    }

    func testDifferentDownReportConsumesAmbiguousPrimaryCycle() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(Mapping(action: .openApplication, command: "k1-hold"), for: .k1, gesture: .hold)
        store.update(Mapping(action: .openApplication, command: "k2-hold"), for: .k2, gesture: .hold)

        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting("r6:01 11 00 00 00 00 00")
        scheduler.advance(by: 0.50)
        store.simulateHIDInputForTesting(nil)

        XCTAssertTrue(executed.isEmpty)
    }

    func testModifierFirstSequenceFiresLayerWithinWindow() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        // M down past the threshold, M release arms the deferred solo window,
        // then D press within the window fires the sequence layer once.
        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        store.simulateHIDInputForTesting(nil)
        XCTAssertTrue(executed.isEmpty)

        scheduler.advance(by: 0.1)
        store.simulateHIDInputForTesting(k8Signature)
        XCTAssertEqual(executed, ["sequence"])

        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["sequence"])
    }

    func testDestinationFirstSequenceFiresLayerWithinWindow() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.simulateHIDInputForTesting(k8Signature)
        scheduler.advance(by: 0.1)
        XCTAssertTrue(executed.isEmpty)

        store.simulateHIDInputForTesting(k10Signature)
        XCTAssertEqual(executed, ["sequence"])

        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["sequence"])
    }

    func testSequenceWindowExpiryCommitsSoloOnceAndLaterDestinationActsSolo() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        store.simulateHIDInputForTesting(nil)

        // The solo Base commit is delayed to the window boundary and commits
        // exactly once.
        scheduler.advance(by: 0.499)
        XCTAssertTrue(executed.isEmpty)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(executed, ["K10 tap"])
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["K10 tap"])

        store.simulateHIDInputForTesting(k8Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 tap", "K8 base"])
    }

    func testDestinationWithinWindowSuppressesSoloCommit() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)
        store.simulateHIDInputForTesting(nil)

        scheduler.advance(by: 0.2)
        store.simulateHIDInputForTesting(k8Signature)
        XCTAssertEqual(executed, ["sequence"])

        // The expired-window commit must not repeat the modifier's solo Base.
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["sequence"])
    }

    func testCovisibleHoldPathFiresLayerOnceWithoutSequenceDuplication() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "K8 base"), for: .k8, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        // The destination joins while the modifier is still physically held,
        // so the existing hold routing owns the cycle and the sequence path
        // never arms a duplicate window.
        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.15)
        store.simulateHIDInputForTesting(k8Signature)
        scheduler.advance(by: 0.20)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["sequence"])
        XCTAssertFalse(executed.contains("K10 tap"))
        XCTAssertFalse(executed.contains("K8 base"))

        // No deferred window remains to fire anything else afterwards.
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["sequence"])
    }

    func testStackedModifiersWithSequenceLayerBehaveAsHold() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(Mapping(action: .openApplication, command: "stacked"), for: .k8, gesture: .tap, modifierControls: [.k10, .k4])

        store.simulateHIDInputForTesting(k10Signature)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(k8Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        // A two-modifier stack is fail-closed for sequences and keeps the
        // existing single layered Tap at the release boundary.
        XCTAssertEqual(executed, ["stacked"])

        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["stacked"])
    }

    func testSubThresholdModifierReleaseStillArmsSequenceWindow() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "sequence", comboMode: .sequence), for: .k8, gesture: .tap, modifierControls: [.k10])

        // A quick K10 tap releases well before the hold threshold, yet it is
        // still a press+release and must arm the sequence window.
        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.1)
        store.simulateHIDInputForTesting(nil)
        XCTAssertTrue(executed.isEmpty)

        scheduler.advance(by: 0.1)
        store.simulateHIDInputForTesting(k8Signature)
        XCTAssertEqual(executed, ["sequence"])

        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["sequence"])
    }

    func testSubThresholdSoloReleaseDefersBaseTapToWindowExpiryOnce() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.standardModifierHoldThreshold = 0.5
        store.setRemoteModifier(.k10, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K10 tap"), for: .k10, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "sequence", comboMode: .sequence), for: .k8, gesture: .tap, modifierControls: [.k10])

        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.1)
        store.simulateHIDInputForTesting(nil)

        // The deferred solo Base Tap commits exactly once at the window
        // boundary even though the release was sub-threshold.
        scheduler.advance(by: 0.499)
        XCTAssertTrue(executed.isEmpty)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(executed, ["K10 tap"])
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["K10 tap"])
    }

    private let k1Signature = "r6:01 12 00 00 00 00 00"
    private let k3Signature = "r6:00 3E 00 00 00 00 00"
    private let k4Signature = "r6:02 00 00 00 00 00 00"
    private let k8Signature = "r6:01 1D 00 00 00 00 00"
    private let k10Signature = "r6:03 1D 00 00 00 00 00"

    private func makeStore(
        scheduler: TestScheduler,
        remoteModifierProvider: @escaping MappingStore.RemoteModifierProvider = { [] },
        remoteFunctionKeyProvider: @escaping MappingStore.RemoteFunctionKeyProvider = { [] },
        remoteKeyProvider: @escaping MappingStore.RemoteKeyProvider = { _ in [] },
        execute: @escaping MappingStore.ActionExecutionOverride
    ) -> MappingStore {
        MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            actionExecutionOverride: execute,
            remoteModifierProvider: remoteModifierProvider,
            remoteFunctionKeyProvider: remoteFunctionKeyProvider,
            remoteKeyProvider: remoteKeyProvider
        )
    }

    private func configureGestureCommands(in store: MappingStore) {
        store.update(Mapping(action: .openApplication, command: "tap"), for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "hold"), for: .k1, gesture: .hold)
        store.update(Mapping(action: .openApplication, command: "double"), for: .k1, gesture: .doubleTap)
    }

    private func configureLayerTransitionCommands(in store: MappingStore) {
        store.update(Mapping(action: .openApplication, command: "base tap"), for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "base double"), for: .k1, gesture: .doubleTap)
        store.update(
            Mapping(action: .openApplication, command: "K3 tap"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3]
        )
        store.update(
            Mapping(action: .openApplication, command: "K3 double"),
            for: .k1,
            gesture: .doubleTap,
            modifierControls: [.k3]
        )
    }

    private func pressAndReleaseK1(_ store: MappingStore) {
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
    }
}
