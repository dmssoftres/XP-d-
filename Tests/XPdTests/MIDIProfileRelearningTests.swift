import Foundation
import XCTest
@testable import XPd

@MainActor
final class MIDIProfileRelearningTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MIDIProfileRelearningTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSingleButtonReport2RelearnUpdatesDeviceLayoutAndPreservesProfileMappings() throws {
        let store = makeStore()

        _ = try store.addMIDIProfile(named: "MIDI A")
        let primaryA = MIDIButtonMapping(
            kind: .chord,
            outputPort: .control,
            channel: 2,
            chord: [36, 40, 43],
            velocity: 112,
            label: "A primary"
        )
        let functionA = MIDIButtonMapping(
            kind: .note,
            outputPort: .performance,
            channel: 3,
            note: 91,
            velocity: 107,
            label: "A function"
        )
        store.updatePrimaryButtonMapping(primaryA, for: .k1)
        store.updateFunctionButtonMapping(functionA, for: .k1)
        let settingsA = try XCTUnwrap(store.currentMIDISettings)
        let aK2Binding = try XCTUnwrap(store.hidBinding(for: .k2))

        _ = try store.addMIDIProfile(named: "MIDI B")
        let primaryB = MIDIButtonMapping(
            kind: .cc,
            outputPort: .control,
            channel: 9,
            controller: 74,
            pressValue: 99,
            releaseValue: 11,
            label: "B primary"
        )
        store.updatePrimaryButtonMapping(primaryB, for: .k1)
        let settingsB = try XCTUnwrap(store.currentMIDISettings)
        let bK2Binding = try XCTUnwrap(store.hidBinding(for: .k2))

        XCTAssertTrue(store.selectProfile("MIDI A"))
        XCTAssertEqual(store.currentMIDISettings, settingsA)

        let learnedSignature = report2Signature(buttons: report2ButtonBit(.k1))
        store.selectedControl = .k1
        store.learnSelectedMIDIControl()
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k1))
        )

        XCTAssertEqual(store.hidBinding(for: .k1), learnedSignature)
        XCTAssertEqual(store.hidBinding(for: .k2), aK2Binding)
        XCTAssertEqual(store.currentMIDISettings, settingsA)
        XCTAssertTrue(store.lastHIDLearningResult?.succeeded == true)

        XCTAssertTrue(store.selectProfile("MIDI B"))
        XCTAssertEqual(store.currentMIDISettings, settingsB)
        XCTAssertEqual(store.hidBinding(for: .k1), learnedSignature)
        XCTAssertEqual(store.hidBinding(for: .k2), bK2Binding)

        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertEqual(store.hidBinding(for: .k1), learnedSignature)
    }

    func testMIDIRelearnRejectsCompositeReport2AndPreservesOldBinding() throws {
        let store = try makeMIDIStore(named: "MIDI")
        let originalBinding = try XCTUnwrap(store.hidBinding(for: .k1))
        let originalSettings = try XCTUnwrap(store.currentMIDISettings)

        store.selectedControl = .k1
        store.learnSelectedMIDIControl()
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(
                buttons: report2ButtonBit(.k1) | report2ButtonBit(.k2)
            )
        )

        XCTAssertNil(store.learningControl)
        XCTAssertEqual(store.hidBinding(for: .k1), originalBinding)
        XCTAssertEqual(store.currentMIDISettings, originalSettings)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)
    }

    func testMIDIRelearnRejectsConflictingReport2SignatureAndPreservesBothBindings() throws {
        let store = try makeMIDIStore(named: "MIDI")
        let k2OriginalBinding = try XCTUnwrap(store.hidBinding(for: .k2))
        let k1Signature = report2Signature(buttons: report2ButtonBit(.k1))

        store.selectedControl = .k1
        store.learnSelectedMIDIControl()
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k1))
        )
        XCTAssertEqual(store.hidBinding(for: .k1), k1Signature)

        store.selectedControl = .k2
        store.learnSelectedMIDIControl()
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k1))
        )

        XCTAssertNil(store.learningControl)
        XCTAssertEqual(store.hidBinding(for: .k1), k1Signature)
        XCTAssertEqual(store.hidBinding(for: .k2), k2OriginalBinding)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)
    }

    func testCancelMIDIRelearnPreservesExistingBinding() throws {
        let store = try makeMIDIStore(named: "MIDI")
        let originalBinding = try XCTUnwrap(store.hidBinding(for: .k1))

        store.selectedControl = .k1
        store.learnSelectedMIDIControl()
        XCTAssertEqual(store.learningControl, .k1)

        store.cancelLearning()

        XCTAssertNil(store.learningControl)
        XCTAssertEqual(store.hidBinding(for: .k1), originalBinding)
        XCTAssertNil(store.lastHIDLearningResult)
    }

    func testMIDIRelearnEntryPointRejectsStandardProfile() {
        let store = makeStore()
        let originalBinding = store.hidBinding(for: .k1)

        store.selectedControl = .k1
        store.learnSelectedMIDIControl()

        XCTAssertNil(store.learningControl)
        XCTAssertEqual(store.hidBinding(for: .k1), originalBinding)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)
    }

    func testSwitchingProfilesCancelsPendingMIDIRelearn() throws {
        let store = try makeMIDIStore(named: "MIDI A")
        _ = try store.addMIDIProfile(named: "MIDI B")
        let midiBBinding = store.hidBinding(for: .k1)
        XCTAssertTrue(store.selectProfile("MIDI A"))

        store.selectedControl = .k1
        store.learnSelectedMIDIControl()
        XCTAssertEqual(store.learningControl, .k1)

        XCTAssertTrue(store.selectProfile("MIDI B"))
        XCTAssertNil(store.learningControl)
        store.hid.simulateInputReportForTesting(
            reportID: 2,
            bytes: report2Bytes(buttons: report2ButtonBit(.k1))
        )

        XCTAssertEqual(store.hidBinding(for: .k1), midiBBinding)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private func makeMIDIStore(named name: String) throws -> MappingStore {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: name)
        return store
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
        [
            0xF0,
            UInt8(truncatingIfNeeded: buttons),
            UInt8(truncatingIfNeeded: buttons >> 8)
        ] + Array(repeating: 0, count: 28)
    }

    private func report2Signature(buttons: UInt16) -> String {
        "r2:" + report2Bytes(buttons: buttons)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }
}
