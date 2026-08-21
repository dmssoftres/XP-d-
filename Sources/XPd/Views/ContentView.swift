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
            ?? "0.1.1"
    }
}
