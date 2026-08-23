import AppKit
import SwiftUI

struct MappingInspector: View {
    let store: MappingStore
    @State private var activeStandardEditorLayer: Set<RemoteControl>?
    @State private var showsStatusAndInput = false

    var body: some View {
        Group {
            if store.activeRealm == .midi {
                midiEditorBody
            } else {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected control")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedControlTitle)
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Text(store.selectedControl.isWheelRotation ? "Rotate" : store.selectedGesture.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            if store.selectedControl.isWheelRotation {
                wheelScrollEditor
            } else {
                mappingEditor
            }

            if let message = store.lastConfigurationResult.message {
                Label(
                    message,
                    systemImage: store.lastConfigurationResult.isSuccess
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(store.lastConfigurationResult.isSuccess ? Color.green : Color.orange)
                .lineLimit(2)
            }

            DisclosureGroup(isExpanded: $showsStatusAndInput) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        statusCard(title: "Current profile", value: store.profileName, detail: "local mappings")
                        statusCard(title: "Device", value: store.hid.isConnected ? "Connected" : "Offline", detail: "VID 10429 · PID 514")
                    }

            GroupBox("Live HID") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.hidBinding(for: store.selectedControl) ?? "No HID input learned")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                    }

                    HStack {
                        Button(store.learningControl == store.selectedControl ? "Waiting for input…" : "Learn selected control") {
                            store.learnSelectedControl()
                        }
                        .disabled(!store.hid.isConnected || !store.hid.hasInputAccess || store.learningControl != nil)

                        if store.hidBinding(for: store.selectedControl) != nil {
                            Button("Clear", role: .destructive) {
                                store.clearHIDBinding(for: store.selectedControl)
                            }
                        }

                        Button {
                            store.hid.openInputMonitoringSettings()
                        } label: {
                            Label("Input Monitoring", systemImage: "gear")
                        }
                        .help("Open Privacy & Security → Input Monitoring in System Settings")
                    }

                    if store.learningControl != nil {
                        Text("Press the matching control on the physical remote.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !store.hid.hasInputAccess {
                        Text("Allow XP[d] in System Settings › Privacy & Security › Input Monitoring, then relaunch.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(store.hid.lastEvent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(6)
            }

            if store.selectedControl == .wheelCenter {
                Label("Hold the center, rotate to highlight a profile, then release to confirm.", systemImage: "dial.medium")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            GroupBox("Input HUD") {
                HStack(spacing: 14) {
                    Toggle("Show HUD", isOn: Bindable(store).showsInputOverlay)

                    Divider()
                        .frame(height: 20)

                    Text("Disappear after")
                        .foregroundStyle(.secondary)

                    Picker("Disappear after", selection: Bindable(store).inputOverlayDuration) {
                        ForEach(MappingStore.inputOverlayDurationOptions, id: \.self) { duration in
                            Text("\(duration.formatted()) seconds").tag(duration)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 92)

                    Spacer()

                    Button {
                        store.previewInputOverlay()
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .disabled(!store.showsInputOverlay)
                }
                .padding(4)
            }

            GroupBox("Standard K modifiers") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Standalone hold threshold")
                        Spacer()
                        Text("\(store.standardModifierHoldThreshold, specifier: "%.1f") s")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                        Stepper(
                            value: Bindable(store).standardModifierHoldThreshold,
                            in: 0.2...1.5,
                            step: 0.1
                        ) { Text("Adjust standalone hold threshold") }
                        .labelsHidden()
                    }
                    Text("A designated K modifier runs its Base Tap action only after it remains held this long. Press another K before the threshold to use the modifier layer instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }
                }
                .padding(.top, 8)
            } label: {
                Text("Status & Input")
                    .font(.headline)
            }

            Spacer(minLength: 0)
        }
            }
        }
        .onChange(of: store.selectedControl) { _, _ in
            ensureModifierLayerSelection()
        }
        .onChange(of: store.selectedGesture) { _, _ in
            if store.isRemoteModifier(store.selectedControl), store.selectedGesture != .tap {
                store.selectedGesture = .tap
            }
        }
        .onChange(of: store.profileName) { _, _ in
            ensureModifierLayerSelection()
        }
        .onChange(of: store.remoteModifierControls) { _, _ in
            ensureModifierLayerSelection()
        }
        .onAppear(perform: ensureModifierLayerSelection)
    }

    // MARK: MIDI editor

    @State private var chordDraft = ""
    @State private var chordValidationMessage: String?

    private var midiEditorBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MIDI Lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selectedControlTitle)
                            .font(.title2.weight(.semibold))
                    }
                    Spacer()
                }

                Picker("Layer", selection: Bindable(store).selectedMIDILayer) {
                    Text("Primary Layer").tag(MIDIMappingLayer.primary)
                    Text("Fn Layer 2").tag(MIDIMappingLayer.function)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            Text(store.selectedMIDILayer == .function
                ? "Hold the assigned Fn control to play Layer 2. All Fn mappings are momentary."
                : "Primary MIDI mappings are available without holding Fn.")
                .font(.caption)
                .foregroundStyle(.secondary)

            fnAssignmentEditor

            if store.selectedControl.isWheelRotation {
                midiWheelEditor
            } else if store.selectedControl == .wheelCenter {
                Text("Select a K button or rotate the wheel to edit its MIDI mapping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                midiButtonEditor
            }

            midiStatusEditor
            midiMonitor

            if let message = store.lastConfigurationResult.message {
                Label(
                    message,
                    systemImage: store.lastConfigurationResult.isSuccess
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(store.lastConfigurationResult.isSuccess ? Color.green : Color.orange)
                .lineLimit(2)
            }

            midiLiveHID
            midiInputHUD
        }
        .onAppear {
            syncChordDraft()
            store.refreshMIDIEndpointStatus()
        }
        .onChange(of: store.selectedMIDILayer) { _, _ in syncChordDraft() }
        .onChange(of: store.selectedControl) { _, _ in syncChordDraft() }
    }

    private var midiButtonBinding: Binding<MIDIButtonMapping> {
        Binding(
            get: { store.midiButtonMapping(for: store.selectedControl, layer: store.selectedMIDILayer) },
            set: { store.updateMIDIButtonMapping($0, for: store.selectedControl, layer: store.selectedMIDILayer) }
        )
    }

    private var midiButtonEditor: some View {
        GroupBox("Button MIDI output") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Output", selection: midiButtonBinding.outputPort) {
                        ForEach(MIDIOutputPort.allCases) { port in
                            Text(port.displayName).tag(port)
                        }
                    }
                    Picker("Type", selection: midiButtonBinding.kind) {
                        ForEach(visibleButtonKinds) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                }

                HStack {
                    TextField("Channel", value: midiButtonBinding.channel, format: .number)
                        .frame(width: 88)
                    Text("Channel 1…16")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(store.selectedMIDILayer == .function ? "Hold Fn → Layer 2" : "Layer 1")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                switch midiButtonBinding.wrappedValue.kind {
                case .note:
                    HStack {
                        TextField("Note", value: midiButtonBinding.note, format: .number)
                        TextField("Velocity", value: midiButtonBinding.velocity, format: .number)
                        TextField("Release", value: midiButtonBinding.releaseVelocity, format: .number)
                    }
                    interactionPicker
                case .cc:
                    HStack {
                        TextField("CC", value: midiButtonBinding.controller, format: .number)
                        TextField("Press", value: midiButtonBinding.pressValue, format: .number)
                        TextField("Release", value: midiButtonBinding.releaseValue, format: .number)
                    }
                    interactionPicker
                case .program:
                    TextField("Program", value: midiButtonBinding.program, format: .number)
                case .chord:
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Chord notes (e.g. 60 64 67)", text: $chordDraft)
                            .onSubmit(commitChord)
                        Text("Enter 1…16 unique notes from 0…127.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let chordValidationMessage {
                            Text(chordValidationMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        TextField("Velocity", value: midiButtonBinding.velocity, format: .number)
                        TextField("Release", value: midiButtonBinding.releaseVelocity, format: .number)
                    }
                    interactionPicker
                case .noAction:
                    Text("This control will not emit a MIDI message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Label (optional)", text: midiButtonBinding.label)
                HStack {
                    Button {
                        store.sendMIDITestMessage(for: store.selectedControl, layer: store.selectedMIDILayer)
                    } label: {
                        Label("Send Test Message", systemImage: "paperplane")
                    }
                    .disabled(midiButtonBinding.wrappedValue.kind == .noAction)
                    Spacer()
                    Text("Click the type or value on the remote preview to edit this control.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(4)
        }
    }

    private var visibleButtonKinds: [MIDIButtonKind] {
        let allowed: [MIDIButtonKind] = store.selectedMIDILayer == .function
            ? [.note, .chord, .noAction]
            : MIDIButtonKind.allCases
        let current = midiButtonBinding.wrappedValue.kind
        return allowed.contains(current) ? allowed : [current] + allowed
    }

    private var interactionPicker: some View {
        Picker("Interaction", selection: midiButtonBinding.interaction) {
            ForEach(MIDIButtonInteraction.allCases) { interaction in
                Text(interaction.rawValue).tag(interaction)
            }
        }
        .pickerStyle(.segmented)
    }

    private var midiWheelBinding: Binding<MIDIWheelMapping> {
        Binding(
            get: { store.midiWheelMapping(for: store.selectedMIDILayer) },
            set: { store.updateMIDIWheelMapping($0, layer: store.selectedMIDILayer) }
        )
    }

    private var midiWheelEditor: some View {
        GroupBox("Wheel MIDI output") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Type", selection: midiWheelBinding.kind) {
                        ForEach(MIDIWheelKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    Picker("Output", selection: midiWheelBinding.outputPort) {
                        ForEach(MIDIOutputPort.allCases) { port in Text(port.displayName).tag(port) }
                    }
                }

                if midiWheelBinding.wrappedValue.kind != .noAction {
                    HStack {
                        TextField("Channel", value: midiWheelBinding.channel, format: .number)
                        if midiWheelBinding.wrappedValue.kind != .pitchBendNudgeReturn {
                            TextField("Controller", value: midiWheelBinding.controller, format: .number)
                        }
                    }
                }

                switch midiWheelBinding.wrappedValue.kind {
                case .relativeCC:
                    Picker("Relative encoding", selection: midiWheelBinding.relativeEncoding) {
                        ForEach(MIDIRelativeEncoding.allCases) { value in Text(value.rawValue).tag(value) }
                    }
                    HStack {
                        TextField("Clockwise", value: midiWheelBinding.clockwiseValue, format: .number)
                        TextField("Counter-clockwise", value: midiWheelBinding.counterClockwiseValue, format: .number)
                    }
                case .absoluteCC:
                    TextField("Step", value: midiWheelBinding.stepSize, format: .number)
                case .pitchBendNudgeReturn:
                    TextField("Pitch step", value: midiWheelBinding.pitchBendStep, format: .number)
                    HStack {
                        TextField("Return delay (s)", value: midiWheelBinding.returnDelay, format: .number)
                        TextField("Return duration (s)", value: midiWheelBinding.returnDuration, format: .number)
                    }
                    Text("Set the musical bend range in the receiving instrument.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .transpose:
                    TextField("Transpose step (semitones)", value: midiWheelBinding.transposeSemitones, format: .number)
                case .drumBank:
                    TextField("Drum bank step", value: midiWheelBinding.drumBankStep, format: .number)
                case .noAction:
                    Text("The wheel is inactive in this layer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if midiWheelBinding.wrappedValue.kind != .noAction {
                    Toggle("Reverse direction", isOn: midiWheelBinding.reversedDirection)
                }
                TextField("Label (optional)", text: midiWheelBinding.label)
            }
            .textFieldStyle(.roundedBorder)
            .padding(4)
        }
    }

    private var fnAssignmentEditor: some View {
        GroupBox("Fn control") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Fn control", selection: fnSelectionBinding) {
                    Text("None").tag("None")
                    ForEach(RemoteControl.allCases.filter { $0.isMIDIEligibleFnControl }) { control in
                        Text(control.rawValue).tag(control.rawValue)
                    }
                }
                HStack {
                    Text("Fn hold threshold")
                    Spacer()
                    Stepper(value: fnHoldThresholdBinding, in: 0.10...3.0, step: 0.05) {
                        Text("\(fnHoldThresholdBinding.wrappedValue, specifier: "%.2f") s")
                            .monospacedDigit()
                    }
                    .labelsHidden()
                }
                Text("A center-as-Fn press becomes Layer 2 after this momentary hold duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Fn is momentary-only: hold it to activate Layer 2, then release to return to Primary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.fnControl == .wheelCenter {
                    Text("Center tap still opens the profile selector; a held center activates Fn. Reliable center hold/release still requires target-remote verification.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }

    private var fnSelectionBinding: Binding<String> {
        Binding(
            get: { store.fnControl?.rawValue ?? "None" },
            set: { rawValue in
                _ = store.updateMIDIPracticeFnControl(RemoteControl(rawValue: rawValue))
            }
        )
    }

    private var fnHoldThresholdBinding: Binding<TimeInterval> {
        Binding(
            get: {
                store.midiSettings?.fnHoldThreshold ?? MIDIProfileSettings.defaultFnHoldThreshold
            },
            set: { threshold in
                _ = store.updateMIDIHoldThreshold(threshold)
            }
        )
    }

    private var midiStatusEditor: some View {
        GroupBox("MIDI status") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(MIDIOutputPort.allCases) { port in
                    let status = store.midiEndpointStatus[port]
                    HStack(spacing: 7) {
                        Circle()
                            .fill(status?.isAvailable == true ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(port.displayName)
                            .font(.caption.weight(.medium))
                        Text(status?.isAvailable == true ? "available" : (status?.error ?? "unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                if let message = store.lastMIDIMessage {
                    Label("Last: \(message.summary)", systemImage: "waveform")
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    Text("Last MIDI message: none")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = store.lastMIDIError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                HStack {
                    Button("Refresh endpoints") { store.refreshMIDIEndpointStatus() }
                    Spacer()
                    Button("Panic", role: .destructive) { store.panicMIDI() }
                }
            }
            .padding(4)
        }
    }

    private var midiMonitor: some View {
        GroupBox("MIDI monitor") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Newest first · actual XP[d] send attempts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { copyMIDIMonitor() }
                        .disabled(store.midiMonitorEvents.isEmpty)
                    Button("Clear") { store.clearMIDIMonitor() }
                        .disabled(store.midiMonitorEvents.isEmpty)
                }

                if store.midiMonitorEvents.isEmpty {
                    ContentUnavailableView(
                        "No MIDI messages yet",
                        systemImage: "waveform",
                        description: Text("Press the remote or use Send Test Message.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(store.midiMonitorEvents) { event in
                                midiMonitorRow(event)
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
            .padding(4)
        }
    }

    private func midiMonitorRow(_ event: MIDIOutputService.MonitorEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                Text(event.outcome.rawValue)
                    .foregroundStyle(event.outcome == .sent ? Color.green : Color.orange)
                Text(event.port == .control ? "CONTROL" : "PERFORMANCE")
                    .foregroundStyle(.secondary)
                Text(event.summary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(event.umpHex)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let error = event.error {
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .font(.caption.monospaced())
        .padding(.vertical, 2)
    }

    private func copyMIDIMonitor() {
        let text = store.midiMonitorEvents.map { event in
            let error = event.error.map { " · \($0)" } ?? ""
            return "\(event.timestamp.ISO8601Format()) · \(event.outcome.rawValue) · \(event.port.displayName) · \(event.summary) · \(event.umpHex)\(error)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var midiLiveHID: some View {
        GroupBox("Live HID") {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.hidBinding(for: store.selectedControl) ?? "No HID input learned")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                HStack {
                    Button(store.learningControl == store.selectedControl ? "Waiting for input…" : "Learn selected control") {
                        store.learnSelectedControl()
                    }
                    .disabled(!store.hid.isConnected || !store.hid.hasInputAccess || store.learningControl != nil)
                    if store.hidBinding(for: store.selectedControl) != nil {
                        Button("Clear", role: .destructive) { store.clearHIDBinding(for: store.selectedControl) }
                    }
                    Button("Input Monitoring") { store.hid.openInputMonitoringSettings() }
                }
                Text(store.hid.lastEvent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(4)
        }
    }

    private var midiInputHUD: some View {
        GroupBox("Input HUD") {
            HStack(spacing: 10) {
                Toggle("Show HUD", isOn: Bindable(store).showsInputOverlay)
                Picker("Hide after", selection: Bindable(store).inputOverlayDuration) {
                    ForEach(MappingStore.inputOverlayDurationOptions, id: \.self) { duration in
                        Text("\(duration.formatted()) s").tag(duration)
                    }
                }
                .pickerStyle(.menu)
                Button("Preview") { store.previewInputOverlay() }
                    .disabled(!store.showsInputOverlay)
            }
            .padding(4)
        }
    }

    private func syncChordDraft() {
        guard store.activeRealm == .midi, !store.selectedControl.isWheelRotation,
              store.selectedControl != .wheelCenter else { return }
        chordDraft = store.midiButtonMapping(for: store.selectedControl, layer: store.selectedMIDILayer).chord
            .map(String.init).joined(separator: " ")
        chordValidationMessage = nil
    }

    private func commitChord() {
        let parts = chordDraft.split(whereSeparator: { $0 == " " || $0 == "," })
        let notes = parts.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= MIDIButtonMapping.maxChordNotes,
              notes.count == parts.count,
              notes.allSatisfy({ (0...127).contains($0) }), Set(notes).count == notes.count else {
            chordValidationMessage = "Use 1…16 unique integer notes from 0…127."
            return
        }
        var mapping = midiButtonBinding.wrappedValue
        mapping.chord = notes
        store.updateMIDIButtonMapping(mapping, for: store.selectedControl, layer: store.selectedMIDILayer)
        chordValidationMessage = nil
    }

    private var mappingEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                if isStandardButtonTitleEligible {
                    TextField("Button title (optional)", text: standardButtonTitleBinding)
                        .textFieldStyle(.roundedBorder)
                }

                if isStandardModifierEligible {
                    standardModifierEditor
                }

                if isStandardLayerEligible {
                    HStack(alignment: .top, spacing: 16) {
                        StandardMappingActionEditor(
                            store: store,
                            modifierControls: [],
                            title: "Base Action",
                            activeCaptureLayer: $activeStandardEditorLayer
                        )

                        Divider()

                        StandardMappingActionEditor(
                            store: store,
                            modifierControls: store.selectedMappingModifiers,
                            title: "\(mappingLayerLabel) Action",
                            layerPicker: AnyView(mappingLayerPicker),
                            activeCaptureLayer: $activeStandardEditorLayer
                        )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    StandardMappingActionEditor(
                        store: store,
                        modifierControls: [],
                        title: nil,
                        activeCaptureLayer: $activeStandardEditorLayer
                    )
                }

                actionResult

                gestureEditor

                persistenceResult
            }
            .padding(4)
        }
    }

    private var wheelScrollEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Action")
                    Spacer()
                    Text("Scroll up and down")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sensitivity")
                            .font(.headline)
                        Spacer()
                        Text(Int(store.wheelSensitivity).formatted())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: Bindable(store).wheelSensitivity,
                        in: WheelScrollSettings.minimumSensitivity...WheelScrollSettings.maximumSensitivity,
                        step: 1
                    )

                    HStack {
                        Text("Less")
                        Spacer()
                        Text("More")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text("Counter-clockwise scrolls up. Clockwise scrolls down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(
                    store.canPostScrollEvents
                        ? "Scrolling access is enabled"
                        : "Allow XP[d] in Accessibility to enable scrolling",
                    systemImage: store.canPostScrollEvents
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(store.canPostScrollEvents ? Color.green : Color.orange)

                HStack(spacing: 10) {
                    Button("Request Scrolling Access") {
                        store.requestScrollingAccess()
                    }
                    Button("Open Accessibility Settings") {
                        store.openAccessibilitySettings()
                    }
                }

                actionResult
                persistenceResult
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var actionResult: some View {
        if let result = store.lastActionResult {
            Label(
                result.message,
                systemImage: result.succeeded
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(result.succeeded ? Color.green : Color.orange)
            .lineLimit(2)
        }
    }

    @ViewBuilder
    private var persistenceResult: some View {
        if let message = store.lastPersistenceResult.message {
            Label(
                message,
                systemImage: store.lastPersistenceResult.succeeded
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(store.lastPersistenceResult.succeeded ? Color.green : Color.orange)
        }
    }

    @ViewBuilder
    private var standardModifierEditor: some View {
        HStack(spacing: 10) {
            Toggle(
                "K modifier",
                isOn: Binding(
                    get: { store.isRemoteModifier(store.selectedControl) },
                    set: { _ = store.setRemoteModifier(store.selectedControl, enabled: $0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.isRemoteModifier(store.selectedControl) {
                Text("Hold alone for Base Tap; combine with another K for its layer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mappingLayerPicker: some View {
        Menu {
            ForEach(availableMappingModifiers) { control in
                Toggle(
                    control.rawValue,
                    isOn: Binding(
                        get: { store.selectedMappingModifiers.contains(control) },
                        set: { enabled in
                            var selected = store.selectedMappingModifiers
                            if enabled {
                                selected.insert(control)
                            } else if selected.count > 1 {
                                selected.remove(control)
                            }
                            store.selectedMappingModifiers = selected
                        }
                    )
                )
            }
        } label: {
            Label(mappingLayerLabel, systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the modifier layer shown in the right column")
    }

    private var availableMappingModifiers: [RemoteControl] {
        RemoteControl.allCases.filter {
            store.isRemoteModifier($0) && $0 != store.selectedControl
        }
    }

    private func ensureModifierLayerSelection() {
        guard isStandardLayerEligible else { return }
        let available = Set(availableMappingModifiers)
        let selected = store.selectedMappingModifiers.intersection(available)
        if selected.isEmpty, let first = availableMappingModifiers.first {
            store.selectedMappingModifiers = [first]
        } else if selected != store.selectedMappingModifiers {
            store.selectedMappingModifiers = selected
        }
    }

    private var gestureEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Gesture")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.isRemoteModifier(store.selectedControl) {
                Text("Hold alone · combine with K for layer")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Picker("Gesture", selection: Bindable(store).selectedGesture) {
                    ForEach(GestureKind.allCases) { gesture in
                        Text(gesture.rawValue).tag(gesture)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
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

    private var selectedControlTitle: String {
        store.selectedControl.isWheelRotation ? "Wheel" : store.selectedControl.rawValue
    }

    private var isStandardButtonTitleEligible: Bool {
        store.activeRealm == .standard && store.selectedControl.isMIDIButton
    }

    private var isStandardModifierEligible: Bool {
        store.activeRealm == .standard && store.selectedControl.isModifierEligible
    }

    private var isStandardLayerEligible: Bool {
        isStandardButtonTitleEligible
            && !store.isRemoteModifier(store.selectedControl)
            && !store.remoteModifierControls.isEmpty
    }

    private var mappingLayerLabel: String {
        guard !store.selectedMappingModifiers.isEmpty else { return "Base" }
        return RemoteControl.allCases
            .filter { store.selectedMappingModifiers.contains($0) }
            .map(\.rawValue)
            .joined(separator: " + ")
    }

    private var standardButtonTitleBinding: Binding<String> {
        Binding(
            get: { store.standardButtonTitle(for: store.selectedControl) },
            set: { store.updateStandardButtonTitle($0, for: store.selectedControl) }
        )
    }

}

private struct StandardMappingActionEditor: View {
    let store: MappingStore
    let modifierControls: Set<RemoteControl>
    let title: String?
    var layerPicker: AnyView? = nil
    @Binding var activeCaptureLayer: Set<RemoteControl>?

    @State private var isEditingCommand = false
    @State private var shortcutCaptureCancellation = 0
    @State private var remoteTriggerCaptureCancellation = 0
    @FocusState private var isCommandFieldFocused: Bool

    private var binding: Binding<Mapping> {
        Binding(
            get: {
                store.mapping(
                    for: store.selectedControl,
                    gesture: store.selectedGesture,
                    modifierControls: modifierControls
                )
            },
            set: {
                store.update(
                    $0,
                    for: store.selectedControl,
                    gesture: store.selectedGesture,
                    modifierControls: modifierControls
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || layerPicker != nil {
                HStack(spacing: 8) {
                    if let title {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    layerPicker
                }
            }

            Picker("Action", selection: actionBinding) {
                ForEach(ActionKind.allCases) { action in
                    Text(action.rawValue).tag(action)
                }
            }

            if isTapInheritanceEligible {
                tapApplicationEditor
            } else {
                commandEditor
            }

            if store.activeRealm == .standard, store.selectedControl.isMIDIButton {
                remoteTriggerEditor
            }

            if isApplicationAction {
                Text("Use an app name, bundle ID, or .app path. Toggle application requires Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: store.selectedControl) { _, _ in cancelEditing() }
        .onChange(of: store.selectedGesture) { _, _ in cancelEditing() }
        .onChange(of: modifierControls) { _, _ in cancelEditing() }
        .onChange(of: store.profileName) { _, _ in cancelEditing() }
        .onChange(of: selectedAction) { _, _ in
            cancelEditing()
        }
        .onChange(of: activeCaptureLayer) { _, activeLayer in
            if let activeLayer, activeLayer != modifierControls {
                cancelEditing()
            }
        }
        .onChange(of: isCommandFieldFocused) { _, isFocused in
            if !isFocused { isEditingCommand = false }
        }
    }

    @ViewBuilder
    private var commandEditor: some View {
        switch selectedAction {
        case .keyboardShortcut:
            KeyboardShortcutCaptureField(
                command: commandBinding,
                shortcut: binding.keyboardShortcut,
                cancellationGeneration: shortcutCaptureCancellation,
                onRecordingChange: updateCaptureState
            )
        case .openApplication, .toggleApplication, .macOSShortcut:
            singleLineCommandEditor
        case .appleScript:
            multilineCommandEditor(
                label: "AppleScript",
                placeholder: "tell application \"Finder\" to activate"
            )
        case .shellCommand:
            multilineCommandEditor(
                label: "Shell command",
                placeholder: "Enter a zsh command"
            )
            Text("Runs with your macOS user permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mediaControl:
            Picker("Media action", selection: mediaActionBinding) {
                Text("Choose media action…").tag(nil as MediaControlAction?)
                ForEach(MediaControlAction.allCases) { action in
                    Text(action.rawValue).tag(action as MediaControlAction?)
                }
            }
        case .windowDisplay:
            Picker("Window / display", selection: windowDisplayActionBinding) {
                Text("Choose window action…").tag(nil as WindowDisplayAction?)
                ForEach(WindowDisplayAction.allCases) { action in
                    Text(action.rawValue).tag(action as WindowDisplayAction?)
                }
            }
            if let windowAction = WindowDisplayAction(rawValue: binding.wrappedValue.command),
               windowAction != .sleepDisplays {
                Text("Frontmost-window actions may require Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .switchProfile:
            Picker("Profile", selection: profileActionBinding) {
                Text("Choose profile…").tag(nil as String?)
                ForEach(store.availableProfiles, id: \.self) { profile in
                    Text(profile).tag(profile as String?)
                }
            }
        case .noAction:
            Text("This mapping will not perform an action.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if selectedAction.isProcessBackedAutomation {
            automationConsentEditor
        }
    }

    private var singleLineCommandEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commandFieldLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isEditingCommand {
                TextField(commandPlaceholder, text: commandBinding)
                    .focused($isCommandFieldFocused)
                    .onSubmit(cancelEditing)
                    .onExitCommand(perform: cancelEditing)
            } else {
                Button(action: beginCommandEditing) {
                    HStack(spacing: 0) {
                        Text(commandDisplayValue)
                            .foregroundStyle(binding.wrappedValue.command.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(commandFieldLabel.lowercased())")
                .help("Click to edit")
            }
        }
    }

    private func multilineCommandEditor(label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: commandBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 76)
                    .scrollContentBackground(.hidden)
                    .padding(3)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                if binding.wrappedValue.command.isEmpty {
                    Text(placeholder)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var remoteTriggerEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Remote trigger")
                .font(.caption)
                .foregroundStyle(.secondary)
            RemoteTriggerChordCaptureField(
                selectedControl: store.selectedControl,
                currentModifiers: binding.wrappedValue.remoteTriggerModifiers,
                currentFunctionKey: binding.wrappedValue.remoteTriggerFunctionKey,
                cancellationGeneration: remoteTriggerCaptureCancellation,
                beginCapture: { callback in
                    store.beginRemoteTriggerCapture(onRemoteButton: callback)
                },
                endCapture: store.endRemoteTriggerCapture,
                onCommit: { control, modifiers, functionKey in
                    let gesture = store.selectedGesture
                    var mapping = store.mapping(
                        for: control,
                        gesture: gesture,
                        modifierControls: modifierControls
                    )
                    mapping.remoteTriggerModifiers = modifiers
                    mapping.remoteTriggerFunctionKey = functionKey
                    store.update(
                        mapping,
                        for: control,
                        gesture: gesture,
                        modifierControls: modifierControls
                    )
                    store.selectedControl = control
                },
                onRecordingChange: updateCaptureState
            )
        }
    }

    private var tapApplicationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use same application as Tap", isOn: binding.usesTapApplication)

            if binding.wrappedValue.usesTapApplication {
                switch store.inheritedTapApplication(
                    for: store.selectedControl,
                    modifierControls: modifierControls
                ) {
                case let .success(application):
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Inherited from Tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(application)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                    }
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else {
                commandEditor
            }
        }
    }

    private var selectedAction: ActionKind {
        binding.wrappedValue.action
    }

    private var actionBinding: Binding<ActionKind> {
        Binding(
            get: { binding.wrappedValue.action },
            set: { action in
                binding.wrappedValue = binding.wrappedValue.selectingAction(
                    action,
                    profileName: store.profileName
                )
            }
        )
    }

    private var commandBinding: Binding<String> {
        Binding(
            get: { binding.wrappedValue.command },
            set: { command in
                binding.wrappedValue = binding.wrappedValue.editingCommand(command)
            }
        )
    }

    private var mediaActionBinding: Binding<MediaControlAction?> {
        Binding(
            get: { MediaControlAction(rawValue: binding.wrappedValue.command) },
            set: { action in
                guard let action else { return }
                binding.wrappedValue = binding.wrappedValue.editingCommand(action.rawValue)
            }
        )
    }

    private var windowDisplayActionBinding: Binding<WindowDisplayAction?> {
        Binding(
            get: { WindowDisplayAction(rawValue: binding.wrappedValue.command) },
            set: { action in
                guard let action else { return }
                binding.wrappedValue = binding.wrappedValue.editingCommand(action.rawValue)
            }
        )
    }

    private var profileActionBinding: Binding<String?> {
        Binding(
            get: {
                let command = binding.wrappedValue.command
                return store.availableProfiles.contains(command) ? command : nil
            },
            set: { profile in
                guard let profile else { return }
                binding.wrappedValue = binding.wrappedValue.editingCommand(profile)
            }
        )
    }

    private var isApplicationAction: Bool {
        selectedAction.isApplicationAction
    }

    private var isTapInheritanceEligible: Bool {
        (store.selectedGesture == .hold || store.selectedGesture == .doubleTap)
            && isApplicationAction
    }

    private var commandPlaceholder: String {
        switch selectedAction {
        case .openApplication, .toggleApplication:
            "Application name (for example, ChatGPT)"
        case .macOSShortcut:
            "Name from the Shortcuts app"
        default:
            "Command"
        }
    }

    private var commandFieldLabel: String {
        switch selectedAction {
        case .openApplication, .toggleApplication:
            "Application"
        case .macOSShortcut:
            "Shortcut name"
        default:
            "Command"
        }
    }

    private var commandDisplayValue: String {
        let command = binding.wrappedValue.command
        return command.isEmpty ? commandPlaceholder : command
    }

    private func beginCommandEditing() {
        isEditingCommand = true
        Task { @MainActor in
            isCommandFieldFocused = true
        }
    }

    private var automationConsentEditor: some View {
        let mapping = binding.wrappedValue
        let hasCommand = !mapping.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mapping.automationEnabled ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(mapping.automationEnabled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mapping.automationEnabled ? "Automation enabled" : "Review required")
                        .font(.caption.weight(.semibold))
                    Text(mapping.automationEnabled
                         ? "This \(selectedAction.automationDisplayName) may run from the remote."
                         : "Stored content is preserved but will not run until enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(mapping.automationEnabled ? "Disable" : "Enable automation") {
                    var updated = binding.wrappedValue
                    updated.automationEnabled.toggle()
                    binding.wrappedValue = updated
                }
                .buttonStyle(.bordered)
                .disabled(!hasCommand)
            }
        }
    }

    private func cancelEditing() {
        isCommandFieldFocused = false
        isEditingCommand = false
        shortcutCaptureCancellation &+= 1
        remoteTriggerCaptureCancellation &+= 1
    }

    private func updateCaptureState(_ isRecording: Bool) {
        if isRecording {
            activeCaptureLayer = modifierControls
        } else if activeCaptureLayer == modifierControls {
            activeCaptureLayer = nil
        }
    }
}
