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

    func testPaletteHasSixStableChoicesInOrder() {
        XCTAssertEqual(
            ModifierColor.allCases,
            [.orange, .yellow, .cyan, .blue, .purple, .pink]
        )
        XCTAssertEqual(
            ModifierColor.allCases.map(\.rawValue),
            ["orange", "yellow", "cyan", "blue", "purple", "pink"]
        )
        XCTAssertEqual(ModifierColor.allCases.map(\.displayName), ["Orange", "Yellow", "Cyan", "Blue", "Purple", "Pink"])
    }

    func testPreEnableSuggestionMatchesColourAssignedWhenEnabled() {
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

    func testPortableV8RoundTripIsDeterministic() throws {
        let store = makeStore()
        XCTAssertTrue(store.setModifierColor(.yellow, for: .k8))
        XCTAssertTrue(store.setModifierColor(.blue, for: .k3))
        let first = try XCTUnwrap(store.exportConfiguration())
        let decoded = try XPdConfiguration.decode(first)
        let global = try XCTUnwrap(decoded.profiles.first(where: { $0.name == "Global" }))
        XCTAssertEqual(global.modifierColors.map(\.control), [.k3, .k8])
        XCTAssertEqual(global.modifierColors.map(\.color), [.blue, .yellow])
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
