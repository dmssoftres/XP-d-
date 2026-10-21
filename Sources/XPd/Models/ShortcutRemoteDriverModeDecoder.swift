import Foundation

/// Decodes the Shortcut Remote's FFE0/0003 notifications while it is in
/// XPPen's Bluetooth "driver mode" (entered with `02 B0 04`).
///
/// Verified packet: `02 F0 <lo> <hi> 00 00 00 <wheel> 00 00`. `lo` holds
/// K1…K8 (bit 0 = K1) and the low two bits of `hi` hold K9 and K10, the same
/// ten-bit order as the wired report-2 `F0` collection. Bit 0x04 of `hi` is
/// the wheel center; `<wheel>` is `01` or `02` for one detent. A held key
/// repeats its packet about every 45 ms, so unchanged states are dropped.
/// Battery (`02 F2 …`) and any packet outside this shape produce no events.
struct ShortcutRemoteDriverModeDecoder {
    enum Event: Equatable {
        /// A report-2 signature in the form `HIDService` already emits for
        /// the wired collection, e.g. `r2:F0 01 00 00 00 00 00 00` (K1).
        case keys(String)
        case wheelCenterPressed
        case wheelCenterReleased
        /// `wheel:+` (clockwise) or `wheel:-` (counter-clockwise).
        case wheel(String)
    }

    static let clockwiseWheelByte: UInt8 = 0x01
    static let counterClockwiseWheelByte: UInt8 = 0x02
    private static let wheelCenterBit: UInt8 = 0x04

    private(set) var keyMask: UInt16 = 0
    private(set) var isWheelCenterHeld = false

    mutating func reset() {
        keyMask = 0
        isWheelCenterHeld = false
    }

    mutating func decode(_ data: Data) -> [Event] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              bytes[0] == 0x02,
              bytes[1] == 0xF0,
              bytes[3] & ~(0x03 | Self.wheelCenterBit) == 0,
              bytes[4] == 0, bytes[5] == 0, bytes[6] == 0,
              bytes.dropFirst(8).allSatisfy({ $0 == 0 })
        else {
            return []
        }

        let wheelByte = bytes[7]
        let wheel: String?
        switch wheelByte {
        case 0x00: wheel = nil
        case Self.clockwiseWheelByte: wheel = "wheel:+"
        case Self.counterClockwiseWheelByte: wheel = "wheel:-"
        default: return []
        }

        let center = bytes[3] & Self.wheelCenterBit != 0
        let mask = UInt16(bytes[2]) | UInt16(bytes[3] & 0x03) << 8

        var events: [Event] = []
        if center, !isWheelCenterHeld {
            isWheelCenterHeld = true
            events.append(.wheelCenterPressed)
        }
        if mask != keyMask {
            keyMask = mask
            events.append(.keys(Self.keySignature(mask: mask)))
        }
        if let wheel {
            events.append(.wheel(wheel))
        }
        if !center, isWheelCenterHeld {
            isWheelCenterHeld = false
            events.append(.wheelCenterReleased)
        }
        return events
    }

    /// The canonical report-2 signature for a K mask (all zero = release).
    static func keySignature(mask: UInt16) -> String {
        let bytes: [UInt8] = [0xF0, UInt8(mask & 0xFF), UInt8(mask >> 8), 0, 0, 0, 0, 0]
        return "r2:" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
