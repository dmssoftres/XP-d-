import AppKit
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

            device
        }
    }

    private var device: some View {
        ZStack(alignment: .topLeading) {
            shell

            Text("XP\npen")
                .font(.system(size: 16, weight: .light, design: .rounded))
                .tracking(-1)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.28))
                .rotationEffect(.degrees(90))
                .position(x: 55, y: 91)

            wheel
                .frame(width: 154, height: 154)
                .position(x: 176, y: 81)

            keyDeck
                .frame(width: 204, height: 272)
                .position(x: 127, y: 326)
        }
        .frame(width: 260, height: 491)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcut Remote")
    }

    private var shell: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(shellGradient)
                .frame(width: 238, height: 462)
                .offset(x: 8, y: 23)
                .shadow(color: .black.opacity(0.34), radius: 9, y: 5)

            Circle()
                .fill(shellGradient)
                .frame(width: 164, height: 164)
                .offset(x: 94, y: 0)

            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
                .frame(width: 238, height: 462)
                .offset(x: 8, y: 23)
        }
    }

    private var shellGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.38, green: 0.39, blue: 0.40),
                Color(red: 0.28, green: 0.29, blue: 0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var wheel: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.22, green: 0.23, blue: 0.24),
                            Color(red: 0.08, green: 0.085, blue: 0.09)
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 77
                    )
                )
                .shadow(color: .black.opacity(0.65), radius: 3, y: 2)

            ForEach(0..<11, id: \.self) { index in
                Circle()
                    .stroke(
                        index.isMultiple(of: 2) ? .white.opacity(0.10) : .black.opacity(0.55),
                        lineWidth: index.isMultiple(of: 2) ? 1 : 1.5
                    )
                    .padding(CGFloat(index * 5 + 5))
            }

            Circle()
                .stroke(.black.opacity(0.75), lineWidth: 3)

            HStack(spacing: 0) {
                wheelDirectionButton(.wheelCCW, systemImage: "arrow.counterclockwise")
                wheelDirectionButton(.wheelCW, systemImage: "arrow.clockwise")
            }
            .clipShape(Circle())

            Button {
                store.selectedControl = .wheelCenter
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white,
                                    Color(red: 1.0, green: 0.10, blue: 0.06),
                                    Color(red: 0.48, green: 0.0, blue: 0.02),
                                    Color(white: 0.035)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 27
                            )
                        )

                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .stroke(.red.opacity(0.34 - Double(index) * 0.06), lineWidth: 1)
                            .padding(CGFloat(index * 5 + 7))
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: .red, radius: 8)
                }
                .overlay {
                    Circle()
                        .stroke(centerStroke, lineWidth: store.liveControl == .wheelCenter ? 2 : 1)
                }
                .shadow(color: .black.opacity(0.72), radius: 3, y: 2)
                .shadow(color: .red.opacity(0.28), radius: 6)
                .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wheel center")
        }
    }

    private var centerStroke: Color {
        if store.liveControl == .wheelCenter { return .green }
        if store.selectedControl == .wheelCenter { return .white.opacity(0.72) }
        return .black.opacity(0.78)
    }

    private func wheelDirectionButton(_ control: RemoteControl, systemImage: String) -> some View {
        Button {
            store.selectedControl = control
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(wheelDirectionColor(control))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.rawValue)
    }

    private func wheelDirectionColor(_ control: RemoteControl) -> Color {
        if store.liveControl == control { return .green }
        if store.selectedControl.isWheelRotation { return .white.opacity(0.82) }
        return .white.opacity(0.18)
    }

    private var keyDeck: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 8) {
                keyButton(.k8)
                keyButton(.k9, height: 132)
                keyButton(.k10)
            }
            .frame(width: 62)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    keyButton(.k4)
                    keyButton(.k1)
                }
                HStack(spacing: 8) {
                    keyButton(.k5)
                    keyButton(.k2)
                }
                HStack(spacing: 8) {
                    keyButton(.k6)
                    keyButton(.k3)
                }
                keyButton(.k7)
            }
            .frame(width: 134)
        }
    }

    private func keyButton(_ control: RemoteControl, height: CGFloat = 62) -> some View {
        Button {
            store.selectedControl = control
        } label: {
            ZStack(alignment: .bottom) {
                Text(control.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(keyLabelColor(control))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let appIcon = loadedApplicationIcon(for: control) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .padding(.bottom, 5)
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(HardwareKeyStyle(
            selected: store.selectedControl == control,
            live: store.liveControl == control
        ))
        .accessibilityLabel(control.rawValue)
    }

    private func keyLabelColor(_ control: RemoteControl) -> Color {
        if store.liveControl == control { return .green }
        if store.selectedControl == control { return .white.opacity(0.86) }
        return .white.opacity(0.30)
    }

    private func loadedApplicationIcon(for control: RemoteControl) -> NSImage? {
        let gestures: [GestureKind] = [.tap, .hold, .doubleTap]
        guard let mapping = gestures
            .map({ store.mapping(for: control, gesture: $0) })
            .first(where: {
                ($0.action == .openApplication || $0.action == .toggleApplication)
                    && !$0.command.isEmpty
            })
        else { return nil }

        let command = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        let expandedCommand = NSString(string: command).expandingTildeInPath
        let appName = command.lowercased().hasSuffix(".app") ? command : "\(command).app"
        let candidatePaths = command.contains("/")
            ? [expandedCommand]
            : [
                "/Applications/\(appName)",
                "/System/Applications/\(appName)",
                "/System/Applications/Utilities/\(appName)",
                NSString(string: "~/Applications/\(appName)").expandingTildeInPath
            ]

        if let path = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: command) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        return nil
    }
}

private struct HardwareKeyStyle: ButtonStyle {
    let selected: Bool
    let live: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: configuration.isPressed
                                ? [Color(white: 0.12), Color(white: 0.19)]
                                : [Color(white: 0.22), Color(white: 0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.58), radius: 2, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(outerStroke, lineWidth: live ? 2 : selected ? 1.5 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                            .padding(3)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var outerStroke: Color {
        if live { return .green }
        if selected { return .white.opacity(0.66) }
        return .black.opacity(0.72)
    }
}
