import Foundation
import XCTest
@testable import XPd

final class XPdConfigurationTests: XCTestCase {
    func testConfigurationRoundTripsDeterministically() throws {
        let configuration = XPdConfiguration(
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
            ],
            profileName: "Global",
            showsInputOverlay: true
        )

        let firstEncoding = try configuration.encodedData()
        let decoded = try XPdConfiguration.decode(firstEncoding)
        let secondEncoding = try decoded.encodedData()

        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(decoded.mappings.map(\.gesture), [.tap, .hold, .doubleTap])
        XCTAssertEqual(decoded.profileName, "Global")
        XCTAssertTrue(decoded.showsInputOverlay)
    }

    func testConfigurationRejectsDuplicateHIDSignatures() {
        let configuration = XPdConfiguration(
            mappings: [],
            hidBindings: [
                .init(control: .k1, signature: "same-report"),
                .init(control: .k2, signature: "same-report")
            ],
            profileName: "Global",
            showsInputOverlay: false
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                error as? XPdConfiguration.ValidationError,
                .duplicateHIDSignature("same-report")
            )
        }
    }
}
