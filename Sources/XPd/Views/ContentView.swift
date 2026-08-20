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
                Text(store.hid.isConnected ? "Shortcut Remote connected" : "Waiting for Shortcut Remote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Profile", selection: Bindable(store).profileName) {
                Text("Global").tag("Global")
                Text("Finder").tag("Finder")
                Text("Logic Pro").tag("Logic Pro")
            }
            .pickerStyle(.menu)
            .frame(width: 180)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
