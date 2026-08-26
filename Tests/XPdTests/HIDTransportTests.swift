import XCTest
@testable import XPd

@MainActor
final class HIDTransportTests: XCTestCase {
    func testTransportMapperTable() {
        XCTAssertEqual(HIDService.transport(fromTransportProperty: "USB"), .usb)
        XCTAssertEqual(HIDService.transport(fromTransportProperty: "Bluetooth Low Energy"), .bluetooth)
        XCTAssertEqual(HIDService.transport(fromTransportProperty: "Bluetooth"), .bluetooth)
        XCTAssertNil(HIDService.transport(fromTransportProperty: nil))
        XCTAssertNil(HIDService.transport(fromTransportProperty: ""))
        XCTAssertNil(HIDService.transport(fromTransportProperty: NSNumber(value: 42)))
        XCTAssertNil(HIDService.transport(fromTransportProperty: NSNumber(value: true)))
        XCTAssertEqual(HIDService.transport(fromTransportProperty: "Internal"), .other("Internal"))
    }

    func testConnectionTransportLifecycleTracksMatchesAndRemoval() {
        let service = HIDService(startHardware: false)
        XCTAssertNil(service.connectionTransport)

        service.simulateDeviceMatchForTesting(transportProperty: "USB")
        XCTAssertEqual(service.connectionTransport, .usb)

        service.simulateDeviceMatchForTesting(transportProperty: "Bluetooth Low Energy")
        XCTAssertEqual(service.connectionTransport, .bluetooth)

        service.simulateDisconnectForTesting()
        XCTAssertNil(service.connectionTransport)
    }
}
