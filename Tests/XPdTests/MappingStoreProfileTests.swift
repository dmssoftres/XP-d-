import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingStoreProfileTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MappingStoreProfileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMappingsAreIndependentAfterSwitchingProfiles() {
        let store = makeStore()
        let global = Mapping(action: .noAction, command: "global")
        let finder = Mapping(action: .noAction, command: "finder")

        store.update(global, for: .k1, gesture: .tap)
        store.profileName = "Finder"
        store.update(finder, for: .k1, gesture: .tap)

        store.profileName = "Global"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), global)
        store.profileName = "Finder"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
    }

    func testStandardButtonTitlesAreProfileSpecificAndReload() {
        let store = makeStore()
        store.updateStandardButtonTitle("  Chrome  ", for: .k1)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "Chrome")

        store.profileName = "Finder"
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "")
        store.updateStandardButtonTitle("Files", for: .k1)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "Files")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profileName, "Finder")
        XCTAssertEqual(reloaded.standardButtonTitle(for: .k1), "Files")
        reloaded.profileName = "Global"
        XCTAssertEqual(reloaded.standardButtonTitle(for: .k1), "Chrome")
    }

    func testRemoteModifierLayersAreProfileSpecificReloadAndSurviveTemporaryDisable() throws {
        let store = makeStore()
        let globalLayer = Mapping(action: .openApplication, command: "Global stacked layer")
        store.setRemoteModifier(.k3, enabled: true)
        store.setRemoteModifier(.k4, enabled: true)
        store.update(
            globalLayer,
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3, .k4]
        )

        store.setRemoteModifier(.k4, enabled: false)
        XCTAssertFalse(store.isRemoteModifier(.k4))
        XCTAssertEqual(
            store.mapping(for: .k1, gesture: .tap, modifierControls: [.k3, .k4]),
            globalLayer
        )
        store.setRemoteModifier(.k4, enabled: true)

        store.profileName = "Finder"
        XCTAssertFalse(store.isRemoteModifier(.k3))
        XCTAssertFalse(store.isRemoteModifier(.k4))
        XCTAssertNotEqual(
            store.mapping(for: .k1, gesture: .tap, modifierControls: [.k3, .k4]),
            globalLayer
        )

        store.profileName = "Global"
        let exported = try XCTUnwrap(store.exportConfiguration())
        defaults.removePersistentDomain(forName: suiteName)
        let imported = makeStore()
        XCTAssertTrue(imported.importConfiguration(exported))
        XCTAssertTrue(imported.isRemoteModifier(.k3))
        XCTAssertTrue(imported.isRemoteModifier(.k4))
        XCTAssertEqual(
            imported.mapping(for: .k1, gesture: .tap, modifierControls: [.k3, .k4]),
            globalLayer
        )

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.isRemoteModifier(.k3))
        XCTAssertTrue(reloaded.isRemoteModifier(.k4))
        XCTAssertEqual(
            reloaded.mapping(for: .k1, gesture: .tap, modifierControls: [.k3, .k4]),
            globalLayer
        )
    }

    func testVersionSixPersistedProfilesMigrateLegacyRemoteTriggerData() throws {
        let source = makeStore()
        let legacyMapping = Mapping(
            action: .openApplication,
            command: "legacy F trigger",
            remoteTriggerModifiers: [.command],
            remoteTriggerFunctionKey: 118
        )
        source.setRemoteModifier(.k3, enabled: true)
        source.update(legacyMapping, for: .k1, gesture: .tap, modifierControls: [.k3])

        let currentData = try XCTUnwrap(defaults.data(forKey: "XPd.profiles.v8"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        object["version"] = XPdConfiguration.preRemoteTriggerKeysVersion
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        defaults.set(legacyData, forKey: "XPd.profiles.v6")
        defaults.removeObject(forKey: "XPd.profiles.v8")

        let restored = makeStore()
        XCTAssertTrue(restored.isRemoteModifier(.k3))
        XCTAssertEqual(
            restored.mapping(for: .k1, gesture: .tap, modifierControls: [.k3]),
            legacyMapping
        )
        let migratedData = try XCTUnwrap(defaults.data(forKey: "XPd.profiles.v8"))
        let migratedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        XCTAssertEqual(migratedObject["version"] as? Int, XPdConfiguration.currentVersion)
    }

    func testStandardButtonTitleEmptyRemovesAndWheelOrMIDIUpdatesAreNoOps() throws {
        let store = makeStore()
        store.updateStandardButtonTitle("Chrome", for: .k1)
        store.updateStandardButtonTitle("   \n", for: .k1)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "")

        store.updateStandardButtonTitle("Wheel", for: .wheelCW)
        XCTAssertEqual(store.standardButtonTitle(for: .wheelCW), "")

        store.updateStandardButtonTitle(String(repeating: "x", count: 25), for: .k1)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), String(repeating: "x", count: 24))

        _ = try store.addMIDIProfile(named: "Pads")
        XCTAssertEqual(store.activeRealm, .midi)
        store.updateStandardButtonTitle("Should not persist", for: .k1)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "")

        store.profileName = "Global"
        XCTAssertEqual(store.standardButtonTitle(for: .k1), String(repeating: "x", count: 24))
    }

    func testAutosaveIsolatedForMappingsAndHIDBindings() {
        let store = makeStore()
        let global = Mapping(action: .noAction, command: "global")
        store.update(global, for: .k1, gesture: .tap)
        store.selectedControl = .k1
        store.learnSelectedControl()
        store.simulateHIDInputForTesting("global-signature")

        store.profileName = "Finder"
        let finder = Mapping(action: .noAction, command: "finder")
        store.update(finder, for: .k1, gesture: .tap)
        store.selectedControl = .k2
        store.learnSelectedControl()
        store.simulateHIDInputForTesting("finder-signature")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profileName, "Finder")
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertEqual(reloaded.hidBinding(for: .k2), "finder-signature")

        reloaded.profileName = "Global"
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap), global)
        XCTAssertEqual(reloaded.hidBinding(for: .k1), "global-signature")
        XCTAssertNotEqual(reloaded.hidBinding(for: .k2), "finder-signature")
    }

    func testLegacySharedStateMigratesIntoGlobalOnly() throws {
        let oldMapping = Mapping(action: .noAction, command: "legacy-global")
        let mappingData = try JSONEncoder().encode([
            MappingKey(control: .k1, gesture: .tap): oldMapping
        ])
        let bindingData = try JSONEncoder().encode([
            RemoteControl.k1: "r6:06 01 11 00 00 00 00 00"
        ])
        defaults.set(mappingData, forKey: "XPd.mappings.v1")
        defaults.set(bindingData, forKey: "XPd.hidBindings.v1")
        defaults.set("Finder", forKey: "XPd.profileName.v1")

        let store = makeStore()
        XCTAssertEqual(store.profileName, "Global")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), oldMapping)
        XCTAssertEqual(store.hidBinding(for: .k1), "r6:01 11 00 00 00 00 00")
        XCTAssertNil(store.hidBinding(for: .k2))

        store.profileName = "Finder"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
        XCTAssertNotEqual(store.hidBinding(for: .k1), "r6:01 11 00 00 00 00 00")
    }

    func testMultiProfileExportImportAndInvalidImportAreAtomic() throws {
        let source = makeStore()
        source.updateStandardButtonTitle("Global title", for: .k1)
        source.update(Mapping(action: .noAction, command: "global"), for: .k1, gesture: .tap)
        source.profileName = "Finder"
        source.updateStandardButtonTitle("Finder title", for: .k1)
        source.update(Mapping(action: .noAction, command: "finder"), for: .k1, gesture: .tap)
        source.selectedControl = .k3
        source.learnSelectedControl()
        source.simulateHIDInputForTesting("finder-k3")

        let data = try XCTUnwrap(source.exportConfiguration())
        let decoded = try XPdConfiguration.decode(data)
        XCTAssertEqual(decoded.profiles.map(\.name), source.availableProfiles)
        XCTAssertEqual(decoded.profiles.first(where: { $0.name == "Finder" })?.hidBindings.count, 13)

        let target = makeStore()
        XCTAssertTrue(target.importConfiguration(data))
        XCTAssertEqual(target.profileName, "Finder")
        XCTAssertEqual(target.mapping(for: .k1, gesture: .tap).command, "finder")
        XCTAssertEqual(target.hidBinding(for: .k3), "finder-k3")
        XCTAssertEqual(target.standardButtonTitle(for: .k1), "Finder title")
        target.profileName = "Global"
        XCTAssertEqual(target.mapping(for: .k1, gesture: .tap).command, "global")
        XCTAssertEqual(target.standardButtonTitle(for: .k1), "Global title")

        let invalidGlobal = XPdConfiguration.Profile(
            name: "Global",
            mappings: [
                .init(control: .k1, gesture: .tap, mapping: Mapping()),
                .init(control: .k1, gesture: .tap, mapping: Mapping(action: .noAction))
            ],
            hidBindings: []
        )
        let validEmptyProfile = XPdConfiguration.Profile(name: "Finder", mappings: [], hidBindings: [])
        let validLogicProfile = XPdConfiguration.Profile(name: "Logic Pro", mappings: [], hidBindings: [])
        let invalidData = try JSONEncoder().encode(XPdConfiguration(
            profiles: [invalidGlobal, validEmptyProfile, validLogicProfile],
            profileName: "Finder",
            showsInputOverlay: true
        ))

        XCTAssertFalse(target.importConfiguration(invalidData))
        XCTAssertEqual(target.profileName, "Global")
        XCTAssertEqual(target.mapping(for: .k1, gesture: .tap).command, "global")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profileName, "Global")
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap).command, "global")
        XCTAssertEqual(reloaded.standardButtonTitle(for: .k1), "Global title")
    }

    func testImportRejectsInvalidStandardButtonTitlesAtomically() throws {
        let target = makeStore()
        target.updateStandardButtonTitle("Keep me", for: .k1)

        func invalidData(_ titles: [XPdConfiguration.StandardButtonTitleEntry]) throws -> Data {
            let profiles = [
                XPdConfiguration.Profile(name: "Global", mappings: [], hidBindings: [], standardButtonTitles: titles),
                XPdConfiguration.Profile(name: "Finder", mappings: [], hidBindings: []),
                XPdConfiguration.Profile(name: "Logic Pro", mappings: [], hidBindings: [])
            ]
            return try JSONEncoder().encode(XPdConfiguration(
                profiles: profiles,
                profileName: "Global",
                showsInputOverlay: true
            ))
        }

        let invalidPayloads = [
            try invalidData([
                .init(control: .k1, title: "One"),
                .init(control: .k1, title: "Two")
            ]),
            try invalidData([.init(control: .wheelCW, title: "Wheel")]),
            try invalidData([.init(control: .k1, title: String(repeating: "x", count: 25))])
        ]

        for data in invalidPayloads {
            XCTAssertFalse(target.importConfiguration(data))
            XCTAssertEqual(target.standardButtonTitle(for: .k1), "Keep me")
            XCTAssertEqual(target.profileName, "Global")
        }

        for legacyVersion in [XPdConfiguration.legacyVersion, XPdConfiguration.previousVersion] {
            let legacy = XPdConfiguration(
                version: legacyVersion,
                profiles: XPdConfiguration.defaultProfileNames.map { name in
                    XPdConfiguration.Profile(
                        name: name,
                        mappings: [],
                        hidBindings: [],
                        standardButtonTitles: name == "Global"
                            ? [.init(control: .k1, title: "Unsupported")]
                            : []
                    )
                },
                profileName: "Global",
                showsInputOverlay: true
            )

            XCTAssertFalse(target.importConfiguration(try JSONEncoder().encode(legacy)))
            XCTAssertEqual(target.standardButtonTitle(for: .k1), "Keep me")
            XCTAssertEqual(target.profileName, "Global")
        }
    }

    func testWheelCenterSelectorConfirmsHighlightedProfileOnRelease() {
        let store = makeStore()
        store.update(Mapping(action: .noAction, command: "global"), for: .k1, gesture: .tap)

        store.simulateHIDInputForTesting("wheel:center")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.pendingProfileNameForTesting, "Global")
        XCTAssertEqual(store.profileName, "Global")

        store.simulateHIDInputForTesting("wheel:+")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.pendingProfileNameForTesting, "Finder")
        XCTAssertEqual(store.profileName, "Global")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "global")

        store.simulateHIDInputForTesting(nil)
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Finder")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())

        store.simulateHIDInputForTesting("wheel:center")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Finder")

        store.simulateHIDInputForTesting(nil)
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Finder")
    }

    func testHIDCenterReleaseWaitsThroughWheelDetentRelease() {
        let store = makeStore()
        let emptyReport = Array(repeating: UInt8(0), count: 7)
        let clockwiseReport: [UInt8] = [0x01, 0x57, 0, 0, 0, 0, 0]

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: clockwiseReport)
        XCTAssertEqual(store.pendingProfileNameForTesting, "Finder")
        XCTAssertEqual(store.profileName, "Global")

        // The empty report immediately after a detent releases the wheel
        // action, not the physically held center switch.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Global")

        // The next standalone empty report is center release and confirms.
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Finder")
    }

    func testHIDDisconnectWhileCenterHeldClearsSelectorWithoutSwitchingProfile() {
        let store = makeStore()
        let emptyReport = Array(repeating: UInt8(0), count: 7)
        let clockwiseReport: [UInt8] = [0x01, 0x57, 0, 0, 0, 0, 0]

        store.hid.simulateInputReportForTesting(reportID: 6, bytes: emptyReport)
        store.hid.simulateInputReportForTesting(reportID: 6, bytes: clockwiseReport)
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.pendingProfileNameForTesting, "Finder")
        XCTAssertEqual(store.profileName, "Global")

        store.hid.simulateDisconnectForTesting()

        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertNil(store.pendingProfileNameForTesting)
        XCTAssertEqual(store.profileName, "Global")
    }

    func testNewProfilesTrimAndPersistIndependentState() throws {
        let store = makeStore()
        let addedName = try store.addProfile(named: "  Studio  ")
        XCTAssertEqual(addedName, "Studio")
        XCTAssertEqual(store.availableProfiles, ["Global", "Finder", "Logic Pro", "Studio"])
        XCTAssertEqual(store.profileName, "Studio")

        let studioMapping = Mapping(action: .noAction, command: "studio")
        store.update(studioMapping, for: .k1, gesture: .tap)
        store.selectedControl = .k2
        store.learnSelectedControl()
        store.simulateHIDInputForTesting("studio-k2")

        store.profileName = "Global"
        XCTAssertNotEqual(store.mapping(for: .k1, gesture: .tap), studioMapping)
        XCTAssertNotEqual(store.hidBinding(for: .k2), "studio-k2")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.availableProfiles, ["Global", "Finder", "Logic Pro", "Studio"])
        reloaded.profileName = "Studio"
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap), studioMapping)
        XCTAssertEqual(reloaded.hidBinding(for: .k2), "studio-k2")
    }

    func testProfileNameValidationAndGlobalProtection() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.addProfile(named: "   ")) { error in
            XCTAssertEqual(error as? MappingStore.ProfileError, .invalidName("   "))
        }
        XCTAssertThrowsError(try store.addProfile(named: String(repeating: "x", count: 41)))
        _ = try store.addProfile(named: "Studio")
        XCTAssertThrowsError(try store.addProfile(named: " studio ")) { error in
            XCTAssertEqual(error as? MappingStore.ProfileError, .duplicateName("studio"))
        }
        XCTAssertThrowsError(try store.deleteProfile(named: "Global")) { error in
            XCTAssertEqual(error as? MappingStore.ProfileError, .cannotDeleteGlobal)
        }
        XCTAssertThrowsError(try store.renameProfile(named: "Global", to: "Everywhere")) { error in
            XCTAssertEqual(error as? MappingStore.ProfileError, .cannotRenameGlobal)
        }
    }

    func testRenamingActiveProfilePreservesStateOrderAndPersistence() throws {
        let store = makeStore()
        _ = try store.addProfile(named: "Studio")
        let mapping = Mapping(action: .noAction, command: "studio")
        store.update(mapping, for: .k1, gesture: .tap)
        store.selectedControl = .k2
        store.learnSelectedControl()
        store.simulateHIDInputForTesting("studio-k2")

        let renamed = try store.renameProfile(named: "Studio", to: "  Editing  ")

        XCTAssertEqual(renamed, "Editing")
        XCTAssertEqual(store.availableProfiles, ["Global", "Finder", "Logic Pro", "Editing"])
        XCTAssertEqual(store.profileName, "Editing")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), mapping)
        XCTAssertEqual(store.hidBinding(for: .k2), "studio-k2")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.availableProfiles, ["Global", "Finder", "Logic Pro", "Editing"])
        XCTAssertEqual(reloaded.profileName, "Editing")
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap), mapping)
        XCTAssertEqual(reloaded.hidBinding(for: .k2), "studio-k2")
    }

    func testRenameValidationAndSelectorResetAreAtomic() throws {
        let store = makeStore()
        store.simulateHIDInputForTesting("wheel:center")
        store.simulateHIDInputForTesting("wheel:+")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)

        XCTAssertThrowsError(try store.renameProfile(named: "Finder", to: " logic pro ")) { error in
            XCTAssertEqual(error as? MappingStore.ProfileError, .duplicateName("logic pro"))
        }
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.availableProfiles, ["Global", "Finder", "Logic Pro"])

        try store.renameProfile(named: "Finder", to: "Files")
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertNil(store.pendingProfileNameForTesting)
        XCTAssertEqual(store.availableProfiles, ["Global", "Files", "Logic Pro"])
    }

    func testDeletingInactiveAndActiveProfilesPreservesFallback() throws {
        let store = makeStore()
        _ = try store.addProfile(named: "Inactive")
        store.profileName = "Global"
        let globalMapping = Mapping(action: .noAction, command: "global")
        store.update(globalMapping, for: .k1, gesture: .tap)
        try store.deleteProfile(named: "Inactive")
        XCTAssertEqual(store.profileName, "Global")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), globalMapping)

        _ = try store.addProfile(named: "Active")
        XCTAssertEqual(store.profileName, "Active")
        try store.deleteProfile(named: "Active")
        XCTAssertEqual(store.profileName, "Global")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), globalMapping)
        XCTAssertFalse(store.availableProfiles.contains("Active"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.profileName, "Global")
        XCTAssertFalse(reloaded.availableProfiles.contains("Active"))
    }

    func testVersionTwoPersistedProfilesMigrateInOrderAndKeepActiveProfile() throws {
        struct LegacyState: Codable {
            let mappings: [MappingKey: Mapping]
            let hidBindings: [RemoteControl: String]
        }
        let globalMapping = Mapping(action: .noAction, command: "legacy-global")
        let finderMapping = Mapping(action: .noAction, command: "legacy-finder")
        let payload = [
            "Finder": LegacyState(mappings: [MappingKey(control: .k1, gesture: .tap): finderMapping], hidBindings: [.k1: "finder"]),
            "Global": LegacyState(mappings: [MappingKey(control: .k1, gesture: .tap): globalMapping], hidBindings: [.k1: "global"]),
            "Logic Pro": LegacyState(mappings: [:], hidBindings: [:])
        ]
        defaults.set(try JSONEncoder().encode(payload), forKey: "XPd.profiles.v2")
        defaults.set("Finder", forKey: "XPd.profileName.v1")

        let store = makeStore()
        XCTAssertEqual(store.availableProfiles, ["Global", "Finder", "Logic Pro"])
        XCTAssertEqual(store.profileName, "Finder")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finderMapping)
        XCTAssertEqual(store.hidBinding(for: .k1), "finder")
        store.profileName = "Global"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), globalMapping)

        store.profileName = "Finder"
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.availableProfiles, ["Global", "Finder", "Logic Pro"])
        XCTAssertEqual(reloaded.profileName, "Finder")
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap), finderMapping)
    }

    func testVersionFourPersistedProfilesMigrateWithEmptyTitles() throws {
        struct LegacyState: Codable {
            let mappings: [MappingKey: Mapping]
            let hidBindings: [RemoteControl: String]
            let realm: ProfileRealm
            let midiSettings: MIDIProfileSettings?
        }
        struct LegacyProfile: Codable {
            let name: String
            let state: LegacyState
        }
        struct LegacyDocument: Codable {
            let version: Int
            let profiles: [LegacyProfile]
            let activeProfileName: String
            let activeRealm: ProfileRealm
            let lastStandardProfileName: String?
            let lastMIDIProfileName: String?
            let midiLocked: Bool
            let workspaceLockControl: RemoteControl
        }

        let legacy = LegacyDocument(
            version: XPdConfiguration.preTitlesVersion,
            profiles: XPdConfiguration.defaultProfileNames.map {
                LegacyProfile(
                    name: $0,
                    state: LegacyState(
                        mappings: [:],
                        hidBindings: [:],
                        realm: .standard,
                        midiSettings: nil
                    )
                )
            },
            activeProfileName: "Finder",
            activeRealm: .standard,
            lastStandardProfileName: "Finder",
            lastMIDIProfileName: nil,
            midiLocked: false,
            workspaceLockControl: .k3
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: "XPd.profiles.v4")

        let store = makeStore()
        XCTAssertEqual(store.profileName, "Finder")
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "")
        store.updateStandardButtonTitle("Migrated", for: .k1)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.standardButtonTitle(for: .k1), "Migrated")
    }

    func testDynamicImportExportAndVersionTwoDocumentUpgrade() throws {
        let source = makeStore()
        try source.addProfile(named: "Studio")
        source.update(Mapping(action: .noAction, command: "studio"), for: .k4, gesture: .tap)
        let data = try XCTUnwrap(source.exportConfiguration())
        let decoded = try XPdConfiguration.decode(data)
        XCTAssertEqual(decoded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(decoded.profiles.map(\.name), source.availableProfiles)
        XCTAssertEqual(decoded.profiles.last?.name, "Studio")

        defaults.removePersistentDomain(forName: suiteName)
        let target = makeStore()
        XCTAssertTrue(target.importConfiguration(data))
        XCTAssertEqual(target.availableProfiles, ["Global", "Finder", "Logic Pro", "Studio"])
        XCTAssertEqual(target.profileName, "Studio")
        XCTAssertEqual(target.mapping(for: .k4, gesture: .tap).command, "studio")

        let v2 = XPdConfiguration(
            version: XPdConfiguration.legacyVersion,
            profiles: XPdConfiguration.defaultProfileNames.map {
                .init(name: $0, mappings: [], hidBindings: [])
            },
            profileName: "Finder",
            showsInputOverlay: false
        )
        let upgraded = try XPdConfiguration.decode(JSONEncoder().encode(v2))
        XCTAssertEqual(upgraded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(upgraded.profiles.map(\.name), XPdConfiguration.defaultProfileNames)
        XCTAssertEqual(upgraded.profileName, "Finder")
    }

    func testDynamicWheelOrderAndStructuralChangesResetSelector() throws {
        let store = makeStore()
        _ = try store.addProfile(named: "Studio")
        store.profileName = "Logic Pro"

        store.simulateHIDInputForTesting("wheel:center")
        store.simulateHIDInputForTesting("wheel:+")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.pendingProfileNameForTesting, "Studio")
        XCTAssertEqual(store.profileName, "Logic Pro")

        store.simulateHIDInputForTesting(nil)
        XCTAssertEqual(store.profileName, "Studio")
        try store.deleteProfile(named: "Studio")
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertNil(store.pendingProfileNameForTesting)
        XCTAssertEqual(store.profileName, "Global")

        store.simulateHIDInputForTesting("wheel:center")
        _ = try store.addProfile(named: "Editing")
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertNil(store.pendingProfileNameForTesting)
        XCTAssertEqual(store.profileName, "Editing")
    }

    func testSwitchProfileMappingSelectsConfiguredProfileAndReportsMissingTarget() {
        let store = makeStore()
        store.update(
            Mapping(action: .switchProfile, command: "Finder"),
            for: .k1,
            gesture: .tap
        )

        var success: ActionExecutionResult?
        store.executeMapping(for: .k1, gesture: .tap) { success = $0 }
        XCTAssertEqual(success, .success("Switched to Finder"))
        XCTAssertEqual(store.profileName, "Finder")

        store.update(
            Mapping(action: .switchProfile, command: "Missing"),
            for: .k2,
            gesture: .tap
        )
        var failure: ActionExecutionResult?
        store.executeMapping(for: .k2, gesture: .tap) { failure = $0 }
        XCTAssertEqual(failure, .failure("Profile not found: Missing."))
        XCTAssertEqual(store.profileName, "Finder")
    }

    func testSwitchProfileTargetWhitespaceExecutesRetargetsAndReloads() throws {
        let store = makeStore()
        store.update(
            Mapping(action: .switchProfile, command: "  Finder\n"),
            for: .k1,
            gesture: .tap
        )

        var execution: ActionExecutionResult?
        store.executeMapping(for: .k1, gesture: .tap) { execution = $0 }
        XCTAssertEqual(execution, .success("Switched to Finder"))
        XCTAssertEqual(store.profileName, "Finder")

        store.profileName = "Global"
        try store.renameProfile(named: "Finder", to: "Files")

        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "Files")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.mapping(for: .k1, gesture: .tap).command, "Files")

        var reloadedExecution: ActionExecutionResult?
        reloaded.executeMapping(for: .k1, gesture: .tap) { reloadedExecution = $0 }
        XCTAssertEqual(reloadedExecution, .success("Switched to Files"))
        XCTAssertEqual(reloaded.profileName, "Files")
    }

    func testImportedProcessAutomationIsDisarmedWithoutLosingContent() throws {
        var mapping = Mapping(action: .shellCommand, command: "echo preserved")
        mapping.automationEnabled = true
        let profiles = XPdConfiguration.defaultProfileNames.map { name in
            XPdConfiguration.Profile(
                name: name,
                mappings: name == "Global"
                    ? [.init(control: .k1, gesture: .tap, mapping: mapping)]
                    : [],
                hidBindings: []
            )
        }
        let data = try JSONEncoder().encode(XPdConfiguration(
            profiles: profiles,
            profileName: "Global",
            showsInputOverlay: true
        ))

        let target = makeStore()
        XCTAssertTrue(target.importConfiguration(data))
        let imported = target.mapping(for: .k1, gesture: .tap)
        XCTAssertEqual(imported.action, .shellCommand)
        XCTAssertEqual(imported.command, "echo preserved")
        XCTAssertFalse(imported.automationEnabled)

        let reloaded = makeStore()
        let persisted = reloaded.mapping(for: .k1, gesture: .tap)
        XCTAssertEqual(persisted.action, .shellCommand)
        XCTAssertEqual(persisted.command, "echo preserved")
        XCTAssertFalse(persisted.automationEnabled)
    }

    func testProfileRenameRetargetsSwitchMappingsAcrossProfiles() throws {
        let store = makeStore()
        store.update(
            Mapping(action: .switchProfile, command: "Finder"),
            for: .k1,
            gesture: .tap
        )
        store.profileName = "Finder"
        store.update(
            Mapping(action: .switchProfile, command: "Finder"),
            for: .k2,
            gesture: .tap
        )
        store.profileName = "Global"

        try store.renameProfile(named: "Finder", to: "Files")

        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "Files")
        store.profileName = "Files"
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap).command, "Files")
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

}
