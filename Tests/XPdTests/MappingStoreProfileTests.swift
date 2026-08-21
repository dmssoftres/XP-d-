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
        XCTAssertEqual(decoded.profiles.map(\.name), MappingStore.availableProfiles)
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

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

}
