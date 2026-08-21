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
    private(set) var batteryPercentage: Int?
    private(set) var lastEvent = "Waiting for Shortcut Remote…"
    private(set) var recentReports: [String] = []

    var onInput: ((String?) -> Void)?

    @ObservationIgnored private let resources = HIDResources()
    @ObservationIgnored private var report6ControlIsActive = false
    @ObservationIgnored private var connectedDevice: IOHIDDevice?
    @ObservationIgnored private var lastBatteryRefresh = Date.distantPast
    private let logger = Logger(subsystem: "com.dmssoftres.xpd", category: "HID")

    private static let batteryPropertyKeys = [
        "BatteryPercent",
        "BatteryLevel",
        "BatteryStrength"
    ]
    private static let batteryRefreshInterval: TimeInterval = 15

    init(startHardware: Bool = true) {
        if startHardware {
            start()
        }
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
                service.connectedDevice = device
                service.registerInputReports(for: device)
                service.isConnected = true
                service.refreshBattery(force: true)
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
                service.handleDeviceRemoval()
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
        refreshBatteryIfNeeded()

        let payloadBytes: [UInt8]
        if let reportByte = UInt8(exactly: reportID), bytes.first == reportByte {
            payloadBytes = Array(bytes.dropFirst())
        } else {
            payloadBytes = bytes
        }

        let isEmptyReport = payloadBytes.allSatisfy({ $0 == 0 })

        // The ACK05 center switch is unusual: unlike the other controls, its
        // press arrives as an otherwise empty report 6. An empty report after
        // a regular report 6 remains the release for that regular control.
        if reportID == 6, isEmptyReport, !report6ControlIsActive {
            lastEvent = "wheel:center"
            recentReports.insert(lastEvent, at: 0)
            recentReports = Array(recentReports.prefix(8))
            logger.info("HID wheel center")
            onInput?("wheel:center")
            return
        }

        if reportID == 6, isEmptyReport {
            report6ControlIsActive = false
            onInput?(nil)
            return
        }

        if isEmptyReport {
            onInput?(nil)
            return
        }

        if reportID == 6 {
            report6ControlIsActive = true
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
        refreshBatteryIfNeeded()

        let direction = value > 0 ? "+" : "-"
        let signature = "wheel:\(direction)"
        lastEvent = "\(signature) · p\(usagePage) u\(usage) r\(reportID)"
        recentReports.insert(lastEvent, at: 0)
        recentReports = Array(recentReports.prefix(8))
        logger.info("HID wheel: \(signature, privacy: .public) value=\(value)")
        onInput?(signature)
    }

    private func handleDeviceRemoval() {
        isConnected = false
        connectedDevice = nil
        batteryPercentage = nil
        lastBatteryRefresh = .distantPast
    }

    private func refreshBatteryIfNeeded() {
        refreshBattery(force: false)
    }

    private func refreshBattery(force: Bool) {
        guard isConnected, let connectedDevice else {
            batteryPercentage = nil
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastBatteryRefresh) >= Self.batteryRefreshInterval else {
            return
        }

        lastBatteryRefresh = now
        batteryPercentage = Self.batteryPercentage(for: connectedDevice)
    }

    private static func batteryPercentage(for device: IOHIDDevice) -> Int? {
        for key in batteryPropertyKeys {
            guard let property = IOHIDDeviceGetProperty(device, key as CFString) else {
                continue
            }

            if let percentage = normalizedBatteryPercentage(from: property) {
                return percentage
            }
        }

        return nil
    }

    /// Accepts only an exact integer percentage. Values such as fractions,
    /// sentinels, booleans, strings, and out-of-range numbers remain unknown.
    static func normalizedBatteryPercentage(from value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              (0...100).contains(doubleValue)
        else {
            return nil
        }

        return Int(doubleValue)
    }
}
