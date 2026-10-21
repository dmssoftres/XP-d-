import Foundation
import XCTest
@testable import XPd

/// Packets below are exact FFE0/0003 notifications captured from the owner's
/// ACK05-B on 2026-10-21 (see docs/firmware/XPPEN_DRIVER_BLE_NOTES.md).
final class ShortcutRemoteDriverModeDecoderTests: XCTestCase {
    private func packet(_ lo: UInt8, _ hi: UInt8, wheel: UInt8 = 0) -> Data {
        Data([0x02, 0xF0, lo, hi, 0x00, 0x00, 0x00, wheel, 0x00, 0x00])
    }

    func testEachKeyMapsToItsVerifiedBit() {
        let captured: [(UInt8, UInt8)] = [
            (0x01, 0x00), (0x02, 0x00), (0x04, 0x00), (0x08, 0x00), (0x10, 0x00),
            (0x20, 0x00), (0x40, 0x00), (0x80, 0x00), (0x00, 0x01), (0x00, 0x02)
        ]
        for (index, bytes) in captured.enumerated() {
            var decoder = ShortcutRemoteDriverModeDecoder()
            XCTAssertEqual(
                decoder.decode(packet(bytes.0, bytes.1)),
                [.keys(ShortcutRemoteDriverModeDecoder.keySignature(mask: UInt16(1) << index))],
                "K\(index + 1)"
            )
        }
    }

    func testKeySignatureUsesTheWiredReport2Form() {
        XCTAssertEqual(ShortcutRemoteDriverModeDecoder.keySignature(mask: 0x001), "r2:F0 01 00 00 00 00 00 00")
        XCTAssertEqual(ShortcutRemoteDriverModeDecoder.keySignature(mask: 0x200), "r2:F0 00 02 00 00 00 00 00")
        XCTAssertNotNil(HIDKeyboardReport(signature: ShortcutRemoteDriverModeDecoder.keySignature(mask: 0x210)))
    }

    func testHeldKeyRepeatsAreDroppedAndReleaseIsReported() {
        var decoder = ShortcutRemoteDriverModeDecoder()
        XCTAssertEqual(decoder.decode(packet(0x08, 0x00)).count, 1)
        XCTAssertEqual(decoder.decode(packet(0x08, 0x00)), [])
        XCTAssertEqual(decoder.decode(packet(0x08, 0x00)), [])
        XCTAssertEqual(
            decoder.decode(packet(0x00, 0x00)),
            [.keys("r2:F0 00 00 00 00 00 00 00")]
        )
    }

    func testK5PlusK10ArrivesAsBothBits() {
        var decoder = ShortcutRemoteDriverModeDecoder()
        _ = decoder.decode(packet(0x00, 0x02))
        XCTAssertEqual(decoder.decode(packet(0x10, 0x02)), [.keys("r2:F0 10 02 00 00 00 00 00")])
        XCTAssertEqual(decoder.decode(packet(0x00, 0x02)), [.keys("r2:F0 00 02 00 00 00 00 00")])
    }

    func testWheelCenterIsSeparateFromK1ThroughK10() {
        var decoder = ShortcutRemoteDriverModeDecoder()
        XCTAssertEqual(decoder.decode(packet(0x00, 0x04)), [.wheelCenterPressed])
        XCTAssertEqual(decoder.decode(packet(0x00, 0x04)), [])
        XCTAssertEqual(decoder.decode(packet(0x20, 0x04)), [.keys("r2:F0 20 00 00 00 00 00 00")])
        XCTAssertEqual(
            decoder.decode(packet(0x00, 0x00)),
            [.keys("r2:F0 00 00 00 00 00 00 00"), .wheelCenterReleased]
        )
    }

    func testWheelDetents() {
        var decoder = ShortcutRemoteDriverModeDecoder()
        XCTAssertEqual(decoder.decode(packet(0x00, 0x00, wheel: 0x01)), [.wheel("wheel:+")])
        XCTAssertEqual(decoder.decode(packet(0x00, 0x00, wheel: 0x02)), [.wheel("wheel:-")])
        XCTAssertEqual(decoder.decode(packet(0x00, 0x00, wheel: 0x02)), [.wheel("wheel:-")])
    }

    func testBatteryAndMalformedPacketsProduceNothing() {
        var decoder = ShortcutRemoteDriverModeDecoder()
        XCTAssertEqual(decoder.decode(Data([0x02, 0xF2, 0x01, 0x64, 0, 0, 0, 0, 0, 0])), [])
        XCTAssertEqual(decoder.decode(Data([0x02, 0xF0, 0x01])), [])
        XCTAssertEqual(decoder.decode(packet(0x01, 0x08)), [])
        XCTAssertEqual(decoder.decode(packet(0x01, 0x00, wheel: 0x03)), [])
        XCTAssertEqual(decoder.decode(Data([0x02, 0xF0, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0])), [])
        XCTAssertEqual(decoder.keyMask, 0)
    }
}

@MainActor
final class BluetoothDriverModeTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.BluetoothDriverModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private func packet(_ lo: UInt8, _ hi: UInt8, wheel: UInt8 = 0) -> [UInt8] {
        [0x02, 0xF0, lo, hi, 0x00, 0x00, 0x00, wheel, 0x00, 0x00]
    }

    func testHIDServiceForwardsDecodedEventsOnlyWhileActive() {
        let hid = HIDService(startHardware: false)
        var received: [String?] = []
        hid.onInput = { received.append($0) }

        hid.simulateDriverModePacketForTesting(packet(0x01, 0x00))
        XCTAssertEqual(received, [], "Packets before activation must be ignored.")

        hid.simulateBluetoothDriverModeForTesting(active: true)
        XCTAssertTrue(hid.isBluetoothDriverModeActive)
        hid.simulateDriverModePacketForTesting(packet(0x01, 0x00))
        hid.simulateDriverModePacketForTesting(packet(0x01, 0x00))
        hid.simulateDriverModePacketForTesting(packet(0x00, 0x00))
        hid.simulateDriverModePacketForTesting(packet(0x00, 0x04))
        hid.simulateDriverModePacketForTesting(packet(0x00, 0x00))
        hid.simulateDriverModePacketForTesting(packet(0x00, 0x00, wheel: 0x01))
        XCTAssertEqual(received, [
            "r2:F0 01 00 00 00 00 00 00",
            "r2:F0 00 00 00 00 00 00 00",
            "wheel:center",
            nil,
            "wheel:+"
        ])
    }

    func testLeavingDriverModeWhileAKeyIsHeldReleasesIt() {
        let hid = HIDService(startHardware: false)
        var received: [String?] = []
        hid.onInput = { received.append($0) }
        hid.simulateBluetoothDriverModeForTesting(active: true)
        hid.simulateDriverModePacketForTesting(packet(0x10, 0x00))
        hid.simulateBluetoothDriverModeForTesting(active: false)
        XCTAssertEqual(received, ["r2:F0 10 00 00 00 00 00 00", nil])
        hid.simulateDriverModePacketForTesting(packet(0x10, 0x00))
        XCTAssertEqual(received.count, 2)
    }

    func testDriverModeOverlaysKeysWithoutRewritingTheLearnedLayout() {
        let store = makeStore()
        let learned = store.hidBindings

        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        XCTAssertTrue(store.isBluetoothDriverModeActive)
        XCTAssertEqual(store.hidBindings, learned, "Driver mode must not rewrite the device layout.")
        XCTAssertEqual(store.standardHIDCollisions(), [])
        XCTAssertEqual(store.standardHIDRolloverCollisions(), [])
        for (index, control) in RemoteControl.allCases.filter(\.isMIDIButton).enumerated() {
            let signature = ShortcutRemoteDriverModeDecoder.keySignature(mask: UInt16(1) << index)
            XCTAssertEqual(store.hidBinding(for: control), signature)
            XCTAssertEqual(store.effectiveMIDIHIDBindings[control], signature)
        }
        XCTAssertEqual(store.hidBinding(for: .wheelCW), learned[.wheelCW])
        XCTAssertEqual(store.hidBinding(for: .wheelCenter), learned[.wheelCenter])

        store.hid.simulateBluetoothDriverModeForTesting(active: false)
        XCTAssertFalse(store.isBluetoothDriverModeActive)
        XCTAssertEqual(store.effectiveStandardHIDBindings, learned)
    }

    func testEachDriverModeKeySelectsItsControl() {
        let store = makeStore()
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        let captured: [(UInt8, UInt8)] = [
            (0x01, 0x00), (0x02, 0x00), (0x04, 0x00), (0x08, 0x00), (0x10, 0x00),
            (0x20, 0x00), (0x40, 0x00), (0x80, 0x00), (0x00, 0x01), (0x00, 0x02)
        ]
        for (control, bytes) in zip(RemoteControl.allCases.filter(\.isMIDIButton), captured) {
            store.hid.simulateDriverModePacketForTesting(packet(bytes.0, bytes.1))
            XCTAssertEqual(store.selectedControl, control)
            store.hid.simulateDriverModePacketForTesting(packet(0x00, 0x00))
        }
    }

    func testKLearningIsBlockedWhileDriverModeIsActive() {
        let store = makeStore()
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        store.selectedControl = .k5
        store.learnSelectedControl()
        XCTAssertNil(store.learningControl)
        store.beginLearningAllHIDControls()
        XCTAssertFalse(store.isLearningAll)
    }

    func testSettingPersistsAndIsAppliedToHIDService() {
        let store = makeStore()
        XCTAssertFalse(store.usesBluetoothDriverMode)
        store.setBluetoothDriverModeEnabled(true)
        XCTAssertTrue(store.hid.isBluetoothDriverModeEnabled)

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.usesBluetoothDriverMode)
        XCTAssertTrue(reloaded.hid.isBluetoothDriverModeEnabled)
    }

    func testDisconnectWhileActiveRestoresTheLearnedLayout() {
        let store = makeStore()
        let learned = store.hidBindings
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        XCTAssertTrue(store.isBluetoothDriverModeActive)

        store.hid.simulateDisconnectForTesting()
        XCTAssertFalse(store.hid.isBluetoothDriverModeActive)
        XCTAssertFalse(store.isBluetoothDriverModeActive)
        XCTAssertEqual(store.effectiveStandardHIDBindings, learned)
        XCTAssertEqual(store.effectiveMIDIHIDBindings, learned)
    }

    func testWheelAndCenterResolveInDriverModeEvenIfTheirBindingsWereRelearned() {
        let store = makeStore()
        store.selectedControl = .wheelCW
        store.clearHIDBinding(for: .wheelCW)
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        XCTAssertEqual(store.effectiveMIDIHIDBindings[.wheelCW], "wheel:+")
        XCTAssertEqual(store.effectiveMIDIHIDBindings[.wheelCCW], "wheel:-")
        XCTAssertEqual(store.effectiveMIDIHIDBindings[.wheelCenter], "wheel:center")
    }

    func testAllLearningIsBlockedWhileDriverModeIsActive() {
        let store = makeStore()
        store.hid.simulateBluetoothDriverModeForTesting(active: true)
        store.selectedControl = .wheelCW
        store.learnSelectedControl()
        XCTAssertNil(store.learningControl)
        let before = store.hidBindings
        store.clearHIDBinding(for: .wheelCenter)
        XCTAssertEqual(store.hidBindings, before)
    }
}
