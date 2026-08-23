import XCTest
@testable import XPd

@MainActor
final class HIDRawReportTraceTests: XCTestCase {
    func testRawTraceKeepsDuplicateK10PacketsAndSemanticFilteringRemainsUnchanged() {
        let service = HIDService(startHardware: false)
        var semanticEvents: [String?] = []
        service.onInput = { semanticEvents.append($0) }

        let k10Payload = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
        service.simulateInputReportForTesting(reportID: 6, bytes: k10Payload)
        service.simulateInputReportForTesting(reportID: 6, bytes: k10Payload)
        service.simulateInputReportForTesting(reportID: 1, bytes: emptyPayload)
        service.simulateInputReportForTesting(reportID: 7, bytes: emptyPayload)
        service.simulateInputReportForTesting(reportID: 9, bytes: emptyPayload)

        XCTAssertEqual(
            service.rawReportTrace,
            [
                "r6:03 1D 00 00 00 00 00",
                "r6:03 1D 00 00 00 00 00",
                "r1:00 00 00 00 00 00 00",
                "r7:00 00 00 00 00 00 00",
                "r9:00 00 00 00 00 00 00"
            ]
        )

        // Unrelated empty collections are traceable but do not terminate the
        // active report-6 K cycle or emit semantic releases.
        XCTAssertEqual(semanticEvents, [
            "r6:03 1D 00 00 00 00 00",
            "r6:03 1D 00 00 00 00 00"
        ])

        service.simulateInputReportForTesting(reportID: 6, bytes: emptyPayload)
        XCTAssertEqual(semanticEvents, [
            "r6:03 1D 00 00 00 00 00",
            "r6:03 1D 00 00 00 00 00",
            nil
        ])
    }

    func testRawTraceNormalizesReportIDPrefixWithoutChangingPayloadIdentity() {
        let service = HIDService(startHardware: false)
        var semanticEvents: [String?] = []
        service.onInput = { semanticEvents.append($0) }

        let payload = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
        service.simulateInputReportForTesting(
            reportID: 6,
            bytes: [0x06] + payload
        )
        service.simulateInputReportForTesting(reportID: 6, bytes: payload)

        XCTAssertEqual(
            service.rawReportTrace,
            [
                "r6:03 1D 00 00 00 00 00",
                "r6:03 1D 00 00 00 00 00"
            ]
        )
        XCTAssertEqual(semanticEvents, [
            "r6:03 1D 00 00 00 00 00",
            "r6:03 1D 00 00 00 00 00"
        ])
    }

    func testRawTraceRecordsAllEmptyCompositeCollectionsBeforeSemanticFiltering() {
        let service = HIDService(startHardware: false)
        var semanticEvents: [String?] = []
        service.onInput = { semanticEvents.append($0) }

        service.simulateInputReportForTesting(reportID: 1, bytes: emptyPayload)
        service.simulateInputReportForTesting(reportID: 6, bytes: emptyPayload)
        service.simulateInputReportForTesting(reportID: 7, bytes: [0x07] + emptyPayload)
        service.simulateInputReportForTesting(reportID: 9, bytes: [0x09] + emptyPayload)

        XCTAssertEqual(
            service.rawReportTrace,
            [
                "r1:00 00 00 00 00 00 00",
                "r6:00 00 00 00 00 00 00",
                "r7:00 00 00 00 00 00 00",
                "r9:00 00 00 00 00 00 00"
            ]
        )

        // Only the verified standalone report-6 empty packet is semantic
        // input; unrelated empty collections remain silent.
        XCTAssertEqual(semanticEvents, ["wheel:center"])
    }

    func testRawTraceRetainsNewestPacketsWithinBound() {
        let service = HIDService(startHardware: false)
        let limit = HIDService.rawReportTraceLimit
        let total = limit + 3

        for index in 0..<total {
            let payload = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, UInt8(index))
            service.simulateInputReportForTesting(reportID: 6, bytes: payload)
        }

        let expected = (3..<total).map { index in
            String(format: "r6:03 1D 00 00 00 00 %02X", index)
        }
        XCTAssertEqual(service.rawReportTrace.count, limit)
        XCTAssertEqual(service.rawReportTrace, expected)
    }

    func testRawTraceClearsOnDisconnect() {
        let service = HIDService(startHardware: false)
        service.simulateInputReportForTesting(reportID: 6, bytes: k10Payload)
        service.simulateInputReportForTesting(reportID: 1, bytes: emptyPayload)

        XCTAssertFalse(service.rawReportTrace.isEmpty)
        service.simulateDisconnectForTesting()
        XCTAssertTrue(service.rawReportTrace.isEmpty)
    }

    private let emptyPayload = [UInt8](repeating: 0, count: 7)
    private let k10Payload = [UInt8](arrayLiteral: 0x03, 0x1D, 0, 0, 0, 0, 0)
}
