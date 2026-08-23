import Foundation

/// The payload of the remote's report-6 boot-keyboard collection.
///
/// The device has no separate usage for a physical K button. Its learned
/// signatures are keyboard state snapshots: one modifier byte followed by
/// six ordinary-key slots. Keeping the parsed state separate from the raw
/// signature supports both collision guidance and safe decomposition of
/// unmatched composite reports.
struct HIDKeyboardReport: Equatable {
    /// The six ordinary-key slots in a USB boot-keyboard report.
    static let bootKeyboardOrdinaryKeyCapacity = 6

    let modifierByte: UInt8
    let keyUsages: Set<UInt8>

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

        if bytes.count == Self.bootKeyboardOrdinaryKeyCapacity + 2, bytes.first == 0x06 {
            bytes.removeFirst()
        }
        guard bytes.count == Self.bootKeyboardOrdinaryKeyCapacity + 1 else { return nil }

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
        guard usages.count <= Self.bootKeyboardOrdinaryKeyCapacity else { return nil }
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

/// A pair of individually parseable report-6 keyboard states whose ordinary
/// key union exceeds the six-key boot-keyboard rollover capacity. Unlike a
/// masking collision, neither control is asserted to be hidden; the combined
/// state simply cannot be represented losslessly by this collection.
struct HIDKeyboardReportRolloverCollision: Equatable, Hashable {
    let firstControl: RemoteControl
    let secondControl: RemoteControl
    let combinedOrdinaryKeyCount: Int
}

enum HIDKeyboardReportCollisionAnalyzer {
    /// Finds every order-specific masking collision among the learned K
    /// controls. The report is a keyboard state snapshot, so a second
    /// control is hidden when merging its learned state with the first
    /// produces the first control's state unchanged.
    ///
    /// Results are deterministic: controls are compared in their physical
    /// K-button order, and each pair is returned in the order(s) that mask.
    static func collisions(
        among bindings: [RemoteControl: String]
    ) -> [HIDKeyboardReportCollision] {
        let controls = RemoteControl.allCases.filter(\.isMIDIButton)
        return controls.indices.dropLast().flatMap { firstIndex in
            controls[(firstIndex + 1)...].flatMap { second in
                collisions(
                    between: controls[firstIndex],
                    and: second,
                    bindings: bindings
                )
            }
        }
    }

    /// Finds every pair of learned K controls whose individually valid
    /// report-6 states require more ordinary-key slots than boot-keyboard
    /// rollover can carry. Results use physical K-button order.
    static func rolloverCollisions(
        among bindings: [RemoteControl: String]
    ) -> [HIDKeyboardReportRolloverCollision] {
        let controls = RemoteControl.allCases.filter(\.isMIDIButton)
        return controls.indices.dropLast().flatMap { firstIndex in
            controls[(firstIndex + 1)...].compactMap { second in
                rolloverCollision(
                    between: controls[firstIndex],
                    and: second,
                    bindings: bindings
                )
            }
        }
    }

    /// Finds a rollover-incompatible pair in one physical order. The pair is
    /// not a directional hidden-control claim: either order exceeds the same
    /// ordinary-key capacity.
    static func rolloverCollision(
        between first: RemoteControl,
        and second: RemoteControl,
        bindings: [RemoteControl: String]
    ) -> HIDKeyboardReportRolloverCollision? {
        guard first != second,
              let firstReport = bindings[first].flatMap(HIDKeyboardReport.init(signature:)),
              let secondReport = bindings[second].flatMap(HIDKeyboardReport.init(signature:)) else {
            return nil
        }

        let combinedCount = firstReport.keyUsages.union(secondReport.keyUsages).count
        guard combinedCount > HIDKeyboardReport.bootKeyboardOrdinaryKeyCapacity else { return nil }
        return HIDKeyboardReportRolloverCollision(
            firstControl: first,
            secondControl: second,
            combinedOrdinaryKeyCount: combinedCount
        )
    }

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
