import Foundation
import XCTest
@testable import XPd

final class XPdConfigurationTests: XCTestCase {
    func testConfigurationRoundTripsDeterministically() throws {
        let configuration = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [
                        .init(
                            control: .k1,
                            gesture: .doubleTap,
                            mapping: Mapping(action: .toggleApplication, command: "ChatGPT")
                        ),
                        .init(
                            control: .k1,
                            gesture: .tap,
                            mapping: Mapping(action: .openApplication, command: "Finder")
                        ),
                        .init(
                            control: .k1,
                            gesture: .hold,
                            mapping: Mapping(action: .noAction, command: "")
                        )
                    ],
                    hidBindings: [
                        .init(control: .k1, signature: "r6:01 12 00 00 00 00 00")
                    ]
                ),
                .init(name: "Finder", mappings: [], hidBindings: []),
                .init(name: "Logic Pro", mappings: [], hidBindings: [])
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let firstEncoding = try configuration.encodedData()
        let decoded = try XPdConfiguration.decode(firstEncoding)
        let secondEncoding = try decoded.encodedData()

        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(decoded.profiles[0].mappings.map(\.gesture), [.tap, .hold, .doubleTap])
        XCTAssertEqual(decoded.profileName, "Global")
        XCTAssertTrue(decoded.showsInputOverlay)
    }

    func testStandardButtonTitlesRoundTripAndSortByControl() throws {
        let configuration = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    standardButtonTitles: [
                        .init(control: .k8, title: " Logic Pro "),
                        .init(control: .k1, title: "Chrome")
                    ]
                ),
                .init(name: "Finder", mappings: [], hidBindings: []),
                .init(name: "Logic Pro", mappings: [], hidBindings: [])
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let first = try configuration.encodedData()
        let decoded = try XPdConfiguration.decode(first)
        XCTAssertEqual(
            decoded.profiles[0].standardButtonTitles.map(\.control),
            [.k1, .k8]
        )
        XCTAssertEqual(decoded.profiles[0].standardButtonTitles[1].title, " Logic Pro ")
        XCTAssertEqual(first, try decoded.encodedData())
    }

    func testRemoteModifierDesignationsAndExactLayersRoundTrip() throws {
        let configuration = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [
                        .init(
                            control: .k1,
                            gesture: .tap,
                            mapping: Mapping(action: .openApplication, command: "stacked"),
                            modifierControls: [.k4, .k3]
                        ),
                        .init(
                            control: .k1,
                            gesture: .tap,
                            mapping: Mapping(action: .openApplication, command: "base")
                        )
                    ],
                    hidBindings: [],
                    remoteModifierControls: [.k4, .k3]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let encoded = try configuration.encodedData()
        let decoded = try XPdConfiguration.decode(encoded)
        XCTAssertEqual(decoded.profiles[0].remoteModifierControls, [.k3, .k4])
        XCTAssertEqual(
            decoded.profiles[0].mappings.first(where: { !$0.modifierControls.isEmpty })?.modifierControls,
            [.k3, .k4]
        )
        XCTAssertEqual(encoded, try decoded.encodedData())
    }

    func testArbitraryRemoteTriggerKeyRoundTripsWithLegacyConditions() throws {
        let configuration = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [
                        .init(
                            control: .k1,
                            gesture: .tap,
                            mapping: Mapping(
                                action: .openApplication,
                                command: "K condition",
                                remoteTriggerModifiers: [.command, .shift],
                                remoteTriggerKeyCode: 40,
                                remoteTriggerKeyDisplay: "K"
                            )
                        ),
                        .init(
                            control: .k2,
                            gesture: .tap,
                            mapping: Mapping(
                                action: .openApplication,
                                command: "F condition",
                                remoteTriggerModifiers: [.option],
                                remoteTriggerFunctionKey: 118
                            )
                        )
                    ],
                    hidBindings: []
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let encoded = try configuration.encodedData()
        let decoded = try XPdConfiguration.decode(encoded)
        let arbitrary = try XCTUnwrap(decoded.profiles[0].mappings.first { $0.control == .k1 })
        let legacy = try XCTUnwrap(decoded.profiles[0].mappings.first { $0.control == .k2 })

        XCTAssertEqual(decoded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(arbitrary.mapping.remoteTriggerKeyCode, 40)
        XCTAssertEqual(arbitrary.mapping.remoteTriggerKeyDisplay, "K")
        XCTAssertEqual(arbitrary.mapping.remoteTriggerModifiers, [.command, .shift])
        XCTAssertEqual(legacy.mapping.remoteTriggerFunctionKey, 118)
        XCTAssertEqual(legacy.mapping.remoteTriggerModifiers, [.option])
        XCTAssertEqual(encoded, try decoded.encodedData())
    }

    func testVersionSixMigratesLegacyRemoteTriggerFieldsWithoutLoss() throws {
        let legacy = XPdConfiguration(
            version: XPdConfiguration.preRemoteTriggerKeysVersion,
            profiles: [
                .init(
                    name: "Global",
                    mappings: [
                        .init(
                            control: .k1,
                            gesture: .tap,
                            mapping: Mapping(
                                action: .openApplication,
                                command: "legacy",
                                remoteTriggerModifiers: [.control],
                                remoteTriggerFunctionKey: 118
                            )
                        )
                    ],
                    hidBindings: [],
                    remoteModifierControls: [.k3]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let upgraded = try XPdConfiguration.decode(JSONEncoder().encode(legacy))
        let mapping = try XCTUnwrap(upgraded.profiles[0].mappings.first)

        XCTAssertEqual(upgraded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(upgraded.profiles[0].remoteModifierControls, [.k3])
        XCTAssertEqual(mapping.mapping.remoteTriggerModifiers, [.control])
        XCTAssertEqual(mapping.mapping.remoteTriggerFunctionKey, 118)
        XCTAssertNil(mapping.mapping.remoteTriggerKeyCode)
        XCTAssertNil(mapping.mapping.remoteTriggerKeyDisplay)

        let roundTripped = try XPdConfiguration.decode(try upgraded.encodedData())
        XCTAssertEqual(roundTripped, upgraded)
    }

    func testRemoteTriggerKeyValidationRejectsModifierAndMultipleKeys() {
        let modifierKey = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(
                        control: .k1,
                        gesture: .tap,
                        mapping: Mapping(remoteTriggerKeyCode: 55, remoteTriggerKeyDisplay: "⌘")
                    )],
                    hidBindings: []
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try modifierKey.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .invalidRemoteTriggerKey(profile: "Global", primary: .k1, gesture: .tap)
            )
        }

        let multipleKeys = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(
                        control: .k1,
                        gesture: .tap,
                        mapping: Mapping(
                            remoteTriggerFunctionKey: 118,
                            remoteTriggerKeyCode: 40,
                            remoteTriggerKeyDisplay: "K"
                        )
                    )],
                    hidBindings: []
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try multipleKeys.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .multipleRemoteTriggerKeys(profile: "Global", primary: .k1, gesture: .tap)
            )
        }

        let outOfRangeKey = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(
                        control: .k1,
                        gesture: .tap,
                        mapping: Mapping(remoteTriggerKeyCode: 128, remoteTriggerKeyDisplay: "Key 128")
                    )],
                    hidBindings: []
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try outOfRangeKey.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .invalidRemoteTriggerKey(profile: "Global", primary: .k1, gesture: .tap)
            )
        }
    }

    func testVersionFiveMigratesToEmptyRemoteModifierState() throws {
        let legacy = XPdConfiguration(
            version: XPdConfiguration.preRemoteLayersVersion,
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(control: .k1, gesture: .tap, mapping: Mapping(command: "legacy"))],
                    hidBindings: [],
                    standardButtonTitles: [.init(control: .k1, title: "Legacy")]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let upgraded = try XPdConfiguration.decode(JSONEncoder().encode(legacy))
        XCTAssertEqual(upgraded.version, XPdConfiguration.currentVersion)
        XCTAssertTrue(upgraded.profiles[0].remoteModifierControls.isEmpty)
        XCTAssertTrue(upgraded.profiles[0].mappings.allSatisfy { $0.modifierControls.isEmpty })
        XCTAssertEqual(upgraded.profiles[0].standardButtonTitles.first?.title, "Legacy")
    }

    func testLegacyAndMIDIProfilesRejectRemoteLayers() throws {
        let legacyWithLayer = XPdConfiguration(
            version: XPdConfiguration.preRemoteLayersVersion,
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(
                        control: .k1,
                        gesture: .tap,
                        mapping: Mapping(command: "invalid legacy layer"),
                        modifierControls: [.k3]
                    )],
                    hidBindings: []
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try XPdConfiguration.decode(JSONEncoder().encode(legacyWithLayer))) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .remoteLayersInLegacyProfile("Global")
            )
        }

        let midiWithLayer = XPdConfiguration(
            profiles: [
                .init(name: "Global", mappings: [], hidBindings: []),
                .init(
                    name: "MIDI",
                    mappings: [.init(
                        control: .k1,
                        gesture: .tap,
                        mapping: Mapping(command: "invalid MIDI layer"),
                        modifierControls: [.k3]
                    )],
                    hidBindings: [],
                    realm: .midi,
                    midiSettings: MIDIProfileSettings()
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try midiWithLayer.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .remoteModifiersOnMIDIProfile("MIDI")
            )
        }
    }

    func testRemoteModifierValidationRejectsWheelsAndSelfLayers() {
        let invalidDesignation = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    remoteModifierControls: [.wheelCW]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try invalidDesignation.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .invalidRemoteModifierControl(profile: "Global", control: .wheelCW)
            )
        }

        let invalidLayer = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(
                        control: .k1,
                        gesture: .tap,
                        mapping: Mapping(command: "self"),
                        modifierControls: [.k1]
                    )],
                    hidBindings: []
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try invalidLayer.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .invalidMappingModifierControl(profile: "Global", primary: .k1, modifier: .k1)
            )
        }
    }

    func testVersionFourMigratesToEmptyStandardButtonTitles() throws {
        let legacy = XPdConfiguration(
            version: XPdConfiguration.preTitlesVersion,
            profiles: [
                .init(name: "Global", mappings: [], hidBindings: []),
                .init(name: "Finder", mappings: [], hidBindings: [])
            ],
            profileName: "Finder",
            showsInputOverlay: false
        )

        let upgraded = try XPdConfiguration.decode(JSONEncoder().encode(legacy))
        XCTAssertEqual(upgraded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(upgraded.profiles.map(\.name), ["Global", "Finder"])
        XCTAssertTrue(upgraded.profiles.allSatisfy { $0.standardButtonTitles.isEmpty })
        XCTAssertEqual(upgraded.profileName, "Finder")
    }

    func testLegacyVersionsRejectUnsupportedStandardButtonTitles() throws {
        for version in [XPdConfiguration.legacyVersion, XPdConfiguration.previousVersion] {
            let legacy = XPdConfiguration(
                version: version,
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

            XCTAssertThrowsError(try XPdConfiguration.decode(JSONEncoder().encode(legacy))) { error in
                XCTAssertEqual(
                    error as? XPdConfiguration.ValidationError,
                    .standardButtonTitlesInLegacyProfile("Global")
                )
            }
        }
    }

    func testStandardButtonTitleValidationRejectsDuplicateNonButtonAndLongEntries() {
        let duplicate = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    standardButtonTitles: [
                        .init(control: .k1, title: "One"),
                        .init(control: .k1, title: "Two")
                    ]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try duplicate.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .duplicateStandardButtonTitle(profile: "Global", control: .k1)
            )
        }

        let nonButton = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    standardButtonTitles: [.init(control: .wheelCW, title: "Wheel")]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try nonButton.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .invalidStandardButtonTitleControl(profile: "Global", control: .wheelCW)
            )
        }

        let tooLong = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [],
                    standardButtonTitles: [
                        .init(control: .k1, title: String(repeating: "x", count: 25))
                    ]
                )
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try tooLong.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .standardButtonTitleTooLong(profile: "Global", control: .k1)
            )
        }
    }

    func testConfigurationRejectsDuplicateHIDSignatures() {
        let configuration = XPdConfiguration(
            profiles: [
                .init(
                    name: "Global",
                    mappings: [],
                    hidBindings: [
                        .init(control: .k1, signature: "same-report"),
                        .init(control: .k2, signature: "same-report")
                    ]
                ),
                .init(name: "Finder", mappings: [], hidBindings: []),
                .init(name: "Logic Pro", mappings: [], hidBindings: [])
            ],
            profileName: "Global",
            showsInputOverlay: false
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .duplicateHIDSignature(profile: "Global", signature: "same-report")
            )
        }
    }

    func testDynamicProfilesPreserveOrderAndRejectInvalidNames() throws {
        let configuration = XPdConfiguration(
            profiles: [
                .init(name: "Global", mappings: [], hidBindings: []),
                .init(name: "Studio", mappings: [], hidBindings: []),
                .init(name: "Logic Pro", mappings: [], hidBindings: [])
            ],
            profileName: "Studio",
            showsInputOverlay: true
        )
        let decoded = try XPdConfiguration.decode(try configuration.encodedData())
        XCTAssertEqual(decoded.profiles.map(\.name), ["Global", "Studio", "Logic Pro"])
        XCTAssertEqual(decoded.profileName, "Studio")

        let duplicate = XPdConfiguration(
            profiles: [
                .init(name: "Global", mappings: [], hidBindings: []),
                .init(name: "studio", mappings: [], hidBindings: []),
                .init(name: "Studio", mappings: [], hidBindings: [])
            ],
            profileName: "Global",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try duplicate.validate()) { error in
            XCTAssertEqual(error as? XPdConfiguration.ValidationError, .duplicateProfileName("Studio"))
        }

        let padded = XPdConfiguration(
            profiles: [.init(name: " Global ", mappings: [], hidBindings: [])],
            profileName: " Global ",
            showsInputOverlay: true
        )
        XCTAssertThrowsError(try padded.validate()) { error in
            XCTAssertEqual(error as? XPdConfiguration.ValidationError, .invalidProfileName(" Global "))
        }
    }

    func testVersionThreeMigratesEveryProfileToStandardWithoutDataLoss() throws {
        let legacy = XPdConfiguration(
            version: XPdConfiguration.previousVersion,
            profiles: [
                .init(
                    name: "Global",
                    mappings: [.init(control: .k1, gesture: .tap, mapping: Mapping(action: .noAction, command: "legacy"))],
                    hidBindings: [.init(control: .k1, signature: "legacy-report")]
                ),
                .init(name: "Studio", mappings: [], hidBindings: [])
            ],
            profileName: "Studio",
            showsInputOverlay: false
        )

        let upgraded = try XPdConfiguration.decode(try JSONEncoder().encode(legacy))
        XCTAssertEqual(upgraded.version, XPdConfiguration.currentVersion)
        XCTAssertEqual(upgraded.profiles.map(\.name), ["Global", "Studio"])
        XCTAssertTrue(upgraded.profiles.allSatisfy { $0.realm == .standard && $0.midiSettings == nil })
        XCTAssertEqual(upgraded.profileName, "Studio")
        XCTAssertEqual(upgraded.lastStandardProfileName, "Studio")
        XCTAssertEqual(upgraded.activeRealm, .standard)
        XCTAssertFalse(upgraded.midiLocked)
        XCTAssertEqual(upgraded.workspaceLockControl, .k3)
        XCTAssertEqual(upgraded.profiles[0].mappings[0].mapping.command, "legacy")
        XCTAssertEqual(upgraded.profiles[0].hidBindings[0].signature, "legacy-report")
    }

    func testMIDIProfileRoundTripsTypedMappingsAndWorkspaceState() throws {
        let settings = MIDIProfileSettings(
            fnControl: .k10,
            fnHoldThreshold: 1.10,
            primaryButtons: [
                .init(
                    control: .k1,
                    mapping: MIDIButtonMapping(
                        kind: .note,
                        outputPort: .performance,
                        channel: 2,
                        note: 36,
                        velocity: 112,
                        releaseVelocity: 0,
                        label: "Kick"
                    )
                )
            ],
            functionButtons: [
                .init(
                    control: .k2,
                    mapping: MIDIButtonMapping(
                        kind: .chord,
                        outputPort: .performance,
                        channel: 2,
                        velocity: 100,
                        chord: [60, 64, 67],
                        interaction: .momentary,
                        label: "Cm"
                    )
                )
            ],
            primaryWheel: MIDIWheelMapping(
                kind: .relativeCC,
                outputPort: .control,
                channel: 1,
                controller: 21,
                relativeEncoding: .twosComplement,
                clockwiseValue: 1,
                counterClockwiseValue: 127
            ),
            functionWheel: MIDIWheelMapping(
                kind: .absoluteCC,
                outputPort: .performance,
                channel: 1,
                controller: 1
            )
        )
        let configuration = XPdConfiguration(
            profiles: [
                .init(name: "Global", mappings: [], hidBindings: []),
                .init(name: "Ableton", mappings: [], hidBindings: [], realm: .midi, midiSettings: settings)
            ],
            profileName: "Ableton",
            showsInputOverlay: true,
            activeRealm: .midi,
            lastStandardProfileName: "Global",
            lastMIDIProfileName: "Ableton",
            midiLocked: true,
            workspaceLockControl: .k3
        )

        let first = try configuration.encodedData()
        let decoded = try XPdConfiguration.decode(first)
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(first, try decoded.encodedData())
        XCTAssertEqual(decoded.profiles[1].midiSettings?.fnControl, .k10)
        XCTAssertEqual(decoded.profiles[1].midiSettings?.fnHoldThreshold, 1.10)
        XCTAssertEqual(decoded.profiles[1].midiSettings?.primaryButtons.first?.mapping.note, 36)
        XCTAssertEqual(decoded.profiles[1].midiSettings?.functionButtons.first?.mapping.chord, [60, 64, 67])
        XCTAssertEqual(decoded.profiles[1].midiSettings?.primaryWheel.controller, 21)
    }

    func testMIDIValidationRejectsInvalidChannelChordFnAndDuplicateEntries() {
        var invalidChannel = MIDIButtonMapping(kind: .note)
        invalidChannel.channel = 17
        XCTAssertThrowsError(try invalidChannel.validate()) { error in
            XCTAssertEqual(error as? MIDIValidationError, .invalidChannel(17))
        }

        var duplicateChord = MIDIButtonMapping(kind: .chord)
        duplicateChord.chord = [60, 60]
        XCTAssertThrowsError(try duplicateChord.validate())

        let duplicateEntries = MIDIProfileSettings(
            fnControl: .wheelCW,
            primaryButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note)),
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .cc))
            ]
        )
        XCTAssertThrowsError(try duplicateEntries.validate()) { error in
            XCTAssertEqual(error as? MIDIValidationError, .invalidFnControl(.wheelCW))
        }

        let duplicateControls = MIDIProfileSettings(
            primaryButtons: [
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .note)),
                .init(control: .k1, mapping: MIDIButtonMapping(kind: .cc))
            ]
        )
        XCTAssertThrowsError(try duplicateControls.validate()) { error in
            XCTAssertEqual(error as? MIDIValidationError, .duplicateButtonMapping(layer: .primary, control: .k1))
        }

        var invalidThreshold = MIDIProfileSettings()
        invalidThreshold.fnHoldThreshold = 0.09
        XCTAssertThrowsError(try invalidThreshold.validate()) { error in
            XCTAssertEqual(error as? MIDIValidationError, .invalidFnHoldThreshold(0.09))
        }

        invalidThreshold.fnHoldThreshold = .nan
        XCTAssertThrowsError(try invalidThreshold.validate())
    }
}
