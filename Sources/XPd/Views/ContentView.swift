import SwiftUI

struct ContentView: View {
    let store: MappingStore
    @State private var isManagingProfiles = false

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
                    Text("v\(appVersion)")
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
            Picker("Profile", selection: Bindable(store).profileName) {
                ForEach(store.availableProfiles, id: \.self) { profile in
                    Text(profile).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            Button {
                isManagingProfiles = true
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .help("Add or remove profiles")
            .accessibilityLabel("Manage profiles")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.3"
    }
}

private struct ProfileManagementView: View {
    let store: MappingStore
    @Environment(\.dismiss) private var dismiss
    @State private var newProfileName = ""
    @State private var profileToDelete: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Profiles")
                        .font(.title2.weight(.semibold))
                    Text("Create a profile for a separate mapping and HID layout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            List {
                ForEach(store.availableProfiles, id: \.self) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile == "Global" ? "globe" : "app")
                            .foregroundStyle(.secondary)
                        Text(profile)
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
                        } else {
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
            _ = try store.addProfile(named: newProfileName)
            newProfileName = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
