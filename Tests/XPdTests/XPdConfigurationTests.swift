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
}
