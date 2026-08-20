import Foundation

/// The portable, versioned configuration format used by XP[d].
///
/// Arrays are used instead of dictionaries deliberately: they make the file
/// format explicit, allow duplicate keys to be rejected on import, and can be
/// sorted before encoding for stable diffs.
struct XPdConfiguration: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let mappings: [MappingEntry]
    let hidBindings: [HIDBindingEntry]
    let profileName: String
    let showsInputOverlay: Bool

    struct MappingEntry: Codable, Equatable {
        let control: RemoteControl
        let gesture: GestureKind
        let mapping: Mapping

        init(control: RemoteControl, gesture: GestureKind, mapping: Mapping) {
            self.control = control
            self.gesture = gesture
            self.mapping = mapping
        }
    }

    struct HIDBindingEntry: Codable, Equatable {
        let control: RemoteControl
        let signature: String

        init(control: RemoteControl, signature: String) {
            self.control = control
            self.signature = signature
        }
    }

    enum ValidationError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case duplicateMappingKey(control: RemoteControl, gesture: GestureKind)
        case duplicateHIDControl(RemoteControl)
        case duplicateHIDSignature(String)
        case emptyHIDSignature(control: RemoteControl)

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                return "Unsupported configuration version: \(version)."
            case let .duplicateMappingKey(control, gesture):
                return "Duplicate mapping for \(control.rawValue) · \(gesture.rawValue)."
            case let .duplicateHIDControl(control):
                return "Duplicate HID binding for \(control.rawValue)."
            case let .duplicateHIDSignature(signature):
                return "Duplicate HID signature: \(signature)."
            case let .emptyHIDSignature(control):
                return "HID signature for \(control.rawValue) cannot be empty."
            }
        }
    }

    init(
        version: Int = XPdConfiguration.currentVersion,
        mappings: [MappingEntry],
        hidBindings: [HIDBindingEntry],
        profileName: String,
        showsInputOverlay: Bool
    ) {
        self.version = version
        self.mappings = mappings
        self.hidBindings = hidBindings
        self.profileName = profileName
        self.showsInputOverlay = showsInputOverlay
    }

    /// Decodes and validates the entire document before returning it.
    static func decode(_ data: Data) throws -> XPdConfiguration {
        let decoder = JSONDecoder()
        let configuration = try decoder.decode(XPdConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    /// Validates semantic constraints that Codable cannot express itself.
    func validate() throws {
        guard version == Self.currentVersion else {
            throw ValidationError.unsupportedVersion(version)
        }

        var mappingKeys = Set<MappingKey>()
        for entry in mappings {
            let key = MappingKey(control: entry.control, gesture: entry.gesture)
            guard mappingKeys.insert(key).inserted else {
                throw ValidationError.duplicateMappingKey(
                    control: entry.control,
                    gesture: entry.gesture
                )
            }
        }

        var hidControls = Set<RemoteControl>()
        var hidSignatures = Set<String>()
        for entry in hidBindings {
            guard !entry.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyHIDSignature(control: entry.control)
            }
            guard hidControls.insert(entry.control).inserted else {
                throw ValidationError.duplicateHIDControl(entry.control)
            }
            guard hidSignatures.insert(entry.signature).inserted else {
                throw ValidationError.duplicateHIDSignature(entry.signature)
            }
        }
    }

    /// Encodes a stable, human-readable document suitable for export or
    /// source-control comparison.
    func encodedData() throws -> Data {
        try validate()

        var sortedConfiguration = self
        sortedConfiguration = XPdConfiguration(
            version: version,
            mappings: mappings.sorted { lhs, rhs in
                let lhsControl = Self.controlIndex(lhs.control)
                let rhsControl = Self.controlIndex(rhs.control)
                if lhsControl != rhsControl { return lhsControl < rhsControl }
                return Self.gestureIndex(lhs.gesture) < Self.gestureIndex(rhs.gesture)
            },
            hidBindings: hidBindings.sorted {
                Self.controlIndex($0.control) < Self.controlIndex($1.control)
            },
            profileName: profileName,
            showsInputOverlay: showsInputOverlay
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sortedConfiguration)
    }

    private static func controlIndex(_ control: RemoteControl) -> Int {
        RemoteControl.allCases.firstIndex(of: control) ?? Int.max
    }

    private static func gestureIndex(_ gesture: GestureKind) -> Int {
        GestureKind.allCases.firstIndex(of: gesture) ?? Int.max
    }
}

enum ConfigurationOperation: Equatable {
    case export
    case `import`
}

/// A compact observable status value for presenting import/export feedback in
/// the SwiftUI inspector without exposing file-system concerns to the store.
enum ConfigurationOperationResult: Equatable {
    case idle
    case succeeded(operation: ConfigurationOperation, detail: String)
    case failed(operation: ConfigurationOperation, message: String)

    var message: String? {
        switch self {
        case .idle:
            return nil
        case let .succeeded(_, detail), let .failed(_, detail):
            return detail
        }
    }

    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
