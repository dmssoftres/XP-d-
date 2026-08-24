import Foundation
import XCTest
@testable import XPd

@MainActor
final class RunModeStoreTests: XCTestCase {
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

    func testDefaultsToEditMode() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MappingStore(userDefaults: defaults, startHardware: false)

        XCTAssertFalse(store.isRunMode)
    }

    func testRunModeTransitionSuccessFailureAndIdempotence() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var transitions: [Bool] = []
        var allowEdit = false
        let store = MappingStore(
            userDefaults: defaults,
            startHardware: false,
            runModeTransition: { enabled in
                transitions.append(enabled)
                if enabled || allowEdit {
                    return .success(enabled ? "Run mode enabled" : "Edit mode enabled")
                }
                return .failure("Edit mode unavailable")
            }
        )

        XCTAssertTrue(store.setRunMode(false))
        XCTAssertEqual(transitions, [])

        XCTAssertTrue(store.setRunMode(true))
        XCTAssertTrue(store.isRunMode)
        XCTAssertEqual(store.lastActionResult, .success("Run mode enabled"))
        XCTAssertTrue(store.setRunMode(true))
        XCTAssertEqual(transitions, [true])

        XCTAssertFalse(store.setRunMode(false))
        XCTAssertTrue(store.isRunMode)
        XCTAssertEqual(store.lastActionResult, .failure("Edit mode unavailable"))

        allowEdit = true
        XCTAssertTrue(store.setRunMode(false))
        XCTAssertFalse(store.isRunMode)
        XCTAssertEqual(store.lastActionResult, .success("Edit mode enabled"))
        XCTAssertEqual(transitions, [true, false, false])
    }

    func testMappedActionExecutesInRunModeWhileHIDSelectionStaysFrozen() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scheduler = TestScheduler()
        var executed: [String] = []
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
        let k1Signature = "r6:00 01 00 00 00 00 00"

        store.selectedControl = .k1
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(k1Signature)
        store.update(
            Mapping(action: .openApplication, command: "Run mapping"),
            for: .k1,
            gesture: .tap
        )
        store.selectedControl = .k2

        XCTAssertTrue(store.setRunMode(true))
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.31)

        XCTAssertEqual(executed, ["Run mapping"])
        XCTAssertEqual(store.selectedControl, .k2)

        XCTAssertTrue(store.setRunMode(false))
        store.simulateHIDInputForTesting(k1Signature)
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 0.31)

        XCTAssertEqual(executed, ["Run mapping", "Run mapping"])
        XCTAssertEqual(store.selectedControl, .k1)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "XPdTests.RunModeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
