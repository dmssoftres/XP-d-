import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingStoreMIDITests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MappingStoreMIDITests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testV3PersistedProfilesMigrateToCurrentStandardSchema() throws {
        struct LegacyState: Codable {
            let mappings: [MappingKey: Mapping]
            let hidBindings: [RemoteControl: String]
        }
        struct LegacyProfile: Codable {
            let name: String
            let state: LegacyState
        }
        struct LegacyDocument: Codable {
            let version: Int
            let profiles: [LegacyProfile]
            let activeProfileName: String
        }

        let legacy = LegacyDocument(
            version: 3,
            profiles: ["Global", "Finder", "Logic Pro"].map {
                LegacyProfile(
                    name: $0,
                    state: LegacyState(
                        mappings: [MappingKey(control: .k1, gesture: .tap): Mapping(action: .noAction, command: $0)],
                        hidBindings: [.k1: "\($0)-signature"]
                    )
                )
            },
            activeProfileName: "Finder"
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: "XPd.profiles.v3")

        let store = makeStore()
        XCTAssertEqual(store.profileName, "Finder")
        XCTAssertEqual(store.activeRealm, .standard)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "Finder")
        XCTAssertNil(store.currentMIDISettings)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profileName, "Finder")
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap).command, "Finder")
    }

    func testMIDIExportImportPreservesRealmAndTypedSettings() throws {
        let source = makeStore()
        let settings = MIDIProfileSettings(
            fnControl: .k10,
            primaryButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 36, velocity: 112))
            ],
            functionButtons: [
                .init(control: .k2, mapping: MIDIButtonMapping(kind: .chord, chord: [48, 52, 55]))
            ],
            primaryWheel: MIDIWheelMapping(kind: .pitchBendNudgeReturn),
            functionWheel: MIDIWheelMapping(kind: .absoluteCC, controller: 1)
        )
        _ = try source.addMIDIProfile(named: "Drum Pads", settings: settings)
        XCTAssertEqual(source.activeRealm, .midi)
        XCTAssertTrue(source.midiLocked)

        let data = try XCTUnwrap(source.exportConfiguration())
        let decoded = try XPdConfiguration.decode(data)
        XCTAssertEqual(decoded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(decoded.activeRealm, .midi)
        XCTAssertEqual(decoded.profiles.first(where: { $0.name == "Drum Pads" })?.realm, .midi)
        XCTAssertEqual(decoded.profiles.first(where: { $0.name == "Drum Pads" })?.midiSettings, settings)

        let target = makeStore()
        XCTAssertTrue(target.importConfiguration(data))
        XCTAssertEqual(target.profileName, "Drum Pads")
        XCTAssertEqual(target.activeRealm, .midi)
        XCTAssertEqual(target.primaryButtonMapping(for: .k1).note, 36)
        XCTAssertEqual(target.functionButtonMapping(for: .k2).chord, [48, 52, 55])
    }

    func testWorkspaceLockFiltersProfilesAndRestoresRealm() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "Performance")
        _ = store.selectProfile("Global")
        XCTAssertEqual(store.activeRealm, .standard)
        XCTAssertTrue(store.toggleWorkspace())
        XCTAssertEqual(store.profileName, "Performance")
        XCTAssertEqual(store.activeRealm, .midi)
        XCTAssertTrue(store.availableProfilesInActiveRealm.allSatisfy { store.profileRealm(for: $0) == .midi })
        XCTAssertTrue(store.toggleWorkspace())
        XCTAssertEqual(store.profileName, "Global")
        XCTAssertEqual(store.activeRealm, .standard)
    }

    func testRenamingRememberedMIDIProfilePreservesWorkspaceRestoration() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "Performance")
        XCTAssertTrue(store.selectProfile("Global"))

        try store.renameProfile(named: "Performance", to: "Live")

        XCTAssertTrue(store.toggleWorkspace())
        XCTAssertEqual(store.profileName, "Live")
        XCTAssertEqual(store.activeRealm, .midi)
    }

    func testNoMIDIProfileFailsWithoutChangingStandardState() {
        let store = makeStore()
        XCTAssertFalse(store.toggleWorkspace())
        XCTAssertEqual(store.profileName, "Global")
        XCTAssertEqual(store.activeRealm, .standard)
        XCTAssertFalse(store.midiLocked)
    }

    func testPrimaryAndFunctionRoutingSeamsTrackFnAndReleaseOrder() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "Performance")
        _ = store.updateFnAssignment(.k10)
        store.updatePrimaryButtonMapping(
            MIDIButtonMapping(kind: .note, note: 36, velocity: 100),
            for: .k1
        )
        store.updateFunctionButtonMapping(
            MIDIButtonMapping(kind: .note, note: 60, velocity: 110),
            for: .k1
        )

        store.simulateMIDIControlPressForTesting(.k1)
        store.simulateMIDIControlReleaseForTesting(.k1)
        store.simulateMIDIControlPressForTesting(.k10)
        store.simulateMIDIControlPressForTesting(.k1)
        store.simulateMIDIControlReleaseForTesting(.k10)
        store.simulateMIDIControlReleaseForTesting(.k1)

        XCTAssertEqual(store.fnControl, .k10)
        XCTAssertTrue(store.midiLocked)
    }

    func testTransposeWheelRoutesByLayerAndHonorsReversal() throws {
        let store = makeStore()
        let settings = MIDIProfileSettings(
            fnControl: .k10,
            primaryButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 60))
            ],
            functionButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 80))
            ],
            primaryWheel: MIDIWheelMapping(kind: .transpose, transposeSemitones: 2),
            functionWheel: MIDIWheelMapping(kind: .transpose, transposeSemitones: 3)
        )
        _ = try store.addMIDIProfile(named: "Transpose", settings: settings)

        store.simulateMIDIControlPressForTesting(.wheelCW)
        XCTAssertEqual(store.midiTransposeOffset(for: .primary), 2)
        XCTAssertTrue(store.midiStatus?.contains("+2") == true)
        store.simulateMIDIControlPressForTesting(.wheelCCW)
        XCTAssertEqual(store.midiTransposeOffset(for: .primary), 0)

        store.simulateMIDIControlPressForTesting(.k10)
        store.simulateMIDIControlPressForTesting(.wheelCW)
        XCTAssertEqual(store.midiTransposeOffset(for: .function), 3)
        store.simulateMIDIControlReleaseForTesting(.k10)

        store.updatePrimaryWheelMapping(
            MIDIWheelMapping(kind: .transpose, reversedDirection: true, transposeSemitones: 2)
        )
        store.simulateMIDIControlPressForTesting(.wheelCCW)
        XCTAssertEqual(store.midiTransposeOffset(for: .primary), 2)
    }

    func testTransposeAndDrumBankOffsetsClampNotesAndChords() throws {
        let store = makeStore()
        let settings = MIDIProfileSettings(
            fnControl: .k10,
            primaryButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 126)),
                .init(control: .k2, mapping: MIDIButtonMapping(kind: .chord, chord: [1, 126]))
            ],
            primaryWheel: MIDIWheelMapping(kind: .transpose, transposeSemitones: 5)
        )
        _ = try store.addMIDIProfile(named: "Clamp", settings: settings)
        store.simulateMIDIControlPressForTesting(.wheelCW)
        XCTAssertEqual(store.midiTransposeOffset(for: .primary), 1)
        XCTAssertEqual(store.effectiveMIDIButtonMappingForTesting(for: .k1).note, 127)
        XCTAssertEqual(store.effectiveMIDIButtonMappingForTesting(for: .k2).chord, [2, 127])

        let drumStore = makeStore()
        _ = try drumStore.addMIDIProfile(
            named: "Drums",
            settings: MIDIProfileSettings(
                primaryButtons: [
                    .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 36)),
                    .init(control: .k2, mapping: MIDIButtonMapping(kind: .chord, chord: [37, 45]))
                ],
                primaryWheel: MIDIWheelMapping(kind: .drumBank, drumBankStep: 1)
            )
        )
        drumStore.simulateMIDIControlPressForTesting(.wheelCW)
        XCTAssertEqual(drumStore.midiDrumBankOffset(for: .primary), 1)
        XCTAssertEqual(drumStore.effectiveMIDIButtonMappingForTesting(for: .k1).note, 46)
        XCTAssertEqual(drumStore.effectiveMIDIButtonMappingForTesting(for: .k2).chord, [47, 55])
    }

    func testSessionOffsetsResetOnPanicAndProfileChange() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(
            named: "Performance",
            settings: MIDIProfileSettings(
                primaryWheel: MIDIWheelMapping(kind: .drumBank, drumBankStep: 2)
            )
        )
        store.simulateMIDIControlPressForTesting(.wheelCW)
        XCTAssertEqual(store.midiDrumBankOffset(for: .primary), 2)
        store.panicMIDI()
        XCTAssertEqual(store.midiDrumBankOffset(for: .primary), 0)
        XCTAssertNil(store.midiStatus)

        store.simulateMIDIControlPressForTesting(.wheelCW)
        XCTAssertEqual(store.midiDrumBankOffset(for: .primary), 2)
        _ = store.selectProfile("Global")
        XCTAssertEqual(store.midiDrumBankOffset(for: .primary), 0)
    }

    func testSelectorConsumesNonLockKeysAndTimeoutDoesNotChangeProfile() {
        let store = makeStore()
        store.simulateHIDInputForTesting("wheel:center")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        let initialGeneration = store.profileSelectorTimeoutGenerationForTesting

        // K1 is not the configured lock key (K3), so it is consumed and the
        // pending selector is cancelled without executing its mapping.
        store.simulateHIDInputForTesting("r6:01 12 00 00 00 00 00")
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Global")

        store.simulateHIDInputForTesting("wheel:center")
        store.simulateHIDInputForTesting("wheel:+")
        XCTAssertTrue(store.profileSelectorTimeoutGenerationForTesting > initialGeneration)
        XCTAssertEqual(store.profileName, "Global")
        store.simulateProfileSelectorTimeoutForTesting()
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Global")
    }

    func testCenterFnUsesProfileHoldThresholdAndFenceDrainsRapidCleanup() async throws {
        let store = makeStore()
        let settings = MIDIProfileSettings(
            fnControl: .wheelCenter,
            fnHoldThreshold: 0.10,
            primaryButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 60))
            ],
            functionButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note, note: 72))
            ],
            primaryWheel: MIDIWheelMapping(kind: .noAction)
        )
        _ = try store.addMIDIProfile(named: "Center Fn", settings: settings)
        XCTAssertEqual(store.currentMIDISettings?.fnHoldThreshold, 0.10)

        store.simulateHIDInputForTesting("wheel:center")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(store.isFnLayerActive)
        store.simulateMIDIControlPressForTesting(.k1)
        store.simulateMIDIControlReleaseForTesting(.wheelCenter)
        store.panicMIDI()
        await store.waitForMIDICommandsForTesting()
        XCTAssertFalse(store.isFnLayerActive)
        XCTAssertEqual(store.midiTransposeOffset(for: .function), 0)
    }

    func testHoldThresholdSetterClampsAndAutosaves() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "Threshold")
        XCTAssertTrue(store.updateMIDIHoldThreshold(0.01))
        XCTAssertEqual(store.currentMIDISettings?.fnHoldThreshold, 0.10)
        XCTAssertTrue(store.updateMIDIHoldThreshold(9.0))
        XCTAssertEqual(store.currentMIDISettings?.fnHoldThreshold, 3.0)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profileName, "Threshold")
        _ = reloaded.selectProfile("Threshold")
        XCTAssertEqual(reloaded.currentMIDISettings?.fnHoldThreshold, 3.0)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
