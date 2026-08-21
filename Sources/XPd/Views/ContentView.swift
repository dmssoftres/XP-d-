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
                .fill(store.hid.isConnected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("XP[d]")
                    .font(.headline)
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
}
