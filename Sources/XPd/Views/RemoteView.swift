import SwiftUI

struct RemoteView: View {
    let store: MappingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Remote").font(.headline)
                Spacer()
                Text(store.hid.lastEvent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }

                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        Text("XP pen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 48, height: 120)

                        Spacer()

                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .stroke(.secondary.opacity(0.45), lineWidth: 4)
                                    .frame(width: 126, height: 126)
                                controlButton(.wheelCenter, label: "Center")
                                    .frame(width: 54, height: 54)
                                    .clipShape(Circle())
                            }

                            HStack(spacing: 8) {
                                controlButton(.wheelCCW, label: "↶ CCW")
                                controlButton(.wheelCW, label: "CW ↷")
                            }
                            .frame(width: 150)
                        }
                    }

                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            controlButton(.k8)
                            controlButton(.k4)
                            controlButton(.k1)
                        }
                        GridRow {
                            controlButton(.k9)
                                .gridCellUnsizedAxes(.horizontal)
                            controlButton(.k5)
                            controlButton(.k2)
                        }
                        GridRow {
                            Color.clear.frame(height: 42)
                            controlButton(.k6)
                            controlButton(.k3)
                        }
                        GridRow {
                            controlButton(.k10)
                            controlButton(.k7)
                                .gridCellColumns(2)
                        }
                    }
                }
                .padding(18)
            }
            .frame(width: 250, height: 455)
        }
    }

    @ViewBuilder
    private func controlButton(_ control: RemoteControl, label: String? = nil) -> some View {
        Button {
            store.selectedControl = control
        } label: {
            Text(label ?? control.rawValue)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: control == .k9 ? 42 : 42)
        }
        .buttonStyle(RemoteButtonStyle(selected: store.selectedControl == control))
    }
}

private struct RemoteButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
