import Foundation
import XCTest
@testable import XPd

@MainActor
final class WheelModifierLayerTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""
    private var executed: [String] = []
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
        suiteName = "XPdTests.WheelModifierLayerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        executed = []
        scheduler = TestScheduler()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // Driver-mode (Bluetooth) signatures: K10 is bit 1 of the high byte.
    private let k10Held = "r2:F0 00 02 00 00 00 00 00"
    private let nothingHeld = "r2:F0 00 00 00 00 00 00 00"
    private let volumeUp = Mapping(action: .mediaControl, command: MediaControlAction.volumeUp.rawValue)

    func testControlHoldingModPastThresholdAloneRunsItsOwnTap() {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(Mapping(action: .openApplication, command: "K10 base"), for: .k10, gesture: .tap)

        store.simulateHIDInputForTesting(k10Held)
        scheduler.advance(by: 2)
        store.simulateHIDInputForTesting(nothingHeld)
        scheduler.advance(by: 2)
        XCTAssertEqual(executed, ["K10 base"], "Proves the setup reaches the point where K10's Tap would fire")
    }

    func testHoldModAndTurnRunsLayerActionAndSuppressesModTap() {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(Mapping(action: .openApplication, command: "K10 base"), for: .k10, gesture: .tap)
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)

        store.simulateHIDInputForTesting(k10Held)
        scheduler.advance(by: 2)
        store.simulateHIDInputForTesting("wheel:+")
        scheduler.advance(by: 0.2)
        store.simulateHIDInputForTesting("wheel:+")
        scheduler.advance(by: 0.2)
        store.simulateHIDInputForTesting(nothingHeld)
        scheduler.advance(by: 2)

        XCTAssertEqual(executed, ["Volume up", "Volume up"], "One action per wheel click; K10's own Tap suppressed")
    }

    func testOtherDirectionWithoutActionStillScrolls() {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)

        store.simulateHIDInputForTesting(k10Held)
        store.simulateHIDInputForTesting("wheel:-")
        XCTAssertEqual(executed, [], "No counter-clockwise action set: normal scrolling")
    }

    func testTurningWithoutModNeverRunsLayerAction() {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)

        store.simulateHIDInputForTesting("wheel:+")
        XCTAssertEqual(executed, [])
    }

    func testOnlyKeysAndMediaAndOnlyMODKeysAreAccepted() {
        let store = makeDriverModeStore()
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)
        XCTAssertEqual(store.wheelLayerMapping(for: .wheelCW, modifier: .k10), Mapping(), "K10 is not a MOD key yet")

        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.updateWheelLayerMapping(Mapping(action: .typeText, command: "hi"), for: .wheelCW, modifier: .k10)
        XCTAssertEqual(store.wheelLayerMapping(for: .wheelCW, modifier: .k10), Mapping(), "Type text not offered for the wheel")
        store.updateWheelLayerMapping(volumeUp, for: .k1, modifier: .k10)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap, modifierControls: [.k10]), Mapping())

        store.updateWheelLayerMapping(volumeUp, for: .wheelCCW, modifier: .k10)
        XCTAssertEqual(store.wheelLayerMapping(for: .wheelCCW, modifier: .k10), volumeUp)
    }

    func testWheelLayerSurvivesRestartExportImportAndIsUndoable() throws {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)

        let reloaded = MappingStore(userDefaults: defaults, startHardware: false)
        XCTAssertEqual(reloaded.wheelLayerMapping(for: .wheelCW, modifier: .k10), volumeUp)

        let data = try XCTUnwrap(store.exportConfiguration())
        store.updateWheelLayerMapping(Mapping(), for: .wheelCW, modifier: .k10)
        XCTAssertTrue(store.importConfiguration(data))
        XCTAssertEqual(store.wheelLayerMapping(for: .wheelCW, modifier: .k10), volumeUp)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.wheelLayerMapping(for: .wheelCW, modifier: .k10), Mapping())
    }

    func testReport6HeldModKeepsLayerForSeveralClicksAndSuppressesTap() {
        let store = makeStore(driverMode: false)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(Mapping(action: .openApplication, command: "K10 base"), for: .k10, gesture: .tap)
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)

        store.simulateHIDInputForTesting("r6:03 1D 00 00 00 00 00") // factory K10 held
        scheduler.advance(by: 2)
        for _ in 0..<3 {
            store.simulateHIDInputForTesting("wheel:+")
            scheduler.advance(by: 0.2)
            store.simulateHIDInputForTesting("r6:03 1D 00 00 00 00 00") // K10 state re-sent
        }
        store.simulateHIDInputForTesting(nil)
        scheduler.advance(by: 2)
        XCTAssertEqual(executed, ["Volume up", "Volume up", "Volume up"])
    }

    func testOtherHeldKeyDoesNotFireAfterWheelLayer() {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(Mapping(action: .openApplication, command: "K10+K3"), for: .k3, gesture: .tap, modifierControls: [.k10])
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)

        store.simulateHIDInputForTesting(k10Held)
        scheduler.advance(by: 2)
        store.simulateHIDInputForTesting("r2:F0 04 02 00 00 00 00 00") // K3 + K10
        store.simulateHIDInputForTesting("wheel:+")
        scheduler.advance(by: 0.2)
        store.simulateHIDInputForTesting(k10Held)
        store.simulateHIDInputForTesting(nothingHeld)
        scheduler.advance(by: 2)
        XCTAssertEqual(executed, ["Volume up"])
    }

    func testChoosingScrollRemovesTheEntry() throws {
        let store = makeDriverModeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.updateWheelLayerMapping(volumeUp, for: .wheelCW, modifier: .k10)
        store.updateWheelLayerMapping(Mapping(), for: .wheelCW, modifier: .k10)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(store.exportConfiguration())) as? [String: Any])
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        let wheelEntries = profiles.flatMap { ($0["mappings"] as? [[String: Any]]) ?? [] }
            .filter { ($0["control"] as? String)?.hasPrefix("Wheel") == true }
            .filter { (($0["modifierControls"] as? [Any]) ?? []).isEmpty == false }
        XCTAssertTrue(wheelEntries.isEmpty, "No empty MOD-layer wheel entry is stored: \(wheelEntries)")
    }

    private func makeDriverModeStore() -> MappingStore {
        makeStore(driverMode: true)
    }

    private func makeStore(driverMode: Bool) -> MappingStore {
        let store = MappingStore(
            userDefaults: defaults,
            startHardware: false,
            gestureSchedule: { [scheduler] delay, action in scheduler.schedule(delay: delay, action: action) },
            actionExecutionOverride: { [weak self] mapping, completion in
                self?.executed.append(mapping.command)
                completion(.success(mapping.command))
            }
        )
        if driverMode {
            store.hid.simulateBluetoothDriverModeForTesting(active: true)
        }
        return store
    }
}
