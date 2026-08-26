import Foundation

/// A normalized keyboard-like state from one of the remote's K-button HID
/// collections.
///
/// The current/factory collection observed in saved captures is report 6, a
/// boot-keyboard state with one modifier byte followed by six ordinary-key
/// slots. Historical captures from an earlier programmed layout used a
/// distinct report-2 collection instead: `F0` followed by a one-hot bitmask
/// (K1…K8 in the first byte, K9…K10 in the second). The Standard F13–F22 fast
/// path also targets report 6, but that preset is only a resolver choice until
/// a live report proves that the connected remote emits those usages. Keeping
/// both parsed forms separate from their raw signatures lets compatibility
/// checks handle either collection without treating their fields as
/// interchangeable.
struct HIDKeyboardReport: Equatable {
    /// The six ordinary-key slots in a USB boot-keyboard report.
    static let bootKeyboardOrdinaryKeyCapacity = 6

    /// Report-2 uses ten one-hot bits: eight in its first mask byte and two
    /// in the next. Additional bytes are accepted only when they are zero,
    /// since the device's report can contain padded payload bytes.
    static let report2OneHotBitCapacity = 10

    enum Encoding: Equatable {
        case report6BootKeyboard
        case report2OneHot
    }

    let encoding: Encoding
    let modifierByte: UInt8
    let keyUsages: Set<UInt8>
    /// Report-2's low ten bits, or nil for report-6 states. A composite
    /// report-2 state may contain more than one bit; learned individual
    /// bindings are checked with `isCompatibleIndividualBinding` below.
    let oneHotMask: UInt16?

    init(modifierByte: UInt8, keyUsages: Set<UInt8>) {
        self.encoding = .report6BootKeyboard
        self.modifierByte = modifierByte
        self.keyUsages = keyUsages
        self.oneHotMask = nil
    }

    private init(oneHotMask: UInt16) {
        self.encoding = .report2OneHot
        self.modifierByte = 0
        self.keyUsages = []
        self.oneHotMask = oneHotMask
    }

    /// True when this state is a report-2 one-hot bitmask rather than the
    /// legacy report-6 boot-keyboard state.
    var isReport2OneHot: Bool {
        encoding == .report2OneHot
    }

    /// Report-6 states remain compatible with the existing analyzer. Report
    /// 2 states are individually compatible only when exactly one known bit
    /// is set; zero and multi-bit states are release/composite states, not
    /// independent learned K bindings.
    var isCompatibleIndividualBinding: Bool {
        switch encoding {
        case .report6BootKeyboard:
            return true
        case .report2OneHot:
            guard let oneHotMask else { return false }
            return oneHotMask != 0 && oneHotMask.nonzeroBitCount == 1
        }
    }

    /// Parses a normalized report-6 signature such as
    /// `r6:03 1D 00 00 00 00 00`.
    ///
    /// It also accepts the current one-hot report-2 form, for example
    /// `r2:F0 01 00 00 00 00 00 00` (K1) or
    /// `r2:F0 00 02 00 00 00 00 00` (K10). Zero padding is normalized away;
    /// the report-2 mask itself is retained so the runtime can distinguish a
    /// composite state from an individual learned binding.
    ///
    /// The legacy report-6 eight-byte form with the report ID repeated in the
    /// payload remains accepted and normalized.
    init?(signature: String) {
        let components = signature.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = components.first else { return nil }

        let prefix = String(first).lowercased()
        let isReport6 = prefix.hasPrefix("r6:")
        let isReport2 = prefix.hasPrefix("r2:")
        guard (isReport6 || isReport2), prefix.count > 3 else { return nil }

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

        if isReport2 {
            guard let mask = Self.report2OneHotMask(from: bytes) else { return nil }
            self.init(oneHotMask: mask)
            return
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
    /// an exact collision. Report-2 states merge by OR-ing their one-hot
    /// masks; a distinct pair therefore remains distinguishable, while a
    /// duplicate learned bit remains an exact collision.
    func merged(with other: HIDKeyboardReport) -> HIDKeyboardReport? {
        guard encoding == other.encoding else { return nil }

        if encoding == .report2OneHot {
            guard let oneHotMask, let otherMask = other.oneHotMask else { return nil }
            return HIDKeyboardReport(oneHotMask: oneHotMask | otherMask)
        }

        let usages = keyUsages.union(other.keyUsages)
        guard usages.count <= Self.bootKeyboardOrdinaryKeyCapacity else { return nil }
        return HIDKeyboardReport(
            modifierByte: modifierByte | other.modifierByte,
            keyUsages: usages
        )
    }

    /// Returns the report-2 bitmask when the signature is structurally a
    /// report-2 state. This small seam is used by the input resolver for
    /// multi-button report-2 snapshots; compatibility auditing additionally
    /// requires `isCompatibleIndividualBinding`.
    static func report2OneHotMask(from signature: String) -> UInt16? {
        let components = signature.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = components.first else { return nil }
        let prefix = String(first).lowercased()
        guard prefix.hasPrefix("r2:"), prefix.count > 3 else { return nil }

        var bytes: [UInt8] = []
        let firstByte = String(prefix.dropFirst(3))
        guard firstByte.count <= 2, let parsedFirstByte = UInt8(firstByte, radix: 16) else {
            return nil
        }
        bytes.append(parsedFirstByte)

        for component in components.dropFirst() {
            let value = String(component)
            guard value.count <= 2, let parsed = UInt8(value, radix: 16) else { return nil }
            bytes.append(parsed)
        }

        return report2OneHotMask(from: bytes)
    }

    private static func report2OneHotMask(from rawBytes: [UInt8]) -> UInt16? {
        guard rawBytes.first == 0xF0 else { return nil }
        let maskBytes = Array(rawBytes.dropFirst())
        guard maskBytes.count >= 2,
              maskBytes.dropFirst(2).allSatisfy({ $0 == 0 }) else {
            return nil
        }

        let low = UInt16(maskBytes.indices.contains(0) ? maskBytes[0] : 0)
        let high = UInt16(maskBytes.indices.contains(1) ? maskBytes[1] : 0) << 8
        let mask = low | high
        let knownBits = (UInt16(1) << report2OneHotBitCapacity) - 1
        guard mask & ~knownBits == 0 else { return nil }
        return mask
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
              let secondReport = bindings[second].flatMap(HIDKeyboardReport.init(signature:)),
              firstReport.encoding == .report6BootKeyboard,
              secondReport.encoding == .report6BootKeyboard else {
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
              firstReport.isCompatibleIndividualBinding,
              secondReport.isCompatibleIndividualBinding,
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
