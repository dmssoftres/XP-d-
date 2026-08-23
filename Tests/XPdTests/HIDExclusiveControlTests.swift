import IOKit.hid
import XCTest
@testable import XPd

@MainActor
final class HIDExclusiveControlTests: XCTestCase {
    func testManagerOpenRequestsExclusiveDeviceSeizure() {
        XCTAssertEqual(
            HIDService.exclusiveManagerOpenOptions,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
    }

    func testHardwareDisabledServiceDoesNotClaimExclusiveControl() {
        let service = HIDService(startHardware: false)

        XCTAssertFalse(service.hasInputAccess)
        XCTAssertFalse(service.hasExclusiveControl)
        XCTAssertFalse(service.isConnected)
    }

    func testHardwareReportIsDiscardedWithoutExclusiveControl() {
        let service = HIDService(startHardware: false)
        var receivedSignatures: [String?] = []
        service.onInput = { receivedSignatures.append($0) }

        service.simulateHardwareInputReportForTesting(reportID: 1, bytes: [0x01, 0x2A])

        XCTAssertTrue(receivedSignatures.isEmpty)
        XCTAssertTrue(service.recentReports.isEmpty)
    }
}
