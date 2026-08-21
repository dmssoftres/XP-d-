import SwiftUI

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
                RemoteView(store: store)
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
                Text(deviceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.hid.isConnected {
                batteryIndicator
            }
            Spacer()
            workspaceControls
            configurationControls
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
            .pickerStyle(.menu)
            .frame(width: 150)
            Button {
                isManagingProfiles = true
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .help("Add, rename, or remove profiles")
            .accessibilityLabel("Manage profiles")
        }
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
                .accessibilityLabel("Active workspace: \(store.activeRealm == .midi ? "MIDI Lock" : "Standard")")

            Button {
                _ = store.toggleWorkspace()
            } label: {
                Label(store.activeRealm == .midi ? "Unlock" : "MIDI", systemImage: store.activeRealm == .midi ? "lock.open" : "lock")
            }
            .controlSize(.small)
            .disabled(store.activeRealm != .midi && store.midiProfiles.isEmpty)
            .help(store.activeRealm == .midi ? "Return to Standard profiles" : "Enter MIDI Lock")

            if store.activeRealm == .midi {
                Text(midiEndpointHeadline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Panic", role: .destructive) { store.panicMIDI() }
                    .controlSize(.small)
                    .help("Send MIDI All Notes Off")
            }
        }
    }

    private var midiEndpointHeadline: String {
        let available = MIDIOutputPort.allCases.filter { store.midiEndpointStatus[$0]?.isAvailable == true }.count
        if let error = MIDIOutputPort.allCases.compactMap({ store.midiEndpointStatus[$0]?.error }).first {
            return "MIDI \(available)/\(MIDIOutputPort.allCases.count) · \(error)"
        }
        return "MIDI \(available)/\(MIDIOutputPort.allCases.count)"
    }

    private var deviceStatus: String {
        if !store.hid.isConnected { return "Waiting for Shortcut Remote" }
        if !store.hid.hasInputAccess { return "Input Monitoring permission required" }
        return "Shortcut Remote connected"
    }

    private var connectionColor: Color {
        if !store.hid.isConnected { return .red }
        if !store.hid.hasInputAccess { return .orange }
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
    @State private var profileBeingRenamed: String?
    @State private var renamedProfileName = ""
    @State private var profileToDelete: String?
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

            HStack(spacing: 8) {
                TextField("New profile name", text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addProfile)
                Picker("Realm", selection: $newProfileRealm) {
                    ForEach(ProfileRealm.allCases) { realm in
                        Text(realm == .midi ? "MIDI" : "Standard").tag(realm)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button("Add", action: addProfile)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .frame(width: 420, height: 390)
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

    private func addProfile() {
        do {
            if newProfileRealm == .midi {
                _ = try store.addMIDIProfile(named: newProfileName)
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
