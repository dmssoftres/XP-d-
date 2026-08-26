import Foundation

/// The portable, versioned configuration format used by XP[d].
///
/// Arrays are used instead of dictionaries deliberately: profile order is
/// meaningful to the wheel selector, while mapping/HID entries can be sorted
/// before encoding for stable diffs.
struct XPdConfiguration: Codable, Equatable {
    static let currentVersion = 9
    static let legacyVersion = 2
    static let previousVersion = 3
    /// Version 4 is the immediately previous schema.  It had no
    /// Standard-mode button-title entries, so decoding it upgrades every
    /// profile with an empty title collection.
    static let preTitlesVersion = 4
    /// Version 5 added Standard button titles but predates dual-role K
    /// modifiers and alternate mapping layers.
    static let preRemoteLayersVersion = 5
    /// Version 6 added dual-role K modifiers and exact remote layers but did
    /// not yet persist arbitrary ordinary keyboard trigger keys.
    static let preRemoteTriggerKeysVersion = 6
    /// Version 7 added remote modifier designations but predates the
    /// profile-scoped modifier colour metadata.
    static let preModifierColorsVersion = 7
    /// Version 8 is the immediately previous schema. It still stored the
    /// physical HID identity independently in every profile.
    static let preHardwareLayoutsVersion = 8
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
    let hardwareLayouts: [HardwareLayout]
    let activeHardwareLayoutID: String
    /// Optional Standard-only resolver selection. The key is omitted from
    /// older documents (and from current exports when disabled); decoding a
    /// missing value as `nil` keeps those documents safely disabled.
    let standardF13F22PresetEnabled: Bool?

    /// A behavior profile. `hidBindings` is retained only to decode legacy schemas.
    struct Profile: Codable, Equatable, Identifiable {
        let name: String
        let mappings: [MappingEntry]
        let hidBindings: [HIDBindingEntry]
        let realm: ProfileRealm
        let midiSettings: MIDIProfileSettings?
        let standardButtonTitles: [StandardButtonTitleEntry]
        let remoteModifierControls: Set<RemoteControl>
        let modifierColors: [ModifierColorEntry]

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
            standardButtonTitles: [StandardButtonTitleEntry] = [],
            remoteModifierControls: Set<RemoteControl> = [],
            modifierColors: [ModifierColorEntry] = []
        ) {
            self.name = name
            self.mappings = mappings
            self.hidBindings = hidBindings
            self.realm = realm
            self.midiSettings = midiSettings
            self.standardButtonTitles = standardButtonTitles
            self.remoteModifierControls = remoteModifierControls
            self.modifierColors = modifierColors
        }

        init(
            name: String,
            mappings: [MappingEntry],
            hidBindings: [HIDBindingEntry],
            profileRealm: ProfileRealm,
            midiSettings: MIDIProfileSettings? = nil,
            standardButtonTitles: [StandardButtonTitleEntry] = [],
            remoteModifierControls: Set<RemoteControl> = [],
            modifierColors: [ModifierColorEntry] = []
        ) {
            self.init(
                name: name,
                mappings: mappings,
                hidBindings: hidBindings,
                realm: profileRealm,
                midiSettings: midiSettings,
                standardButtonTitles: standardButtonTitles,
                remoteModifierControls: remoteModifierControls,
                modifierColors: modifierColors
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
            remoteModifierControls = try container.decodeIfPresent(Set<RemoteControl>.self, forKey: .remoteModifierControls) ?? []
            modifierColors = try container.decodeIfPresent([ModifierColorEntry].self, forKey: .modifierColors) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(mappings, forKey: .mappings)
            try container.encode(hidBindings, forKey: .hidBindings)
            try container.encode(realm, forKey: .realm)
            try container.encodeIfPresent(midiSettings, forKey: .midiSettings)
            try container.encode(standardButtonTitles, forKey: .standardButtonTitles)
            try container.encode(
                RemoteControl.allCases.filter { remoteModifierControls.contains($0) },
                forKey: .remoteModifierControls
            )
            try container.encode(modifierColors, forKey: .modifierColors)
        }

        private enum CodingKeys: String, CodingKey {
            case name, mappings, hidBindings, realm, midiSettings, standardButtonTitles, remoteModifierControls, modifierColors
        }
    }

    struct MappingEntry: Codable, Equatable {
        let control: RemoteControl
        let gesture: GestureKind
        let mapping: Mapping
        let modifierControls: Set<RemoteControl>

        init(
            control: RemoteControl,
            gesture: GestureKind,
            mapping: Mapping,
            modifierControls: Set<RemoteControl> = []
        ) {
            self.control = control
            self.gesture = gesture
            self.mapping = mapping
            self.modifierControls = modifierControls
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            control = try container.decode(RemoteControl.self, forKey: .control)
            gesture = try container.decode(GestureKind.self, forKey: .gesture)
            mapping = try container.decode(Mapping.self, forKey: .mapping)
            modifierControls = try container.decodeIfPresent(Set<RemoteControl>.self, forKey: .modifierControls) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(control, forKey: .control)
            try container.encode(gesture, forKey: .gesture)
            try container.encode(mapping, forKey: .mapping)
            try container.encode(
                RemoteControl.allCases.filter { modifierControls.contains($0) },
                forKey: .modifierControls
            )
        }

        private enum CodingKeys: String, CodingKey {
            case control, gesture, mapping, modifierControls
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

    /// A physical remote's HID identity. Hardware layouts are deliberately
    /// separate from profiles: switching an action/profile set must not
    /// silently switch the physical buttons that produce those actions.
    struct HardwareLayout: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let hidBindings: [HIDBindingEntry]

        /// Compatibility spelling for callers that refer to the entries as
        /// generic bindings rather than HID bindings.
        var bindings: [HIDBindingEntry] { hidBindings }

        init(id: String, name: String, hidBindings: [HIDBindingEntry]) {
            self.id = id
            self.name = name
            self.hidBindings = hidBindings
        }

        init(id: String, name: String, bindings: [HIDBindingEntry]) {
            self.init(id: id, name: name, hidBindings: bindings)
        }
    }

    /// The v9 profile payload intentionally has no `hidBindings` key. Keep
    /// this separate from `Profile` so old v2–v8 fixtures can continue to be
    /// encoded through the compatibility shape.
    private struct V9ProfilePayload: Codable {
        let name: String
        let mappings: [MappingEntry]
        let realm: ProfileRealm
        let midiSettings: MIDIProfileSettings?
        let standardButtonTitles: [StandardButtonTitleEntry]
        let remoteModifierControls: Set<RemoteControl>
        let modifierColors: [ModifierColorEntry]

        init(profile: Profile) {
            name = profile.name
            mappings = profile.mappings
            realm = profile.realm
            midiSettings = profile.midiSettings
            standardButtonTitles = profile.standardButtonTitles
            remoteModifierControls = profile.remoteModifierControls
            modifierColors = profile.modifierColors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            mappings = try container.decodeIfPresent([MappingEntry].self, forKey: .mappings) ?? []
            realm = try container.decodeIfPresent(ProfileRealm.self, forKey: .realm) ?? .standard
            midiSettings = try container.decodeIfPresent(MIDIProfileSettings.self, forKey: .midiSettings)
            standardButtonTitles = try container.decodeIfPresent([StandardButtonTitleEntry].self, forKey: .standardButtonTitles) ?? []
            remoteModifierControls = try container.decodeIfPresent(Set<RemoteControl>.self, forKey: .remoteModifierControls) ?? []
            modifierColors = try container.decodeIfPresent([ModifierColorEntry].self, forKey: .modifierColors) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(mappings, forKey: .mappings)
            try container.encode(realm, forKey: .realm)
            try container.encodeIfPresent(midiSettings, forKey: .midiSettings)
            try container.encode(standardButtonTitles, forKey: .standardButtonTitles)
            try container.encode(
                RemoteControl.allCases.filter { remoteModifierControls.contains($0) },
                forKey: .remoteModifierControls
            )
            try container.encode(modifierColors, forKey: .modifierColors)
        }

        private enum CodingKeys: String, CodingKey {
            case name, mappings, realm, midiSettings, standardButtonTitles, remoteModifierControls, modifierColors
        }

        var profile: Profile {
            Profile(
                name: name,
                mappings: mappings,
                hidBindings: [],
                realm: realm,
                midiSettings: midiSettings,
                standardButtonTitles: standardButtonTitles,
                remoteModifierControls: remoteModifierControls,
                modifierColors: modifierColors
            )
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

    /// A profile-scoped colour assignment. Entries are arrays instead of a
    /// dictionary so portable JSON can be sorted deterministically and reject
    /// duplicate controls during validation.
    struct ModifierColorEntry: Codable, Equatable {
        let control: RemoteControl
        let color: ModifierColor

        init(control: RemoteControl, color: ModifierColor) {
            self.control = control
            self.color = color
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
        case emptyHardwareLayoutID
        case emptyHardwareLayoutName
        case duplicateHardwareLayoutID(String)
        case duplicateHardwareLayoutName(String)
        case invalidActiveHardwareLayout(String)
        case duplicateHIDControlInLayout(layout: String, control: RemoteControl)
        case duplicateHIDSignatureInLayout(layout: String, signature: String)
        case emptyHIDSignatureInLayout(layout: String, control: RemoteControl)
        case invalidRemoteModifierControl(profile: String, control: RemoteControl)
        case remoteModifiersOnMIDIProfile(String)
        case remoteLayersInLegacyProfile(String)
        case remoteTriggerKeysInLegacyProfile(String)
        case invalidRemoteTriggerKey(profile: String, primary: RemoteControl, gesture: GestureKind)
        case multipleRemoteTriggerKeys(profile: String, primary: RemoteControl, gesture: GestureKind)
        case invalidMappingModifierControl(profile: String, primary: RemoteControl, modifier: RemoteControl)
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
        case modifierColorsInLegacyProfile(String)
        case modifierColorsOnMIDIProfile(String)
        case invalidModifierColorControl(profile: String, control: RemoteControl)
        case duplicateModifierColor(profile: String, control: RemoteControl)

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
            case .emptyHardwareLayoutID:
                return "Hardware layout IDs cannot be empty."
            case .emptyHardwareLayoutName:
                return "Hardware layout names cannot be empty."
            case let .duplicateHardwareLayoutID(id):
                return "Duplicate hardware layout ID: \(id)."
            case let .duplicateHardwareLayoutName(name):
                return "Duplicate hardware layout name: \(name)."
            case let .invalidActiveHardwareLayout(id):
                return "Invalid active hardware layout: \(id)."
            case let .duplicateHIDControlInLayout(layout, control):
                return "Duplicate HID binding in hardware layout \(layout) for \(control.rawValue)."
            case let .duplicateHIDSignatureInLayout(layout, signature):
                return "Duplicate HID signature in hardware layout \(layout): \(signature)."
            case let .emptyHIDSignatureInLayout(layout, control):
                return "HID signature in hardware layout \(layout) for \(control.rawValue) cannot be empty."
            case let .invalidRemoteModifierControl(profile, control):
                return "Remote modifier in \(profile) must target a K button: \(control.rawValue)."
            case let .remoteModifiersOnMIDIProfile(profile):
                return "MIDI profile \(profile) cannot contain Standard remote modifiers."
            case let .remoteLayersInLegacyProfile(profile):
                return "Legacy profile \(profile) cannot contain remote modifier layers."
            case let .remoteTriggerKeysInLegacyProfile(profile):
                return "Legacy profile \(profile) cannot contain arbitrary keyboard trigger keys."
            case let .invalidRemoteTriggerKey(profile, primary, gesture):
                return "Remote trigger for \(primary.rawValue) · \(gesture.rawValue) in \(profile) must use an ordinary keyboard key."
            case let .multipleRemoteTriggerKeys(profile, primary, gesture):
                return "Remote trigger for \(primary.rawValue) · \(gesture.rawValue) in \(profile) may contain only one keyboard key."
            case let .invalidMappingModifierControl(profile, primary, modifier):
                return "Mapping layer in \(profile) cannot use \(modifier.rawValue) for \(primary.rawValue)."
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
            case let .modifierColorsInLegacyProfile(profile):
                return "Modifier colours are unsupported in the legacy profile schema: \(profile)."
            case let .modifierColorsOnMIDIProfile(profile):
                return "MIDI profile \(profile) cannot contain Standard modifier colours."
            case let .invalidModifierColorControl(profile, control):
                return "Modifier colour in \(profile) must target a K button: \(control.rawValue)."
            case let .duplicateModifierColor(profile, control):
                return "Duplicate modifier colour in \(profile) for \(control.rawValue)."
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
        workspaceLockControl: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl,
        hardwareLayouts: [HardwareLayout]? = nil,
        activeHardwareLayoutID: String? = nil,
        standardF13F22PresetEnabled: Bool? = nil
    ) {
        self.version = version
        self.profiles = version == Self.currentVersion
            ? profiles.map(Self.profileWithoutHIDBindings)
            : profiles
        self.profileName = profileName
        self.showsInputOverlay = showsInputOverlay
        self.activeRealm = activeRealm
        self.lastStandardProfileName = lastStandardProfileName
        self.lastMIDIProfileName = lastMIDIProfileName
        self.midiLocked = midiLocked
        self.workspaceLockControl = workspaceLockControl
        if version == Self.currentVersion {
            let layouts = hardwareLayouts ?? Self.layoutsDerivedFromProfiles(profiles)
            self.hardwareLayouts = layouts
            self.activeHardwareLayoutID = activeHardwareLayoutID
                ?? Self.activeLayoutID(for: profileName, in: profiles, layouts: layouts)
                ?? layouts.first?.id
                ?? ""
        } else {
            self.hardwareLayouts = hardwareLayouts ?? []
            self.activeHardwareLayoutID = activeHardwareLayoutID ?? ""
        }
        self.standardF13F22PresetEnabled = version == Self.currentVersion
            ? standardF13F22PresetEnabled
            : nil
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
        workspaceLockKey: RemoteControl = XPdConfiguration.defaultWorkspaceLockControl,
        hardwareLayouts: [HardwareLayout]? = nil,
        activeHardwareLayoutID: String? = nil,
        standardF13F22PresetEnabled: Bool? = nil
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
            workspaceLockControl: workspaceLockKey,
            hardwareLayouts: hardwareLayouts,
            activeHardwareLayoutID: activeHardwareLayoutID,
            standardF13F22PresetEnabled: standardF13F22PresetEnabled
        )
    }

    /// Alternate names used by workspace/routing code; the persisted keys
    /// remain concise and stable.
    var activeProfileRealm: ProfileRealm { activeRealm }
    var workspaceLockKey: RemoteControl { workspaceLockControl }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        let decodedProfiles: [Profile]
        if decodedVersion == Self.currentVersion {
            decodedProfiles = try container.decodeIfPresent([V9ProfilePayload].self, forKey: .profiles)?.map(\.profile) ?? []
        } else {
            decodedProfiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        }
        let decodedProfileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "Global"
        let decodedShowsInputOverlay = try container.decodeIfPresent(Bool.self, forKey: .showsInputOverlay) ?? true
        let decodedRealm = try container.decodeIfPresent(ProfileRealm.self, forKey: .activeRealm)
        let decodedLastStandard = try container.decodeIfPresent(String.self, forKey: .lastStandardProfileName)
        let decodedLastMIDI = try container.decodeIfPresent(String.self, forKey: .lastMIDIProfileName)
        let decodedMIDIlocked = try container.decodeIfPresent(Bool.self, forKey: .midiLocked) ?? false
        let decodedLockControl = try container.decodeIfPresent(RemoteControl.self, forKey: .workspaceLockControl)
            ?? container.decodeIfPresent(RemoteControl.self, forKey: .workspaceLockKey)
            ?? .k3
        let decodedHardwareLayouts = try container.decodeIfPresent([HardwareLayout].self, forKey: .hardwareLayouts) ?? []
        let decodedActiveHardwareLayoutID = try container.decodeIfPresent(String.self, forKey: .activeHardwareLayoutID) ?? ""
        let decodedStandardF13F22PresetEnabled = try container.decodeIfPresent(Bool.self, forKey: .standardF13F22PresetEnabled)
        version = decodedVersion
        profiles = decodedProfiles
        profileName = decodedProfileName
        showsInputOverlay = decodedShowsInputOverlay
        activeRealm = decodedRealm ?? (decodedProfiles.first(where: { $0.name == decodedProfileName })?.realm ?? .standard)
        lastStandardProfileName = decodedLastStandard
        lastMIDIProfileName = decodedLastMIDI
        midiLocked = decodedMIDIlocked
        workspaceLockControl = decodedLockControl
        hardwareLayouts = decodedHardwareLayouts
        activeHardwareLayoutID = decodedActiveHardwareLayoutID
        standardF13F22PresetEnabled = decodedStandardF13F22PresetEnabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if version == Self.currentVersion {
            try container.encode(profiles.map(V9ProfilePayload.init(profile:)), forKey: .profiles)
            try container.encode(hardwareLayouts, forKey: .hardwareLayouts)
            try container.encode(activeHardwareLayoutID, forKey: .activeHardwareLayoutID)
        } else {
            try container.encode(profiles, forKey: .profiles)
        }
        try container.encode(profileName, forKey: .profileName)
        try container.encode(showsInputOverlay, forKey: .showsInputOverlay)
        try container.encode(activeRealm, forKey: .activeRealm)
        try container.encodeIfPresent(lastStandardProfileName, forKey: .lastStandardProfileName)
        try container.encodeIfPresent(lastMIDIProfileName, forKey: .lastMIDIProfileName)
        try container.encode(midiLocked, forKey: .midiLocked)
        try container.encode(workspaceLockControl, forKey: .workspaceLockControl)
        if version == Self.currentVersion {
            try container.encodeIfPresent(standardF13F22PresetEnabled, forKey: .standardF13F22PresetEnabled)
        }
    }

    /// Decodes and validates the entire document before returning it. Versions
    /// 2–8 retain their published profile-owned HID shape while being upgraded
    /// to the v9 device-level hardware-layout shape.
    static func decode(_ data: Data) throws -> XPdConfiguration {
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionEnvelope.self, from: data).version
        switch version {
        case currentVersion:
            let configuration = try decoder.decode(XPdConfiguration.self, from: data)
            try configuration.validate()
            return configuration
        case preHardwareLayoutsVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV8()
            return try migrateLegacy(legacy)
        case preModifierColorsVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV7()
            let normalized = XPdConfiguration(
                version: preHardwareLayoutsVersion,
                profiles: legacy.profiles.map { profile in
                    Profile(
                        name: profile.name,
                        mappings: profile.mappings,
                        hidBindings: profile.hidBindings,
                        realm: profile.realm,
                        midiSettings: profile.midiSettings,
                        standardButtonTitles: profile.standardButtonTitles,
                        remoteModifierControls: profile.remoteModifierControls,
                        modifierColors: RemoteControl.allCases.filter {
                            profile.remoteModifierControls.contains($0)
                        }.map {
                            ModifierColorEntry(control: $0, color: .orange)
                        }
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
            try normalized.validateV8()
            return try migrateLegacy(normalized)
        case preRemoteTriggerKeysVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV6()
            let normalized = XPdConfiguration(
                version: preHardwareLayoutsVersion,
                profiles: legacy.profiles.map { profile in
                    Profile(
                        name: profile.name,
                        mappings: profile.mappings,
                        hidBindings: profile.hidBindings,
                        realm: profile.realm,
                        midiSettings: profile.midiSettings,
                        standardButtonTitles: profile.standardButtonTitles,
                        remoteModifierControls: profile.remoteModifierControls,
                        modifierColors: RemoteControl.allCases.filter {
                            profile.remoteModifierControls.contains($0)
                        }.map {
                            ModifierColorEntry(control: $0, color: .orange)
                        }
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
            try normalized.validateV8()
            return try migrateLegacy(normalized)
        case preRemoteLayersVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV5()
            let normalized = XPdConfiguration(
                version: preHardwareLayoutsVersion,
                profiles: legacy.profiles.map {
                    Profile(
                        name: $0.name,
                        mappings: $0.mappings,
                        hidBindings: $0.hidBindings,
                        realm: $0.realm,
                        midiSettings: $0.midiSettings,
                        standardButtonTitles: $0.standardButtonTitles,
                        remoteModifierControls: [],
                        modifierColors: []
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
            try normalized.validateV8()
            return try migrateLegacy(normalized)
        case preTitlesVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            try legacy.validateV4()
            let normalized = XPdConfiguration(
                version: preHardwareLayoutsVersion,
                profiles: legacy.profiles.map {
                    Profile(
                        name: $0.name,
                        mappings: $0.mappings,
                        hidBindings: $0.hidBindings,
                        realm: $0.realm,
                        midiSettings: $0.midiSettings,
                        standardButtonTitles: [],
                        remoteModifierControls: [],
                        modifierColors: []
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
            try normalized.validateV8()
            return try migrateLegacy(normalized)
        case legacyVersion, previousVersion:
            let legacy = try decoder.decode(XPdConfiguration.self, from: data)
            if version == legacyVersion {
                try legacy.validateV2()
            } else {
                try legacy.validateV3()
            }
            let normalized = XPdConfiguration(
                version: preHardwareLayoutsVersion,
                profiles: legacy.profiles.map {
                    Profile(
                        name: $0.name,
                        mappings: $0.mappings,
                        hidBindings: $0.hidBindings,
                        realm: .standard,
                        midiSettings: nil,
                        standardButtonTitles: [],
                        remoteModifierControls: [],
                        modifierColors: []
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
            try normalized.validateV8()
            return try migrateLegacy(normalized)
        default:
            throw ValidationError.unsupportedVersion(version)
        }
    }

    private static func migrateLegacy(_ legacy: XPdConfiguration) throws -> XPdConfiguration {
        var layouts: [HardwareLayout] = []
        var profileLayoutIndexes: [Int] = []

        for profile in legacy.profiles {
            let normalizedBindings = normalizedHIDBindings(profile.hidBindings)
            if let existingIndex = layouts.firstIndex(where: { $0.hidBindings == normalizedBindings }) {
                profileLayoutIndexes.append(existingIndex)
            } else {
                let index = layouts.count
                layouts.append(
                    HardwareLayout(
                        id: "migrated-\(index + 1)",
                        name: "Migrated from \(profile.name)",
                        hidBindings: normalizedBindings
                    )
                )
                profileLayoutIndexes.append(index)
            }
        }

        let activeProfileIndex = legacy.profiles.firstIndex(where: { $0.name == legacy.profileName }) ?? 0
        let activeLayoutIndex = profileLayoutIndexes[activeProfileIndex]
        let migrated = XPdConfiguration(
            version: Self.currentVersion,
            profiles: legacy.profiles.map(profileWithoutHIDBindings),
            profileName: legacy.profileName,
            showsInputOverlay: legacy.showsInputOverlay,
            activeRealm: legacy.activeRealm,
            lastStandardProfileName: legacy.lastStandardProfileName,
            lastMIDIProfileName: legacy.lastMIDIProfileName,
            midiLocked: legacy.midiLocked,
            workspaceLockControl: legacy.workspaceLockControl,
            hardwareLayouts: layouts,
            activeHardwareLayoutID: layouts[activeLayoutIndex].id
        )
        try migrated.validate()
        return migrated
    }

    private static func profileWithoutHIDBindings(_ profile: Profile) -> Profile {
        Profile(
            name: profile.name,
            mappings: profile.mappings,
            hidBindings: [],
            realm: profile.realm,
            midiSettings: profile.midiSettings,
            standardButtonTitles: profile.standardButtonTitles,
            remoteModifierControls: profile.remoteModifierControls,
            modifierColors: profile.modifierColors
        )
    }

    private static func normalizedHIDBindings(_ bindings: [HIDBindingEntry]) -> [HIDBindingEntry] {
        bindings.sorted {
            let lhsControl = controlIndex($0.control)
            let rhsControl = controlIndex($1.control)
            if lhsControl != rhsControl { return lhsControl < rhsControl }
            return $0.signature < $1.signature
        }
    }

    private static func layoutsDerivedFromProfiles(_ profiles: [Profile]) -> [HardwareLayout] {
        var layouts: [HardwareLayout] = []
        for profile in profiles {
            let normalizedBindings = normalizedHIDBindings(profile.hidBindings)
            guard !layouts.contains(where: { $0.hidBindings == normalizedBindings }) else { continue }
            layouts.append(
                HardwareLayout(
                    id: "layout-\(layouts.count + 1)",
                    name: layouts.isEmpty ? "Default" : "Layout \(layouts.count + 1)",
                    hidBindings: normalizedBindings
                )
            )
        }
        if layouts.isEmpty {
            layouts.append(HardwareLayout(id: "layout-1", name: "Default", hidBindings: []))
        }
        return layouts
    }

    private static func activeLayoutID(
        for profileName: String,
        in profiles: [Profile],
        layouts: [HardwareLayout]
    ) -> String? {
        guard let profile = profiles.first(where: { $0.name == profileName }) else { return nil }
        let normalizedBindings = normalizedHIDBindings(profile.hidBindings)
        return layouts.first(where: { $0.hidBindings == normalizedBindings })?.id
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

        try validateHardwareLayouts()
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

        try validateEntries(
            allowMIDISettings: false,
            allowStandardButtonTitles: false,
            allowRemoteLayers: false,
            allowRemoteTriggerKeys: false,
            allowModifierColors: false
        )
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
        try validateEntries(
            allowMIDISettings: false,
            allowStandardButtonTitles: false,
            allowRemoteLayers: false,
            allowRemoteTriggerKeys: false,
            allowModifierColors: false
        )
    }

    /// Version 4 predates Standard button titles.  Keep its realm/MIDI
    /// validation intact while rejecting title fields that do not belong to
    /// that schema.
    private func validateV4() throws {
        guard version == Self.preTitlesVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        try validateCurrentProfileShape()
        try validateEntries(
            allowStandardButtonTitles: false,
            allowRemoteLayers: false,
            allowRemoteTriggerKeys: false,
            allowModifierColors: false
        )
    }

    /// Version 5 is the immediately previous current-realm schema. It has
    /// titles but no remote modifier designation/layer fields.
    private func validateV5() throws {
        guard version == Self.preRemoteLayersVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        try validateCurrentProfileShape()
        try validateEntries(
            allowRemoteLayers: false,
            allowRemoteTriggerKeys: false,
            allowModifierColors: false
        )
    }

    /// Version 6 is the immediately previous schema. It supports exact K
    /// layers and the legacy modifier/F-key trigger gates, but not the new
    /// arbitrary ordinary-key condition.
    private func validateV6() throws {
        guard version == Self.preRemoteTriggerKeysVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        try validateCurrentProfileShape()
        try validateEntries(allowRemoteTriggerKeys: false, allowModifierColors: false)
    }

    /// Version 7 is the immediately previous schema. It supports remote
    /// modifier designations and exact layers but has no colour metadata.
    private func validateV7() throws {
        guard version == Self.preModifierColorsVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        try validateCurrentProfileShape()
        try validateEntries(allowModifierColors: false)
    }

    /// Version 8 is the final profile-owned HID schema. It is validated
    /// before its bindings are grouped into v9 hardware layouts.
    private func validateV8() throws {
        guard version == Self.preHardwareLayoutsVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        try validateCurrentProfileShape()
        try validateEntries()
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

    private func validateHardwareLayouts() throws {
        var layoutIDs = Set<String>()
        var layoutNames = Set<String>()

        for layout in hardwareLayouts {
            guard !layout.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyHardwareLayoutID
            }
            guard !layout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyHardwareLayoutName
            }
            guard layoutIDs.insert(layout.id).inserted else {
                throw ValidationError.duplicateHardwareLayoutID(layout.id)
            }
            let nameKey = Self.profileNameComparisonKey(layout.name)
            guard layoutNames.insert(nameKey).inserted else {
                throw ValidationError.duplicateHardwareLayoutName(layout.name)
            }

            var controls = Set<RemoteControl>()
            var signatures = Set<String>()
            for entry in layout.hidBindings {
                guard !entry.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.emptyHIDSignatureInLayout(
                        layout: layout.name,
                        control: entry.control
                    )
                }
                guard controls.insert(entry.control).inserted else {
                    throw ValidationError.duplicateHIDControlInLayout(
                        layout: layout.name,
                        control: entry.control
                    )
                }
                guard signatures.insert(entry.signature).inserted else {
                    throw ValidationError.duplicateHIDSignatureInLayout(
                        layout: layout.name,
                        signature: entry.signature
                    )
                }
            }
        }

        guard layoutIDs.contains(activeHardwareLayoutID) else {
            throw ValidationError.invalidActiveHardwareLayout(activeHardwareLayoutID)
        }
    }

    private func validateEntries(
        allowMIDISettings: Bool = true,
        allowRemoteLayers: Bool = true,
        allowRemoteTriggerKeys: Bool = true,
        allowModifierColors: Bool = true
    ) throws {
        try validateEntries(
            allowMIDISettings: allowMIDISettings,
            allowStandardButtonTitles: true,
            allowRemoteLayers: allowRemoteLayers,
            allowRemoteTriggerKeys: allowRemoteTriggerKeys,
            allowModifierColors: allowModifierColors
        )
    }

    private func validateEntries(
        allowMIDISettings: Bool = true,
        allowStandardButtonTitles: Bool,
        allowRemoteLayers: Bool = true,
        allowRemoteTriggerKeys: Bool = true,
        allowModifierColors: Bool = true
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
            if !allowModifierColors, !profile.modifierColors.isEmpty {
                throw ValidationError.modifierColorsInLegacyProfile(profile.name)
            }
            if profile.realm == .midi, !profile.modifierColors.isEmpty {
                throw ValidationError.modifierColorsOnMIDIProfile(profile.name)
            }
            var modifierColorControls = Set<RemoteControl>()
            for entry in profile.modifierColors {
                guard entry.control.isModifierEligible else {
                    throw ValidationError.invalidModifierColorControl(
                        profile: profile.name,
                        control: entry.control
                    )
                }
                guard modifierColorControls.insert(entry.control).inserted else {
                    throw ValidationError.duplicateModifierColor(
                        profile: profile.name,
                        control: entry.control
                    )
                }
            }
            if profile.realm == .midi, !profile.remoteModifierControls.isEmpty {
                throw ValidationError.remoteModifiersOnMIDIProfile(profile.name)
            }
            if !allowRemoteLayers,
               (!profile.remoteModifierControls.isEmpty
                || profile.mappings.contains(where: { !$0.modifierControls.isEmpty })) {
                throw ValidationError.remoteLayersInLegacyProfile(profile.name)
            }
            if profile.realm == .midi,
               profile.mappings.contains(where: { !$0.modifierControls.isEmpty }) {
                throw ValidationError.remoteModifiersOnMIDIProfile(profile.name)
            }
            for modifier in profile.remoteModifierControls {
                guard modifier.isModifierEligible else {
                    throw ValidationError.invalidRemoteModifierControl(
                        profile: profile.name,
                        control: modifier
                    )
                }
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
                for modifier in entry.modifierControls {
                    guard modifier.isModifierEligible, modifier != entry.control else {
                        throw ValidationError.invalidMappingModifierControl(
                            profile: profile.name,
                            primary: entry.control,
                            modifier: modifier
                        )
                    }
                }
                let key = MappingKey(
                    control: entry.control,
                    gesture: entry.gesture,
                    modifierControls: entry.modifierControls
                )
                guard mappingKeys.insert(key).inserted else {
                    throw ValidationError.duplicateMappingKey(
                        profile: profile.name,
                        control: entry.control,
                        gesture: entry.gesture
                    )
                }

                if !allowRemoteTriggerKeys,
                   (entry.mapping.remoteTriggerKeyCode != nil
                    || entry.mapping.remoteTriggerKeyDisplay != nil) {
                    throw ValidationError.remoteTriggerKeysInLegacyProfile(profile.name)
                }
                if entry.mapping.remoteTriggerKeyCode != nil,
                   entry.mapping.remoteTriggerFunctionKey != nil {
                    throw ValidationError.multipleRemoteTriggerKeys(
                        profile: profile.name,
                        primary: entry.control,
                        gesture: entry.gesture
                    )
                }
                if let keyCode = entry.mapping.remoteTriggerKeyCode,
                   keyCode > 127
                    || KeyboardShortcut.isModifierKeyCode(keyCode)
                    || KeyboardShortcut.functionKeyCodes.contains(keyCode) {
                    throw ValidationError.invalidRemoteTriggerKey(
                        profile: profile.name,
                        primary: entry.control,
                        gesture: entry.gesture
                    )
                }
                if let display = entry.mapping.remoteTriggerKeyDisplay,
                   entry.mapping.remoteTriggerKeyCode == nil,
                   !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError.invalidRemoteTriggerKey(
                        profile: profile.name,
                        primary: entry.control,
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
        case Self.preRemoteLayersVersion:
            try validateV5()
        case Self.preRemoteTriggerKeysVersion:
            try validateV6()
        case Self.preModifierColorsVersion:
            try validateV7()
        case Self.preHardwareLayoutsVersion:
            try validateV8()
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
                        let lhsGesture = Self.gestureIndex(lhs.gesture)
                        let rhsGesture = Self.gestureIndex(rhs.gesture)
                        if lhsGesture != rhsGesture { return lhsGesture < rhsGesture }
                        return Self.modifierSetIndex(lhs.modifierControls) < Self.modifierSetIndex(rhs.modifierControls)
                    },
                    hidBindings: profile.hidBindings.sorted {
                        Self.controlIndex($0.control) < Self.controlIndex($1.control)
                    },
                    realm: profile.realm,
                    midiSettings: Self.sortedMIDISettings(profile.midiSettings),
                    standardButtonTitles: profile.standardButtonTitles.sorted {
                        Self.controlIndex($0.control) < Self.controlIndex($1.control)
                    },
                    remoteModifierControls: Set(RemoteControl.allCases.filter {
                        profile.remoteModifierControls.contains($0)
                    }),
                    modifierColors: profile.modifierColors.sorted {
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
            workspaceLockControl: workspaceLockControl,
            hardwareLayouts: version == Self.currentVersion
                ? hardwareLayouts.map { layout in
                    HardwareLayout(
                        id: layout.id,
                        name: layout.name,
                        hidBindings: Self.normalizedHIDBindings(layout.hidBindings)
                    )
                }
                : nil,
            activeHardwareLayoutID: version == Self.currentVersion
                ? activeHardwareLayoutID
                : nil,
            standardF13F22PresetEnabled: version == Self.currentVersion
                ? standardF13F22PresetEnabled
                : nil
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
        case hardwareLayouts, activeHardwareLayoutID, standardF13F22PresetEnabled
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

    private static func modifierSetIndex(_ controls: Set<RemoteControl>) -> String {
        RemoteControl.allCases
            .filter { controls.contains($0) }
            .map(\.rawValue)
            .joined(separator: "\u{1F}")
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
