import XCTest
@testable import XPd

final class HIDKeyboardReportTests: XCTestCase {
    func testK10FirstMasksK8WhenTheirKeyboardStatesAreMerged() {
        let bindings: [RemoteControl: String] = [
            .k10: "r6:03 1D 00 00 00 00 00",
            .k8: "r6:01 1D 00 00 00 00 00"
        ]

        XCTAssertEqual(
            HIDKeyboardReportCollisionAnalyzer.collisions(
                between: .k10,
                and: .k8,
                bindings: bindings
            ),
            [HIDKeyboardReportCollision(firstControl: .k10, hiddenControl: .k8)]
        )
    }

    func testReverseSelectedLayerDirectionDoesNotWarnWhenDestinationIsPressedFirst() {
        let bindings: [RemoteControl: String] = [
            .k10: "r6:03 1D 00 00 00 00 00",
            .k8: "r6:01 1D 00 00 00 00 00"
        ]

        // K10 as the modifier and K8 as the destination is the failing
        // physical order: the K10 state masks K8. If the roles are reversed,
        // the selected destination is K10 and the expected order is K8 then
        // K10, so the warning must not be shown for that layer.
        XCTAssertEqual(
            HIDKeyboardReportCollisionAnalyzer.collisions(
                for: .k8,
                modifierControls: [.k10],
                bindings: bindings
            ),
            [HIDKeyboardReportCollision(firstControl: .k10, hiddenControl: .k8)]
        )
        XCTAssertTrue(
            HIDKeyboardReportCollisionAnalyzer.collisions(
                for: .k10,
                modifierControls: [.k8],
                bindings: bindings
            ).isEmpty
        )
    }

    func testExactIdenticalSignaturesReportBothIndistinguishableDirections() {
        let bindings: [RemoteControl: String] = [
            .k1: "r6:01 1D 00 00 00 00 00",
            .k2: "r6:01 1D 00 00 00 00 00"
        ]

        let collisions = HIDKeyboardReportCollisionAnalyzer.collisions(
            between: .k1,
            and: .k2,
            bindings: bindings
        )

        XCTAssertEqual(
            Set(collisions),
            Set([
                HIDKeyboardReportCollision(firstControl: .k1, hiddenControl: .k2),
                HIDKeyboardReportCollision(firstControl: .k2, hiddenControl: .k1)
            ])
        )
    }

    func testNonOverlappingKeyboardStatesDoNotReportCollision() {
        let bindings: [RemoteControl: String] = [
            .k1: "r6:00 04 00 00 00 00 00",
            .k2: "r6:00 05 00 00 00 00 00"
        ]

        XCTAssertTrue(
            HIDKeyboardReportCollisionAnalyzer.collisions(
                between: .k1,
                and: .k2,
                bindings: bindings
            ).isEmpty
        )
    }

    func testAllLearnedFactoryBindingsReportEveryOrderSpecificMaskingPair() {
        let bindings: [RemoteControl: String] = [
            .k1: "r6:01 12 00 00 00 00 00",
            .k2: "r6:01 11 00 00 00 00 00",
            .k3: "r6:00 3E 00 00 00 00 00",
            .k4: "r6:02 00 00 00 00 00 00",
            .k5: "r6:01 00 00 00 00 00 00",
            .k6: "r6:04 00 00 00 00 00 00",
            .k7: "r6:01 16 00 00 00 00 00",
            .k8: "r6:01 1D 00 00 00 00 00",
            .k9: "r6:00 2C 00 00 00 00 00",
            .k10: "r6:03 1D 00 00 00 00 00"
        ]

        XCTAssertEqual(
            Set(HIDKeyboardReportCollisionAnalyzer.collisions(among: bindings)),
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
        XCTAssertTrue(HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(among: bindings).isEmpty)
    }

    func testUniqueFunctionKeyBindingsHaveNoContainmentCollisions() {
        let bindings = Dictionary(uniqueKeysWithValues: RemoteControl.allCases
            .filter(\.isMIDIButton)
            .enumerated()
            .map { index, control in
                (control, String(format: "r6:00 %02X 00 00 00 00 00", 0x68 + index))
            })

        XCTAssertTrue(HIDKeyboardReportCollisionAnalyzer.collisions(among: bindings).isEmpty)
        XCTAssertTrue(HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(among: bindings).isEmpty)
    }

    func testReport2OneHotBindingsParseAcrossBothMaskBytes() throws {
        let k1 = try XCTUnwrap(HIDKeyboardReport(signature: "r2:F0 01 00 00 00 00 00 00"))
        let k8 = try XCTUnwrap(HIDKeyboardReport(signature: "r2:F0 80 00 00 00 00 00 00"))
        let k9 = try XCTUnwrap(HIDKeyboardReport(signature: "r2:F0 00 01 00 00 00 00 00"))
        let k10 = try XCTUnwrap(HIDKeyboardReport(signature: "r2:F0 00 02 00 00 00 00 00"))

        XCTAssertEqual(k1.encoding, .report2OneHot)
        XCTAssertEqual(k1.oneHotMask, 0x0001)
        XCTAssertEqual(k8.oneHotMask, 0x0080)
        XCTAssertEqual(k9.oneHotMask, 0x0100)
        XCTAssertEqual(k10.oneHotMask, 0x0200)
        XCTAssertTrue([k1, k8, k9, k10].allSatisfy(\.isCompatibleIndividualBinding))

    }

    func testReport2CompositeStateIsParseableButNotAnIndividualBinding() throws {
        let composite = try XCTUnwrap(
            HIDKeyboardReport(signature: "r2:F0 03 00 00 00 00 00 00")
        )

        XCTAssertEqual(composite.encoding, .report2OneHot)
        XCTAssertEqual(composite.oneHotMask, 0x0003)
        XCTAssertFalse(composite.isCompatibleIndividualBinding)
        XCTAssertEqual(
            HIDKeyboardReport.report2OneHotMask(from: "r2:F0 03 00 00 00 00 00 00"),
            0x0003
        )
    }

    func testReport2RejectsUnknownBitsAndNonZeroPadding() {
        let invalidSignatures = [
            "r1:F0 01 00 00 00 00 00 00",
            "r2:F0 01",
            "r2:01 01 00 00 00 00 00 00",
            "r2:F0 00 04 00 00 00 00 00",
            "r2:F0 01 00 01 00 00 00 00",
            "r2:F0 GG 00 00 00 00 00 00"
        ]

        for signature in invalidSignatures {
            XCTAssertNil(
                HIDKeyboardReport(signature: signature),
                "Expected malformed/non-one-hot report-2 signature to be rejected: \(signature)"
            )
            XCTAssertNil(HIDKeyboardReport.report2OneHotMask(from: signature))
        }
    }

    func testUniqueReport2OneHotBindingsHaveNoMaskingOrRolloverCollisions() {
        let bindings = Dictionary(uniqueKeysWithValues: RemoteControl.allCases
            .filter(\.isMIDIButton)
            .enumerated()
            .map { index, control in
                let byteOffset = index < 8 ? 0 : 1
                let bit = UInt8(1 << (index < 8 ? index : index - 8))
                let firstMask = byteOffset == 0 ? bit : 0
                let secondMask = byteOffset == 1 ? bit : 0
                return (
                    control,
                    String(format: "r2:F0 %02X %02X 00 00 00 00 00", firstMask, secondMask)
                )
            })

        XCTAssertEqual(HIDKeyboardReportCollisionAnalyzer.collisions(among: bindings), [])
        XCTAssertEqual(HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(among: bindings), [])
    }

    func testDuplicateReport2OneHotBindingReportsBothIndistinguishableDirections() {
        let bindings: [RemoteControl: String] = [
            .k1: "r2:F0 01 00 00 00 00 00 00",
            .k2: "r2:F0 01 00 00 00 00 00 00"
        ]

        XCTAssertEqual(
            Set(HIDKeyboardReportCollisionAnalyzer.collisions(among: bindings)),
            Set([
                HIDKeyboardReportCollision(firstControl: .k1, hiddenControl: .k2),
                HIDKeyboardReportCollision(firstControl: .k2, hiddenControl: .k1)
            ])
        )
        XCTAssertEqual(HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(among: bindings), [])
    }

    func testIndividuallyParseableMultiKeyReportsExposeRolloverCapacityPair() {
        let first = "r6:00 04 05 06 07 00 00"
        let second = "r6:00 08 09 0A 0B 00 00"
        XCTAssertNotNil(HIDKeyboardReport(signature: first))
        XCTAssertNotNil(HIDKeyboardReport(signature: second))

        XCTAssertEqual(
            HIDKeyboardReportCollisionAnalyzer.rolloverCollisions(
                among: [.k1: first, .k2: second]
            ),
            [
                HIDKeyboardReportRolloverCollision(
                    firstControl: .k1,
                    secondControl: .k2,
                    combinedOrdinaryKeyCount: 8
                )
            ]
        )
    }

    func testReportParserNormalizesZeroSlotsAndKeyOrder() {
        let ordered = HIDKeyboardReport(signature: "r6:01 1D 00 00 00 00 00")
        let reordered = HIDKeyboardReport(signature: "R6:01 00 00 1D 00 00 00")
        let legacyReportIDForm = HIDKeyboardReport(signature: "r6:06 01 1D 00 00 00 00 00")

        XCTAssertNotNil(ordered)
        XCTAssertEqual(ordered, reordered)
        XCTAssertEqual(ordered, legacyReportIDForm)
    }

    func testReportParserRejectsMalformedAndNonKeyboardSignatures() {
        let invalidSignatures = [
            "r1:03 1D 00 00 00 00 00",
            "r6:GG 1D 00 00 00 00 00",
            "r6:03 1D 00",
            "r6:03 1D 00 00 00 00 00 00"
        ]

        for signature in invalidSignatures {
            XCTAssertNil(
                HIDKeyboardReport(signature: signature),
                "Expected malformed/non-report-6 signature to be rejected: \(signature)"
            )
        }
    }
}

@MainActor
final class HIDKeyboardReportRuntimeTests: XCTestCase {
    func testExactK10ReportWinsOverItsK8Subset() {
        let scheduler = TestScheduler()
        let executionLog = ExecutionLog()
        let store = makeStore(scheduler: scheduler, executionLog: executionLog)

        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "K10 base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K8 base"),
            for: .k8,
            gesture: .tap
        )

        // K10 is an exact learned binding. Even though K8's report is a
        // strict subset, the runtime must not synthesize K8 from the K10
        // packet or execute the wrong action.
        store.simulateHIDInputForTesting(k10Signature)
        scheduler.advance(by: 0.5)

        XCTAssertEqual(executionLog.values, ["K10 base"])
    }

    func testUnmatchedUnionOfTwoNonOverlappingBindingsResolvesBothControls() {
        let scheduler = TestScheduler()
        let executionLog = ExecutionLog()
        let store = makeStore(scheduler: scheduler, executionLog: executionLog)
        clearAllKBindings(in: store)
        learn("r6:01 04 00 00 00 00 00", for: .k1, in: store)
        learn("r6:01 05 00 00 00 00 00", for: .k2, in: store)
        learn("r6:01 00 00 00 00 00 00", for: .k3, in: store)

        XCTAssertTrue(store.setRemoteModifier(.k1, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "K1 + K2 layer"),
            for: .k2,
            gesture: .tap,
            modifierControls: [.k1]
        )

        // There is no exact binding for this report. The unique minimum
        // cover is K1 + K2; K3 is a redundant pure-modifier subset and must
        // not make the resolver choose a spurious alternative. The resolved
        // controls should enter the same layer state machine as two
        // physically observed controls.
        store.simulateHIDInputForTesting("r6:01 04 05 00 00 00 00")
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executionLog.values, ["K1 + K2 layer"])
    }

    func testUnmatchedSingleSubsetIsNotSynthesizedAsAControl() {
        let scheduler = TestScheduler()
        let executionLog = ExecutionLog()
        let store = makeStore(scheduler: scheduler, executionLog: executionLog)
        clearAllKBindings(in: store)
        learn("r6:00 04 00 00 00 00 00", for: .k1, in: store)
        store.update(
            Mapping(action: .openApplication, command: "K1 base"),
            for: .k1,
            gesture: .tap
        )

        // A single subset does not explain the complete report. Failing
        // closed avoids firing K1 when another, unlearned key is present.
        store.simulateHIDInputForTesting("r6:00 04 05 00 00 00 00")
        scheduler.advance(by: 1)

        XCTAssertTrue(executionLog.values.isEmpty)
    }

    func testTiedMinimumCoversAreRejectedAsAmbiguous() {
        // K1+K2, K1+K4, K3+K2, and K3+K4 are tied minimum covers. The
        // resolver must reject all of them instead of choosing by dictionary
        // order. Use the pure resolver seam so duplicate signatures are kept
        // in the fixture; the learning UI intentionally removes duplicates.
        let bindings: [RemoteControl: String] = [
            .k1: "r6:00 04 00 00 00 00 00",
            .k2: "r6:00 05 00 00 00 00 00",
            .k3: "r6:00 04 00 00 00 00 00",
            .k4: "r6:00 05 00 00 00 00 00"
        ]

        XCTAssertNil(
            MappingStore.decomposedKeyboardControls(
                for: "r6:00 04 05 00 00 00 00",
                bindings: bindings
            )
        )
    }

    private let k10Signature = "r6:03 1D 00 00 00 00 00"

    private func makeStore(
        scheduler: TestScheduler,
        executionLog: ExecutionLog
    ) -> MappingStore {
        let suiteName = "XPdTests.HIDKeyboardReportRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            actionExecutionOverride: { mapping, completion in
                executionLog.values.append(mapping.command)
                completion(.success(mapping.command))
            }
        )
    }

    private func clearAllKBindings(in store: MappingStore) {
        for control in RemoteControl.allCases where control.isMIDIButton {
            store.clearHIDBinding(for: control)
        }
    }

    private func learn(_ signature: String, for control: RemoteControl, in store: MappingStore) {
        store.selectedControl = control
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(signature)
        XCTAssertEqual(store.hidBinding(for: control), signature)
    }

    private final class ExecutionLog {
        var values: [String] = []
    }

    @MainActor
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
}
