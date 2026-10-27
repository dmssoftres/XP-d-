import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let store: MappingStore
    @State private var isManagingProfiles = false
    @State private var isImportingConfiguration = false
    @State private var isExportingConfiguration = false
    @State private var exportDocument = XPdConfigurationDocument()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 8) {
                    RemoteView(store: store)
                    if store.showsKeyMonitor {
                        KeyMonitorView(store: store)
                    }
                }
                .frame(width: 300)
                ScrollView(.vertical) {
                    MappingInspector(store: store)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
        .sheet(isPresented: $isManagingProfiles) {
            ProfileManagementView(store: store)
        }
        .fileImporter(
            isPresented: $isImportingConfiguration,
            allowedContentTypes: XPdConfigurationDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importConfiguration
        )
        .fileExporter(
            isPresented: $isExportingConfiguration,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename,
            onCompletion: exportConfigurationCompleted
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connectionColor)
                .frame(width: 9, height: 9)
                .accessibilityLabel(deviceStatus)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("XP[d]")
                        .font(.headline)
                    Text(AppVersion.display)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    connectionIcon
                    Text(deviceStatus)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: 2) {
                runModeButton
                if store.hid.isConnected {
                    batteryIndicator
                }
            }
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                workspaceControls
                configurationControls
                HStack(spacing: 6) {
                    Text("Profile")
                    Picker("Profile", selection: profileSelectionBinding) {
                        ForEach(store.availableProfiles, id: \.self) { profile in
                            HStack(spacing: 6) {
                                Text(profile)
                                Text(store.profileRealm(for: profile) == .midi ? "MIDI" : "Standard")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(width: 150, height: 24)
                }
                Button {
                    isManagingProfiles = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                }
                .buttonStyle(.borderless)
                .frame(height: 24)
                .help("Add, rename, or remove profiles")
                .accessibilityLabel("Manage profiles")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var profileSelectionBinding: Binding<String> {
        Binding(
            get: { store.profileName },
            set: { _ = store.selectProfile($0) }
        )
    }

    private var workspaceControls: some View {
        HStack(spacing: 7) {
            Text(store.activeRealm == .midi ? "MIDI Lock" : "Standard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.activeRealm == .midi ? .orange : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .frame(height: 24)
                .accessibilityLabel("Active workspace: \(store.activeRealm == .midi ? "MIDI Lock" : "Standard")")

            if store.autoSwitchProfilesEnabled, store.activeRealm == .standard {
                Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .frame(height: 24)
                    .help("Profiles switch automatically by app (Manage profiles to change)")
            }

            Button {
                _ = store.toggleWorkspace()
            } label: {
                Label(store.activeRealm == .midi ? "Unlock" : "MIDI", systemImage: store.activeRealm == .midi ? "lock.open" : "lock")
            }
            .disabled(store.activeRealm != .midi && store.midiProfiles.isEmpty)
            .help(store.activeRealm == .midi ? "Return to Standard profiles" : "Enter MIDI Lock")

            if store.activeRealm == .midi {
                Text(midiEndpointHeadline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Panic", role: .destructive) { store.panicMIDI() }
                    .help("Send MIDI All Notes Off")
            }
        }
        .controlSize(.regular)
    }

    private var midiEndpointHeadline: String {
        let available = MIDIOutputPort.allCases.filter { store.midiEndpointStatus[$0]?.isAvailable == true }.count
        if let error = MIDIOutputPort.allCases.compactMap({ store.midiEndpointStatus[$0]?.error }).first {
            return "MIDI \(available)/\(MIDIOutputPort.allCases.count) · \(error)"
        }
        return "MIDI \(available)/\(MIDIOutputPort.allCases.count)"
    }

    private var deviceStatus: String {
        if !store.hid.hasInputAccess { return "Input Monitoring permission required" }
        if !store.hid.hasExclusiveControl { return "Exclusive remote control unavailable" }
        guard store.hid.isConnected else { return "Waiting for Shortcut Remote" }
        switch store.hid.connectionTransport {
        case .usb: return "USB cable"
        case .bluetooth:
            return store.hid.isBluetoothDriverModeActive
                ? "Bluetooth · driver mode"
                : "Bluetooth"
        case .other(let raw): return "Connected via \(raw)"
        case nil: return "Connected"
        }
    }

    @ViewBuilder
    private var connectionIcon: some View {
        if store.hid.hasInputAccess, store.hid.hasExclusiveControl, store.hid.isConnected {
            switch store.hid.connectionTransport {
            case .bluetooth:
                BluetoothGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                    .frame(width: 4.2, height: 6.6)
                    .accessibilityHidden(true)
            case .usb:
                Image(systemName: "cable.connector")
                    .font(.system(size: 6.5))
                    .accessibilityHidden(true)
            default:
                EmptyView()
            }
        }
    }

    private var connectionColor: Color {
        if !store.hid.hasInputAccess || !store.hid.hasExclusiveControl { return .orange }
        if !store.hid.isConnected { return .red }
        return .green
    }

    private var batteryIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol)
            Text(batteryLabel)
        }
        .font(.caption)
        .foregroundStyle(batteryColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(batteryAccessibilityLabel)
    }

    private var runModeButton: some View {
        Button {
            _ = store.setRunMode(!store.isRunMode)
        } label: {
            Label(
                store.isRunMode ? "Run" : "Edit",
                systemImage: store.isRunMode ? "lock.fill" : "lock.open"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 54, minHeight: 22)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Run locks editor selection while mappings execute")
        .accessibilityLabel(store.isRunMode ? "Run mode" : "Edit mode")
        .accessibilityHint("Run locks editor selection while mappings execute")
    }

    private var batteryLabel: String {
        guard let percentage = store.hid.batteryPercentage else {
            return "Battery unavailable"
        }
        return "\(percentage)%"
    }

    private var batterySymbol: String {
        guard let percentage = store.hid.batteryPercentage else {
            return "questionmark.circle"
        }
        switch percentage {
        case 90...100: return "battery.100percent"
        case 75..<90: return "battery.75percent"
        case 50..<75: return "battery.50percent"
        case 25..<50: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryColor: Color {
        guard let percentage = store.hid.batteryPercentage else {
            return .secondary
        }
        if percentage <= 10 { return .red }
        if percentage <= 20 { return .orange }
        return .secondary
    }

    private var batteryAccessibilityLabel: String {
        guard let percentage = store.hid.batteryPercentage else {
            return "Remote battery unavailable"
        }
        return "Remote battery \(percentage) percent"
    }

    private var configurationControls: some View {
        HStack(spacing: 10) {
            Button {
                isImportingConfiguration = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            Button {
                guard let data = store.exportConfiguration() else { return }
                exportDocument = XPdConfigurationDocument(data: data)
                isExportingConfiguration = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .controlSize(.regular)
    }

    private func importConfiguration(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                store.importConfiguration(data)
            } catch {
                store.configurationFileOperationFailed(.import, error: error)
            }
        case .failure(let error):
            guard !isUserCancellation(error) else { return }
            store.configurationFileOperationFailed(.import, error: error)
        }
    }

    private func exportConfigurationCompleted(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            store.configurationExportCompleted()
        case .failure(let error):
            guard !isUserCancellation(error) else { return }
            store.configurationFileOperationFailed(.export, error: error)
        }
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    private var exportFilename: String {
        let safeProfileName = store.profileName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safeProfileName.isEmpty ? "XPd-Configuration" : "XPd-\(safeProfileName)"
    }

}

private struct ProfileManagementView: View {
    let store: MappingStore
    @Environment(\.dismiss) private var dismiss
    @State private var newProfileName = ""
    @State private var newProfileRealm: ProfileRealm = .standard
    @State private var midiProfileTemplate: MIDIProfileTemplate = .performancePads
    @State private var profileBeingRenamed: String?
    @State private var renamedProfileName = ""
    @State private var profileToDelete: String?
    @State private var duplicateSource: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Profiles")
                        .font(.title2.weight(.semibold))
                    Text("Create or rename profiles with separate mappings and HID layouts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Switch profiles automatically by app", isOn: Binding(
                    get: { store.autoSwitchProfilesEnabled },
                    set: { store.autoSwitchProfilesEnabled = $0 }
                ))
                Text("Give a Standard profile its apps with the app button. Apps in no list keep the current profile; MIDI Lock is never left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(store.availableProfiles, id: \.self) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile == "Global" ? "globe" : "app")
                            .foregroundStyle(.secondary)
                        if profileBeingRenamed == profile {
                            TextField("Profile name", text: $renamedProfileName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { renameProfile(profile) }
                        } else {
                            Text(profile)
                        }
                        Text(store.profileRealm(for: profile) == .midi ? "MIDI" : "Standard")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(store.profileRealm(for: profile) == .midi ? .orange : .secondary)
                        if profile == store.profileName {
                            Text("Active")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.profileRealm(for: profile) == .standard, profileBeingRenamed != profile {
                            AutoSwitchAppsButton(store: store, profile: profile)
                        }
                        if profileBeingRenamed != profile {
                            Button {
                                beginDuplicating(profile)
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .buttonStyle(.borderless)
                            .help("Duplicate \(profile) as a new profile")
                            .accessibilityLabel("Duplicate \(profile)")
                        }
                        if profile == "Global" {
                            Text("Required")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if profileBeingRenamed == profile {
                            Button {
                                renameProfile(profile)
                            } label: {
                                Image(systemName: "checkmark")
                            }
                            .buttonStyle(.borderless)
                            .disabled(renamedProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Save profile name")
                            Button {
                                cancelRenaming()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel renaming")
                        } else {
                            Button {
                                beginRenaming(profile)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Rename \(profile)")
                            Button {
                                profileToDelete = profile
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Delete \(profile)")
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 150)

            if let duplicateSource {
                HStack(spacing: 6) {
                    Label("Copy of \(duplicateSource) — all its keys, without its apps", systemImage: "plus.square.on.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        self.duplicateSource = nil
                        newProfileName = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel duplicating")
                }
            }

            HStack(spacing: 8) {
                TextField("New profile name", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addProfile)
                if duplicateSource == nil {
                    Picker("Realm", selection: $newProfileRealm) {
                        ForEach(ProfileRealm.allCases) { realm in
                            Text(realm == .midi ? "MIDI" : "Standard").tag(realm)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Button(duplicateSource == nil ? "Add" : "Duplicate", action: addProfile)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if newProfileRealm == .midi, duplicateSource == nil {
                Picker("MIDI template", selection: $midiProfileTemplate) {
                    ForEach(MIDIProfileTemplate.allCases) { template in
                        Text(template.displayName).tag(template)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .frame(width: 460, height: 500)
        .confirmationDialog(
            "Delete \(profileToDelete ?? "profile")?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let profileToDelete else { return }
                do {
                    try store.deleteProfile(named: profileToDelete)
                    self.profileToDelete = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        }
    }

    private func beginDuplicating(_ profile: String) {
        cancelRenaming()
        duplicateSource = profile
        newProfileName = String("\(profile) copy".prefix(40))
        errorMessage = nil
    }

    private func addProfile() {
        do {
            if let duplicateSource {
                _ = try store.duplicateProfile(named: duplicateSource, as: newProfileName)
                self.duplicateSource = nil
            } else if newProfileRealm == .midi {
                _ = try store.addMIDIProfile(named: newProfileName, template: midiProfileTemplate)
            } else {
                _ = try store.addProfile(named: newProfileName)
            }
            newProfileName = ""
            newProfileRealm = .standard
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginRenaming(_ profile: String) {
        profileBeingRenamed = profile
        renamedProfileName = profile
        errorMessage = nil
    }

    private func cancelRenaming() {
        profileBeingRenamed = nil
        renamedProfileName = ""
    }

    private func renameProfile(_ profile: String) {
        do {
            _ = try store.renameProfile(named: profile, to: renamedProfileName)
            cancelRenaming()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Small per-profile control: icons of the assigned apps plus a popover to
/// add (running app or Choose…) and remove them.
private struct AutoSwitchAppsButton: View {
    let store: MappingStore
    let profile: String
    @State private var isEditing = false
    @State private var message: String?

    private var apps: [String] { store.autoSwitchApplications(for: profile) }

    var body: some View {
        Button {
            message = nil
            isEditing = true
        } label: {
            HStack(spacing: 2) {
                ForEach(apps.prefix(3), id: \.self) { bundleID in
                    Image(nsImage: AppIdentity.icon(for: bundleID))
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                if apps.count > 3 {
                    Text("+\(apps.count - 3)").font(.caption2)
                }
                Image(systemName: "app.badge")
            }
        }
        .buttonStyle(.borderless)
        .help("Apps that switch to \(profile)")
        .accessibilityLabel("Apps for \(profile)")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps that switch to \(profile)")
                .font(.headline)
            if apps.isEmpty {
                Text("No apps yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.self) { bundleID in
                HStack(spacing: 6) {
                    Image(nsImage: AppIdentity.icon(for: bundleID))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(AppIdentity.name(for: bundleID))
                    Spacer()
                    Button {
                        store.removeAutoSwitchApplication(bundleID, from: profile)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(AppIdentity.name(for: bundleID))")
                }
            }
            HStack {
                Menu("Add running app") {
                    ForEach(AppIdentity.runningApplications(), id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()
                Button("Choose…", action: chooseApplication)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func add(_ bundleID: String) {
        switch store.addAutoSwitchApplication(bundleID, to: profile) {
        case .added:
            message = nil
        case let .alreadyAssigned(owner):
            message = "\(AppIdentity.name(for: bundleID)) already switches to \(owner). Remove it there first."
        case .invalid:
            message = "That app cannot be used for switching."
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The popover closes while the panel is open; reopen it so the
        // result (or an error) is visible.
        isEditing = true
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            message = "That app has no bundle identifier."
            return
        }
        add(bundleID)
    }
}

/// Name and icon for a bundle ID, falling back to the ID itself when the
/// app is not installed.
enum AppIdentity {
    struct RunningApp {
        let bundleID: String
        let name: String
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func runningApplications() -> [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return RunningApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Small always-visible monitor: the remote keys held right now and the
/// last few presses, combos and wheel turns with what they did.
private struct KeyMonitorView: View {
    let store: MappingStore
    private static let visibleEvents = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Pressed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                let held = store.keyMonitorHeldControls
                if held.isEmpty {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(held.enumerated()), id: \.element) { index, control in
                        if index > 0 { Text("+").font(.caption).foregroundStyle(.secondary) }
                        Text(control.rawValue)
                            .font(.caption.weight(.bold).monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.35), in: Capsule())
                    }
                }
                Spacer()
                if !store.keyMonitorEvents.isEmpty {
                    Button {
                        store.clearKeyMonitor()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear the list")
                }
                Button {
                    store.showsKeyMonitor = false
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Hide the key monitor (turn it back on from the XP[d] menu bar icon)")
            }
            ForEach(store.keyMonitorEvents.prefix(Self.visibleEvents)) { event in
                HStack(spacing: 4) {
                    Text(event.input + (event.count > 1 ? " ×\(event.count)" : ""))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                    Text(event.result)
                        .font(.caption2)
                        .foregroundStyle(event.failed ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if store.keyMonitorEvents.isEmpty {
                Text("Press a key on the remote to see it here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(width: 260, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Key monitor")
    }
}

/// The Bluetooth rune (SF Symbols has no Bluetooth glyph).
private struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0, 0.27))
        path.addLine(to: point(1, 0.73))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(1, 0.27))
        path.addLine(to: point(0, 0.73))
        return path
    }
}
