import AppKit
import Foundation
import IOKit.hid
import IOKit.hidsystem
import Observation
import OSLog

private final class HIDResources: @unchecked Sendable {
    var manager: IOHIDManager?

    deinit {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}

@Observable
@MainActor
final class HIDService {
    static let vendorID = 10429
    static let productID = 514
    static let exclusiveManagerOpenOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)

    enum ConnectionTransport: Equatable {
        case usb
        case bluetooth
        case other(String)
    }

    private(set) var connectionTransport: ConnectionTransport?
    private(set) var isConnected = false
    private(set) var hasInputAccess = false
    private(set) var hasExclusiveControl = false
    private(set) var batteryPercentage: Int?
    private(set) var lastEvent = "Waiting for Shortcut Remote…"
    private(set) var recentReports: [String] = []
    /// Chronological, memory-only diagnostic trace of reports delivered to
    /// the decoder. It intentionally includes duplicate and empty reports;
    /// semantic filtering is performed only after this trace is recorded.
    private(set) var rawReportTrace: [String] = []

    var onInput: ((String?) -> Void)?
    var onDisconnect: (() -> Void)?

    @ObservationIgnored private let resources = HIDResources()
    @ObservationIgnored private let bluetoothBatteryMonitor = ShortcutRemoteBatteryMonitor()
    @ObservationIgnored private var report6ControlIsActive = false
    @ObservationIgnored private var wheelCenterIsHeld = false
    @ObservationIgnored private var connectedDevice: IOHIDDevice?
    @ObservationIgnored private var hidBatteryPercentage: Int?
    @ObservationIgnored private var bluetoothBatteryPercentage: Int?
    @ObservationIgnored private var lastBatteryRefresh = Date.distantPast
    private let logger = Logger(subsystem: "com.dmssoftres.xpd", category: "HID")
    private let modifierArbitrationLogger = Logger(
        subsystem: "com.dmssoftres.xpd",
        category: "ModifierArbitration"
    )

    private static let batteryPropertyKeys = [
        "BatteryPercent",
        "BatteryLevel",
        "BatteryStrength"
    ]
    private static let batteryRefreshInterval: TimeInterval = 15
    static let rawReportTraceLimit = 12

    init(startHardware: Bool = true) {
        bluetoothBatteryMonitor.onBatteryPercentage = { [weak self] percentage in
            guard let self, self.isConnected else { return }
            self.bluetoothBatteryPercentage = percentage
            self.updateBatteryPercentage()
        }
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
                service.report6ControlIsActive = false
                service.wheelCenterIsHeld = false
                service.rawReportTrace.removeAll()
                service.connectedDevice = device
                service.connectionTransport = HIDService.transport(
                    fromTransportProperty: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString)
                )
                service.isConnected = true
                service.refreshBattery(force: true)
                service.bluetoothBatteryMonitor.startMonitoring()
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

        IOHIDManagerRegisterInputReportCallback(manager, { context, result, _, _, reportID, report, reportLength in
            guard let context, result == kIOReturnSuccess else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            MainActor.assumeIsolated {
                let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
                service.receivedHardwareReport(reportID: reportID, bytes: bytes)
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
                guard service.hasExclusiveControl else { return }
                service.receivedWheel(
                    value: integerValue,
                    usagePage: usagePage,
                    usage: usage,
                    reportID: IOHIDElementGetReportID(element)
                )
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, Self.exclusiveManagerOpenOptions)
        if result != kIOReturnSuccess {
            hasExclusiveControl = false
            hasInputAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            lastEvent = hasInputAccess
                ? "Exclusive control unavailable (\(result))"
                : "Input Monitoring permission required"
            logger.error("Unable to seize HID manager: \(result)")
        } else {
            hasInputAccess = true
            hasExclusiveControl = true
            logger.info("HID manager opened with exclusive control")
        }
    }

    private func received(reportID: UInt32, bytes: [UInt8]) {
        refreshBatteryIfNeeded()

        let payloadBytes: [UInt8]
        if let reportByte = UInt8(exactly: reportID), bytes.first == reportByte {
            payloadBytes = Array(bytes.dropFirst())
        } else {
            payloadBytes = bytes
        }

        recordRawReport(reportID: reportID, payloadBytes: payloadBytes)

        let isEmptyReport = payloadBytes.allSatisfy({ $0 == 0 })

        if reportID == 2 {
            // Report 2 is a vendor bitmask collection, not a generic
            // keyboard stream. Drop malformed/unknown states at the HID
            // boundary so neither learning nor runtime routing can turn an
            // unverified packet into a K control. The parser also enforces
            // the F0 marker, ten-bit mask, and zero-padding contract.
            let payload = payloadBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            guard payloadBytes.count >= 3,
                  HIDKeyboardReport(signature: "r2:\(payload)") != nil else {
                return
            }
        }

        if reportID == 2,
           payloadBytes.count > 1,
           payloadBytes.first == 0xF0,
           payloadBytes.dropFirst().allSatisfy({ $0 == 0 }) {
            // The remapped K-button collection uses report 2 with an F0
            // marker followed by a padded bitmask. Its all-zero mask is the
            // physical release boundary, even though the marker itself
            // means this is not an empty HID packet.
            let payload = payloadBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let signature = "r2:\(payload)"
            lastEvent = signature
            recentReports.insert(signature, at: 0)
            recentReports = Array(recentReports.prefix(8))
            logger.info("HID input: \(signature, privacy: .public)")
            onInput?(signature)
            return
        }

        if isEmptyReport {
            // The supported remote is a composite HID device. Its mouse and
            // digitizer collections (report IDs 1, 7, and 9) can emit empty
            // packets while a report-6 keyboard key is still held. Those
            // packets are not keyboard releases and must not terminate the
            // K-button cycle in MappingStore. Report 6 empty packets release
            // the legacy boot-keyboard collection; the report-2 F0/all-zero
            // boundary is handled above.
            guard reportID == 6 else { return }

            if report6ControlIsActive {
                // A report-6 empty packet immediately after a wheel detent is
                // that detent's release. While center is held, it must not
                // confirm the profile selector; the next standalone empty
                // report is the center release.
                modifierArbitrationLogger.info("report-6 empty release")
                report6ControlIsActive = false
                if wheelCenterIsHeld {
                    return
                }
                onInput?(nil)
                return
            }

            if wheelCenterIsHeld {
                wheelCenterIsHeld = false
                lastEvent = "wheel:center released"
                recentReports.insert(lastEvent, at: 0)
                recentReports = Array(recentReports.prefix(8))
                logger.info("HID wheel center released")
                onInput?(nil)
                return
            }

            // The ACK05 center switch is unusual: its press arrives as an
            // otherwise empty report 6. Keep the center held until the next
            // standalone empty report, which is the physical release.
            wheelCenterIsHeld = true
            lastEvent = "wheel:center"
            recentReports.insert(lastEvent, at: 0)
            recentReports = Array(recentReports.prefix(8))
            logger.info("HID wheel center")
            onInput?("wheel:center")
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

    private func receivedHardwareReport(reportID: UInt32, bytes: [UInt8]) {
        guard hasExclusiveControl else { return }
        received(reportID: reportID, bytes: bytes)
    }

    private func recordRawReport(reportID: UInt32, payloadBytes: [UInt8]) {
        let payload = payloadBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        rawReportTrace.append("r\(reportID):\(payload)")
        if rawReportTrace.count > Self.rawReportTraceLimit {
            rawReportTrace.removeFirst(rawReportTrace.count - Self.rawReportTraceLimit)
        }
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
        connectionTransport = nil
        report6ControlIsActive = false
        wheelCenterIsHeld = false
        rawReportTrace.removeAll()
        hidBatteryPercentage = nil
        bluetoothBatteryPercentage = nil
        batteryPercentage = nil
        lastBatteryRefresh = .distantPast
        bluetoothBatteryMonitor.stopMonitoring()
        onDisconnect?()
    }

    func simulateDisconnectForTesting() {
        handleDeviceRemoval()
    }

    /// Internal test seam for exercising transport capture and removal clearing
    /// without a real HID device.
    func simulateDeviceMatchForTesting(transportProperty: Any?) {
        connectionTransport = Self.transport(fromTransportProperty: transportProperty)
    }

    /// Internal test seam for exercising report-6 center and wheel-release
    /// decoding without opening a real HID manager.
    func simulateInputReportForTesting(reportID: UInt32, bytes: [UInt8]) {
        received(reportID: reportID, bytes: bytes)
    }

    /// Internal test seam for proving that the production report boundary
    /// remains fail-closed when the manager did not obtain exclusive control.
    func simulateHardwareInputReportForTesting(reportID: UInt32, bytes: [UInt8]) {
        receivedHardwareReport(reportID: reportID, bytes: bytes)
    }

    private func refreshBatteryIfNeeded() {
        refreshBattery(force: false)
    }

    private func refreshBattery(force: Bool) {
        guard isConnected, let connectedDevice else {
            hidBatteryPercentage = nil
            batteryPercentage = nil
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastBatteryRefresh) >= Self.batteryRefreshInterval else {
            return
        }

        lastBatteryRefresh = now
        hidBatteryPercentage = Self.batteryPercentage(for: connectedDevice)
        updateBatteryPercentage()
    }

    private func updateBatteryPercentage() {
        batteryPercentage = bluetoothBatteryPercentage ?? hidBatteryPercentage
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

    /// Maps the IOKit `kIOHIDTransportKey` property of the matched device to a
    /// transport. Non-string or empty values stay unknown; any unrecognized
    /// string is preserved so an unexpected transport is visible, never
    /// mislabeled.
    static func transport(fromTransportProperty value: Any?) -> ConnectionTransport? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        switch raw {
        case "USB": return .usb
        case "Bluetooth Low Energy", "Bluetooth": return .bluetooth
        default: return .other(raw)
        }
    }
}
