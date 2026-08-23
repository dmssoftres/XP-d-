import Foundation

/// The payload of the remote's report-6 boot-keyboard collection.
///
/// The device has no separate usage for a physical K button. Its learned
/// signatures are keyboard state snapshots: one modifier byte followed by
/// six ordinary-key slots. Keeping the parsed state separate from the raw
/// signature supports both collision guidance and safe decomposition of
/// unmatched composite reports.
struct HIDKeyboardReport: Equatable {
    let modifierByte: UInt8
    let keyUsages: Set<UInt8>

    private static let keySlotCount = 6

    init(modifierByte: UInt8, keyUsages: Set<UInt8>) {
        self.modifierByte = modifierByte
        self.keyUsages = keyUsages
    }

    /// Parses a normalized report-6 signature such as
    /// `r6:03 1D 00 00 00 00 00`.
    ///
    /// A legacy eight-byte form with the report ID repeated in the payload
    /// is accepted as well; it is normalized here rather than treated as a
    /// different physical input.
    init?(signature: String) {
        let components = signature.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = components.first else { return nil }

        let prefix = String(first).lowercased()
        guard prefix.hasPrefix("r6:"), prefix.count > 3 else { return nil }

        var bytes: [UInt8] = []
        let firstByte = String(prefix.dropFirst(3))
        guard firstByte.count <= 2, let parsedFirstByte = UInt8(firstByte, radix: 16) else {
            return nil
        }
        bytes.append(parsedFirstByte)

        for component in components.dropFirst() {
            let value = String(component)
            guard value.count <= 2, let parsed = UInt8(value, radix: 16) else {
                return nil
            }
            bytes.append(parsed)
        }

        if bytes.count == Self.keySlotCount + 2, bytes.first == 0x06 {
            bytes.removeFirst()
        }
        guard bytes.count == Self.keySlotCount + 1 else { return nil }

        self.init(
            modifierByte: bytes[0],
            keyUsages: Set(bytes.dropFirst().filter { $0 != 0 })
        )
    }

    /// Returns the keyboard state produced when both controls are held.
    /// Boot-keyboard rollover cannot represent more than six distinct key
    /// usages, so an over-capacity union is intentionally not classified as
    /// an exact collision.
    func merged(with other: HIDKeyboardReport) -> HIDKeyboardReport? {
        let usages = keyUsages.union(other.keyUsages)
        guard usages.count <= Self.keySlotCount else { return nil }
        return HIDKeyboardReport(
            modifierByte: modifierByte | other.modifierByte,
            keyUsages: usages
        )
    }
}

/// An order-specific collision in the remote's boot-keyboard report.
/// `hiddenControl` is not distinguishable when `firstControl` is already
/// held and the hidden control is pressed afterwards.
struct HIDKeyboardReportCollision: Equatable, Hashable {
    let firstControl: RemoteControl
    let hiddenControl: RemoteControl
}

enum HIDKeyboardReportCollisionAnalyzer {
    /// Finds exact masking collisions for one destination and its selected
    /// Standard modifier controls.
    static func collisions(
        for destination: RemoteControl,
        modifierControls: Set<RemoteControl>,
        bindings: [RemoteControl: String]
    ) -> [HIDKeyboardReportCollision] {
        RemoteControl.allCases
            .filter { modifierControls.contains($0) && $0 != destination }
            .flatMap { modifier in
                collisions(
                    between: modifier,
                    and: destination,
                    bindings: bindings
                )
                .filter {
                    $0.firstControl == modifier && $0.hiddenControl == destination
                }
            }
    }

    /// Finds the order(s) in which two learned controls collapse to one
    /// control's exact keyboard state. Non-report-6 bindings are ignored.
    static func collisions(
        between first: RemoteControl,
        and second: RemoteControl,
        bindings: [RemoteControl: String]
    ) -> [HIDKeyboardReportCollision] {
        guard first != second,
              let firstReport = bindings[first].flatMap(HIDKeyboardReport.init(signature:)),
              let secondReport = bindings[second].flatMap(HIDKeyboardReport.init(signature:)),
              let merged = firstReport.merged(with: secondReport) else {
            return []
        }

        var collisions: [HIDKeyboardReportCollision] = []
        if merged == firstReport {
            collisions.append(
                HIDKeyboardReportCollision(firstControl: first, hiddenControl: second)
            )
        }
        if merged == secondReport {
            collisions.append(
                HIDKeyboardReportCollision(firstControl: second, hiddenControl: first)
            )
        }
        return collisions
    }
}
