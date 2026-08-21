import Foundation

/// The portable, versioned configuration format used by XP[d].
///
/// Arrays are used instead of dictionaries deliberately: profile order is
/// meaningful to the wheel selector, while mapping/HID entries can be sorted
/// before encoding for stable diffs.
struct XPdConfiguration: Codable, Equatable {
    static let currentVersion = 5
    static let legacyVersion = 2
    static let previousVersion = 3
    /// Version 4 is the immediately previous schema.  It had no
    /// Standard-mode button-title entries, so decoding it upgrades every
    /// profile with an empty title collection.
    static let preTitlesVersion = 4
    static let defaultProfileNames = ["Global", "Finder", "Logic Pro"]
    static let defaultWorkspaceLockControl: RemoteControl = .k3

    let version: Int
    let profiles: [Profile]
    let profileName: String
    let showsInputOverlay: Bool
    let activeRealm: ProfileRealm
    let lastStandardProfileName: String?
    let lastMIDIProfileName: String?
    let midiLocked: Bool
    let workspaceLockControl: RemoteControl

    /// A complete mapping and HID-binding record owned by one profile.
    struct Profile: Codable, Equatable, Identifiable {
        let name: String
        let mappings: [MappingEntry]
        let hidBindings: [HIDBindingEntry]
        let realm: ProfileRealm
        let midiSettings: MIDIProfileSettings?
        let standardButtonTitles: [StandardButtonTitleEntry]

        var id: String { name }

        var profileRealm: ProfileRealm {
            realm
        }

        init(
            name: String,
            mappings: [MappingEntry],
            hidBindings: [HIDBindingEntry],
            realm: ProfileRealm = .standard,
            midiSettings: MIDIProfileSettings? = nil,
            standardButtonTitles: [StandardButtonTitleEntry] = []
        ) {
            self.name = name
            self.mappings = mappings
            self.hidBindings = hidBindings
            self.realm = realm
            self.midiSettings = midiSettings
            self.standardButtonTitles = standardButtonTitles
        }

        init(
            name: String,
            mappings: [MappingEntry],
            hidBindings: [HIDBindingEntry],
            profileRealm: ProfileRealm,
            midiSettings: MIDIProfileSettings? = nil,
            standardButtonTitles: [StandardButtonTitleEntry] = []
        ) {
            self.init(
                name: name,
                mappings: mappings,
                hidBindings: hidBindings,
                realm: profileRealm,
                midiSettings: midiSettings,
                standardButtonTitles: standardButtonTitles
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            mappings = try container.decodeIfPresent([MappingEntry].self, forKey: .mappings) ?? []
            hidBindings = try container.decodeIfPresent([HIDBindingEntry].self, forKey: .hidBindings) ?? []
            realm = try container.decodeIfPresent(ProfileRealm.self, forKey: .realm) ?? .standard
            midiSettings = try container.decodeIfPresent(MIDIProfileSettings.self, forKey: .midiSettings)
            standardButtonTitles = try container.decodeIfPresent([StandardButtonTitleEntry].self, forKey: .standardButtonTitles) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(mappings, forKey: .mappings)
            try container.encode(hidBindings, forKey: .hidBindings)
            try container.encode(realm, forKey: .realm)
            try container.encodeIfPresent(midiSettings, forKey: .midiSettings)
            try container.encode(standardButtonTitles, forKey: .standardButtonTitles)
        }

        private enum CodingKeys: String, CodingKey {
            case name, mappings, hidBindings, realm, midiSettings, standardButtonTitles
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

    /// An optional label shown above a Standard-mode K-button in the hardware
    /// preview.  Titles are profile-scoped and intentionally independent of
    /// the Tap/Hold/Double mapping entries.
    struct StandardButtonTitleEntry: Codable, Equatable {
        let control: RemoteControl
        let title: String

        init(control: RemoteControl, title: String) {
            self.control = control
            self.title = title
        }
    }

    enum ValidationError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case duplicateProfileName(String)
        case unknownProfileName(String)
        case missingProfileName(String)
        case invalidProfileName(String)
        case invalidActiveProfile(String)
        case invalidRememberedProfile(String, ProfileRealm)
        case invalidWorkspaceLockControl(RemoteControl)
        case invalidMIDIWorkspaceState
        case midiSettingsInLegacyProfile(String)
        case midiSettingsOnStandardProfile(String)
        case duplicateMappingKey(profile: String, control: RemoteControl, gesture: GestureKind)
        case duplicateHIDControl(profile: String, control: RemoteControl)
        case duplicateHIDSignature(profile: String, signature: String)
        case emptyHIDSignature(profile: String, control: RemoteControl)
        case standardButtonTitlesInLegacyProfile(String)
        case standardButtonTitlesOnMIDIProfile(String)
        case invalidStandardButtonTitleControl(profile: String, control: RemoteControl)
        case duplicateStandardButtonTitle(profile: String, control: RemoteControl)
        case standardButtonTitleTooLong(profile: String, control: RemoteControl)

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
            case let .invalidRememberedProfile(name, realm):
                return "Remembered \(realm.rawValue) profile is not present: \(name)."
            case let .invalidWorkspaceLockControl(control):
                return "Workspace lock control must be a K button: \(control.rawValue)."
            case .invalidMIDIWorkspaceState:
                return "MIDI Lock can only be active in the MIDI profile realm."
            case let .midiSettingsInLegacyProfile(name):
                return "Legacy profile unexpectedly contains MIDI settings: \(name)."
            case let .midiSettingsOnStandardProfile(name):
                return "Standard profile unexpectedly contains MIDI settings: \(name)."
            case let .duplicateMappingKey(profile, control, gesture):
                return "Duplicate mapping in \(profile) for \(control.rawValue) · \(gesture.rawValue)."
            case let .duplicateHIDControl(profile, control):
                return "Duplicate HID binding in \(profile) for \(control.rawValue)."
            case let .duplicateHIDSignature(profile, signature):
                return "Duplicate HID signature in \(profile): \(signature)."
            case let .emptyHIDSignature(profile, control):
                return "HID signature in \(profile) for \(control.rawValue) cannot be empty."
            case let .standardButtonTitlesInLegacyProfile(profile):
                return "Standard button titles are unsupported in the legacy profile schema: \(profile)."
            case let .standardButtonTitlesOnMIDIProfile(profile):
                return "MIDI profile \(profile) cannot contain Standard button titles."
            case let .invalidStandardButtonTitleControl(profile, control):
                return "Standard button title in \(profile) must target a K button: \(control.rawValue)."
            case let .duplicateStandardButtonTitle(profile, control):
                return "Duplicate Standard button title in \(profile) for \(control.rawValue)."
            case let .standardButtonTitleTooLong(profile, control):
                return "Standard button title in \(profile) for \(control.rawValue) must be at most 24 characters."
            }
        }
    }

    init(
        version: Int = XPdConfiguration.currentVersion,
        profiles: [Profile],
        profileName: String,
        showsInputOverlay: Bool,
        activeRealm: ProfileRealm = .standard,
        lastStandardProfileName: String? = nil,
        lastMIDIProfileName: String? = nil,
        midiLocked: Bool = false,
        workspaceLockControl: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl
    ) {
        self.version = version
        self.profiles = profiles
        self.profileName = profileName
        self.showsInputOverlay = showsInputOverlay
        self.activeRealm = activeRealm
        self.lastStandardProfileName = lastStandardProfileName
        self.lastMIDIProfileName = lastMIDIProfileName
        self.midiLocked = midiLocked
        self.workspaceLockControl = workspaceLockControl
    }

    init(
        version: Int = XPdConfiguration.currentVersion,
        profiles: [Profile],
        profileName: String,
        showsInputOverlay: Bool,
        activeProfileRealm: ProfileRealm,
        lastStandardProfileName: String? = nil,
        lastMIDIProfileName: String? = nil,
        midiLocked: Bool = false,
        workspaceLockKey: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl
    ) {
        self.init(
            version: version,
            profiles: profiles,
            profileName: profileName,
            showsInputOverlay: showsInputOverlay,
            activeRealm: activeProfileRealm,
            lastStandardProfileName: lastStandardProfileName,
            lastMIDIProfileName: lastMIDIProfileName,
            midiLocked: midiLocked,
            workspaceLockControl: workspaceLockKey
        )
    }

    /// Alternate names used by workspace/routing code; the persisted keys
    /// remain concise and stable.
    var activeProfileRealm: ProfileRealm { activeRealm }
    var workspaceLockKey: RemoteControl { workspaceLockControl }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        let decodedProfiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        let decodedProfileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "Global"
        let decodedShowsInputOverlay = try container.decodeIfPresent(Bool.self, forKey: .showsInputOverlay) ?? true
        let decodedRealm = try container.decodeIfPresent(ProfileRealm.self, forKey: .activeRealm)
        let decodedLastStandard = try container.decodeIfPresent(String.self, forKey: .lastStandardProfileName)
        let decodedLastMIDI = try container.decodeIfPresent(String.self, forKey: .lastMIDIProfileName)
        let decodedMIDIlocked = try container.decodeIfPresent(Bool.self, forKey: .midiLocked) ?? false
        let decodedLockControl = try container.decodeIfPresent(RemoteControl.self, forKey: .workspaceLockControl)
            ?? container.decodeIfPresent(RemoteControl.self, forKey: .workspaceLockKey)
            ?? .k3
        version = decodedVersion
        profiles = decodedProfiles
        profileName = decodedProfileName
        showsInputOverlay = decodedShowsInputOverlay
        activeRealm = decodedRealm ?? (decodedProfiles.first(where: { $0.name == decodedProfileName })?.realm ?? .standard)
        lastStandardProfileName = decodedLastStandard
        lastMIDIProfileName = decodedLastMIDI
        midiLocked = decodedMIDIlocked
        workspaceLockControl = decodedLockControl
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(profileName, forKey: .profileName)
        try container.encode(showsInputOverlay, forKey: .showsInputOverlay)
        try container.encode(activeRealm, forKey: .activeRealm)
        try container.encodeIfPresent(lastStandardProfileName, forKey: .lastStandardProfileName)
        try container.encodeIfPresent(lastMIDIProfileName, forKey: .lastMIDIProfileName)
        try container.encode(midiLocked, forKey: .midiLocked)
        try container.encode(workspaceLockControl, forKey: .workspaceLockControl)
    }

    /// Decodes and validates the entire document before returning it. Versions
    /// 2 and 3 are decoded through their published shape and upgraded to v5;
    /// every migrated profile is explicitly marked as standard. Version 4 is
    /// the current-realm schema and gains empty title collections during the
    /// upgrade.
    static func decode(_ data: Data) throws -> XPdConfiguration {
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionEnvelope.self, from: data).version
        switch version {
        case currentVersion:
            let configuration = try decoder.decode(XPdConfiguration.self, from: data)
            try configuration.validate()
            return configuration
        case preTitlesVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV4()
            return XPdConfiguration(
                version: currentVersion,
                profiles: legacy.profiles.map {
                    Profile(
                        name: $0.name,
                        mappings: $0.mappings,
                        hidBindings: $0.hidBindings,
                        realm: $0.realm,
                        midiSettings: $0.midiSettings,
                        standardButtonTitles: []
                    )
                },
                profileName: legacy.profileName,
                showsInputOverlay: legacy.showsInputOverlay,
                activeRealm: legacy.activeRealm,
                lastStandardProfileName: legacy.lastStandardProfileName,
                lastMIDIProfileName: legacy.lastMIDIProfileName,
                midiLocked: legacy.midiLocked,
                workspaceLockControl: legacy.workspaceLockControl
            )
        case legacyVersion, previousVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            if version == legacyVersion {
                try legacy.validateV2()
            } else {
                try legacy.validateV3()
            }
            return XPdConfiguration(
                version: currentVersion,
                profiles: legacy.profiles.map {
                    Profile(
                        name: $0.name,
                        mappings: $0.mappings,
                        hidBindings: $0.hidBindings,
                        realm: .standard,
                        midiSettings: nil,
                        standardButtonTitles: []
                    )
                },
                profileName: legacy.profileName,
                showsInputOverlay: legacy.showsInputOverlay,
                activeRealm: .standard,
                lastStandardProfileName: legacy.profileName,
                lastMIDIProfileName: nil,
                midiLocked: false,
                workspaceLockControl: .k3
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

        guard profiles.first(where: { $0.name == profileName })?.realm == activeRealm else {
            throw ValidationError.invalidActiveProfile(profileName)
        }
        guard workspaceLockControl.isMIDIButton else {
            throw ValidationError.invalidWorkspaceLockControl(workspaceLockControl)
        }
        guard !midiLocked || activeRealm == .midi else {
            throw ValidationError.invalidMIDIWorkspaceState
        }
        try validateRememberedProfile(lastStandardProfileName, realm: .standard)
        try validateRememberedProfile(lastMIDIProfileName, realm: .midi)

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

    /// Version 3 added dynamic profile names but no MIDI realm or workspace
    /// state.  Keep its validation separate so malformed v3 input cannot be
    /// “rescued” by v4 defaults during migration.
    private func validateV3() throws {
        guard version == Self.previousVersion else {
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
            guard profileNames.insert(Self.profileNameComparisonKey(trimmedName)).inserted else {
                throw ValidationError.duplicateProfileName(profile.name)
            }
        }
        guard profiles.contains(where: { $0.name == "Global" }) else {
            throw ValidationError.missingProfileName("Global")
        }
        guard profiles.contains(where: { $0.name == profileName }) else {
            throw ValidationError.invalidActiveProfile(profileName)
        }
        try validateEntries(allowMIDISettings: false)
    }

    /// Version 4 predates Standard button titles.  Keep its realm/MIDI
    /// validation intact while rejecting title fields that do not belong to
    /// that schema.
    private func validateV4() throws {
        guard version == Self.preTitlesVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        try validateCurrentProfileShape()
        try validateEntries(allowStandardButtonTitles: false)
    }

    private func validateCurrentProfileShape() throws {
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
        guard profiles.first(where: { $0.name == profileName })?.realm == activeRealm else {
            throw ValidationError.invalidActiveProfile(profileName)
        }
        guard workspaceLockControl.isMIDIButton else {
            throw ValidationError.invalidWorkspaceLockControl(workspaceLockControl)
        }
        guard !midiLocked || activeRealm == .midi else {
            throw ValidationError.invalidMIDIWorkspaceState
        }
        try validateRememberedProfile(lastStandardProfileName, realm: .standard)
        try validateRememberedProfile(lastMIDIProfileName, realm: .midi)
    }

    private func validateRememberedProfile(_ name: String?, realm: ProfileRealm) throws {
        guard let name else { return }
        guard profiles.contains(where: { $0.name == name && $0.realm == realm }) else {
            throw ValidationError.invalidRememberedProfile(name, realm)
        }
    }

    private func validateEntries(allowMIDISettings: Bool = true) throws {
        try validateEntries(allowMIDISettings: allowMIDISettings, allowStandardButtonTitles: true)
    }

    private func validateEntries(
        allowMIDISettings: Bool = true,
        allowStandardButtonTitles: Bool
    ) throws {
        for profile in profiles {
            if profile.realm == .standard, profile.midiSettings != nil {
                throw ValidationError.midiSettingsOnStandardProfile(profile.name)
            }
            if profile.realm == .midi, !allowMIDISettings, profile.midiSettings != nil {
                throw ValidationError.midiSettingsInLegacyProfile(profile.name)
            }
            if allowMIDISettings, let midiSettings = profile.midiSettings {
                try midiSettings.validate()
            }
            if !allowStandardButtonTitles, !profile.standardButtonTitles.isEmpty {
                throw ValidationError.standardButtonTitlesInLegacyProfile(profile.name)
            }
            if profile.realm == .midi, !profile.standardButtonTitles.isEmpty {
                throw ValidationError.standardButtonTitlesOnMIDIProfile(profile.name)
            }
            var titleControls = Set<RemoteControl>()
            for entry in profile.standardButtonTitles {
                guard entry.control.isMIDIButton else {
                    throw ValidationError.invalidStandardButtonTitleControl(
                        profile: profile.name,
                        control: entry.control
                    )
                }
                guard titleControls.insert(entry.control).inserted else {
                    throw ValidationError.duplicateStandardButtonTitle(
                        profile: profile.name,
                        control: entry.control
                    )
                }
                guard entry.title.trimmingCharacters(in: .whitespacesAndNewlines).count <= 24 else {
                    throw ValidationError.standardButtonTitleTooLong(
                        profile: profile.name,
                        control: entry.control
                    )
                }
            }
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
        // Keep the encoder useful for migration fixtures and older callers.
        switch version {
        case Self.legacyVersion:
            try validateV2()
        case Self.previousVersion:
            try validateV3()
        case Self.preTitlesVersion:
            try validateV4()
        case Self.currentVersion:
            try validate()
        default:
            throw ValidationError.unsupportedVersion(version)
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
                    },
                    realm: profile.realm,
                    midiSettings: Self.sortedMIDISettings(profile.midiSettings),
                    standardButtonTitles: profile.standardButtonTitles.sorted {
                        Self.controlIndex($0.control) < Self.controlIndex($1.control)
                    }
                )
            },
            profileName: profileName,
            showsInputOverlay: showsInputOverlay,
            activeRealm: activeRealm,
            lastStandardProfileName: lastStandardProfileName,
            lastMIDIProfileName: lastMIDIProfileName,
            midiLocked: midiLocked,
            workspaceLockControl: workspaceLockControl
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sortedConfiguration)
    }

    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles, profileName, showsInputOverlay
        case activeRealm, lastStandardProfileName, lastMIDIProfileName
        case midiLocked, workspaceLockControl, workspaceLockKey
    }

    private static func sortedMIDISettings(_ settings: MIDIProfileSettings?) -> MIDIProfileSettings? {
        guard var settings else { return nil }
        settings.primaryButtons.sort { controlIndex($0.control) < controlIndex($1.control) }
        settings.functionButtons.sort { controlIndex($0.control) < controlIndex($1.control) }
        return settings
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
