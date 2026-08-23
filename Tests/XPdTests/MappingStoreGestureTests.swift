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
        scheduler.advance(by: 0.72)
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
        scheduler.advance(by: 0.72)

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
        scheduler.advance(by: 0.72)
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

    func testSequentialModifierReleaseThenPrimaryUsesPendingLayer() {
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
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.10)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K3 layer"])
    }

    func testStandaloneModifierTapWaitsForGraceWindow() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.29)
        XCTAssertTrue(executed.isEmpty)

        scheduler.advance(by: 0.01)
        XCTAssertEqual(executed, ["K3 tap"])
    }

    func testSequentialStackedModifiersResolveExactLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(
            Mapping(action: .openApplication, command: "stacked layer"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3, .k4]
        )

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.10)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.10)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["stacked layer"])
    }

    func testSplitModifierThenRolloverPrimaryUsesBothModifiers() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(
            Mapping(action: .openApplication, command: "split stacked layer"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3, .k4]
        )

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        store.simulateHIDInputForTesting(k4Signature)
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["split stacked layer"])
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
        store.simulateHIDInputForTesting(nil)
        store.simulateHIDInputForTesting(k4Signature)
        scheduler.advance(by: 0.31)
        XCTAssertTrue(executed.isEmpty)

        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)
        XCTAssertTrue(executed.isEmpty)
    }

    func testModifierPrimaryAfterGraceExecutesStandaloneThenBase() {
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

        XCTAssertEqual(executed, ["K3 tap", "base"])
    }

    func testPendingModifierTapCancelsOnProfileChange() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        store.profileName = "Finder"
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testPendingModifierTapCancelsOnWheelCenterProfileSelectorEntry() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)

        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)
        store.simulateHIDInputForTesting("wheel:center")
        scheduler.advance(by: 1)

        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertTrue(executed.isEmpty)
    }

    func testPendingModifierTapCancelsWhenAddingProfileReplacesActiveState() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)
        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)

        XCTAssertEqual(try store.addProfile(named: "Scratch"), "Scratch")
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testPendingModifierTapCancelsWhenDeletingActiveProfile() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        XCTAssertEqual(try store.addProfile(named: "Scratch"), "Scratch")
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "K3 tap"), for: .k3, gesture: .tap)
        store.simulateHIDInputForTesting(k3Signature)
        store.simulateHIDInputForTesting(nil)

        try store.deleteProfile(named: "Scratch")
        scheduler.advance(by: 1)

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

    func testDesignatedModifierTapExecutesButHoldDoesNot() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.setRemoteModifier(.k3, enabled: true)
        store.update(Mapping(action: .openApplication, command: "modifier tap"), for: .k3, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "modifier hold"), for: .k3, gesture: .hold)

        store.simulateHIDInputForTesting(k3Signature)
        scheduler.advance(by: 1)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["modifier tap"])
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
        scheduler.advance(by: 0.72)
        store.simulateHIDInputForTesting(nil)

        XCTAssertEqual(executed, ["normal hold"])
    }

    func testRemoteTriggerCaptureConsumesKButtonUntilEnded() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        var captured: RemoteControl?
        let store = makeStore(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        store.update(Mapping(action: .openApplication, command: "normal"), for: .k1, gesture: .tap)

        store.beginRemoteTriggerCapture { captured = $0 }
        pressAndReleaseK1(store)
        scheduler.advance(by: 1)
        XCTAssertEqual(captured, .k1)
        XCTAssertTrue(executed.isEmpty)

        store.endRemoteTriggerCapture()
        pressAndReleaseK1(store)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["normal"])
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
        scheduler.advance(by: 0.72)
        store.simulateHIDInputForTesting(nil)

        XCTAssertTrue(executed.isEmpty)
    }

    private let k1Signature = "r6:01 12 00 00 00 00 00"
    private let k3Signature = "r6:00 3E 00 00 00 00 00"
    private let k4Signature = "r6:02 00 00 00 00 00 00"

    private func makeStore(
        scheduler: TestScheduler,
        remoteModifierProvider: @escaping MappingStore.RemoteModifierProvider = { [] },
        remoteFunctionKeyProvider: @escaping MappingStore.RemoteFunctionKeyProvider = { [] },
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
            remoteFunctionKeyProvider: remoteFunctionKeyProvider
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
