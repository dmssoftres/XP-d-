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

    func testDifferentDownReportCancelsDisplacedLiveButton() {
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

        XCTAssertEqual(executed, ["k2-hold"])
    }

    private let k1Signature = "r6:01 12 00 00 00 00 00"

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

    private func configureGestureCommands(in store: MappingStore) {
        store.update(Mapping(action: .openApplication, command: "tap"), for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "hold"), for: .k1, gesture: .hold)
        store.update(Mapping(action: .openApplication, command: "double"), for: .k1, gesture: .doubleTap)
    }

    private func pressAndReleaseK1(_ store: MappingStore) {
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
    }
}
