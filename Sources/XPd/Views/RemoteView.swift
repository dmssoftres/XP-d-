import AppKit
import SwiftUI

struct RemoteView: View {
    let store: MappingStore

    var body: some View {
        device
            .padding(.top, 18)
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

            if store.activeRealm == .midi {
                midiWheelSummary
            }
        }
    }

    private var midiWheelSummary: some View {
        let mapping = store.midiWheelMapping(for: store.selectedMIDILayer)
        return VStack(spacing: 1) {
            Text(mapping.kind.rawValue)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(wheelSummary(mapping))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 86)
        .padding(.top, 20)
        .allowsHitTesting(false)
        .accessibilityLabel("MIDI wheel \(mapping.kind.rawValue), \(wheelSummary(mapping))")
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
        if store.activeRealm == .midi {
            return AnyView(midiKeyButton(control, height: height))
        }
        return AnyView(standardKeyButton(control, height: height))
    }

    private func midiKeyButton(_ control: RemoteControl, height: CGFloat) -> some View {
        let mapping = store.midiButtonMapping(for: control, layer: store.selectedMIDILayer)
        let isFn = store.fnControl == control
        return VStack(spacing: 1) {
            if isFn {
                Text("FN")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Menu {
                    ForEach(midiMenuKinds(current: mapping.kind)) { kind in
                        Button {
                            var updated = mapping
                            updated.kind = kind
                            store.updateMIDIButtonMapping(updated, for: control, layer: store.selectedMIDILayer)
                        } label: {
                            if kind == mapping.kind {
                                Label(kind.rawValue, systemImage: "checkmark")
                            } else {
                                Text(kind.rawValue)
                            }
                        }
                    }
                } label: {
                    Text(mapping.kind.rawValue)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.73))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .help("Change MIDI message type")
            }

            Button {
                store.selectedControl = control
            } label: {
                VStack(spacing: 2) {
                    Text(control.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(keyLabelColor(control))
                    if isFn {
                        Text("Hold → Layer 2")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    } else {
                        let detail = midiButtonDetail(mapping)
                        VStack(spacing: 0) {
                            Text(detail.primary)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Text(detail.secondary)
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: height - 14, maxHeight: height - 14)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(HardwareKeyStyle(
                selected: store.selectedControl == control,
                live: store.liveControl == control
            ))
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isFn ? "\(control.rawValue), FN, hold for Layer 2" : "\(control.rawValue), \(mapping.kind.rawValue), \(midiButtonSummary(mapping))")
    }

    private func midiButtonSummary(_ mapping: MIDIButtonMapping) -> String {
        let detail = midiButtonDetail(mapping)
        return "\(detail.primary) \(detail.secondary)"
    }

    private func midiButtonDetail(_ mapping: MIDIButtonMapping) -> (primary: String, secondary: String) {
        switch mapping.kind {
        case .note:
            return ("\(midiNoteName(mapping.note)) (\(mapping.note))", "Ch \(mapping.channel) · V \(mapping.velocity)")
        case .cc:
            return ("CC \(mapping.controller)", "Ch \(mapping.channel) · \(mapping.pressValue)/\(mapping.releaseValue)")
        case .program:
            return ("PC \(mapping.program)", "Ch \(mapping.channel)")
        case .chord:
            return (mapping.chord.map(String.init).joined(separator: ","), "Ch \(mapping.channel) · V \(mapping.velocity)")
        case .noAction:
            return ("No output", "")
        }
    }

    private func midiNoteName(_ note: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        guard (0...127).contains(note) else { return "N" }
        return names[note % 12] + String(note / 12 - 2)
    }

    private func midiMenuKinds(current: MIDIButtonKind) -> [MIDIButtonKind] {
        let allowed: [MIDIButtonKind] = store.selectedMIDILayer == .function
            ? [.note, .chord, .noAction]
            : MIDIButtonKind.allCases
        return allowed.contains(current) ? allowed : [current] + allowed
    }

    private func wheelSummary(_ mapping: MIDIWheelMapping) -> String {
        switch mapping.kind {
        case .relativeCC:
            return "CC\(mapping.controller) Ch\(mapping.channel) \(mapping.clockwiseValue)/\(mapping.counterClockwiseValue)"
        case .absoluteCC: return "CC\(mapping.controller) Ch\(mapping.channel) step \(mapping.stepSize)"
        case .pitchBendNudgeReturn: return "Ch\(mapping.channel) ±\(mapping.pitchBendStep) → 0"
        case .transpose: return "\(mapping.transposeSemitones > 0 ? "+" : "")\(mapping.transposeSemitones) st"
        case .drumBank: return "step \(mapping.drumBankStep)"
        case .noAction: return "—"
        }
    }

    /*
     The standard key implementation is intentionally kept above in the
     MIDI branch's fallback.  This overload is retained here so the remote
     remains the same compact hardware view in Standard profiles.
     */
    private func standardKeyButton(_ control: RemoteControl, height: CGFloat) -> some View {
        let title = store.standardButtonTitle(for: control)
        let routes = store.standardApplicationRoutes(for: control)
        let routeSelection = standardApplicationRouteDisplaySelection(routes)
        let hasMainWindowToggle = store.hasMainWindowToggleMapping(for: control)
        return Button {
            store.selectedControl = control
        } label: {
            ZStack(alignment: .bottom) {
                Text(control.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(keyLabelColor(control))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !title.isEmpty {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(keyLabelColor(control))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 3)
                            .padding(.top, 4)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                if !routes.isEmpty {
                    applicationRouteStrip(
                        routeSelection.visible,
                        hiddenCount: routeSelection.hiddenCount,
                        height: height
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(HardwareKeyStyle(
            selected: store.selectedControl == control,
            live: store.liveControl == control
        ))
        .overlay(alignment: .topLeading) {
            if hasMainWindowToggle {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                    .padding(3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.isRemoteModifier(control) {
                Text("MOD")
                    .font(.system(size: 6.5, weight: .bold, design: .rounded))
                    .foregroundStyle(store.modifierColor(for: control).swiftUIColor)
                    .padding(.horizontal, 4)
                    .frame(height: 12)
                    .background(.black.opacity(0.52), in: Capsule())
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(
            standardButtonAccessibilityLabel(
                control: control,
                title: title,
                routes: routes,
                hiddenCount: routeSelection.hiddenCount,
                hasMainWindowToggle: hasMainWindowToggle
            )
        )
        .help(
            standardButtonAccessibilityLabel(
                control: control,
                title: title,
                routes: routes,
                hiddenCount: routeSelection.hiddenCount,
                hasMainWindowToggle: hasMainWindowToggle
            )
        )
    }

    private func applicationRouteStrip(
        _ routes: [StandardApplicationRoute],
        hiddenCount: Int,
        height: CGFloat
    ) -> some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    applicationRouteSlot(route(at: 0, in: routes))
                    Spacer(minLength: 0)
                    applicationRouteSlot(route(at: 1, in: routes))
                }

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    applicationRouteSlot(route(at: 2, in: routes))
                    Spacer(minLength: 0)
                    applicationRouteSlot(route(at: 3, in: routes))
                }
            }
            .padding(.horizontal, 3)
            // Keep the two route rows spatially distinct from the centered Kx.
            // Corner badges remain independent overlays at the key boundary.
            .padding(.vertical, 3)

            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.system(size: 6, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 2)
                    .frame(height: 10)
                    .background(.black.opacity(0.68), in: Capsule())
                    .offset(y: 13)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func route(at index: Int, in routes: [StandardApplicationRoute]) -> StandardApplicationRoute? {
        guard routes.indices.contains(index) else { return nil }
        return routes[index]
    }

    @ViewBuilder
    private func applicationRouteSlot(_ route: StandardApplicationRoute?) -> some View {
        if let route {
            applicationRouteIndicator(route)
                .frame(width: 18, height: 18)
        } else {
            Color.clear
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func applicationRouteIndicator(_ route: StandardApplicationRoute) -> some View {
        if route.isBase {
            applicationRouteIcon(for: route.target, size: 14)
                .frame(maxWidth: .infinity)
        } else {
            applicationRouteIcon(for: route.target, size: 14)
                .padding(2)
                .frame(width: 18, height: 18)
                .background {
                    modifierRouteFill(route.modifierControls)
                        .clipShape(Capsule())
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            modifierRouteStroke(route.modifierControls),
                            lineWidth: 0.75
                        )
                }
        }
    }

    private func modifierRouteFill(_ modifiers: Set<RemoteControl>) -> some View {
        let colors = modifierRouteColors(modifiers)
        if colors.count <= 1 {
            return AnyView((colors.first ?? ModifierColor.orange.swiftUIColor).opacity(0.48))
        }
        return AnyView(
            LinearGradient(
                colors: colors.map { $0.opacity(0.48) },
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func modifierRouteStroke(_ modifiers: Set<RemoteControl>) -> LinearGradient {
        let colors = modifierRouteColors(modifiers)
        return LinearGradient(
            colors: (colors.isEmpty ? [ModifierColor.orange.swiftUIColor] : colors)
                .map { $0.opacity(0.96) },
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func modifierRouteColors(_ modifiers: Set<RemoteControl>) -> [Color] {
        RemoteControl.allCases
            .filter { modifiers.contains($0) }
            .map { store.modifierColor(for: $0).swiftUIColor }
    }

    private func standardButtonAccessibilityLabel(
        control: RemoteControl,
        title: String,
        routes: [StandardApplicationRoute],
        hiddenCount: Int,
        hasMainWindowToggle: Bool
    ) -> String {
        var parts = [control.rawValue]
        if !title.isEmpty { parts.append(title) }

        let routeSummary = routes.map { route in
            let target = "\(route.gesture.rawValue) \(route.target)"
            guard !route.isBase else { return "Base \(target)" }
            let modifiers = RemoteControl.allCases
                .filter { route.modifierControls.contains($0) }
                .map(\.rawValue)
                .joined(separator: " + ")
            return "\(modifiers) \(target)"
        }
        if !routeSummary.isEmpty {
            parts.append(routeSummary.joined(separator: "; "))
        }
        if hiddenCount > 0 {
            parts.append("\(hiddenCount) additional application route\(hiddenCount == 1 ? "" : "s") hidden")
        }
        if store.isRemoteModifier(control) {
            parts.append("K modifier")
        }
        if hasMainWindowToggle {
            parts.append("Show or hide XP[d]")
        }
        return parts.joined(separator: ", ")
    }

    private func keyLabelColor(_ control: RemoteControl) -> Color {
        if store.liveControl == control { return .green }
        if store.selectedControl == control { return .white.opacity(0.86) }
        return .white.opacity(0.30)
    }

    @ViewBuilder
    private func applicationRouteIcon(for target: String, size: CGFloat) -> some View {
        if let icon = applicationIcon(for: target) {
            Image(nsImage: icon)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: size, height: size)
        }
    }

    private func applicationIcon(for target: String) -> NSImage? {
        let command = target.trimmingCharacters(in: .whitespacesAndNewlines)

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

func standardApplicationRouteDisplaySelection(
    _ routes: [StandardApplicationRoute]
) -> (visible: [StandardApplicationRoute], hiddenCount: Int) {
    let capacity = 4
    guard routes.count > capacity else {
        return (routes, 0)
    }

    let primary = routes.first(where: { $0.isBase })
    let secondary = routes.filter(\.isBase).dropFirst()
    let modifiers = routes.filter { !$0.isBase }
    var visible: [StandardApplicationRoute] = []

    if let primary {
        visible.append(primary)
    }

    // Reserve one slot for a modifier route whenever one is available.
    // Base routes therefore remain contiguous immediately after the primary,
    // while the layer representation is never entirely hidden.
    let reservedModifierSlots = modifiers.isEmpty ? 0 : 1
    let secondaryCapacity = max(0, capacity - visible.count - reservedModifierSlots)
    visible.append(contentsOf: secondary.prefix(secondaryCapacity))
    visible.append(contentsOf: modifiers.prefix(max(0, capacity - visible.count)))

    return (visible, max(0, routes.count - visible.count))
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
