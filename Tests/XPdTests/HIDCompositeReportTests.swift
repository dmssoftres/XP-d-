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

    func testUnrelatedEmptyReportsDoNotPreventModifierThresholdAction() {
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
        XCTAssertEqual(executed, ["K10 base"])

        // The already-fired cycle consumes a later K8 until report-6 release.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: k8Report)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        scheduler.advance(by: 1)
        XCTAssertEqual(executed, ["K10 base"])
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
