import SwiftUI

struct MappingInspector: View {
    let store: MappingStore

    private var binding: Binding<Mapping> {
        Binding(
            get: { store.mapping(for: store.selectedControl, gesture: store.selectedGesture) },
            set: { store.update($0, for: store.selectedControl, gesture: store.selectedGesture) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected control")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.selectedControl.rawValue)
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Text(store.selectedGesture.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Action", selection: binding.action) {
                        ForEach(ActionKind.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }

                    TextField("Command", text: binding.command)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Gesture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Gesture", selection: Bindable(store).selectedGesture) {
                            ForEach(GestureKind.allCases) { gesture in
                                Text(gesture.rawValue).tag(gesture)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
                .padding(4)
            }

            HStack(spacing: 12) {
                statusCard(title: "Current profile", value: store.profileName, detail: "local mappings")
                statusCard(title: "Device", value: store.hid.isConnected ? "Connected" : "Offline", detail: "VID 10429 · PID 514")
            }

            GroupBox("Live HID") {
                HStack {
                    Text(store.hid.lastEvent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(6)
            }

            if store.selectedControl == .wheelCenter {
                Label("Wheel-center input is intentionally unresolved until we identify its HID report.", systemImage: "ladybug")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
        }
    }

    private func statusCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
