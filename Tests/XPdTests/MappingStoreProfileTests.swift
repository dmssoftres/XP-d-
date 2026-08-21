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
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "ChatGPT")
        XCTAssertNotEqual(store.hidBinding(for: .k1), "r6:01 11 00 00 00 00 00")
    }

    func testMultiProfileExportImportAndInvalidImportAreAtomic() throws {
        let source = makeStore()
        source.update(Mapping(action: .noAction, command: "global"), for: .k1, gesture: .tap)
        source.profileName = "Finder"
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
        target.profileName = "Global"
        XCTAssertEqual(target.mapping(for: .k1, gesture: .tap).command, "global")

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
    }

    func testWheelCenterSelectorConfirmsPendingProfileOnlyOnSecondPress() {
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

        store.simulateHIDInputForTesting("wheel:center")
        XCTAssertFalse(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Finder")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "ChatGPT")

        store.simulateHIDInputForTesting("wheel:center")
        XCTAssertTrue(store.isProfileSelectorVisibleForTesting)
        XCTAssertEqual(store.profileName, "Finder")
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

        store.simulateHIDInputForTesting("wheel:center")
        XCTAssertEqual(store.profileName, "Studio")
        store.simulateHIDInputForTesting("wheel:center")
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

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

}
