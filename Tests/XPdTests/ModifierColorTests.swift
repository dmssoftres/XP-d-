import Foundation
import XCTest
@testable import XPd

@MainActor
final class ModifierColorTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.ModifierColorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPaletteHasEightStableChoicesInOrder() {
        XCTAssertEqual(
            ModifierColor.allCases,
            [.orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]
        )
        XCTAssertEqual(
            ModifierColor.allCases.map(\.rawValue),
            ["orange", "yellow", "green", "cyan", "blue", "purple", "pink", "red"]
        )
        XCTAssertEqual(
            ModifierColor.allCases.map(\.displayName),
            ["Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Pink", "Red"]
        )
    }

    func testSuggestedColourMatchesColourAssignedWhenEnabled() {
        let store = makeStore()
        let suggested = store.modifierColor(for: .k3)

        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: true))
        XCTAssertEqual(store.modifierColor(for: .k3), suggested)
    }

    func testExplicitPreselectionWinsAndSurvivesDisableAndReenable() {
        let store = makeStore()
        XCTAssertTrue(store.setModifierColor(.cyan, for: .k3))
        XCTAssertEqual(store.modifierColor(for: .k3), .cyan)
        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: true))
        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: false))
        XCTAssertEqual(store.modifierColor(for: .k3), .cyan)
        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: true))
        XCTAssertEqual(store.modifierColor(for: .k3), .cyan)
    }

    func testAssignmentsAreProfileSpecificAndReload() throws {
        let store = makeStore()
        XCTAssertTrue(store.setModifierColor(.purple, for: .k3))
        store.profileName = "Finder"
        XCTAssertEqual(store.modifierColor(for: .k3), .orange)
        XCTAssertTrue(store.setModifierColor(.pink, for: .k3))
        store.profileName = "Global"
        XCTAssertEqual(store.modifierColor(for: .k3), .purple)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.modifierColor(for: .k3), .purple)
        reloaded.profileName = "Finder"
        XCTAssertEqual(reloaded.modifierColor(for: .k3), .pink)
        XCTAssertNotNil(try XCTUnwrap(reloaded.exportConfiguration()))
    }

    func testPortableV9RoundTripIsDeterministic() throws {
        let store = makeStore()
        XCTAssertTrue(store.setModifierColor(.green, for: .k8))
        XCTAssertTrue(store.setModifierColor(.red, for: .k3))
        let first = try XCTUnwrap(store.exportConfiguration())
        let decoded = try XPdConfiguration.decode(first)
        let global = try XCTUnwrap(decoded.profiles.first(where: { $0.name == "Global" }))
        XCTAssertEqual(global.modifierColors.map(\.control), [.k3, .k8])
        XCTAssertEqual(global.modifierColors.map(\.color), [.red, .green])
        XCTAssertEqual(first, try decoded.encodedData())
    }

    func testVersionSevenMigrationAssignsOrangeWithoutLosingMappings() throws {
        let legacy = XPdConfiguration(
            version: XPdConfiguration.preModifierColorsVersion,
            profiles: [
                .init(
                    name: "Global",
                    mappings: [
                        .init(
                            control: .k1,
                            gesture: .tap,
                            mapping: Mapping(action: .openApplication, command: "Finder")
                        )
                    ],
                    hidBindings: [],
                    remoteModifierControls: [.k3]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let upgraded = try XPdConfiguration.decode(try legacy.encodedData())
        let profile = try XCTUnwrap(upgraded.profiles.first)
        XCTAssertEqual(upgraded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(profile.modifierColors.map(\.control), [.k3])
        XCTAssertEqual(profile.modifierColors.map(\.color), [.orange])
        XCTAssertEqual(profile.mappings.first?.mapping.command, "Finder")
    }

    func testPersistedVersionSevenProfilesMigrateToV9WithOrangeModifierColour() throws {
        let source = makeStore()
        XCTAssertTrue(source.setRemoteModifier(.k3, enabled: true))
        source.update(
            Mapping(action: .openApplication, command: "Finder"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k3]
        )

        let currentData = try XCTUnwrap(defaults.data(forKey: "XPd.profiles.v9"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        let layouts = try XCTUnwrap(root["hardwareLayouts"] as? [[String: Any]])
        let activeLayoutID = try XCTUnwrap(root["activeHardwareLayoutID"] as? String)
        let activeBindings = try XCTUnwrap(
            layouts.first(where: { $0["id"] as? String == activeLayoutID })?["bindings"]
        )
        root["version"] = XPdConfiguration.preModifierColorsVersion
        var profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        for index in profiles.indices {
            var state = try XCTUnwrap(profiles[index]["state"] as? [String: Any])
            state["hidBindings"] = activeBindings
            state.removeValue(forKey: "modifierColors")
            profiles[index]["state"] = state
        }
        root["profiles"] = profiles
        root.removeValue(forKey: "hardwareLayouts")
        root.removeValue(forKey: "activeHardwareLayoutID")
        defaults.set(
            try JSONSerialization.data(withJSONObject: root),
            forKey: "XPd.profiles.v7"
        )
        defaults.removeObject(forKey: "XPd.profiles.v9")

        let restored = makeStore()
        XCTAssertTrue(restored.isRemoteModifier(.k3))
        XCTAssertEqual(restored.modifierColor(for: .k3), .orange)
        XCTAssertEqual(
            restored.mapping(for: .k1, gesture: .tap, modifierControls: [.k3]).command,
            "Finder"
        )
        XCTAssertNotNil(defaults.data(forKey: "XPd.profiles.v9"))
    }

    func testModifierColourValidationRejectsDuplicateNonKAndMIDIEntries() throws {
        let duplicate = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    modifierColors: [
                        .init(control: .k3, color: .orange),
                        .init(control: .k3, color: .cyan)
                    ]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try duplicate.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .duplicateModifierColor(profile: "Global", control: .k3)
            )
        }

        let nonK = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    modifierColors: [.init(control: .wheelCW, color: .orange)]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try nonK.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .invalidModifierColorControl(profile: "Global", control: .wheelCW)
            )
        }

        let midi = XPdConfiguration(
            profiles: [
                .init(name: "Global", mappings: [], hidBindings: []),
                .init(
                    name: "Pads",
                    mappings: [],
                    hidBindings: [],
                    realm: .midi,
                    modifierColors: [.init(control: .k3, color: .pink)]
                )
            ],
            profileName: "Pads",
            showsInputOverlay: true,
            activeRealm: .midi
        )
        XCTAssertThrowsError(try midi.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .modifierColorsOnMIDIProfile("Pads")
            )
        }
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
