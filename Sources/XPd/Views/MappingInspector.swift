import SwiftUI

struct MappingInspector: View {
    let store: MappingStore
    @State private var isImportingConfiguration = false
    @State private var isExportingConfiguration = false
    @State private var exportDocument = XPdConfigurationDocument()
    @State private var isEditingCommand = false
    @FocusState private var isCommandFieldFocused: Bool

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

            HStack(spacing: 12) {
                statusCard(title: "Current profile", value: store.profileName, detail: "local mappings")
                statusCard(title: "Device", value: store.hid.isConnected ? "Connected" : "Offline", detail: "VID 10429 · PID 514")
            }

            configurationControls

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
                Label("Press once to open the profile selector, rotate to highlight, then press again to confirm.", systemImage: "dial.medium")
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

            Spacer(minLength: 0)
        }
        .fileImporter(
            isPresented: $isImportingConfiguration,
            allowedContentTypes: XPdConfigurationDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importConfiguration
        )
        .fileExporter(
            isPresented: $isExportingConfiguration,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename,
            onCompletion: exportConfigurationCompleted
        )
        .onChange(of: store.selectedControl) { _, _ in
            endCommandEditing()
        }
        .onChange(of: store.selectedGesture) { _, _ in
            endCommandEditing()
        }
        .onChange(of: selectedAction) { _, _ in
            endCommandEditing()
        }
        .onChange(of: isCommandFieldFocused) { _, isFocused in
            if !isFocused {
                isEditingCommand = false
            }
        }
    }

    private var mappingEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Action", selection: binding.action) {
                    ForEach(ActionKind.allCases) { action in
                        Text(action.rawValue).tag(action)
                    }
                }

                commandEditor

                if isApplicationAction {
                    Text("Use an app name, bundle ID, or .app path. Toggle application requires Accessibility permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                actionResult

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
    private var commandEditor: some View {
        if isEditingCommand {
            TextField(commandPlaceholder, text: binding.command)
                .focused($isCommandFieldFocused)
                .onSubmit(endCommandEditing)
                .onExitCommand(perform: endCommandEditing)
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
            .accessibilityLabel("Edit command")
            .help("Click to edit")
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

    private func endCommandEditing() {
        isCommandFieldFocused = false
        isEditingCommand = false
    }

    private var configurationControls: some View {
        HStack(spacing: 10) {
            Button {
                isImportingConfiguration = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            Button {
                guard let data = store.exportConfiguration() else { return }
                exportDocument = XPdConfigurationDocument(data: data)
                isExportingConfiguration = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Spacer()

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
        }
    }

    private func importConfiguration(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                store.importConfiguration(data)
            } catch {
                store.configurationFileOperationFailed(.import, error: error)
            }
        case .failure(let error):
            guard !isUserCancellation(error) else { return }
            store.configurationFileOperationFailed(.import, error: error)
        }
    }

    private func exportConfigurationCompleted(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            store.configurationExportCompleted()
        case .failure(let error):
            guard !isUserCancellation(error) else { return }
            store.configurationFileOperationFailed(.export, error: error)
        }
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    private var exportFilename: String {
        let safeProfileName = store.profileName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safeProfileName.isEmpty ? "XPd-Configuration" : "XPd-\(safeProfileName)"
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

    private var selectedAction: ActionKind {
        store.mapping(for: store.selectedControl, gesture: store.selectedGesture).action
    }

    private var selectedControlTitle: String {
        store.selectedControl.isWheelRotation ? "Wheel" : store.selectedControl.rawValue
    }

    private var isApplicationAction: Bool {
        selectedAction == .openApplication || selectedAction == .toggleApplication
    }

    private var commandPlaceholder: String {
        isApplicationAction ? "Application name (for example, ChatGPT)" : "Command"
    }
}
