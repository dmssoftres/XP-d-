import Foundation

/// The portable, versioned configuration format used by XP[d].
///
/// Arrays are used instead of dictionaries deliberately: they make the file
/// format explicit, allow duplicate keys to be rejected on import, and can be
/// sorted before encoding for stable diffs.
struct XPdConfiguration: Codable, Equatable {
    static let currentVersion = 2
    static let availableProfileNames = ["Global", "Finder", "Logic Pro"]

    let version: Int
    let profiles: [Profile]
    let profileName: String
    let showsInputOverlay: Bool

    /// A complete mapping and HID-binding record owned by one profile.
    struct Profile: Codable, Equatable, Identifiable {
        let name: String
        let mappings: [MappingEntry]
        let hidBindings: [HIDBindingEntry]

        var id: String { name }

        init(name: String, mappings: [MappingEntry], hidBindings: [HIDBindingEntry]) {
            self.name = name
            self.mappings = mappings
            self.hidBindings = hidBindings
        }
    }

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
        case duplicateProfileName(String)
        case unknownProfileName(String)
        case missingProfileName(String)
        case invalidActiveProfile(String)
        case duplicateMappingKey(profile: String, control: RemoteControl, gesture: GestureKind)
        case duplicateHIDControl(profile: String, control: RemoteControl)
        case duplicateHIDSignature(profile: String, signature: String)
        case emptyHIDSignature(profile: String, control: RemoteControl)

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                return "Unsupported configuration version: \(version)."
            case let .duplicateProfileName(name):
                return "Duplicate profile: \(name)."
            case let .unknownProfileName(name):
                return "Unknown profile: \(name)."
            case let .missingProfileName(name):
                return "Missing profile: \(name)."
            case let .invalidActiveProfile(name):
                return "Invalid active profile: \(name)."
            case let .duplicateMappingKey(profile, control, gesture):
                return "Duplicate mapping in \(profile) for \(control.rawValue) · \(gesture.rawValue)."
            case let .duplicateHIDControl(profile, control):
                return "Duplicate HID binding in \(profile) for \(control.rawValue)."
            case let .duplicateHIDSignature(profile, signature):
                return "Duplicate HID signature in \(profile): \(signature)."
            case let .emptyHIDSignature(profile, control):
                return "HID signature in \(profile) for \(control.rawValue) cannot be empty."
            }
        }
    }

    init(
        version: Int = XPdConfiguration.currentVersion,
        profiles: [Profile],
        profileName: String,
        showsInputOverlay: Bool
    ) {
        self.version = version
        self.profiles = profiles
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

        var profileNames = Set<String>()
        for profile in profiles {
            guard profileNames.insert(profile.name).inserted else {
                throw ValidationError.duplicateProfileName(profile.name)
            }
            guard Self.availableProfileNames.contains(profile.name) else {
                throw ValidationError.unknownProfileName(profile.name)
            }
        }

        for requiredName in Self.availableProfileNames {
            guard profileNames.contains(requiredName) else {
                throw ValidationError.missingProfileName(requiredName)
            }
        }

        guard profileNames.contains(profileName) else {
            throw ValidationError.invalidActiveProfile(profileName)
        }

        for profile in profiles {
            var mappingKeys = Set<MappingKey>()
            for entry in profile.mappings {
                let key = MappingKey(control: entry.control, gesture: entry.gesture)
                guard mappingKeys.insert(key).inserted else {
                    throw ValidationError.duplicateMappingKey(
                        profile: profile.name,
                        control: entry.control,
                        gesture: entry.gesture
                    )
                }
            }

            var hidControls = Set<RemoteControl>()
            var hidSignatures = Set<String>()
            for entry in profile.hidBindings {
                guard !entry.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.emptyHIDSignature(
                        profile: profile.name,
                        control: entry.control
                    )
                }
                guard hidControls.insert(entry.control).inserted else {
                    throw ValidationError.duplicateHIDControl(
                        profile: profile.name,
                        control: entry.control
                    )
                }
                guard hidSignatures.insert(entry.signature).inserted else {
                    throw ValidationError.duplicateHIDSignature(
                        profile: profile.name,
                        signature: entry.signature
                    )
                }
            }
        }
    }

    /// Encodes a stable, human-readable document suitable for export or
    /// source-control comparison.
    func encodedData() throws -> Data {
        try validate()

        let sortedConfiguration = XPdConfiguration(
            version: version,
            profiles: profiles.sorted { Self.profileIndex($0.name) < Self.profileIndex($1.name) }.map { profile in
                Profile(
                    name: profile.name,
                    mappings: profile.mappings.sorted { lhs, rhs in
                        let lhsControl = Self.controlIndex(lhs.control)
                        let rhsControl = Self.controlIndex(rhs.control)
                        if lhsControl != rhsControl { return lhsControl < rhsControl }
                        return Self.gestureIndex(lhs.gesture) < Self.gestureIndex(rhs.gesture)
                    },
                    hidBindings: profile.hidBindings.sorted {
                        Self.controlIndex($0.control) < Self.controlIndex($1.control)
                    }
                )
            },
            profileName: profileName,
            showsInputOverlay: showsInputOverlay
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sortedConfiguration)
    }

    private static func profileIndex(_ profileName: String) -> Int {
        availableProfileNames.firstIndex(of: profileName) ?? Int.max
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
