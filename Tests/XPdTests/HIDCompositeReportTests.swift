import Foundation
import XCTest
@testable import XPd

@MainActor
final class HIDCompositeReportTests: XCTestCase {
    func testUnrelatedCompositeEmptyReportsDoNotReleaseReport6Control() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        let k10Report = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
        let emptyReport = [UInt8](repeating: 0, count: 7)

        service.simulateInputReportForTesting(reportID: 6, bytes: k10Report)
        service.simulateInputReportForTesting(reportID: 1, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 7, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 9, bytes: emptyReport)

        XCTAssertEqual(events, ["r6:03 1D 00 00 00 00 00"])

        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        XCTAssertEqual(events, ["r6:03 1D 00 00 00 00 00", nil])
    }

    func testDisconnectClearsReportScopedReleaseTracking() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        let k10Report = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
        let emptyReport = [UInt8](repeating: 0, count: 7)

        service.simulateInputReportForTesting(reportID: 6, bytes: k10Report)
        service.simulateDisconnectForTesting()
        service.simulateInputReportForTesting(reportID: 1, bytes: emptyReport)

        // With no active report-6 control after disconnect, an empty report 6
        // is the verified standalone center press rather than a stale K release.
        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)

        XCTAssertEqual(events, ["r6:03 1D 00 00 00 00 00", "wheel:center"])
    }

    func testStandaloneReport6CenterPressAndReleaseRemainDistinct() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        let emptyReport = [UInt8](repeating: 0, count: 7)

        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 1, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 7, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 9, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)

        XCTAssertEqual(events, ["wheel:center", nil])
    }

    func testWheelDetentReleaseDoesNotConfirmHeldCenter() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        let emptyReport = [UInt8](repeating: 0, count: 7)
        let clockwiseReport: [UInt8] = [0x01, 0x57, 0, 0, 0, 0, 0]

        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        service.simulateInputReportForTesting(reportID: 6, bytes: clockwiseReport)
        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)

        XCTAssertEqual(events, ["wheel:center", "wheel:+"])

        service.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        XCTAssertEqual(events, ["wheel:center", "wheel:+", nil])
    }

    func testDecodedReport6K10ThenK8BeforeThresholdExecutesExactModifierLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let suiteName = "XPdTests.HIDCompositeReportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            actionExecutionOverride: { mapping, completion in
                executed.append(mapping.command)
                completion(.success(mapping.command))
            }
        )
        store.setRemoteModifier(.k10, enabled: true)
        store.update(
            Mapping(action: .openApplication, command: "K8 base"),
            for: .k8,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let emptyReport = [UInt8](repeating: 0, count: 7)
        let k10Report = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
        let k8Report = [UInt8](arrayLiteral: 0x01, 0x1D, 0, 0, 0, 0, 0)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Report)
        store.hid.simulateInputReportForTesting(reportID: 1, bytes: emptyReport)
        store.hid.simulateInputReportForTesting(reportID: 7, bytes: emptyReport)
        store.hid.simulateInputReportForTesting(reportID: 9, bytes: emptyReport)
        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k8Report)
        XCTAssertTrue(executed.isEmpty)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 layer"])
    }

    func testUnrelatedEmptyReportsDoNotPreventModifierReleaseCommitOrLateLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let suiteName = "XPdTests.HIDCompositeReportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            actionExecutionOverride: { mapping, completion in
                executed.append(mapping.command)
                completion(.success(mapping.command))
            }
        )
        store.setRemoteModifier(.k10, enabled: true)
        store.update(
            Mapping(action: .openApplication, command: "K10 base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let emptyReport = [UInt8](repeating: 0, count: 7)
        let k10Report = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
        let k8Report = [UInt8](arrayLiteral: 0x01, 0x1D, 0, 0, 0, 0, 0)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Report)
        store.hid.simulateInputReportForTesting(reportID: 1, bytes: emptyReport)
        store.hid.simulateInputReportForTesting(reportID: 7, bytes: emptyReport)
        store.hid.simulateInputReportForTesting(reportID: 9, bytes: emptyReport)
        scheduler.advance(by: 0.5)
        XCTAssertTrue(executed.isEmpty)

        // Unrelated empty reports do not release K10. A destination arriving
        // after the standalone threshold still forms the exact layer.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k8Report)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["K10 + K8 layer"])
    }

    func testDecodedReport6RepeatedDestinationUnderHeldK10ExecutesEachLayeredTap() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        clearAllKBindings(in: store)
        learnReport6("r6:00 71 00 00 00 00 00", for: .k10, in: store)
        learnReport6("r6:00 6D 00 00 00 00 00", for: .k6, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K6 Layer"),
            for: .k6,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10AndK6 = [UInt8](arrayLiteral: 0x00, 0x71, 0x6D, 0, 0, 0, 0)
        let k10Only = [UInt8](arrayLiteral: 0x00, 0x71, 0, 0, 0, 0, 0)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10AndK6)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        scheduler.advance(by: 0.30)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10AndK6)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        scheduler.advance(by: 0.30)

        store.hid.simulateInputReportForTesting(
            reportID: 6,
            bytes: [UInt8](repeating: 0, count: 7)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K6 Layer", "K10 + K6 Layer"])
        XCTAssertFalse(executed.contains("K10 Base"))
    }

    func testDecodedReport6TransitionFromK6ToK3UnderHeldK10ReconcilesDestination() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        clearAllKBindings(in: store)
        learnReport6("r6:00 71 00 00 00 00 00", for: .k10, in: store)
        learnReport6("r6:00 6D 00 00 00 00 00", for: .k6, in: store)
        learnReport6("r6:00 6A 00 00 00 00 00", for: .k3, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K6 Layer"),
            for: .k6,
            gesture: .tap,
            modifierControls: [.k10]
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K3 Layer"),
            for: .k3,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10AndK6 = [UInt8](arrayLiteral: 0x00, 0x71, 0x6D, 0, 0, 0, 0)
        let k10AndK3 = [UInt8](arrayLiteral: 0x00, 0x71, 0x6A, 0, 0, 0, 0)
        let k10Only = [UInt8](arrayLiteral: 0x00, 0x71, 0, 0, 0, 0, 0)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10AndK6)
        // K6 is released while K10 remains physically held.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10AndK3)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        scheduler.advance(by: 0.30)

        store.hid.simulateInputReportForTesting(
            reportID: 6,
            bytes: [UInt8](repeating: 0, count: 7)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K6 Layer", "K10 + K3 Layer"])
        XCTAssertFalse(executed.contains("K10 Base"))
    }

    func testDecodedReport6F13StyleChordToK6SnapshotCompletesLayerOnce() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        clearAllKBindings(in: store)
        learnReport6("r6:00 71 00 00 00 00 00", for: .k10, in: store)
        learnReport6("r6:00 6D 00 00 00 00 00", for: .k6, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K6 Layer"),
            for: .k6,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10AndK6 = [UInt8](arrayLiteral: 0x00, 0x71, 0x6D, 0, 0, 0, 0)
        let k6Only = [UInt8](arrayLiteral: 0x00, 0x6D, 0, 0, 0, 0, 0)
        let empty = [UInt8](repeating: 0, count: 7)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10AndK6)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k6Only)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K6 Layer"])
        XCTAssertFalse(executed.contains("K10 Base"))
    }

    func testReport2OneHotBindingsAreLearnedIndividuallyForEveryKButton() {
        let store = makeReport2Store()

        for (index, control) in RemoteControl.allCases
            .filter(\.isMIDIButton)
            .enumerated() {
            learnReport2(UInt16(1) << UInt16(index), for: control, in: store)
        }

        for (index, control) in RemoteControl.allCases
            .filter(\.isMIDIButton)
            .enumerated() {
            XCTAssertEqual(
                store.hidBinding(for: control),
                report2Signature(UInt16(1) << UInt16(index)),
                "Expected " + control.rawValue + " to retain its exact report-2 one-hot binding"
            )
        }
    }

    func testReport2K10AloneExecutesBaseOnlyOnReleaseAfterThreshold() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)

        scheduler.advance(by: 0.01)
        XCTAssertTrue(executed.isEmpty)

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        XCTAssertEqual(executed, ["K10 Base"])
    }

    func testReport2K10ThenK8BeforeThresholdExecutesOnlyExactLayerOnNeutralRelease() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8) | report2ButtonBit(.k10))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Layer"])
    }

    func testReport2K10ThenK8AtAndAfterThresholdStillExecutesExactLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.5)
        XCTAssertTrue(executed.isEmpty)

        // Equality with the threshold and a later arrival both remain layer
        // eligible while K10 is physically held.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.30)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Layer", "K10 + K8 Layer"])
        XCTAssertFalse(executed.contains("K10 Base"))
    }

    func testReport2DestinationFirstThenK10BeforeThresholdRoutesExactLayer() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K8 Base"),
            for: .k8,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8) | report2ButtonBit(.k10))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Layer"])
    }

    func testReport2ModifierFirstLayeredHoldExecutesOnlyLayerHold() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        configureLayeredGestureCommands(in: store)

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.10)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )

        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(executed, ["K10 + K8 Hold"])

        // Releasing the destination first must not re-arm K10 Base, and the
        // recognized Hold must suppress this press's layered Tap/Double.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 1)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Hold"])
    }

    func testReport2DestinationFirstLayeredHoldKeepsLayerWhenModifierReleasesFirst() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        configureLayeredGestureCommands(in: store)

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k8)
        )
        scheduler.advance(by: 0.10)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        scheduler.advance(by: 0.50)

        XCTAssertEqual(executed, ["K10 + K8 Hold"])

        // Once the exact layer has formed, releasing K10 first must not turn
        // the still-held destination into its Base gesture.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k8)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Hold"])
    }

    func testReport2SequentialDestinationsWhileK10HeldExecuteIndependentLayeredHolds() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k9), for: .k9, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        configureLayeredGestureCommands(in: store)
        store.update(
            Mapping(action: .openApplication, command: "K9 Base Hold"),
            for: .k9,
            gesture: .hold
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K9 Hold"),
            for: .k9,
            gesture: .hold,
            modifierControls: [.k10]
        )

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        let k9 = report2ButtonBit(.k9)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.10)

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        scheduler.advance(by: 0.50)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k9)
        )
        scheduler.advance(by: 0.50)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 1)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Hold", "K10 + K9 Hold"])
    }

    func testSavedReport2ExactCompositeBindingWinsOverBitmaskDecomposition() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        let compositeMask = report2ButtonBit(.k8) | report2ButtonBit(.k10)

        let configuration = XPdConfiguration(
            profiles: [.init(name: "Global", mappings: [], hidBindings: [])],
            profileName: "Global",
            showsInputOverlay: true,
            hardwareLayouts: [
                .init(
                    id: "legacy-composite",
                    name: "Legacy composite",
                    bindings: [
                        .init(control: .k1, signature: report2Signature(compositeMask)),
                        .init(control: .k8, signature: report2Signature(report2ButtonBit(.k8))),
                        .init(control: .k10, signature: report2Signature(report2ButtonBit(.k10)))
                    ]
                )
            ],
            activeHardwareLayoutID: "legacy-composite"
        )
        XCTAssertTrue(store.importConfiguration(try configuration.encodedData()))
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "Exact composite"),
            for: .k1,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: compositeMask)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["Exact composite"])
    }

    func testReport2AmbiguousDuplicateMaskCoverFailsClosed() {
        let firstBit = report2ButtonBit(.k1)
        let secondBit = report2ButtonBit(.k2)
        let bindings: [RemoteControl: String] = [
            .k1: report2Signature(firstBit),
            .k2: report2Signature(firstBit),
            .k3: report2Signature(secondBit)
        ]

        XCTAssertNil(
            MappingStore.decomposedStandardBitmaskControls(
                for: report2Signature(firstBit | secondBit),
                bindings: bindings
            )
        )
    }

    func testReport2PartialReleaseSnapshotsReplaceHeldStandardControls() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k9), for: .k9, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 + K9 Layer"),
            for: .k9,
            gesture: .tap,
            modifierControls: [.k10]
        )

        // K8 is released while K10 remains held; the next snapshot adds K9.
        // The released K8 must not remain as a stale second primary.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8) | report2ButtonBit(.k10))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k9) | report2ButtonBit(.k10))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K9 Layer"])
    }

    func testReport2DestinationReleaseBeforeNeutralDoesNotRearmK10Base() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.10)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        // K8 is released first, leaving K10 physically held.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )

        // Passing K10's standalone threshold must not re-arm its Base action
        // after the same cycle has already formed the K10+K8 layer.
        scheduler.advance(by: 0.60)
        XCTAssertFalse(executed.contains("K10 Base"))

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Layer"])
    }

    func testReport2ModifierReleaseFirstKeepsLayerUntilDestinationRelease() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K8 Base"),
            for: .k8,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        // Release the modifier first. The destination's already-formed layer
        // identity must survive until the destination itself is released.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k8)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 + K8 Layer"])
    }

    func testReport2SequentialDestinationsWhileK10HeldUseLayeredTaps() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k9), for: .k9, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K8 Base"),
            for: .k8,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K9 Base"),
            for: .k9,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Layer"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K9 Layer"),
            for: .k9,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        let k9 = report2ButtonBit(.k9)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.10)

        // K10 remains held while K8 is pressed and released.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k8)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.30)
        XCTAssertEqual(executed, ["K10 + K8 Layer"])

        // The same held modifier must then route the next destination to its
        // own layer, without leaking either destination into the other.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10 | k9)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.30)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(
            executed,
            ["K10 + K8 Layer", "K10 + K9 Layer"]
        )
        XCTAssertFalse(executed.contains("K10 Base"))
        XCTAssertFalse(executed.contains("K8 Base"))
        XCTAssertFalse(executed.contains("K9 Base"))
    }

    func testFactoryStyleReport6SequenceFiresLayerOnDestinationPress() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }
        clearAllKBindings(in: store)
        learnReport6("r6:00 71 00 00 00 00 00", for: .k10, in: store)
        learnReport6("r6:00 6D 00 00 00 00 00", for: .k6, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "sequence layer", comboMode: .sequence),
            for: .k6,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10Only = [UInt8](arrayLiteral: 0x00, 0x71, 0, 0, 0, 0, 0)
        let k6Only = [UInt8](arrayLiteral: 0x00, 0x6D, 0, 0, 0, 0, 0)
        let empty = [UInt8](repeating: 0, count: 7)

        // M solo down/up arms the deferred window anchored at its release.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k10Only)
        scheduler.advance(by: 0.5)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)
        XCTAssertTrue(executed.isEmpty)

        // D press within the window fires once and consumes the cycle.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k6Only)
        XCTAssertEqual(executed, ["sequence layer"])

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["sequence layer"])
        XCTAssertFalse(executed.contains("K10 Base"))
    }

    func testReport2SequenceWindowExpiryCommitsSoloOnceThenDestinationActsSolo() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(Mapping(action: .openApplication, command: "K8 Base"), for: .k8, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )

        let k10 = report2ButtonBit(.k10)
        let k8 = report2ButtonBit(.k8)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k10)
        )
        scheduler.advance(by: 0.5)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )

        scheduler.advance(by: 0.499)
        XCTAssertTrue(executed.isEmpty)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(executed, ["K10 Base"])

        // A separate destination press after expiry acts fully solo.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: k8)
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        scheduler.advance(by: 0.30)

        XCTAssertEqual(executed, ["K10 Base", "K8 Base"])
    }

    func testStandardSequenceMappingsStayInertInMIDIRealm() throws {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "sequence", comboMode: .sequence),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )
        _ = try store.addMIDIProfile(named: "MIDI Realm")
        store.profileName = "MIDI Realm"

        let k10 = report2Bytes(buttons: report2ButtonBit(.k10))
        let k8AndK10 = report2Bytes(buttons: report2ButtonBit(.k8) | report2ButtonBit(.k10))
        let neutral = report2Bytes(buttons: 0)
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: k10)
        scheduler.advance(by: 0.5)
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: neutral)
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: k8AndK10)
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: neutral)
        scheduler.advance(by: 1)

        XCTAssertTrue(executed.isEmpty)
    }

    func testRelearnedMIDIReport2FnHeldDestinationAndReleaseUseFunctionLayer() async throws {
        let store = makeReport2Store()
        _ = try store.addMIDIProfile(named: "Report 2 MIDI")

        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        XCTAssertTrue(store.updateMIDIPracticeFnControl(.k10))
        store.updatePrimaryButtonMapping(
            MIDIButtonMapping(kind: .note, note: 36, velocity: 100),
            for: .k8
        )
        store.updateFunctionButtonMapping(
            MIDIButtonMapping(kind: .note, note: 72, velocity: 110),
            for: .k8
        )
        store.clearMIDIMonitor()

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        XCTAssertTrue(store.isFnLayerActive)

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8) | report2ButtonBit(.k10))
        )
        XCTAssertTrue(store.isFnLayerActive)

        // Releasing only the destination keeps Fn held and releases the
        // function-layer note before the final neutral snapshot releases Fn.
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        XCTAssertTrue(store.isFnLayerActive)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        XCTAssertFalse(store.isFnLayerActive)

        await store.waitForMIDICommandsForTesting()
        for _ in 0..<3 { await Task.yield() }
        let summaries = store.midiMonitorEvents.map(\.summary)
        XCTAssertTrue(summaries.contains("Note On 72 · Ch 1 · V110"))
        XCTAssertTrue(summaries.contains("Note Off 72 · Ch 1"))
        XCTAssertFalse(summaries.contains { $0.hasPrefix("Note On 36") })
    }

    func testReport6MIDITwoButtonsOverlapAndReleaseIndependentlyInBothOrders() async throws {
        let store = makeReport2Store()
        _ = try store.addMIDIProfile(named: "Report 6 MIDI")

        let empty = [UInt8](repeating: 0, count: 7)
        let k1 = [UInt8](arrayLiteral: 0x00, 0x68, 0, 0, 0, 0, 0)
        let k2 = [UInt8](arrayLiteral: 0x00, 0x69, 0, 0, 0, 0, 0)
        let k1AndK2 = [UInt8](arrayLiteral: 0x00, 0x68, 0x69, 0, 0, 0, 0)

        store.selectedControl = .k1
        store.learnSelectedMIDIControl()
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k1)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)

        store.selectedControl = .k2
        store.learnSelectedMIDIControl()
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k2)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)

        store.updatePrimaryButtonMapping(
            MIDIButtonMapping(kind: .note, note: 60, velocity: 100),
            for: .k1
        )
        store.updatePrimaryButtonMapping(
            MIDIButtonMapping(kind: .note, note: 64, velocity: 100),
            for: .k2
        )

        func noteSummaries() -> [String] {
            store.midiMonitorEvents.reversed().map(\.summary).filter { $0.hasPrefix("Note ") }
        }

        store.clearMIDIMonitor()
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k1)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k1AndK2)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k2)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)
        await store.waitForMIDICommandsForTesting()

        XCTAssertEqual(
            noteSummaries(),
            [
                "Note On 60 · Ch 1 · V100",
                "Note On 64 · Ch 1 · V100",
                "Note Off 60 · Ch 1",
                "Note Off 64 · Ch 1"
            ]
        )

        store.clearMIDIMonitor()
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k2)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k1AndK2)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k1)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: empty)
        await store.waitForMIDICommandsForTesting()

        XCTAssertEqual(
            noteSummaries(),
            [
                "Note On 64 · Ch 1 · V100",
                "Note On 60 · Ch 1 · V100",
                "Note Off 64 · Ch 1",
                "Note Off 60 · Ch 1"
            ]
        )
    }

    func testReport6WheelReleaseDoesNotClearHeldReport2MIDIControls() async throws {
        let store = makeReport2Store()
        _ = try store.addMIDIProfile(named: "Report 2 Wheel Isolation")

        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        learnReport2(report2ButtonBit(.k8), for: .k8, in: store)
        XCTAssertTrue(store.updateMIDIPracticeFnControl(.k10))
        store.updateFunctionButtonMapping(
            MIDIButtonMapping(kind: .note, note: 72, velocity: 110),
            for: .k8
        )
        store.clearMIDIMonitor()

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        XCTAssertTrue(store.isFnLayerActive)

        let emptyReport = [UInt8](repeating: 0, count: 7)
        let clockwiseReport: [UInt8] = [0x01, 0x57, 0, 0, 0, 0, 0]
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: clockwiseReport)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)

        // The nil emitted by report 6 belongs to that collection only; Fn's
        // report-2 held set must survive the wheel detent release.
        XCTAssertTrue(store.isFnLayerActive)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8) | report2ButtonBit(.k10))
        )
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )

        await store.waitForMIDICommandsForTesting()
        for _ in 0..<3 { await Task.yield() }
        let summaries = store.midiMonitorEvents.map(\.summary)
        XCTAssertTrue(summaries.contains("Note On 72 · Ch 1 · V110"))
        XCTAssertFalse(summaries.contains { $0.hasPrefix("Note On 36") })
    }

    func testReport2RepeatsDoNotRestartModifierTimerOrDuplicateControls() {
        let scheduler = TestScheduler()
        var executed: [String] = []
        let store = makeReport2Store(scheduler: scheduler) { mapping, completion in
            executed.append(mapping.command)
            completion(.success(mapping.command))
        }

        learnReport2(report2ButtonBit(.k10), for: .k10, in: store)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.standardModifierHoldThreshold = 0.5
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )

        let k10 = report2Bytes(buttons: report2ButtonBit(.k10))
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: k10)
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: k10)
        scheduler.advance(by: 0.49)
        XCTAssertTrue(executed.isEmpty)

        // A repeat at the threshold boundary must not schedule a second timer
        // or move the existing timer's deadline.
        store.hid.simulateInputReportForTesting(reportID: 2, bytes: k10)
        scheduler.advance(by: 0.01)
        XCTAssertTrue(executed.isEmpty)

        store.hid.simulateInputReportForTesting(reportID: 2, bytes: k10)
        scheduler.advance(by: 1)
        XCTAssertTrue(executed.isEmpty)

        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        XCTAssertEqual(executed, ["K10 Base"])
    }

    func testNeutralReport2F0ReleasesAndUnrelatedEmptyReportsRemainIgnored() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        service.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k10))
        )
        service.simulateInputReportForTesting(
            reportID: 1,
            bytes: [UInt8](repeating: 0, count: 7)
        )
        service.simulateInputReportForTesting(
            reportID: 7,
            bytes: [UInt8](repeating: 0, count: 7)
        )
        service.simulateInputReportForTesting(
            reportID: 9,
            bytes: [UInt8](repeating: 0, count: 7)
        )
        // A zero-filled vendor packet has no report-2 F0 event marker and is
        // unrelated input; it must not become a release boundary.
        service.simulateInputReportForTesting(
            reportID: 2,
            bytes: [UInt8](repeating: 0, count: 7)
        )
        XCTAssertEqual(events, [report2Signature(report2ButtonBit(.k10))])

        service.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )
        XCTAssertEqual(
            events,
            [report2Signature(report2ButtonBit(.k10)), report2Signature(0)]
        )
    }

    func testMalformedOrUnknownReport2EventsFailClosed() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        let malformedReports: [[UInt8]] = [
            [],
            [0xF0],
            [0xF0, 0x01],
            [0xF1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00],
            // Bits above the ten physical buttons are not a valid one-hot or
            // composite state and must not be guessed as a K control.
            [0xF0, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]
        ]

        for bytes in malformedReports {
            service.simulateInputReportForTesting(reportID: 2, bytes: bytes)
        }

        XCTAssertTrue(events.isEmpty)
    }

    func testReport6KeyboardBehaviorRemainsAvailableAlongsideReport2() {
        let service = HIDService(startHardware: false)
        var events: [String?] = []
        service.onInput = { events.append($0) }

        service.simulateInputReportForTesting(
            reportID: 6,
            bytes: [0x03, 0x1D, 0, 0, 0, 0, 0]
        )
        service.simulateInputReportForTesting(
            reportID: 6,
            bytes: [UInt8](repeating: 0, count: 7)
        )

        service.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k8))
        )
        service.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: 0)
        )

        XCTAssertEqual(
            events,
            [
                "r6:03 1D 00 00 00 00 00",
                nil,
                report2Signature(report2ButtonBit(.k8)),
                report2Signature(0)
            ]
        )
    }

    private func makeReport2Store(
        scheduler: TestScheduler? = nil,
        actionExecutionOverride: MappingStore.ActionExecutionOverride? = nil
    ) -> MappingStore {
        let suiteName = "XPdTests.HIDCompositeReportTests.Report2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { delay, action in
                (scheduler ?? TestScheduler()).schedule(delay: delay, action: action)
            },
            actionExecutionOverride: actionExecutionOverride,
            // Never read the Mac's live keyboard state: a real key or modifier
            // held during the run (e.g. from the paired remote) made these
            // timing tests fail intermittently.
            remoteModifierProvider: { [] },
            remoteFunctionKeyProvider: { [] },
            remoteKeyProvider: { _ in [] }
        )
    }

    private func clearAllKBindings(in store: MappingStore) {
        for control in RemoteControl.allCases where control.isMIDIButton {
            store.clearHIDBinding(for: control)
        }
    }

    private func learnReport6(
        _ signature: String,
        for control: RemoteControl,
        in store: MappingStore
    ) {
        store.selectedControl = control
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(signature)
        XCTAssertEqual(
            store.hidBinding(for: control),
            signature,
            "Expected \(control.rawValue) to learn its report-6 binding"
        )
    }

    private func configureLayeredGestureCommands(in store: MappingStore) {
        store.update(
            Mapping(action: .openApplication, command: "K10 Base"),
            for: .k10,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K8 Base Tap"),
            for: .k8,
            gesture: .tap
        )
        store.update(
            Mapping(action: .openApplication, command: "K8 Base Hold"),
            for: .k8,
            gesture: .hold
        )
        store.update(
            Mapping(action: .openApplication, command: "K8 Base Double"),
            for: .k8,
            gesture: .doubleTap
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Tap"),
            for: .k8,
            gesture: .tap,
            modifierControls: [.k10]
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Hold"),
            for: .k8,
            gesture: .hold,
            modifierControls: [.k10]
        )
        store.update(
            Mapping(action: .openApplication, command: "K10 + K8 Double"),
            for: .k8,
            gesture: .doubleTap,
            modifierControls: [.k10]
        )
    }

    private func learnReport2(
        _ buttons: UInt16,
        for control: RemoteControl,
        in store: MappingStore
    ) {
        store.selectedControl = control
        store.learnSelectedControl()
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: buttons)
        )
        XCTAssertEqual(
            store.hidBinding(for: control),
            report2Signature(buttons),
            "Expected " + control.rawValue + " to learn its report-2 binding"
        )
    }

    private func report2ButtonBit(_ control: RemoteControl) -> UInt16 {
        guard let index = RemoteControl.allCases
            .filter(\.isMIDIButton)
            .firstIndex(of: control) else {
            return 0
        }
        return UInt16(1) << UInt16(index)
    }

    private func report2Bytes(buttons: UInt16) -> [UInt8] {
        [0xF0, UInt8(truncatingIfNeeded: buttons), UInt8(truncatingIfNeeded: buttons >> 8)]
            + Array(repeating: 0, count: 28)
    }

    private func report2Signature(_ buttons: UInt16) -> String {
        "r2:" + report2Bytes(buttons: buttons)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }

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
