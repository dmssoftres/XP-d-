import SwiftUI

struct ContentView: View {
    let store: MappingStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 28) {
                RemoteView(store: store)
                    .frame(width: 300)
                MappingInspector(store: store)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
        .background(.regularMaterial)
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
            Spacer()
            Picker("Profile", selection: Bindable(store).profileName) {
                ForEach(MappingStore.availableProfiles, id: \.self) { profile in
                    Text(profile).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
    }
}
