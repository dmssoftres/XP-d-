import Foundation

/// The portable, versioned configuration format used by XP[d].
///
/// Arrays are used instead of dictionaries deliberately: profile order is
/// meaningful to the wheel selector, while mapping/HID entries can be sorted
/// before encoding for stable diffs.
struct XPdConfiguration: Codable, Equatable {
    static let currentVersion = 3
    static let legacyVersion = 2
    static let defaultProfileNames = ["Global", "Finder", "Logic Pro"]

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
        case invalidProfileName(String)
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
            case let .invalidProfileName(name):
                return "Profile names must be trimmed, non-empty, and at most 40 characters: \(name)."
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

    /// Decodes and validates the entire document before returning it. Version
    /// 2 exports are validated using the historical exact profile set and
    /// returned as an upgraded v3 value.
    static func decode(_ data: Data) throws -> XPdConfiguration {
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionEnvelope.self, from: data).version
        switch version {
        case currentVersion:
            let configuration = try decoder.decode(XPdConfiguration.self, from: data)
            try configuration.validate()
            return configuration
        case legacyVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV2()
            return XPdConfiguration(
                version: currentVersion,
                profiles: legacy.profiles,
                profileName: legacy.profileName,
                showsInputOverlay: legacy.showsInputOverlay
            )
        default:
            throw ValidationError.unsupportedVersion(version)
        }
    }

    /// Validates semantic constraints that Codable cannot express itself.
    func validate() throws {
        guard version == Self.currentVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        guard !profiles.isEmpty else {
            throw ValidationError.missingProfileName("Global")
        }

        var profileNames = Set<String>()
        for profile in profiles {
            let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, trimmedName.count <= 40, trimmedName == profile.name else {
                throw ValidationError.invalidProfileName(profile.name)
            }
            let foldedName = Self.profileNameComparisonKey(trimmedName)
            guard profileNames.insert(foldedName).inserted else {
                throw ValidationError.duplicateProfileName(profile.name)
            }
        }

        guard profiles.contains(where: { $0.name == "Global" }) else {
            throw ValidationError.missingProfileName("Global")
        }
        guard profiles.contains(where: { $0.name == profileName }) else {
            throw ValidationError.invalidActiveProfile(profileName)
        }

        try validateEntries()
    }

    /// Validates the historical fixed-profile export before upgrading it to
    /// the current dynamic format.
    private func validateV2() throws {
        guard version == Self.legacyVersion else {
            throw ValidationError.unsupportedVersion(version)
        }

        var profileNames = Set<String>()
        for profile in profiles {
            guard profileNames.insert(profile.name).inserted else {
                throw ValidationError.duplicateProfileName(profile.name)
            }
            guard Self.defaultProfileNames.contains(profile.name) else {
                throw ValidationError.unknownProfileName(profile.name)
            }
        }
        for requiredName in Self.defaultProfileNames {
            guard profileNames.contains(requiredName) else {
                throw ValidationError.missingProfileName(requiredName)
            }
        }
        guard profileNames.contains(profileName) else {
            throw ValidationError.invalidActiveProfile(profileName)
        }

        try validateEntries()
    }

    private func validateEntries() throws {
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
        // Keep the encoder useful for migration fixtures and older callers;
        // normal store exports always construct the current v3 value.
        if version == Self.legacyVersion {
            try validateV2()
        } else {
            try validate()
        }

        let sortedConfiguration = XPdConfiguration(
            version: version,
            // Profile order is meaningful to the wheel selector. Callers
            // provide the persisted order, while entries within each profile
            // are sorted for deterministic output.
            profiles: profiles.map { profile in
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

    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    static func profileNameComparisonKey(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
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
