import XCTest
@testable import XPd

final class WheelScrollSettingsTests: XCTestCase {
    func testSensitivityClampsToSupportedRange() {
        XCTAssertEqual(WheelScrollSettings(sensitivity: -4).sensitivity, 1)
        XCTAssertEqual(WheelScrollSettings(sensitivity: 40).sensitivity, 10)
        XCTAssertEqual(WheelScrollSettings(sensitivity: .nan).sensitivity, 5)
    }

    func testDirectionAndSensitivityProduceStableLineDeltas() {
        let settings = WheelScrollSettings(sensitivity: 6.4)
        XCTAssertEqual(settings.delta(for: .up), 6)
        XCTAssertEqual(settings.delta(for: .down), -6)
    }
}
