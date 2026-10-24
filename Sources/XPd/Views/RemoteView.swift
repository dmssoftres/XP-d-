import AppKit
import SwiftUI

struct RemoteView: View {
    let store: MappingStore

    @State private var dropTargetControl: RemoteControl?
    @State private var pendingDrop: MappingDropProposal?
    @State private var pendingKeyDrop: KeyDropProposal?
    @State private var chipDrag: ChipDrag?
    /// Whether the current key-face drag started with ⌥ (decided once).
    @State private var keyDragStartedWithOption: Bool?
    @State private var keyFrames: [RemoteControl: CGRect] = [:]

    /// A chip being dragged inside the remote picture. This is an in-view
    /// drag (not a macOS drag session) so the pointer can show a hand for
    /// move and the copy pointer while Command is held.
    private struct ChipDrag {
        let token: String
        let preview: AnyView
        var location: CGPoint
        var isCopy: Bool
        /// True for an ⌥-drag of the whole key rather than one chip.
        var isWholeKey = false
    }

    var body: some View {
        device
            .padding(.top, 18)
            .confirmationDialog(
                pendingDrop.map(dropChoiceTitle) ?? "This key already has an action",
                isPresented: dropChoiceIsPresented,
                titleVisibility: .visible,
                presenting: pendingDrop
            ) { proposal in
                if proposal.canSwap {
                    Button("Swap") { resolvePendingDrop(swap: true) }
                }
                Button("Replace", role: .destructive) { resolvePendingDrop(swap: false) }
                Button("Cancel", role: .cancel) {
                    pendingDrop = nil
                    store.cancelMappingDrag()
                }
            } message: { proposal in
                Text(proposal.isCopy
                    ? "Replace erases the action on \(proposal.destinationControl.rawValue) and puts a copy there."
                    : proposal.canSwap
                    ? "Swap exchanges the actions. Replace moves this action and erases the one on \(proposal.destinationControl.rawValue)."
                    : "The other action has an incomplete application target, so it cannot be swapped. Replace erases it.")
            }
            .confirmationDialog(
                pendingKeyDrop.map { "\($0.target.rawValue) already has actions" } ?? "This key already has actions",
                isPresented: keyDropChoiceIsPresented,
                titleVisibility: .visible,
                presenting: pendingKeyDrop
            ) { proposal in
                if proposal.canSwap {
                    Button("Swap Keys") { resolvePendingKeyDrop(swap: true) }
                }
                Button("Replace", role: .destructive) { resolvePendingKeyDrop(swap: false) }
                Button("Cancel", role: .cancel) {
                    pendingKeyDrop = nil
                    store.cancelKeyDrag()
                }
            } message: { proposal in
                Text(proposal.isCopy
                    ? "Replace erases everything on \(proposal.target.rawValue) and puts a copy of \(proposal.drag.control.rawValue) there."
                    : proposal.canSwap
                    ? "Swap exchanges all actions and titles of \(proposal.drag.control.rawValue) and \(proposal.target.rawValue). Replace moves \(proposal.drag.control.rawValue) and erases \(proposal.target.rawValue)."
                    : "\(proposal.target.rawValue) has shortcuts that use \(proposal.drag.control.rawValue) as MOD, so they cannot be swapped. Replace erases \(proposal.target.rawValue).")
            }
    }

    private var keyDropChoiceIsPresented: Binding<Bool> {
        Binding(
            get: { pendingKeyDrop != nil },
            set: { isPresented in
                if !isPresented, pendingKeyDrop != nil {
                    pendingKeyDrop = nil
                    store.cancelKeyDrag()
                }
            }
        )
    }

    private func resolvePendingKeyDrop(swap: Bool) {
        guard let proposal = pendingKeyDrop else { return }
        pendingKeyDrop = nil
        if store.resolveKeyDrop(proposal, swap: swap) {
            store.selectedControl = proposal.target
        }
    }

    /// ⌥-drag on a key's face moves the whole key (all its actions and its
    /// title); add ⌘ to copy. Without ⌥ the key behaves as a normal button.
    private func wholeKeyDragGesture(_ control: RemoteControl) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(remoteSpace))
            .onChanged { value in
                let flags = NSEvent.modifierFlags
                let isCopy = flags.contains(.command)
                if keyDragStartedWithOption == nil {
                    keyDragStartedWithOption = flags.contains(.option)
                }
                if chipDrag == nil {
                    guard keyDragStartedWithOption == true,
                          let token = store.beginKeyDrag(from: control) else {
                        keyDragStartedWithOption = false // try once only
                        return
                    }
                    let preview = Text(control.rawValue)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    chipDrag = ChipDrag(token: token, preview: AnyView(preview), location: value.location, isCopy: isCopy, isWholeKey: true)
                }
                guard chipDrag?.isWholeKey == true else { return }
                chipDrag?.location = value.location
                chipDrag?.isCopy = isCopy
                dropTargetControl = keyFrames.first { $0.value.contains(value.location) }?.key
                (isCopy ? NSCursor.dragCopy : NSCursor.closedHand).set()
            }
            .onEnded { value in
                keyDragStartedWithOption = nil
                guard chipDrag?.isWholeKey == true else { return }
                finishChipDrag(at: value.location)
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
        .coordinateSpace(name: remoteSpace)
        .onPreferenceChange(KeyFramePreferenceKey.self) { keyFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let chipDrag {
                chipDrag.preview
                    .overlay(alignment: .topTrailing) {
                        if chipDrag.isCopy {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white, .green)
                                .offset(x: 6, y: -6)
                        }
                    }
                    .scaleEffect(1.25)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                    .position(chipDrag.location)
                    .allowsHitTesting(false)
            }
        }
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
        mapping.displayDetail
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
        let nonApplicationRoutes = store.standardNonApplicationRoutes(for: control)
        let routeSelection = standardApplicationRouteDisplaySelection(
            routes,
            hasNonApplicationMarkers: !nonApplicationRoutes.isEmpty
        )
        let nonApplicationMarkerSelection = standardNonApplicationMarkerDisplaySelection(
            nonApplicationRoutes,
            applicationHiddenCount: routeSelection.hiddenCount
        )
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

            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(HardwareKeyStyle(
            selected: store.selectedControl == control,
            live: store.liveControl == control
        ))
        .simultaneousGesture(wholeKeyDragGesture(control))
        // Chips sit above the button (matching HardwareKeyStyle's 5 pt label
        // inset) so each one can be dragged onto another key.
        .overlay {
            if !routes.isEmpty {
                applicationRouteStrip(
                    control,
                    routeSelection.visible,
                    hiddenCount: routeSelection.hiddenCount,
                    height: height,
                    reservesBottomRow: !nonApplicationRoutes.isEmpty
                )
                .padding(.horizontal, 5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !nonApplicationRoutes.isEmpty {
                standardNonApplicationMarkerStrip(control, nonApplicationMarkerSelection)
            }
        }
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
                hasMainWindowToggle: hasMainWindowToggle,
                nonApplicationMarkers: nonApplicationMarkerSelection
            )
        )
        .help(
            standardButtonAccessibilityLabel(
                control: control,
                title: title,
                routes: routes,
                hiddenCount: routeSelection.hiddenCount,
                hasMainWindowToggle: hasMainWindowToggle,
                nonApplicationMarkers: nonApplicationMarkerSelection
            )
        )
        .overlay {
            if dropTargetControl == control {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(chipDrag?.isCopy == true ? Color.green : Color.accentColor, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: KeyFramePreferenceKey.self,
                    value: [control: proxy.frame(in: .named(remoteSpace))]
                )
            }
        }
        // Inspector action cards still use a macOS drag session.
        .dropDestination(for: String.self) { tokens, _ in
            guard let token = tokens.first else { return false }
            switch store.dropMapping(token: token, onto: control, copy: NSEvent.modifierFlags.contains(.command)) {
            case .moved:
                store.selectedControl = control
                return true
            case .needsChoice(let proposal):
                pendingDrop = proposal
                return true
            case .rejected:
                return false
            }
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetControl = control
            } else if dropTargetControl == control {
                dropTargetControl = nil
            }
        }
    }

    private var dropChoiceIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDrop != nil },
            set: { isPresented in
                if !isPresented, pendingDrop != nil {
                    pendingDrop = nil
                    store.cancelMappingDrag()
                }
            }
        )
    }

    private func resolvePendingDrop(swap: Bool) {
        guard let proposal = pendingDrop else { return }
        pendingDrop = nil
        if store.resolveMappingDrop(proposal, swap: swap) {
            store.selectedControl = proposal.destinationControl
        }
    }

    private func dropChoiceTitle(_ proposal: MappingDropProposal) -> String {
        let gestures = proposal.occupiedGestures.map(\.rawValue).joined(separator: " and ")
        let layer = proposal.drag.modifierControls.isEmpty
            ? ""
            : RemoteControl.allCases.filter { proposal.drag.modifierControls.contains($0) }
                .map(\.rawValue).joined(separator: "+") + " "
        return "\(proposal.destinationControl.rawValue) already has a \(layer)\(gestures) action"
    }

    /// Lets a chip on a key be dragged onto another key. A plain click still
    /// selects the key underneath.
    private func draggableChip<Content: View>(
        _ control: RemoteControl,
        @ViewBuilder content: () -> Content,
        begin: @escaping () -> String?
    ) -> some View {
        let chip = content()
        return chip
            .contentShape(Rectangle())
            .onTapGesture { store.selectedControl = control }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(remoteSpace))
                    .onChanged { value in
                        let isCopy = NSEvent.modifierFlags.contains(.command)
                        if chipDrag == nil {
                            guard let token = begin() else { return }
                            chipDrag = ChipDrag(token: token, preview: AnyView(chip), location: value.location, isCopy: isCopy)
                        }
                        chipDrag?.location = value.location
                        chipDrag?.isCopy = isCopy
                        dropTargetControl = keyFrames.first { $0.value.contains(value.location) }?.key
                        (isCopy ? NSCursor.dragCopy : NSCursor.closedHand).set()
                    }
                    .onEnded { value in
                        finishChipDrag(at: value.location)
                    }
            )
            .onHover { inside in
                guard chipDrag == nil else { return }
                (inside ? NSCursor.openHand : NSCursor.arrow).set()
            }
            .help("Drag onto another K button to move this action. Hold ⌘ to copy it.")
    }

    private func finishChipDrag(at location: CGPoint) {
        defer {
            chipDrag = nil
            dropTargetControl = nil
            NSCursor.arrow.set()
        }
        guard let drag = chipDrag,
              let target = keyFrames.first(where: { $0.value.contains(location) })?.key else {
            store.cancelMappingDrag()
            store.cancelKeyDrag()
            return
        }
        let isCopy = NSEvent.modifierFlags.contains(.command)
        if drag.isWholeKey {
            switch store.dropKey(token: drag.token, onto: target, copy: isCopy) {
            case .moved:
                store.selectedControl = target
            case .needsChoice(let proposal):
                pendingKeyDrop = proposal
            case .rejected:
                store.cancelKeyDrag()
            }
            return
        }
        switch store.dropMapping(token: drag.token, onto: target, copy: isCopy) {
        case .moved:
            store.selectedControl = target
        case .needsChoice(let proposal):
            pendingDrop = proposal
        case .rejected:
            store.cancelMappingDrag()
        }
    }

    private func standardNonApplicationMarkerStrip(
        _ control: RemoteControl,
        _ selection: StandardNonApplicationMarkerDisplaySelection
    ) -> some View {
        HStack(spacing: standardNonApplicationMarkerGroupSpacing) {
            ForEach(selection.visible) { group in
                draggableChip(control) {
                    standardNonApplicationMarkerGroup(group)
                } begin: {
                    store.beginNonApplicationMarkerDrag(
                        from: control,
                        modifierControls: Set(group.modifierControls)
                    )
                }
            }

            if selection.hiddenCount > 0 {
                Text("+\(selection.hiddenCount)")
                    .font(.system(size: 5.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: standardNonApplicationMarkerOverflowWidth, height: 9)
                    .background(.black.opacity(0.70), in: Capsule())
            }

            if selection.applicationHiddenCount > 0 {
                Text("A+\(selection.applicationHiddenCount)")
                    .font(.system(size: 5.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(width: standardNonApplicationMarkerApplicationOverflowWidth, height: 9)
                    .background(.black.opacity(0.70), in: Capsule())
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // Clicks on the rail outside a chip still select the key.
        .onTapGesture { store.selectedControl = control }
        .frame(width: standardNonApplicationMarkerRailWidth, height: 18, alignment: .bottomTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 3)
        .padding(.trailing, standardNonApplicationMarkerTrailingInset)
        .accessibilityHidden(true)
    }

    private func standardNonApplicationMarkerGroup(
        _ group: StandardNonApplicationMarkerGroup
    ) -> some View {
        HStack(spacing: standardNonApplicationMarkerDotSpacing) {
            if group.isBase {
                standardNonApplicationMarkerDot(.white.opacity(0.92))
            } else {
                standardNonApplicationModeChip(
                    modifiers: group.modifierControls,
                    sequence: group.badge == .sequence
                )
            }
        }
    }

    private func standardNonApplicationModeChip(
        modifiers: [RemoteControl],
        sequence: Bool
    ) -> some View {
        let colors = modifierRouteColors(Set(modifiers))
        let fill = colors.count <= 1
            ? AnyShapeStyle((colors.first ?? ModifierColor.orange.swiftUIColor).opacity(0.9))
            : AnyShapeStyle(LinearGradient(colors: colors.map { $0.opacity(0.9) }, startPoint: .leading, endPoint: .trailing))
        return Circle()
            .fill(fill)
            .frame(
                width: standardNonApplicationMarkerModeChipWidth,
                height: standardNonApplicationMarkerModeChipHeight
            )
            .overlay {
                Text(sequence ? "S" : "H")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.82))
            }
            .overlay {
                Circle()
                    .stroke(.black.opacity(0.76), lineWidth: 0.55)
            }
    }

    private func standardNonApplicationMarkerDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay {
                Circle()
                    .stroke(.black.opacity(0.76), lineWidth: 0.55)
            }
            .frame(
                width: standardNonApplicationMarkerDotDiameter,
                height: standardNonApplicationMarkerDotDiameter
            )
    }

    private func applicationRouteStrip(
        _ control: RemoteControl,
        _ routes: [StandardApplicationRoute],
        hiddenCount: Int,
        height: CGFloat,
        reservesBottomRow: Bool = false
    ) -> some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    applicationRouteSlot(control, route(at: 0, in: routes))
                    Spacer(minLength: 0)
                    applicationRouteSlot(control, route(at: 1, in: routes))
                }

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    applicationRouteSlot(control, route(at: 2, in: routes))
                    Spacer(minLength: 0)
                    applicationRouteSlot(control, route(at: 3, in: routes))
                }
            }
            .padding(.horizontal, 3)
            // Keep the two route rows spatially distinct from the centered Kx.
            // Corner badges remain independent overlays at the key boundary.
            .padding(.vertical, 3)

            if hiddenCount > 0, !reservesBottomRow {
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
        .accessibilityHidden(true)
    }

    private func route(at index: Int, in routes: [StandardApplicationRoute]) -> StandardApplicationRoute? {
        guard routes.indices.contains(index) else { return nil }
        return routes[index]
    }

    @ViewBuilder
    private func applicationRouteSlot(_ control: RemoteControl, _ route: StandardApplicationRoute?) -> some View {
        let width: CGFloat = (route?.isBase == false) ? 29 : 18
        if let route {
            draggableChip(control) {
                applicationRouteIndicator(route)
                    .frame(width: width, height: 18)
            } begin: {
                store.beginApplicationRouteDrag(from: control, route: route)
            }
        } else {
            Color.clear
                .frame(width: width, height: 18)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func applicationRouteIndicator(_ route: StandardApplicationRoute) -> some View {
        if route.isBase {
            applicationRouteIcon(for: route.target, size: 14)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 2) {
                applicationRouteIcon(for: route.target, size: 13)
                Text(route.isSequenceCombo ? "S" : "H")
                    .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.82))
            }
            .padding(.horizontal, 3)
            .frame(height: 18)
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
        hasMainWindowToggle: Bool,
        nonApplicationMarkers: StandardNonApplicationMarkerDisplaySelection
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
            let mode = route.isSequenceCombo ? " sequence mode" : ""
            return "\(modifiers) \(target)\(mode)"
        }
        if !routeSummary.isEmpty {
            parts.append(routeSummary.joined(separator: "; "))
        }
        if hiddenCount > 0 {
            parts.append("\(hiddenCount) additional application route\(hiddenCount == 1 ? "" : "s") hidden")
        }
        let nonApplicationSummary = nonApplicationMarkers.visible.map { group in
            if group.isBase {
                return "Base non-application action layer"
            }
            let modifiers = group.modifierControls.map(\.rawValue).joined(separator: " + ")
            return "\(modifiers) non-application action layer"
        }
        if !nonApplicationSummary.isEmpty {
            parts.append(nonApplicationSummary.joined(separator: "; "))
        }
        if nonApplicationMarkers.hiddenCount > 0 {
            let count = nonApplicationMarkers.hiddenCount
            parts.append("\(count) additional non-application action layer\(count == 1 ? "" : "s") hidden")
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

enum StandardNonApplicationMarkerBadge: Equatable {
    case hold
    case sequence

    var label: String {
        switch self {
        case .hold: return "H"
        case .sequence: return "S"
        }
    }
}

private let remoteSpace = "XPd.remote"

private struct KeyFramePreferenceKey: PreferenceKey {
    static let defaultValue: [RemoteControl: CGRect] = [:]

    static func reduce(value: inout [RemoteControl: CGRect], nextValue: () -> [RemoteControl: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct StandardNonApplicationMarkerGroup: Equatable, Identifiable {
    let modifierControls: [RemoteControl]
    let isBase: Bool
    var badge: StandardNonApplicationMarkerBadge? = nil

    var id: String {
        isBase ? "base" : modifierControls.map(\.rawValue).joined(separator: "+")
    }
}

struct StandardNonApplicationMarkerDisplaySelection: Equatable {
    let visible: [StandardNonApplicationMarkerGroup]
    let hiddenCount: Int
    let applicationHiddenCount: Int
}

let standardNonApplicationMarkerRailWidth: CGFloat = 60
let standardNonApplicationMarkerTrailingInset: CGFloat = 2
private let standardNonApplicationMarkerDotDiameter: CGFloat = 5
private let standardNonApplicationMarkerDotSpacing: CGFloat = 0.5
private let standardNonApplicationMarkerGroupSpacing: CGFloat = 1
private let standardNonApplicationMarkerHorizontalPadding: CGFloat = 1
private let standardNonApplicationMarkerOverflowWidth: CGFloat = 8
private let standardNonApplicationMarkerApplicationOverflowWidth: CGFloat = 8

func standardNonApplicationMarkerDisplaySelection(
    _ routes: [StandardNonApplicationRoute],
    applicationHiddenCount: Int = 0
) -> StandardNonApplicationMarkerDisplaySelection {
    var containsBase = false
    var modifierSets = Set<Set<RemoteControl>>()
    var sequenceSets = Set<Set<RemoteControl>>()

    for route in routes {
        if route.isBase {
            containsBase = true
        } else if !route.modifierControls.isEmpty {
            modifierSets.insert(route.modifierControls)
            if route.isSequenceCombo {
                sequenceSets.insert(route.modifierControls)
            }
        }
    }

    var groups: [StandardNonApplicationMarkerGroup] = []
    if containsBase {
        groups.append(StandardNonApplicationMarkerGroup(modifierControls: [], isBase: true))
    }
    groups.append(contentsOf: modifierSets
        .sorted(by: standardNonApplicationModifierSetPrecedes)
        .map { set in
            StandardNonApplicationMarkerGroup(
                modifierControls: standardNonApplicationModifierOrder(set),
                isBase: false,
                badge: sequenceSets.contains(set) ? .sequence : .hold
            )
        })

    let contentWidth = standardNonApplicationMarkerRailWidth
        - (standardNonApplicationMarkerHorizontalPadding * 2)
    let allGroupsWidth = standardNonApplicationMarkerGroupsWidth(groups)
        + standardNonApplicationMarkerOverflowTailWidth(
            hasVisibleGroups: !groups.isEmpty,
            hasMarkerOverflow: false,
            hasApplicationOverflow: applicationHiddenCount > 0
        )
    if allGroupsWidth <= contentWidth {
        return StandardNonApplicationMarkerDisplaySelection(
            visible: groups,
            hiddenCount: 0,
            applicationHiddenCount: applicationHiddenCount
        )
    }

    // Reserve the overflow badge before choosing visible groups. Whole route
    // groups stay intact, so a combined MOD layer never loses a participant
    // dot; groups that cannot fit are represented by +N.
    let visibleWidth = contentWidth
        - standardNonApplicationMarkerOverflowTailWidth(
            hasVisibleGroups: true,
            hasMarkerOverflow: true,
            hasApplicationOverflow: applicationHiddenCount > 0
        )
    var usedWidth: CGFloat = 0
    var visible: [StandardNonApplicationMarkerGroup] = []
    for group in groups {
        let groupWidth = standardNonApplicationMarkerGroupWidth(group)
        let spacing = visible.isEmpty ? 0 : standardNonApplicationMarkerGroupSpacing
        guard usedWidth + spacing + groupWidth <= visibleWidth else { break }
        visible.append(group)
        usedWidth += spacing + groupWidth
    }

    return StandardNonApplicationMarkerDisplaySelection(
        visible: visible,
        hiddenCount: max(0, groups.count - visible.count),
        applicationHiddenCount: applicationHiddenCount
    )
}

private func standardNonApplicationMarkerOverflowTailWidth(
    hasVisibleGroups: Bool,
    hasMarkerOverflow: Bool,
    hasApplicationOverflow: Bool
) -> CGFloat {
    var width: CGFloat = 0
    var hasPreviousItem = hasVisibleGroups
    if hasMarkerOverflow {
        if hasPreviousItem { width += standardNonApplicationMarkerGroupSpacing }
        width += standardNonApplicationMarkerOverflowWidth
        hasPreviousItem = true
    }
    if hasApplicationOverflow {
        if hasPreviousItem { width += standardNonApplicationMarkerGroupSpacing }
        width += standardNonApplicationMarkerApplicationOverflowWidth
    }
    return width
}

private func standardNonApplicationMarkerGroupsWidth(
    _ groups: [StandardNonApplicationMarkerGroup]
) -> CGFloat {
    groups.enumerated().reduce(0) { width, item in
        let spacing = item.offset == 0 ? 0 : standardNonApplicationMarkerGroupSpacing
        return width + spacing + standardNonApplicationMarkerGroupWidth(item.element)
    }
}

private let standardNonApplicationMarkerModeChipWidth: CGFloat = 12
private let standardNonApplicationMarkerModeChipHeight: CGFloat = 12

private func standardNonApplicationMarkerGroupWidth(
    _ group: StandardNonApplicationMarkerGroup
) -> CGFloat {
    guard !group.isBase else {
        return standardNonApplicationMarkerDotDiameter
    }
    return standardNonApplicationMarkerModeChipWidth
}

func standardNonApplicationMarkerDisplayWidth(
    for selection: StandardNonApplicationMarkerDisplaySelection
) -> CGFloat {
    standardNonApplicationMarkerGroupsWidth(selection.visible)
        + standardNonApplicationMarkerOverflowTailWidth(
            hasVisibleGroups: !selection.visible.isEmpty,
            hasMarkerOverflow: selection.hiddenCount > 0,
            hasApplicationOverflow: selection.applicationHiddenCount > 0
        )
        + (standardNonApplicationMarkerHorizontalPadding * 2)
}

private func standardNonApplicationModifierOrder(
    _ modifiers: Set<RemoteControl>
) -> [RemoteControl] {
    RemoteControl.allCases.filter { modifiers.contains($0) }
}

private func standardNonApplicationModifierSetPrecedes(
    _ lhs: Set<RemoteControl>,
    _ rhs: Set<RemoteControl>
) -> Bool {
    if lhs.count != rhs.count { return lhs.count < rhs.count }

    let lhsOrder = RemoteControl.allCases.enumerated()
        .filter { lhs.contains($0.element) }
        .map(\.offset)
    let rhsOrder = RemoteControl.allCases.enumerated()
        .filter { rhs.contains($0.element) }
        .map(\.offset)
    return lhsOrder.lexicographicallyPrecedes(rhsOrder)
}

func standardApplicationRouteDisplaySelection(
    _ routes: [StandardApplicationRoute],
    hasNonApplicationMarkers: Bool = false
) -> (visible: [StandardApplicationRoute], hiddenCount: Int) {
    // Non-application markers own the full bottom row, so application icons
    // use only the two top-row slots while the rail is present.
    let capacity = hasNonApplicationMarkers ? 2 : 4
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
