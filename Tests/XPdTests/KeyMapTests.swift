import Foundation
import XCTest
@testable import XPd

@MainActor
final class KeyMapTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.KeyMapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testShowsBaseModLayersTitlesAndWheel() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(Mapping(action: .typeText, command: "Kind regards"), for: .k1, gesture: .hold)
        store.update(Mapping(action: .openApplication, command: "Calculator"), for: .k5, gesture: .tap, modifierControls: [.k10])
        store.updateStandardButtonTitle("Files", for: .k1)
        store.updateWheelLayerMapping(
            Mapping(action: .mediaControl, command: MediaControlAction.volumeUp.rawValue),
            for: .wheelCW,
            modifier: .k10
        )

        let map = store.keyMapPresentation()
        XCTAssertFalse(map.isMIDI)
        XCTAssertEqual(map.profileName, "Global")
        XCTAssertEqual(map.keys.map(\.control), RemoteControl.allCases.filter(\.isMIDIButton))
        let k1 = try XCTUnwrap(map.key(.k1))
        XCTAssertEqual(k1.title, "Files")
        XCTAssertEqual(k1.lines, ["Finder", "Hold: Type · Kind regards"])
        XCTAssertEqual(map.key(.k5)?.lines, ["K10+ Calculator"])
        XCTAssertEqual(map.key(.k10)?.isModifier, true)
        XCTAssertEqual(map.key(.k10)?.lines, [], "A MOD key does not list its own layer")
        XCTAssertEqual(map.wheelLines, ["Turn: scroll", "K10 + ↻: Volume up"])
    }

    func testLongListsAreCapped() {
        XCTAssertEqual(KeyMapPresentation.capped(["1", "2", "3"]), ["1", "2", "3"])
        XCTAssertEqual(KeyMapPresentation.capped((1...8).map(String.init)), ["1", "2", "3", "4", "+4 more"])
    }

    func testMIDIProfileShowsMIDIOutput() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "Live")
        let map = store.keyMapPresentation()
        XCTAssertTrue(map.isMIDI)
        XCTAssertEqual(map.keys.count, 10)
        XCTAssertFalse(map.keys.allSatisfy { $0.lines.isEmpty })
    }

    func testAssignedActionTogglesAndNextPressCloses() {
        let store = makeStore()
        store.update(
            Mapping(action: .windowDisplay, command: WindowDisplayAction.showKeyMap.rawValue),
            for: .k1,
            gesture: .tap
        )
        var result: ActionExecutionResult?
        store.executeMapping(for: .k1, gesture: .tap) { result = $0 }
        XCTAssertTrue(store.isKeyMapVisible)
        XCTAssertEqual(result, .success("Key map shown"))

        store.simulateHIDInputForTesting(nil) // release is not a new press
        XCTAssertTrue(store.isKeyMapVisible)
        store.simulateHIDInputForTesting("r6:00 3E 00 00 00 00 00") // K3 pressed
        XCTAssertFalse(store.isKeyMapVisible)

        store.executeMapping(for: .k1, gesture: .tap) { result = $0 }
        store.executeMapping(for: .k1, gesture: .tap) { result = $0 }
        XCTAssertFalse(store.isKeyMapVisible)
        XCTAssertEqual(result, .success("Key map hidden"))
    }

    func testEmptyDriverModeReleaseDoesNotClose() {
        let store = makeStore()
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        store.showKeyMap()
        store.simulateHIDInputForTesting("r2:F0 00 00 00 00 00 00 00")
        XCTAssertTrue(store.isKeyMapVisible)
        store.hideKeyMap()
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
