import Foundation
import XCTest
@testable import XPd

@MainActor
final class KeyMonitorTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""
    private var scheduler = TestScheduler()

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

        func schedule(delay: TimeInterval, action: @escaping @MainActor () -> Void) -> GestureScheduledAction {
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


    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.KeyMonitorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        scheduler = TestScheduler()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testShowsHeldKeysAndComboWithItsResult() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(Mapping(action: .openApplication, command: "Calculator"), for: .k5, gesture: .tap, modifierControls: [.k10])

        store.simulateHIDInputForTesting("r2:F0 00 02 00 00 00 00 00") // K10
        scheduler.advance(by: 0.5)
        store.simulateHIDInputForTesting("r2:F0 10 02 00 00 00 00 00") // K10 + K5
        XCTAssertEqual(store.keyMonitorHeldControls, [.k5, .k10])
        store.simulateHIDInputForTesting("r2:F0 00 02 00 00 00 00 00")
        store.simulateHIDInputForTesting("r2:F0 00 00 00 00 00 00 00")
        scheduler.advance(by: 2)

        XCTAssertEqual(store.keyMonitorHeldControls, [])
        XCTAssertEqual(store.keyMonitorEvents.first?.input, "K10 + K5 · Tap")
        XCTAssertEqual(store.keyMonitorEvents.first?.result, "Calculator")
    }

    func testUnmappedPressStillShowsAndWheelClicksFold() {
        let store = makeStore()
        store.simulateHIDInputForTesting("r2:F0 01 00 00 00 00 00 00") // K1
        store.simulateHIDInputForTesting("r2:F0 00 00 00 00 00 00 00")
        scheduler.advance(by: 2)
        for _ in 0..<3 {
            store.simulateHIDInputForTesting("wheel:+")
            scheduler.advance(by: 0.2)
        }
        let events = store.keyMonitorEvents
        XCTAssertEqual(events.first?.input, "Wheel ↻")
        XCTAssertEqual(events.first?.count, 3)
        XCTAssertEqual(events.dropFirst().first?.input, "K1 · Tap")
        XCTAssertEqual(events.dropFirst().first?.result, "no action")
    }

    func testHiddenMonitorRecordsNothingAndSettingPersists() {
        let store = makeStore()
        XCTAssertTrue(store.showsKeyMonitor, "On by default")
        store.showsKeyMonitor = false
        store.simulateHIDInputForTesting("wheel:+")
        XCTAssertTrue(store.keyMonitorEvents.isEmpty)
        XCTAssertFalse(MappingStore(userDefaults: defaults, startHardware: false).showsKeyMonitor)
    }

    func testListIsCapped() {
        let store = makeStore()
        for index in 0..<10 {
            store.simulateHIDInputForTesting(index.isMultiple(of: 2) ? "wheel:+" : "wheel:-")
            scheduler.advance(by: 0.2)
        }
        XCTAssertEqual(store.keyMonitorEvents.count, MappingStore.keyMonitorEventLimit)
        store.clearKeyMonitor()
        XCTAssertTrue(store.keyMonitorEvents.isEmpty)
    }

    private func makeStore() -> MappingStore {
        let store = MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { [scheduler] delay, action in scheduler.schedule(delay: delay, action: action) },
            actionExecutionOverride: { mapping, completion in completion(.success(mapping.command)) }
        )
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        return store
    }
}
