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

    func testConfigureStandardKLayersCommitsAtomicallyAndPreservesWheelBindings() {
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

        XCTAssertTrue(store.isLearningAll)
        XCTAssertFalse(store.isStandardKLayerLiveVerified)
        XCTAssertEqual(store.hidBindings, oldBindings)
        completeStandardKLayerLiveVerification(store, with: newBindings)

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
        XCTAssertEqual(
            store.lastHIDLearningResult?.message,
            "Configured and live-verified Standard K1–K10 layers in the active hardware layout."
        )
        XCTAssertTrue(store.isStandardKLayerLiveVerified)
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

    func testConfigureStandardKLayersRejectsMaskingReport6SetWithActionableContext() {
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
        XCTAssertTrue(store.lastHIDLearningResult?.message.contains("K10 held hides K5") == true)
        XCTAssertTrue(store.lastHIDLearningResult?.message.contains("prior hardware layout was preserved") == true)
    }

    func testConfigureStandardKLayersRejectsMissingLiveCompositeAndPreservesPriorLayout() {
        let store = makeStore()
        let oldBindings = store.hidBindings
        let bindings = hardwareLearningSignatures()

        store.beginLearningAllHIDControls()
        captureStandardKLayerSingles(store, with: bindings)
        XCTAssertTrue(store.isLearningAll)
        XCTAssertFalse(store.isStandardKLayerLiveVerified)

        store.simulateHIDInputForTesting(bindings[.k10])
        store.simulateHIDInputForTesting(report2ReleaseSignature)

        XCTAssertFalse(store.isLearningAll)
        XCTAssertFalse(store.isStandardKLayerLiveVerified)
        XCTAssertEqual(store.hidBindings, oldBindings)
        XCTAssertTrue(store.lastHIDLearningResult?.message.contains("K10 held, then K5") == true)
        XCTAssertTrue(store.lastHIDLearningResult?.message.contains("prior hardware layout was preserved") == true)
    }

    func testConfigureStandardKLayersRejectsWrongOrderAndWrongComposite() {
        let wrongOrderStore = makeStore()
        let wrongOrderBindings = hardwareLearningSignatures()
        let wrongOrderOriginal = wrongOrderStore.hidBindings
        wrongOrderStore.beginLearningAllHIDControls()
        captureStandardKLayerSingles(wrongOrderStore, with: wrongOrderBindings)
        wrongOrderStore.simulateHIDInputForTesting(wrongOrderBindings[.k5])
        XCTAssertFalse(wrongOrderStore.isLearningAll)
        XCTAssertEqual(wrongOrderStore.hidBindings, wrongOrderOriginal)
        XCTAssertTrue(wrongOrderStore.lastHIDLearningResult?.message.contains("K10 held, then K5") == true)

        let wrongCompositeStore = makeStore()
        let wrongCompositeBindings = hardwareLearningSignatures()
        let wrongCompositeOriginal = wrongCompositeStore.hidBindings
        wrongCompositeStore.beginLearningAllHIDControls()
        captureStandardKLayerSingles(wrongCompositeStore, with: wrongCompositeBindings)
        wrongCompositeStore.simulateHIDInputForTesting(wrongCompositeBindings[.k10])
        wrongCompositeStore.simulateHIDInputForTesting(
            report2CompositeSignature(for: .k10, and: .k4, in: wrongCompositeBindings)
        )
        XCTAssertFalse(wrongCompositeStore.isLearningAll)
        XCTAssertEqual(wrongCompositeStore.hidBindings, wrongCompositeOriginal)
        XCTAssertTrue(wrongCompositeStore.lastHIDLearningResult?.message.contains("K10 held, then K5") == true)
    }

    func testConfigureStandardKLayersAcceptsReport6CombinedStatesAndNilReleases() {
        let store = makeStore()
        let bindings = uniqueReport6KBindings()

        store.beginLearningAllHIDControls()
        captureStandardKLayerSingles(store, with: bindings)
        store.simulateHIDInputForTesting(bindings[.k10])
        store.simulateHIDInputForTesting(report6CompositeSignature(for: .k10, and: .k5, in: bindings))
        store.simulateHIDInputForTesting(nil)
        store.simulateHIDInputForTesting(bindings[.k5])
        store.simulateHIDInputForTesting(report6CompositeSignature(for: .k5, and: .k10, in: bindings))
        store.simulateHIDInputForTesting(nil)

        XCTAssertTrue(store.lastHIDLearningResult?.succeeded == true)
        XCTAssertTrue(store.isStandardKLayerLiveVerified)
    }

    func testStandardKLayerLiveVerificationAcceptsBothReport2PartialReleaseDirectionsForBothOrders() {
        for firstOrderPartial in [.k10, .k5] as [RemoteControl] {
            for secondOrderPartial in [.k5, .k10] as [RemoteControl] {
                let store = makeStore()
                let bindings = hardwareLearningSignatures()
                store.beginLearningAllHIDControls()
                captureStandardKLayerSingles(store, with: bindings)
                completeStandardKLayerVerificationOrder(
                    store,
                    first: .k10,
                    second: .k5,
                    bindings: bindings,
                    partialReleaseState: firstOrderPartial
                )
                completeStandardKLayerVerificationOrder(
                    store,
                    first: .k5,
                    second: .k10,
                    bindings: bindings,
                    partialReleaseState: secondOrderPartial
                )
                XCTAssertTrue(store.isStandardKLayerLiveVerified, "report-2 first partial=\(firstOrderPartial.rawValue), second partial=\(secondOrderPartial.rawValue), result=\(store.lastHIDLearningResult?.message ?? "none")")
            }
        }
    }

    func testStandardKLayerLiveVerificationAcceptsBothReport6PartialReleaseDirectionsForBothOrders() {
        for firstOrderPartial in [.k10, .k5] as [RemoteControl] {
            for secondOrderPartial in [.k5, .k10] as [RemoteControl] {
                let store = makeStore()
                let bindings = uniqueReport6KBindings()
                store.beginLearningAllHIDControls()
                captureStandardKLayerSingles(store, with: bindings)
                completeReport6StandardKLayerVerificationOrder(
                    store,
                    first: .k10,
                    second: .k5,
                    bindings: bindings,
                    partialReleaseState: firstOrderPartial
                )
                completeReport6StandardKLayerVerificationOrder(
                    store,
                    first: .k5,
                    second: .k10,
                    bindings: bindings,
                    partialReleaseState: secondOrderPartial
                )
                XCTAssertTrue(store.isStandardKLayerLiveVerified, "report-6 first partial=\(firstOrderPartial.rawValue), second partial=\(secondOrderPartial.rawValue), result=\(store.lastHIDLearningResult?.message ?? "none")")
            }
        }
    }

    func testLiveVerifiedReport6KeepsValidStatesButInvalidatesUnknownKState() {
        let store = makeStore()
        let bindings = uniqueReport6KBindings()
        configureStandardKLayers(store, with: bindings)
        XCTAssertTrue(store.isStandardKLayerLiveVerified)

        store.simulateHIDInputForTesting(bindings[.k10])
        store.simulateHIDInputForTesting(report6CompositeSignature(for: .k10, and: .k5, in: bindings))
        store.simulateHIDInputForTesting("r6:01 56 00 00 00 00 00")
        XCTAssertTrue(store.isStandardKLayerLiveVerified)

        store.simulateHIDInputForTesting("r6:03 1D 00 00 00 00 00")
        XCTAssertFalse(store.isStandardKLayerLiveVerified)
        XCTAssertTrue(store.lastHIDLearningResult?.message.contains("report-6 K input") == true)
    }

    func testStandardKLayerLiveVerificationBecomesTrueOnlyAfterBothOrdersAndInvalidates() {
        let store = makeStore()
        let bindings = hardwareLearningSignatures()
        store.beginLearningAllHIDControls()
        captureStandardKLayerSingles(store, with: bindings)

        XCTAssertFalse(store.isStandardKLayerLiveVerified)
        completeStandardKLayerVerificationOrder(store, first: .k10, second: .k5, bindings: bindings)
        XCTAssertTrue(store.isLearningAll)
        XCTAssertFalse(store.isStandardKLayerLiveVerified)
        XCTAssertTrue(store.standardKLayerVerificationPrompt?.contains("K5") == true)

        completeStandardKLayerVerificationOrder(store, first: .k5, second: .k10, bindings: bindings)
        XCTAssertTrue(store.isStandardKLayerLiveVerified)

        store.hid.simulateDisconnectForTesting()
        XCTAssertFalse(store.isStandardKLayerLiveVerified)

        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isStandardKLayerLiveVerified)

        configureStandardKLayers(store, with: bindings)
        XCTAssertTrue(store.isStandardKLayerLiveVerified)
        store.selectedControl = .k1
        store.learnSelectedControl()
        XCTAssertFalse(store.isStandardKLayerLiveVerified)
        store.cancelLearning()

        configureStandardKLayers(store, with: bindings)
        XCTAssertTrue(store.isStandardKLayerLiveVerified)
        XCTAssertTrue(store.selectHardwareLayout(id: store.activeHardwareLayoutID))
        XCTAssertFalse(store.isStandardKLayerLiveVerified)
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

    func testConfigureStandardKLayersDoesNotStartOrResetMIDISession() throws {
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

        let midiProfileBefore = try midiProfilePayload(named: "MIDI", from: store)
        store.beginLearningAllHIDControls()
        XCTAssertEqual(store.activeRealm, .midi)
        XCTAssertFalse(store.isLearningAll)
        XCTAssertNil(store.learningControl)
        XCTAssertTrue(store.isFnLayerActive)
        XCTAssertEqual(
            store.lastHIDLearningResult?.message,
            "Configure Standard K layers is available only in the Standard workspace. MIDI input, mappings, and settings were not changed."
        )
        XCTAssertEqual(try midiProfilePayload(named: "MIDI", from: store), midiProfileBefore)
    }

    func testConfigureStandardKLayersPreservesMIDIProfileMappingsAndSettingsOnSuccessAndFailure() throws {
        let store = makeStore()
        _ = try store.addMIDIProfile(named: "MIDI")
        XCTAssertTrue(store.updateMIDIPracticeFnControl(.k10))
        store.updateMIDIButtonMapping(
            MIDIButtonMapping(kind: .cc, controller: 74, pressValue: 96, releaseValue: 12),
            for: .k8
        )
        let midiProfileBefore = try midiProfilePayload(named: "MIDI", from: store)

        XCTAssertTrue(store.selectProfile("Global"))
        configureStandardKLayers(store, with: hardwareLearningSignatures())
        XCTAssertTrue(store.lastHIDLearningResult?.succeeded == true)
        XCTAssertEqual(try midiProfilePayload(named: "MIDI", from: store), midiProfileBefore)

        let bindingsBeforeFailure = store.hidBindings
        configureStandardKLayers(store, with: factoryKBindings())
        XCTAssertFalse(store.lastHIDLearningResult?.succeeded ?? true)
        XCTAssertEqual(store.hidBindings, bindingsBeforeFailure)
        XCTAssertEqual(try midiProfilePayload(named: "MIDI", from: store), midiProfileBefore)
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

    private func configureStandardKLayers(
        _ store: MappingStore,
        with bindings: [RemoteControl: String]
    ) {
        store.beginLearningAllHIDControls()
        captureStandardKLayerSingles(store, with: bindings)
        guard store.isLearningAll else { return }
        completeStandardKLayerLiveVerification(store, with: bindings)
    }

    private func captureStandardKLayerSingles(
        _ store: MappingStore,
        with bindings: [RemoteControl: String]
    ) {
        for control in RemoteControl.allCases.filter(\.isMIDIButton) {
            store.simulateHIDInputForTesting(bindings[control])
            store.simulateHIDInputForTesting(
                bindings[control]?.hasPrefix("r2:") == true ? report2ReleaseSignature : nil
            )
        }
    }

    private func completeStandardKLayerLiveVerification(
        _ store: MappingStore,
        with bindings: [RemoteControl: String]
    ) {
        if bindings[.k10]?.hasPrefix("r6:") == true {
            completeReport6StandardKLayerVerificationOrder(store, first: .k10, second: .k5, bindings: bindings)
            completeReport6StandardKLayerVerificationOrder(store, first: .k5, second: .k10, bindings: bindings)
        } else {
            completeStandardKLayerVerificationOrder(store, first: .k10, second: .k5, bindings: bindings)
            completeStandardKLayerVerificationOrder(store, first: .k5, second: .k10, bindings: bindings)
        }
    }

    private func completeStandardKLayerVerificationOrder(
        _ store: MappingStore,
        first: RemoteControl,
        second: RemoteControl,
        bindings: [RemoteControl: String],
        partialReleaseState: RemoteControl? = nil
    ) {
        store.simulateHIDInputForTesting(bindings[first])
        store.simulateHIDInputForTesting(report2CompositeSignature(for: first, and: second, in: bindings))
        if let partialReleaseState {
            store.simulateHIDInputForTesting(bindings[partialReleaseState])
        }
        store.simulateHIDInputForTesting(report2ReleaseSignature)
    }

    private func completeReport6StandardKLayerVerificationOrder(
        _ store: MappingStore,
        first: RemoteControl,
        second: RemoteControl,
        bindings: [RemoteControl: String],
        partialReleaseState: RemoteControl? = nil
    ) {
        store.simulateHIDInputForTesting(bindings[first])
        store.simulateHIDInputForTesting(report6CompositeSignature(for: first, and: second, in: bindings))
        if let partialReleaseState {
            store.simulateHIDInputForTesting(bindings[partialReleaseState])
        }
        store.simulateHIDInputForTesting(nil)
    }

    private func report2CompositeSignature(
        for first: RemoteControl,
        and second: RemoteControl,
        in bindings: [RemoteControl: String]
    ) -> String {
        let firstMask = HIDKeyboardReport.report2OneHotMask(from: bindings[first]!)!
        let secondMask = HIDKeyboardReport.report2OneHotMask(from: bindings[second]!)!
        let mask = firstMask | secondMask
        return String(format: "r2:F0 %02X %02X 00 00 00 00 00", mask & 0xFF, mask >> 8)
    }

    private func uniqueReport6KBindings() -> [RemoteControl: String] {
        Dictionary(uniqueKeysWithValues: RemoteControl.allCases.filter(\.isMIDIButton).enumerated().map {
            ($0.element, String(format: "r6:00 %02X 00 00 00 00 00", 0x68 + $0.offset))
        })
    }

    private func report6CompositeSignature(
        for first: RemoteControl,
        and second: RemoteControl,
        in bindings: [RemoteControl: String]
    ) -> String {
        let firstReport = HIDKeyboardReport(signature: bindings[first]!)!
        let secondReport = HIDKeyboardReport(signature: bindings[second]!)!
        let combined = firstReport.merged(with: secondReport)!
        let usages = combined.keyUsages.sorted()
        let padded = usages + Array(repeating: 0, count: HIDKeyboardReport.bootKeyboardOrdinaryKeyCapacity - usages.count)
        return String(
            format: "r6:%02X %@",
            combined.modifierByte,
            padded.map { String(format: "%02X", $0) }.joined(separator: " ")
        )
    }

    private func factoryKBindings() -> [RemoteControl: String] {
        [
            .k1: "r6:01 12 00 00 00 00 00",
            .k2: "r6:01 11 00 00 00 00 00",
            .k3: "r6:00 3E 00 00 00 00 00",
            .k4: "r6:02 00 00 00 00 00 00",
            .k5: "r6:01 00 00 00 00 00 00",
            .k6: "r6:04 00 00 00 00 00 00",
            .k7: "r6:01 16 00 00 00 00 00",
            .k8: "r6:01 1D 00 00 00 00 00",
            .k9: "r6:00 2C 00 00 00 00 00",
            .k10: "r6:03 1D 00 00 00 00 00"
        ]
    }

    private func midiProfilePayload(named name: String, from store: MappingStore) throws -> Data {
        let configuration = try XCTUnwrap(store.exportConfiguration())
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: configuration) as? [String: Any]
        )
        let profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        let profile = try XCTUnwrap(profiles.first(where: { $0["name"] as? String == name }))
        return try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    }
}
