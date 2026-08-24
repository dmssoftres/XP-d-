import AppKit
import SwiftUI

struct MappingInspector: View {
    let store: MappingStore
    @State private var activeStandardEditorLayer: Set<RemoteControl>?
    @State private var selectedModifierGesture: GestureKind = .tap
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
                Text(headerGestureLabel)
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
                        statusCard(
                            title: "Device",
                            value: deviceControlStatus,
                            detail: store.hid.hasExclusiveControl ? "Exclusive control" : "Factory input not blocked"
                        )
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
                        .disabled(!store.hid.isConnected || !store.hid.hasInputAccess || !store.hid.hasExclusiveControl || store.learningControl != nil)

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
                    } else if let result = store.lastHIDLearningResult {
                        Label(
                            result.message,
                            systemImage: result.succeeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if !store.hid.hasInputAccess {
                        Text("Allow XP[d] in System Settings › Privacy & Security › Input Monitoring, then relaunch.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if !store.hid.hasExclusiveControl {
                        Text("XP[d] could not take exclusive control. Factory remote shortcuts are not safely blocked.")
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

            GroupBox("Raw HID trace") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Decoder input · oldest first. Repeated and empty reports are shown before interpretation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.hid.rawReportTrace.isEmpty {
                        Text("No raw reports received yet.")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(store.hid.rawReportTrace.enumerated()), id: \.offset) { _, report in
                                    Text(report)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 132)
                    }
                }
                .padding(6)
            }

            standardHIDCompatibility

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
                    Text("A designated K held alone runs its Base Tap when this timer expires. Press a destination K while the modifier is still held and before the timer expires to run that exact layer instead.")
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
            resetModifierGestureSelection()
            ensureModifierLayerSelection()
        }
        .onChange(of: store.selectedGesture) { _, _ in
            if store.isRemoteModifier(store.selectedControl), store.selectedGesture != .tap {
                store.selectedGesture = .tap
            }
        }
        .onChange(of: store.profileName) { _, _ in
            resetModifierGestureSelection()
            ensureModifierLayerSelection()
        }
        .onChange(of: store.selectedMappingModifiers) { _, _ in
            resetModifierGestureSelection()
        }
        .onChange(of: store.remoteModifierControls) { _, _ in
            resetModifierGestureSelection()
            ensureModifierLayerSelection()
        }
        .onChange(of: savedMappingModifierLayers) { _, _ in
            ensureModifierLayerSelection()
        }
        .onAppear(perform: ensureModifierLayerSelection)
    }

    private var deviceControlStatus: String {
        if !store.hid.hasInputAccess { return "Permission required" }
        if !store.hid.hasExclusiveControl { return "Control unavailable" }
        return store.hid.isConnected ? "Connected" : "Offline"
    }

    @ViewBuilder
    private var standardHIDCompatibility: some View {
        if store.activeRealm == .standard {
            let kControls = RemoteControl.allCases.filter(\.isMIDIButton)
            let learnedCount = kControls.reduce(into: 0) { count, control in
                if store.hidBinding(for: control)
                    .flatMap(HIDKeyboardReport.init(signature:))?
                    .isCompatibleIndividualBinding == true {
                    count += 1
                }
            }
            let invalidCount = kControls.reduce(into: 0) { count, control in
                guard let binding = store.hidBinding(for: control),
                      let report = HIDKeyboardReport(signature: binding),
                      !report.isCompatibleIndividualBinding else {
                    return
                }
                count += 1
            }
            let collisions = store.standardHIDCollisions()
            let rolloverCollisions = store.standardHIDRolloverCollisions()

            GroupBox("K-input compatibility") {
                VStack(alignment: .leading, spacing: 6) {
                    if learnedCount == kControls.count && invalidCount == 0
                        && collisions.isEmpty && rolloverCollisions.isEmpty {
                        Label("All ten learned K inputs are independent.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if collisions.isEmpty && rolloverCollisions.isEmpty {
                        Text("Learned \(learnedCount) of \(kControls.count) compatible individual K inputs. Learn all ten to verify compatibility.")
                            .foregroundStyle(.secondary)
                        if invalidCount > 0 {
                            Text("\(invalidCount) saved input(s) are composite or empty report-2 states, not individual one-hot K bindings.")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        if !collisions.isEmpty {
                            Text("Learned keyboard assignments overlap:")
                                .foregroundStyle(.orange)
                            ForEach(collisions, id: \.self) { collision in
                                Text("• \(collision.firstControl.rawValue) held → \(collision.hiddenControl.rawValue) hidden")
                            }
                        }
                        if !rolloverCollisions.isEmpty {
                            Text("Some learned pairs exceed six-key boot-keyboard rollover:")
                                .foregroundStyle(.orange)
                            ForEach(rolloverCollisions, id: \.self) { collision in
                                Text("• \(collision.firstControl.rawValue) + \(collision.secondControl.rawValue) require \(collision.combinedOrdinaryKeyCount) ordinary keys")
                            }
                        }
                        if invalidCount > 0 {
                            Text("\(invalidCount) saved input(s) are composite or empty report-2 states, not individual one-hot K bindings.")
                                .foregroundStyle(.orange)
                        }
                        Text("This is inferred from the learned report-2 or report-6 bindings, not a live hardware observation. Relearn affected buttons with distinct shortcuts in the remote settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(4)
            }
        }
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
                    .disabled(!store.hid.isConnected || !store.hid.hasInputAccess || !store.hid.hasExclusiveControl || store.learningControl != nil)
                    if store.hidBinding(for: store.selectedControl) != nil {
                        Button("Clear", role: .destructive) { store.clearHIDBinding(for: store.selectedControl) }
                    }
                    Button("Input Monitoring") { store.hid.openInputMonitoringSettings() }
                }
                if store.learningControl != nil {
                    Text("Press the matching control on the physical remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let result = store.lastHIDLearningResult {
                    Label(
                        result.message,
                        systemImage: result.succeeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !store.hid.hasExclusiveControl, store.hid.hasInputAccess {
                    Text("Exclusive control unavailable · factory input not blocked")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(store.hid.lastEvent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                    standardLayerCollisionWarning

                    HStack(alignment: .top, spacing: 16) {
                        StandardMappingActionEditor(
                            store: store,
                            modifierControls: [],
                            title: "Base Action",
                            gesture: store.selectedGesture,
                            activeCaptureLayer: $activeStandardEditorLayer
                        )

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            standardModifierLayerSelector
                            modifierGestureEditor

                            StandardMappingActionEditor(
                                store: store,
                                modifierControls: store.selectedMappingModifiers,
                                title: "\(mappingLayerLabel) Action",
                                gesture: selectedModifierGesture,
                                isEditable: selectedModifierLayerIsActive,
                                activeCaptureLayer: $activeStandardEditorLayer
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    StandardMappingActionEditor(
                        store: store,
                        modifierControls: [],
                        title: nil,
                        gesture: store.selectedGesture,
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

    @ViewBuilder
    private var standardLayerCollisionWarning: some View {
        let collisions = store.standardModifierHIDCollisions(
            for: store.selectedControl,
            modifierControls: store.selectedMappingModifiers
        )
        let rolloverCollisions = store.standardHIDRolloverCollisions().filter { collision in
            (collision.firstControl == store.selectedControl
                && store.selectedMappingModifiers.contains(collision.secondControl))
                || (collision.secondControl == store.selectedControl
                    && store.selectedMappingModifiers.contains(collision.firstControl))
        }

        if !collisions.isEmpty || !rolloverCollisions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(collisions, id: \.self) { collision in
                    Label {
                        Text(
                            "The learned keyboard assignments overlap: \(collision.firstControl.rawValue) held can hide \(collision.hiddenControl.rawValue). XP[d] infers this from the saved report-6 bindings, so relearn one affected button with a distinct shortcut in the remote's settings, then use Learn selected control in Status & Input."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                }
                ForEach(rolloverCollisions, id: \.self) { collision in
                    Label {
                        Text(
                            "The learned keyboard states for \(collision.firstControl.rawValue) + \(collision.secondControl.rawValue) require \(collision.combinedOrdinaryKeyCount) ordinary keys, exceeding the six-key boot-keyboard rollover capacity. XP[d] infers this from the saved report-6 bindings; relearn an affected button with a distinct shortcut in the remote's settings."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
            Text("K modifier")

            if store.isRemoteModifier(store.selectedControl) {
                HStack(spacing: 5) {
                    ForEach(ModifierColor.allCases) { color in
                        Button {
                            _ = store.setModifierColor(color, for: store.selectedControl)
                        } label: {
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 17, height: 17)
                                .overlay {
                                    Circle()
                                        .stroke(.white, lineWidth: store.modifierColor(for: store.selectedControl) == color ? 2 : 0)
                                    if store.modifierColor(for: store.selectedControl) == color {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.black.opacity(0.78))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(color.displayName) modifier colour")
                        .accessibilityValue(
                            store.modifierColor(for: store.selectedControl) == color ? "Selected" : "Not selected"
                        )
                        .help("Use \(color.displayName) for this modifier")
                    }
                }
            }

            Toggle(
                "Enable K modifier",
                isOn: Binding(
                    get: { store.isRemoteModifier(store.selectedControl) },
                    set: { _ = store.setRemoteModifier(store.selectedControl, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.isRemoteModifier(store.selectedControl) {
                Text("Hold alone until the timer, or press a destination K before it expires")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var availableMappingModifiers: [RemoteControl] {
        RemoteControl.allCases.filter {
            store.isRemoteModifier($0) && $0 != store.selectedControl
        }
    }

    private var savedMappingModifierLayers: [Set<RemoteControl>] {
        store.standardModifierLayers(for: store.selectedControl)
    }

    private var selectedModifierLayerIsActive: Bool {
        !store.selectedMappingModifiers.isEmpty
            && store.selectedMappingModifiers.isSubset(of: store.remoteModifierControls)
    }

    private func resetModifierGestureSelection() {
        selectedModifierGesture = .tap
        activeStandardEditorLayer = nil
    }

    private func ensureModifierLayerSelection() {
        guard canChooseStandardLayer else { return }
        let active = Set(availableMappingModifiers)
        let selected = store.selectedMappingModifiers
        let selectedIsAvailable = !selected.isEmpty
            && (selected.isSubset(of: active) || savedMappingModifierLayers.contains(selected))

        if selectedIsAvailable {
            return
        }
        if let first = availableMappingModifiers.first {
            store.selectedMappingModifiers = [first]
        } else if let first = savedMappingModifierLayers.first {
            store.selectedMappingModifiers = first
        }
    }

    private var standardModifierLayerSelector: some View {
        Menu {
            if !availableMappingModifiers.isEmpty {
                Section("Available MOD buttons") {
                    ForEach(availableMappingModifiers) { control in
                        Button {
                            toggleSelectedModifier(control)
                        } label: {
                            HStack {
                                Image(systemName: store.selectedMappingModifiers.contains(control)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                Text(control.rawValue)
                                if isLayerConfigured([control]) {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(
                            store.selectedMappingModifiers == [control]
                                && availableMappingModifiers.count == 1
                        )
                    }
                }
            }

            if !savedMappingModifierLayers.isEmpty {
                Section("Saved layers") {
                    ForEach(savedMappingModifierLayers, id: \.self) { layer in
                        Button {
                            store.selectedMappingModifiers = layer
                        } label: {
                            HStack {
                                Image(systemName: store.selectedMappingModifiers == layer
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                Text(mappingLayerLabel(for: layer))
                                if isLayerConfigured(layer) {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(.green)
                                }
                                if !layer.isSubset(of: store.remoteModifierControls) {
                                    Text("Disabled")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                modifierLayerChips(store.selectedMappingModifiers)
                Spacer(minLength: 8)
                if isLayerConfigured(store.selectedMappingModifiers) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Configured")
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Choose one or more MOD buttons for the action below")
        .accessibilityLabel("MOD layer \(mappingLayerLabel)")
    }

    private var modifierGestureEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Gesture")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("MOD gesture", selection: $selectedModifierGesture) {
                ForEach(GestureKind.allCases) { gesture in
                    Text(gesture.rawValue)
                        .tag(gesture)
                        .accessibilityLabel("MOD \(gesture.rawValue) gesture")
                        .accessibilityValue(
                            isModifierGestureConfigured(gesture) ? "Configured" : "Not configured"
                        )
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .overlay {
                HStack(spacing: 0) {
                    ForEach(GestureKind.allCases) { gesture in
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .trailing) {
                                if isModifierGestureConfigured(gesture) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                        .padding(.trailing, 8)
                                }
                            }
                    }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .accessibilityLabel("MOD gesture")
        }
    }

    private func isModifierGestureConfigured(_ gesture: GestureKind) -> Bool {
        guard !store.selectedMappingModifiers.isEmpty else { return false }
        return store.isMappingConfigured(
            for: store.selectedControl,
            gesture: gesture,
            modifierControls: store.selectedMappingModifiers
        )
    }

    private func modifierLayerChips(_ layer: Set<RemoteControl>) -> some View {
        HStack(spacing: 4) {
            ForEach(RemoteControl.allCases.filter { layer.contains($0) }) { control in
                Text(control.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        store.isRemoteModifier(control)
                            ? store.modifierColor(for: control).swiftUIColor
                            : Color.secondary
                    )
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(.black.opacity(0.34), in: Capsule())
                    .opacity(store.isRemoteModifier(control) ? 1 : 0.48)
            }
        }
    }

    private func toggleSelectedModifier(_ control: RemoteControl) {
        var layer = store.selectedMappingModifiers
        if layer.contains(control) {
            guard layer.count > 1 else { return }
            layer.remove(control)
        } else {
            layer.insert(control)
        }
        store.selectedMappingModifiers = layer
    }

    private func isLayerConfigured(_ layer: Set<RemoteControl>) -> Bool {
        store.isMappingConfigured(
            for: store.selectedControl,
            gesture: selectedModifierGesture,
            modifierControls: layer
        )
    }

    private var gestureEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(isStandardLayerEligible ? "Base Gesture" : "Gesture")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.isRemoteModifier(store.selectedControl) {
                Text("Hold alone · combine with K for layer")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Picker(
                    isStandardLayerEligible ? "Base gesture" : "Gesture",
                    selection: Bindable(store).selectedGesture
                ) {
                    ForEach(GestureKind.allCases) { gesture in
                        Text(gesture.rawValue)
                        .tag(gesture)
                        .accessibilityLabel(gesture.rawValue)
                        .accessibilityValue(
                            isGestureConfigured(gesture) ? "Configured" : "Not configured"
                        )
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .overlay {
                    HStack(spacing: 0) {
                        ForEach(GestureKind.allCases) { gesture in
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .trailing) {
                                    if isGestureConfigured(gesture) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                            .padding(.trailing, 8)
                                    }
                                }
                        }
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func isGestureConfigured(_ gesture: GestureKind) -> Bool {
        store.isMappingConfigured(
            for: store.selectedControl,
            gesture: gesture
        )
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

    private var headerGestureLabel: String {
        if store.selectedControl.isWheelRotation {
            return "Rotate"
        }
        if isStandardLayerEligible {
            return "Base \(store.selectedGesture.rawValue)"
        }
        return store.selectedGesture.rawValue
    }

    private var isStandardButtonTitleEligible: Bool {
        store.activeRealm == .standard && store.selectedControl.isMIDIButton
    }

    private var isStandardModifierEligible: Bool {
        store.activeRealm == .standard && store.selectedControl.isModifierEligible
    }

    private var isStandardLayerEligible: Bool {
        canChooseStandardLayer && !store.selectedMappingModifiers.isEmpty
    }

    private var canChooseStandardLayer: Bool {
        isStandardButtonTitleEligible
            && !store.isRemoteModifier(store.selectedControl)
            && (!store.remoteModifierControls.isEmpty || !savedMappingModifierLayers.isEmpty)
    }

    private var mappingLayerLabel: String {
        mappingLayerLabel(for: store.selectedMappingModifiers)
    }

    private func mappingLayerLabel(for layer: Set<RemoteControl>) -> String {
        guard !layer.isEmpty else { return "Base" }
        return RemoteControl.allCases
            .filter { layer.contains($0) }
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
    let gesture: GestureKind
    var isEditable = true
    @Binding var activeCaptureLayer: Set<RemoteControl>?

    @State private var isEditingCommand = false
    @State private var shortcutCaptureCancellation = 0
    @State private var remoteTriggerCaptureCancellation = 0
    @State private var pendingPasteConfirmation: MappingDestinationSnapshot?
    @State private var pendingDeleteConfirmation: MappingDestinationSnapshot?
    @State private var connectedScreens = WindowScreenDestination.connected
    @FocusState private var isCommandFieldFocused: Bool

    private var binding: Binding<Mapping> {
        Binding(
            get: {
                store.mapping(
                    for: store.selectedControl,
                    gesture: gesture,
                    modifierControls: modifierControls
                )
            },
            set: {
                guard isEditable else { return }
                store.update(
                    $0,
                    for: store.selectedControl,
                    gesture: gesture,
                    modifierControls: modifierControls
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let title {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(isEditable ? Color.primary : Color.secondary)
                    Spacer(minLength: 8)
                } else {
                    Spacer(minLength: 0)
                }

                if isPendingCutSource {
                    Image(systemName: "scissors")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("This action is marked to move")
                        .accessibilityLabel("Marked to move")
                }

                mappingClipboardControls
            }

            Group {
                Picker("Action", selection: actionBinding) {
                    ForEach(ActionKind.allCases) { action in
                        Text(action.editorLabel).tag(action)
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
            .disabled(!isEditable)
            .opacity(isEditable ? 1 : 0.42)

            if !isEditable {
                Label("This saved layer is disabled. Re-enable its MOD buttons or delete the action.", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: store.selectedControl) { _, _ in cancelEditing() }
        .onChange(of: gesture) { _, _ in cancelEditing() }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            connectedScreens = WindowScreenDestination.connected
        }
        .confirmationDialog(
            "Replace the existing action?",
            isPresented: pasteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                cancelEditing()
                if let pendingPasteConfirmation {
                    _ = store.pasteMapping(to: pendingPasteConfirmation, replacingExisting: true)
                }
                self.pendingPasteConfirmation = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pasting here will replace the current action and its trigger settings.")
        }
        .confirmationDialog(
            "Delete this action?",
            isPresented: deleteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Action", role: .destructive) {
                cancelEditing()
                if let pendingDeleteConfirmation {
                    _ = store.deleteMapping(for: pendingDeleteConfirmation)
                }
                self.pendingDeleteConfirmation = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The action and its trigger settings will be reset to Empty.")
        }
    }

    private var pasteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingPasteConfirmation != nil },
            set: { isPresented in
                if !isPresented { pendingPasteConfirmation = nil }
            }
        )
    }

    private var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteConfirmation != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteConfirmation = nil }
            }
        )
    }

    private var isPendingCutSource: Bool {
        store.mappingClipboardOperation(
            for: store.selectedControl,
            gesture: gesture,
            modifierControls: modifierControls
        ) == .cut
    }

    private var mappingClipboardControls: some View {
        HStack(spacing: 1) {
            Button {
                cancelEditing()
                _ = store.copyMapping(
                    from: store.selectedControl,
                    gesture: gesture,
                    modifierControls: modifierControls
                )
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy action")
            .accessibilityLabel("Copy action")
            .disabled(!store.canCopyMapping(
                for: store.selectedControl,
                gesture: gesture,
                modifierControls: modifierControls
            ) || !isEditable)

            Button {
                cancelEditing()
                _ = store.cutMapping(
                    from: store.selectedControl,
                    gesture: gesture,
                    modifierControls: modifierControls
                )
            } label: {
                Image(systemName: "scissors")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Cut action for moving")
            .accessibilityLabel("Cut action")
            .disabled(!store.canCutMapping(
                for: store.selectedControl,
                gesture: gesture,
                modifierControls: modifierControls
            ) || !isEditable)

            Button {
                cancelEditing()
                let destination = store.mappingDestinationSnapshot(
                    for: store.selectedControl,
                    gesture: gesture,
                    modifierControls: modifierControls
                )
                switch store.pasteMapping(to: destination) {
                case .destinationOccupied:
                    pendingPasteConfirmation = destination
                default:
                    break
                }
            } label: {
                Image(systemName: "clipboard")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Paste action")
            .accessibilityLabel("Paste action")
            .disabled(!store.canPasteMapping(
                to: store.selectedControl,
                gesture: gesture,
                modifierControls: modifierControls
            ) || !isEditable)

            Button(role: .destructive) {
                let destination = store.mappingDestinationSnapshot(
                    for: store.selectedControl,
                    gesture: gesture,
                    modifierControls: modifierControls
                )
                if destination.expectedMapping != Mapping() {
                    pendingDeleteConfirmation = destination
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete action")
            .accessibilityLabel("Delete action")
            .disabled(!store.destinationHasMapping(
                for: store.selectedControl,
                gesture: gesture,
                modifierControls: modifierControls
            ))
        }
        .font(.caption)
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
            Picker("Window / display", selection: windowDisplayCommandBinding) {
                Text("Choose window action…").tag(nil as String?)
                ForEach(WindowDisplayAction.allCases) { action in
                    Text(action.rawValue).tag(action.rawValue as String?)
                }
                Section("Send frontmost window to screen") {
                    ForEach(connectedScreens) { destination in
                        Text(destination.name).tag(destination.command as String?)
                    }
                    if unavailableScreenIdentity != nil {
                        Text("Unavailable screen")
                            .tag(binding.wrappedValue.command as String?)
                    }
                }
            }
            if let windowAction = WindowDisplayAction(rawValue: binding.wrappedValue.command),
               windowAction == .toggleXPd {
                Text("Shows or hides XP[d] without requiring Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let windowAction = WindowDisplayAction(rawValue: binding.wrappedValue.command),
                      windowAction != .sleepDisplays {
                Text("Frontmost-window actions may require Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let screenIdentity = WindowScreenDestination.identity(from: binding.wrappedValue.command) {
                Text(screenMoveHelp(screenIdentity: screenIdentity))
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
            EmptyView()
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
            Text("When pressed")
                .font(.caption)
                .foregroundStyle(.secondary)
            RemoteTriggerChordCaptureField(
                selectedControl: store.selectedControl,
                modifierControls: modifierControls,
                availableModifierControls: [],
                currentModifiers: binding.wrappedValue.remoteTriggerModifiers,
                currentFunctionKey: binding.wrappedValue.remoteTriggerFunctionKey,
                currentKeyCode: binding.wrappedValue.remoteTriggerKeyCode,
                currentKeyDisplay: binding.wrappedValue.remoteTriggerKeyDisplay,
                cancellationGeneration: remoteTriggerCaptureCancellation,
                beginRemoteCapture: { onRemoteModifier in
                    store.beginRemoteTriggerCapture(onRemoteModifier: onRemoteModifier)
                },
                endRemoteCapture: store.endRemoteTriggerCapture,
                onModifierControlsChange: { _ in },
                onKeyboardConditionCommit: { remoteModifiers, modifiers, keyCode, keyDisplay in
                    var mapping = store.mapping(
                        for: store.selectedControl,
                        gesture: gesture,
                        modifierControls: remoteModifiers
                    )
                    mapping.remoteTriggerModifiers = modifiers
                    mapping.remoteTriggerFunctionKey = nil
                    mapping.remoteTriggerKeyCode = nil
                    mapping.remoteTriggerKeyDisplay = nil
                    if let keyCode {
                        if KeyboardShortcut.functionKeyCodes.contains(keyCode) {
                            // Keep F1…F12 in the established field so v6
                            // exports and existing trigger gates stay stable.
                            mapping.remoteTriggerFunctionKey = keyCode
                        } else {
                            mapping.remoteTriggerKeyCode = keyCode
                            mapping.remoteTriggerKeyDisplay = keyDisplay
                        }
                    }
                    store.update(
                        mapping,
                        for: store.selectedControl,
                        gesture: gesture,
                        modifierControls: remoteModifiers
                    )
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

    private var windowDisplayCommandBinding: Binding<String?> {
        Binding(
            get: {
                let command = binding.wrappedValue.command
                if WindowDisplayAction(rawValue: command) != nil {
                    return command
                }
                if let screenIdentity = WindowScreenDestination.identity(from: command),
                   let connectedDestination = WindowScreenDestination.resolve(
                       screenIdentity,
                       among: connectedScreens
                   ) {
                    return connectedDestination.command
                }
                if WindowScreenDestination.identity(from: command) != nil {
                    return command
                }
                return nil
            },
            set: { command in
                guard let command else { return }
                binding.wrappedValue = binding.wrappedValue.editingCommand(command)
            }
        )
    }

    private var unavailableScreenIdentity: WindowScreenDestination.Identity? {
        guard let screenIdentity = WindowScreenDestination.identity(from: binding.wrappedValue.command),
              WindowScreenDestination.resolve(screenIdentity, among: connectedScreens) == nil else {
            return nil
        }
        return screenIdentity
    }

    private func screenMoveHelp(screenIdentity: WindowScreenDestination.Identity) -> String {
        if let destination = WindowScreenDestination.resolve(
            screenIdentity,
            among: connectedScreens
        ) {
            return "Moves the frontmost window to \(destination.name). Requires Accessibility permission."
        }
        return "The selected screen is disconnected or ambiguous. Choose a connected screen before using this action."
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
        (gesture == .hold || gesture == .doubleTap)
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
