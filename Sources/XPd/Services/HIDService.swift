import Foundation
import IOKit.hid
import Observation

@Observable
final class HIDService {
    static let vendorID = 10429
    static let productID = 514

    private(set) var isConnected = false
    private(set) var lastEvent = "Waiting for Shortcut Remote…"

    private var manager: IOHIDManager?

    init() {
        start()
    }

    deinit {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                service.isConnected = true
                service.lastEvent = "Shortcut Remote connected"
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                service.isConnected = false
                service.lastEvent = "Shortcut Remote disconnected"
            }
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context, let value else { return }
            let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let integerValue = IOHIDValueGetIntegerValue(value)
            DispatchQueue.main.async {
                service.lastEvent = "page \(page) · usage \(usage) · value \(integerValue)"
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
