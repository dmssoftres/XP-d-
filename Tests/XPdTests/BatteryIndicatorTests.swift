import Foundation
import XCTest
@testable import XPd

@MainActor
final class BatteryIndicatorTests: XCTestCase {
    func testNormalizedBatteryPercentageAcceptsExactIntegerPercentages() {
        XCTAssertEqual(HIDService.normalizedBatteryPercentage(from: NSNumber(value: 0)), 0)
        XCTAssertEqual(HIDService.normalizedBatteryPercentage(from: NSNumber(value: 42)), 42)
        XCTAssertEqual(HIDService.normalizedBatteryPercentage(from: NSNumber(value: 100)), 100)
    }

    func testNormalizedBatteryPercentageRejectsUnknownRepresentations() {
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: nil))
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: NSNumber(value: -1)))
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: NSNumber(value: 101)))
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: NSNumber(value: 42.5)))
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: NSNumber(value: Double.nan)))
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: NSNumber(value: true)))
        XCTAssertNil(HIDService.normalizedBatteryPercentage(from: "42"))
    }
}
