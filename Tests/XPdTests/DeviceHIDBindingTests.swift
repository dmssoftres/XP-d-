import Foundation
import XCTest
@testable import XPd

@MainActor
final class DeviceHIDBindingTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.DeviceHIDBindingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLearnedBindingIsSharedAcrossProfilesAndNewProfiles() throws {
        let store = makeStore()
        let learned = "r2:F0 01 00 00 00 00 00 00"

        store.selectedControl = .k1
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(learned)
        XCTAssertEqual(store.hidBinding(for: .k1), learned)

        XCTAssertTrue(store.selectProfile("Finder"))
        XCTAssertEqual(store.hidBinding(for: .k1), learned)

        _ = try store.addProfile(named: "Studio")
        XCTAssertEqual(store.hidBinding(for: .k1), learned)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.hidBinding(for: .k1), learned)
        XCTAssertTrue(reloaded.selectProfile("Global"))
        XCTAssertEqual(reloaded.hidBinding(for: .k1), learned)
    }

    func testLearnAllCommitsAtomicallyAndPreservesWheelBindings() {
        let store = makeStore()
        let oldBindings = store.hidBindings
        let newBindings = hardwareLearningSignatures()

        store.beginLearningAllHIDControls()
        XCTAssertTrue(store.isLearningAll)
        XCTAssertEqual(store.learningAllControl, .k1)
        XCTAssertEqual(store.learningAllProgress, 0)

        for (index, control) in RemoteControl.allCases.filter(\.isMIDIButton).enumerated() {
            store.simulateHIDInputForTesting(newBindings[control])
            XCTAssertTrue(store.isLearningAll)
            XCTAssertEqual(store.learningAllProgress, index + 1)
            XCTAssertTrue(store.isLearningAllAwaitingRelease)
            XCTAssertEqual(store.hidBindings, oldBindings)
            store.simulateHIDInputForTesting(report2ReleaseSignature)
            if index < 9 { XCTAssertTrue(store.isLearningAll) }
        }

        XCTAssertFalse(store.isLearningAll)
        XCTAssertNil(store.learningAllControl)
        XCTAssertEqual(store.learningAllProgress, 0)
        XCTAssertEqual(store.hidBinding(for: .wheelCW), oldBindings[.wheelCW])
        XCTAssertEqual(store.hidBinding(for: .wheelCCW), oldBindings[.wheelCCW])
        XCTAssertEqual(store.hidBinding(for: .wheelCenter), oldBindings[.wheelCenter])
        XCTAssertEqual(
            Set(RemoteControl.allCases.filter(\.isMIDIButton).compactMap { store.hidBinding(for: $0) }),
            Set(newBindings.values)
        )
        XCTAssertTrue(store.lastHIDLearningResult?.succeeded == true)
    }

    func testLearnAllCancelAndInvalidCaptureLeaveOldLayoutUntouched() {
        let store = makeStore()
        let oldBindings = store.hidBindings

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting("r2:F0 01 00 00 00 00 00 00")
        store.cancelLearning()
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, oldBindings)

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting("r2:F0 01 00 00 00 00 00 00")
        store.simulateHIDInputForTesting(report2ReleaseSignature)
        store.simulateHIDInputForTesting("r2:F0 01 00 00 00 00 00 00")
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, oldBindings)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting("r6:00 04 00 00 00 00 00")
        store.simulateHIDInputForTesting(nil)
        store.simulateHIDInputForTesting("r2:F0 02 00 00 00 00 00 00")
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, oldBindings)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)
    }

    func testLearnAllRejectsMaskingReport6SetOnlyAfterFullAtomicValidation() {
        let store = makeStore()
        let oldBindings = store.hidBindings

        store.beginLearningAllHIDControls()
        for control in RemoteControl.allCases.filter(\.isMIDIButton) {
            store.simulateHIDInputForTesting(oldBindings[control])
            XCTAssertEqual(store.hidBindings, oldBindings)
            store.simulateHIDInputForTesting(nil)
        }

        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, oldBindings)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)
    }

    func testDisconnectAndLayoutSwitchCancelLearnAllWithoutPartialWrites() throws {
        let global = bindingEntries(k1: "r6:00 04 00 00 00 00 00")
        let finder = bindingEntries(k1: "r6:00 05 00 00 00 00 00")
        let payload: [String: Any] = [
            "version": 8,
            "profiles": [
                ["name": "Global", "state": ["mappings": [], "hidBindings": global, "realm": "standard"]],
                ["name": "Finder", "state": ["mappings": [], "hidBindings": finder, "realm": "standard"]]
            ],
            "activeProfileName": "Finder",
            "activeRealm": "standard"
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "XPd.profiles.v8")
        let store = makeStore()
        let finderBindings = store.hidBindings

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting("r2:F0 01 00 00 00 00 00 00")
        store.hid.simulateDisconnectForTesting()
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, finderBindings)

        let globalLayout = try XCTUnwrap(
            store.hardwareLayouts.first(where: { $0.name == "Migrated from Global" })
        )
        store.beginLearningAllHIDControls()
        XCTAssertTrue(store.selectHardwareLayout(id: globalLayout.id))
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBinding(for: .k1), "r6:00 04 00 00 00 00 00")

        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertEqual(store.hidBinding(for: .k1), "r6:00 04 00 00 00 00 00")
        XCTAssertEqual(makeStore().activeHardwareLayoutID, globalLayout.id)
    }

    func testProfileMutationAndImportCancelLearnAllWithoutStaleCommit() throws {
        let store = makeStore()
        let originalK1 = store.hidBinding(for: .k1)
        let candidate = "r2:F0 01 00 00 00 00 00 00"

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting(candidate)
        _ = try store.addProfile(named: "Studio")
        XCTAssertFalse(store.isLearningAll)
        store.simulateHIDInputForTesting(report2ReleaseSignature)
        XCTAssertEqual(store.hidBinding(for: .k1), originalK1)

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting(candidate)
        _ = try store.renameProfile(named: "Studio", to: "Studio renamed")
        XCTAssertFalse(store.isLearningAll)
        store.simulateHIDInputForTesting(report2ReleaseSignature)
        XCTAssertEqual(store.hidBinding(for: .k1), originalK1)

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting(candidate)
        try store.deleteProfile(named: "Finder")
        XCTAssertFalse(store.isLearningAll)
        store.simulateHIDInputForTesting(report2ReleaseSignature)
        XCTAssertEqual(store.hidBinding(for: .k1), originalK1)

        let configuration = try XCTUnwrap(store.exportConfiguration())
        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting(candidate)
        XCTAssertTrue(store.importConfiguration(configuration))
        XCTAssertFalse(store.isLearningAll)
        store.simulateHIDInputForTesting(report2ReleaseSignature)
        XCTAssertEqual(store.hidBinding(for: .k1), originalK1)
    }

    func testLearnAllIgnoresHeldRepeatsAndRequiresReleaseBeforeAnotherInput() {
        let store = makeStore()
        let oldBindings = store.hidBindings
        let k1 = "r2:F0 01 00 00 00 00 00 00"

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting(k1)
        store.simulateHIDInputForTesting(k1)

        XCTAssertTrue(store.isLearningAll)
        XCTAssertEqual(store.learningAllControl, .k1)
        XCTAssertEqual(store.learningAllProgress, 1)
        XCTAssertEqual(store.hidBindings, oldBindings)

        store.simulateHIDInputForTesting("r2:F0 02 00 00 00 00 00 00")
        XCTAssertFalse(store.isLearningAll)
        XCTAssertEqual(store.hidBindings, oldBindings)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)
    }

    func testLearnAllPublishesCapturedSignatureOnlyUntilRelease() {
        let store = makeStore()
        let k1 = "r2:F0 01 00 00 00 00 00 00"

        store.beginLearningAllHIDControls()
        store.simulateHIDInputForTesting(k1)

        XCTAssertEqual(store.learningAllCapturedSignature, k1)
        XCTAssertTrue(store.isLearningAllAwaitingRelease)

        store.simulateHIDInputForTesting(report2ReleaseSignature)

        XCTAssertNil(store.learningAllCapturedSignature)
        XCTAssertFalse(store.isLearningAllAwaitingRelease)
        XCTAssertEqual(store.learningAllControl, .k2)
    }

    func testStandardKLearningRejectsReport2ReleaseAndCompositeButAcceptsFactoryReport6() {
        let store = makeStore()
        let original = store.hidBinding(for: .k1)

        store.selectedControl = .k1
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(report2ReleaseSignature)
        XCTAssertNil(store.learningControl)
        XCTAssertEqual(store.hidBinding(for: .k1), original)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)

        store.learnSelectedControl()
        store.simulateHIDInputForTesting("r2:F0 03 00 00 00 00 00 00")
        XCTAssertNil(store.learningControl)
        XCTAssertEqual(store.hidBinding(for: .k1), original)
        XCTAssertEqual(store.lastHIDLearningResult?.succeeded, false)

        let factoryShortcut = "r6:03 44 00 00 00 00 00"
        store.learnSelectedControl()
        store.simulateHIDInputForTesting(factoryShortcut)
        XCTAssertEqual(store.hidBinding(for: .k1), factoryShortcut)
        XCTAssertTrue(store.lastHIDLearningResult?.succeeded == true)
    }

    func testLearnAllResetsHeldMIDINoteAndFnBeforeConsumingRelease() async throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "MIDI")
        XCTAssertTrue(store.updateMIDIPracticeFnControl(.k10))
        store.updateFunctionButtonMapping(
            MIDIButtonMapping(kind: .note, note: 72, velocity: 110),
            for: .k8
        )
        store.clearMIDIMonitor()

        store.simulateMIDIControlPressForTesting(.k10)
        store.simulateMIDIControlPressForTesting(.k8)
        XCTAssertTrue(store.isFnLayerActive)

        store.beginLearningAllHIDControls()
        XCTAssertFalse(store.isFnLayerActive)
        store.cancelLearning()

        await store.waitForMIDICommandsForTesting()
        for _ in 0..<3 { await Task.yield() }
        let summaries = store.midiMonitorEvents.map(\.summary)
        XCTAssertTrue(summaries.contains("Note On 72 · Ch 1 · V110"))
        XCTAssertTrue(summaries.contains("Note Off 72 · Ch 1"))
    }

    func testMalformedV8MigrationDoesNotWriteV9OrChangeV8Payload() {
        let malformed = Data("not-json".utf8)
        defaults.set(malformed, forKey: "XPd.profiles.v8")

        let store = makeStore()

        XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v8"), malformed)
        XCTAssertNil(defaults.data(forKey: "XPd.profiles.v9"))
        XCTAssertEqual(store.lastPersistenceResult.succeeded, false)
    }

    func testDuplicateProfileV8MigrationFailsClosedWithoutWritingV9() throws {
        let duplicateProfiles: [String: Any] = [
            "version": 8,
            "profiles": [
                ["name": "Global", "state": ["mappings": [], "hidBindings": [], "realm": "standard"]],
                ["name": "Global", "state": ["mappings": [], "hidBindings": [], "realm": "standard"]]
            ],
            "activeProfileName": "Global",
            "activeRealm": "standard"
        ]
        let original = try JSONSerialization.data(withJSONObject: duplicateProfiles)
        defaults.set(original, forKey: "XPd.profiles.v8")

        let store = makeStore()

        XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v8"), original)
        XCTAssertNil(defaults.data(forKey: "XPd.profiles.v9"))
        XCTAssertEqual(store.lastPersistenceResult.succeeded, false)
    }

    func testV8MigrationRejectsOriginalEmptyAndDuplicateHIDSignatures() throws {
        for bindings in [
            ["K1", "   ", "K2", "r6:00 05 00 00 00 00 00"],
            ["K1", "r6:00 04 00 00 00 00 00", "K2", "r6:00 04 00 00 00 00 00"]
        ] as [[Any]] {
            defaults.removePersistentDomain(forName: suiteName)
            let payload: [String: Any] = [
                "version": 8,
                "profiles": [[
                    "name": "Global",
                    "state": ["mappings": [], "hidBindings": bindings, "realm": "standard"]
                ]],
                "activeProfileName": "Global",
                "activeRealm": "standard"
            ]
            let original = try JSONSerialization.data(withJSONObject: payload)
            defaults.set(original, forKey: "XPd.profiles.v8")

            let store = makeStore()

            XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v8"), original)
            XCTAssertNil(defaults.data(forKey: "XPd.profiles.v9"))
            XCTAssertEqual(store.lastPersistenceResult.succeeded, false)
        }
    }

    func testCorruptV9NeverFallsBackToOrOverwritesV8() throws {
        let v8: [String: Any] = [
            "version": 8,
            "profiles": [[
                "name": "Global",
                "state": ["mappings": [], "hidBindings": bindingEntries(k1: "r6:00 04 00 00 00 00 00"), "realm": "standard"]
            ]],
            "activeProfileName": "Global",
            "activeRealm": "standard"
        ]
        let v8Bytes = try JSONSerialization.data(withJSONObject: v8)
        // This is otherwise a valid v9 profile payload. Its missing
        // top-level hardware layout and active layout ID are the corruption
        // under test; it must not be treated as an older profile-owned HID
        // document or be replaced from v8.
        let incompleteV9: [String: Any] = [
            "version": 9,
            "profiles": [[
                "name": "Global",
                "state": ["mappings": [], "realm": "standard"]
            ]],
            "activeProfileName": "Global",
            "activeRealm": "standard",
            "midiLocked": false,
            "workspaceLockControl": "K3"
        ]
        let corruptV9 = try JSONSerialization.data(withJSONObject: incompleteV9)
        defaults.set(v8Bytes, forKey: "XPd.profiles.v8")
        defaults.set(corruptV9, forKey: "XPd.profiles.v9")

        let store = makeStore()

        XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v9"), corruptV9)
        XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v8"), v8Bytes)
        XCTAssertEqual(store.lastPersistenceResult.succeeded, false)
    }

    func testV9RejectsOriginalInvalidLayoutBindingsWithoutRewritingEitherSchema() throws {
        let retainedV8: [String: Any] = [
            "version": 8,
            "profiles": [[
                "name": "Global",
                "state": ["mappings": [], "hidBindings": [], "realm": "standard"]
            ]],
            "activeProfileName": "Global",
            "activeRealm": "standard"
        ]
        let v8Bytes = try JSONSerialization.data(withJSONObject: retainedV8)
        let invalidBindings: [[Any]] = [
            ["K1", "   "],
            ["K1", "r6:06 00 04 00 00 00 00 00", "K2", "r6:00 04 00 00 00 00 00"]
        ]

        for bindings in invalidBindings {
            defaults.removePersistentDomain(forName: suiteName)
            let v9: [String: Any] = [
                "version": 9,
                "profiles": [[
                    "name": "Global",
                    "state": ["mappings": [], "realm": "standard"]
                ]],
                "hardwareLayouts": [[
                    "id": "remote-a", "name": "Remote A", "bindings": bindings
                ]],
                "activeHardwareLayoutID": "remote-a",
                "activeProfileName": "Global",
                "activeRealm": "standard",
                "midiLocked": false,
                "workspaceLockControl": "K3"
            ]
            let v9Bytes = try JSONSerialization.data(withJSONObject: v9)
            defaults.set(v9Bytes, forKey: "XPd.profiles.v9")
            defaults.set(v8Bytes, forKey: "XPd.profiles.v8")

            let store = makeStore()

            XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v9"), v9Bytes)
            XCTAssertEqual(defaults.data(forKey: "XPd.profiles.v8"), v8Bytes)
            XCTAssertEqual(store.lastPersistenceResult.succeeded, false)
        }
    }

    func testDuplicateNamesInV3ThroughV7FailClosedWithoutCrashOrWrite() throws {
        let versionsAndKeys: [(Int, String)] = [
            (3, "XPd.profiles.v3"), (4, "XPd.profiles.v4"), (5, "XPd.profiles.v5"),
            (6, "XPd.profiles.v6"), (7, "XPd.profiles.v7")
        ]
        for (version, key) in versionsAndKeys {
            defaults.removePersistentDomain(forName: suiteName)
            let payload: [String: Any] = [
                "version": version,
                "profiles": [
                    ["name": "Global", "state": ["mappings": [], "hidBindings": []]],
                    ["name": "Global", "state": ["mappings": [], "hidBindings": []]]
                ],
                "activeProfileName": "Global"
            ]
            let original = try JSONSerialization.data(withJSONObject: payload)
            defaults.set(original, forKey: key)

            let store = makeStore()

            XCTAssertEqual(defaults.data(forKey: key), original, "v\(version) bytes must remain recoverable")
            XCTAssertNil(defaults.data(forKey: "XPd.profiles.v9"))
            XCTAssertEqual(store.lastPersistenceResult.succeeded, false)
        }
    }

    func testV8MigrationDeduplicatesSetsAndSelectsActiveProfileSet() throws {
        let global = bindingEntries(k1: "r6:00 04 00 00 00 00 00")
        let finder = bindingEntries(k1: "r6:00 05 00 00 00 00 00")
        let profiles: [[String: Any]] = [
            ["name": "Global", "state": ["mappings": [], "hidBindings": global, "realm": "standard"]],
            ["name": "Finder", "state": ["mappings": [], "hidBindings": finder, "realm": "standard"]],
            ["name": "Logic Pro", "state": ["mappings": [], "hidBindings": global, "realm": "standard"]]
        ]
        let payload: [String: Any] = [
            "version": 8,
            "profiles": profiles,
            "activeProfileName": "Finder",
            "activeRealm": "standard",
            "midiLocked": false,
            "workspaceLockControl": "K3"
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "XPd.profiles.v8")

        let store = makeStore()
        XCTAssertEqual(store.profileName, "Finder")
        XCTAssertEqual(store.hardwareLayouts.count, 2)
        XCTAssertEqual(store.activeHardwareLayoutName, "Migrated from Finder")
        XCTAssertEqual(store.hidBinding(for: .k1), "r6:00 05 00 00 00 00 00")
        XCTAssertNotNil(defaults.data(forKey: "XPd.profiles.v8"), "v8 remains recoverable after migration")

        let persisted = try XCTUnwrap(defaults.data(forKey: "XPd.profiles.v9"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, XPdConfiguration.currentVersion)
        XCTAssertNotNil(object["hardwareLayouts"])
        let encodedProfiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertNil(encodedProfiles.first?["hidBindings"])
    }

    func testModifierDesignationSurvivesDivergentLayoutSwitchAndReload() throws {
        let global: [Any] = bindingEntries(k1: "r6:00 04 00 00 00 00 00") + [
            "K10", "r6:03 1D 00 00 00 00 00"
        ]
        let finder = bindingEntries(k1: "r6:00 05 00 00 00 00 00")
        let payload: [String: Any] = [
            "version": 8,
            "profiles": [
                [
                    "name": "Global",
                    "state": [
                        "mappings": [], "hidBindings": global,
                        "remoteModifierControls": ["K10"], "realm": "standard"
                    ]
                ],
                ["name": "Finder", "state": ["mappings": [], "hidBindings": finder, "realm": "standard"]]
            ],
            "activeProfileName": "Global",
            "activeRealm": "standard"
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "XPd.profiles.v8")
        let store = makeStore()
        let globalLayout = try XCTUnwrap(store.hardwareLayouts.first { $0.name == "Migrated from Global" })
        let finderLayout = try XCTUnwrap(store.hardwareLayouts.first { $0.name == "Migrated from Finder" })

        XCTAssertTrue(store.isRemoteModifier(.k10))
        XCTAssertTrue(store.selectHardwareLayout(id: finderLayout.id))
        XCTAssertFalse(store.isRemoteModifier(.k10))
        XCTAssertTrue(store.selectHardwareLayout(id: globalLayout.id))
        XCTAssertTrue(store.isRemoteModifier(.k10))

        XCTAssertTrue(makeStore().isRemoteModifier(.k10))
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private func bindingEntries(k1: String) -> [Any] {
        [
            "K1", k1,
            "Wheel CCW", "wheel:-",
            "Wheel CW", "wheel:+",
            "Wheel Center", "wheel:center"
        ]
    }

    private func hardwareLearningSignatures() -> [RemoteControl: String] {
        Dictionary(uniqueKeysWithValues: RemoteControl.allCases.filter(\.isMIDIButton).enumerated().map {
            let index = $0.offset
            let mask: UInt16 = 1 << UInt16(index)
            let low = UInt8(mask & 0xFF)
            let high = UInt8((mask >> 8) & 0xFF)
            return ($0.element, String(format: "r2:F0 %02X %02X 00 00 00 00 00", low, high))
        })
    }

    private var report2ReleaseSignature: String {
        "r2:F0 00 00 00 00 00 00 00"
    }
}
