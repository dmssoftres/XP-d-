import AppKit
import CoreGraphics

/// A connected macOS display whose hardware identity is encoded inside the
/// existing Window / display mapping command. Resolution intentionally fails
/// closed instead of moving a window to an arbitrary replacement screen.
struct WindowScreenDestination: Hashable, Identifiable {
    struct Identity: Hashable {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let unit: UInt32

        func matches(_ other: Self) -> Bool {
            guard vendor == other.vendor, model == other.model else { return false }
            if serial != 0, other.serial != 0 {
                return serial == other.serial
            }
            return unit == other.unit
        }
    }

    static let commandPrefix = "Send frontmost window to screen:v1:"

    let displayID: CGDirectDisplayID
    let name: String
    let identity: Identity

    var id: String { command }

    var command: String {
        let values = [identity.vendor, identity.model, identity.serial, identity.unit]
        return Self.commandPrefix + values.map(String.init).joined(separator: ":")
    }

    static var connected: [Self] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = number.uint32Value
            return Self(
                displayID: displayID,
                name: screen.localizedName,
                identity: Identity(
                    vendor: CGDisplayVendorNumber(displayID),
                    model: CGDisplayModelNumber(displayID),
                    serial: CGDisplaySerialNumber(displayID),
                    unit: CGDisplayUnitNumber(displayID)
                )
            )
        }
    }

    static func identity(from command: String) -> Identity? {
        guard command.hasPrefix(commandPrefix) else { return nil }
        let values = command.dropFirst(commandPrefix.count).split(separator: ":")
        guard values.count == 4,
              let vendor = UInt32(values[0]),
              let model = UInt32(values[1]),
              let serial = UInt32(values[2]),
              let unit = UInt32(values[3]),
              vendor != 0 || model != 0 || serial != 0 || unit != 0 else {
            return nil
        }
        return Identity(vendor: vendor, model: model, serial: serial, unit: unit)
    }

    static func accessibilityVisibleBounds(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        displayBounds: CGRect
    ) -> CGRect {
        let leftInset = visibleFrame.minX - screenFrame.minX
        let topInset = screenFrame.maxY - visibleFrame.maxY
        return CGRect(
            x: displayBounds.minX + leftInset,
            y: displayBounds.minY + topInset,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    static func visibleBounds(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }) else {
            return nil
        }
        return accessibilityVisibleBounds(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            displayBounds: CGDisplayBounds(displayID)
        )
    }

    static func resolve(
        _ identity: Identity,
        among destinations: [Self] = connected
    ) -> Self? {
        if let exact = destinations.first(where: { $0.identity == identity }) {
            return exact
        }
        let compatible = destinations.filter { $0.identity.matches(identity) }
        return compatible.count == 1 ? compatible[0] : nil
    }
}
