import AppKit
import Foundation
import IOKit.hid
import IOKit.hidsystem
import Observation
import OSLog

private final class HIDResources: @unchecked Sendable {
    var manager: IOHIDManager?
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    deinit {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        reportBuffer.deallocate()
    }
}

@Observable
@MainActor
final class HIDService {
    static let vendorID = 10429
    static let productID = 514

    private(set) var isConnected = false
    private(set) var hasInputAccess = false
    private(set) var lastEvent = "Waiting for Shortcut Remote…"
    private(set) var recentReports: [String] = []

    var onInput: ((String?) -> Void)?

    @ObservationIgnored private let resources = HIDResources()
    private let logger = Logger(subsystem: "com.dmssoftres.xpd", category: "HID")

    init() {
        start()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }

        NSWorkspace.shared.open(url)
    }

    private func start() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        resources.manager = manager

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
                service.registerInputReports(for: device)
                service.isConnected = true
                service.lastEvent = service.hasInputAccess
                    ? "Shortcut Remote connected"
                    : "Connected · Input Monitoring required"
                service.logger.info("Shortcut Remote connected")
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated {
                let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
                service.isConnected = false
                service.lastEvent = "Shortcut Remote disconnected"
                service.logger.info("Shortcut Remote disconnected")
            }
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let integerValue = IOHIDValueGetIntegerValue(value)
            let isWheel = usagePage == 0x01 && usage == 0x38
            let isHorizontalWheel = usagePage == 0x0C && usage == 0x0238
            guard integerValue != 0, isWheel || isHorizontalWheel else { return }

            MainActor.assumeIsolated {
                let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
                service.receivedWheel(
                    value: integerValue,
                    usagePage: usagePage,
                    usage: usage,
                    reportID: IOHIDElementGetReportID(element)
                )
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            hasInputAccess = false
            lastEvent = "Unable to open HID manager (\(result))"
            logger.error("Unable to open HID manager: \(result)")
        } else {
            hasInputAccess = true
            logger.info("HID manager opened")
        }
    }

    private func registerInputReports(for device: IOHIDDevice) {
        IOHIDDeviceRegisterInputReportCallback(
            device,
            resources.reportBuffer,
            64,
            { context, result, _, _, reportID, report, reportLength in
                guard let context, result == kIOReturnSuccess else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                MainActor.assumeIsolated {
                    let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
                    service.received(reportID: reportID, bytes: bytes)
                }
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
    }

    private func received(reportID: UInt32, bytes: [UInt8]) {
        let payloadBytes: [UInt8]
        if let reportByte = UInt8(exactly: reportID), bytes.first == reportByte {
            payloadBytes = Array(bytes.dropFirst())
        } else {
            payloadBytes = bytes
        }

        if payloadBytes.allSatisfy({ $0 == 0 }) {
            onInput?(nil)
            return
        }

        if reportID == 6, payloadBytes.count >= 2, payloadBytes[0] == 0x01 {
            let wheelSignature: String?
            switch payloadBytes[1] {
            case 0x57: wheelSignature = "wheel:+"
            case 0x56: wheelSignature = "wheel:-"
            default: wheelSignature = nil
            }

            if let wheelSignature {
                lastEvent = "\(wheelSignature) · r6 \(String(format: "%02X", payloadBytes[0])) \(String(format: "%02X", payloadBytes[1]))"
                recentReports.insert(lastEvent, at: 0)
                recentReports = Array(recentReports.prefix(8))
                logger.info("HID wheel: \(wheelSignature, privacy: .public)")
                onInput?(wheelSignature)
                return
            }
        }

        let payload = payloadBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let signature = "r\(reportID):\(payload)"

        lastEvent = signature
        recentReports.insert(signature, at: 0)
        recentReports = Array(recentReports.prefix(8))
        logger.info("HID input: \(signature, privacy: .public)")
        onInput?(signature)
    }

    private func receivedWheel(value: Int, usagePage: UInt32, usage: UInt32, reportID: UInt32) {
        let direction = value > 0 ? "+" : "-"
        let signature = "wheel:\(direction)"
        lastEvent = "\(signature) · p\(usagePage) u\(usage) r\(reportID)"
        recentReports.insert(lastEvent, at: 0)
        recentReports = Array(recentReports.prefix(8))
        logger.info("HID wheel: \(signature, privacy: .public) value=\(value)")
        onInput?(signature)
    }
}
