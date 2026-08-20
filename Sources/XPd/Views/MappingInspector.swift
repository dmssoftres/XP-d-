import SwiftUI

struct MappingInspector: View {
    let store: MappingStore
    @State private var isImportingConfiguration = false
    @State private var isExportingConfiguration = false
    @State private var exportDocument = XPdConfigurationDocument()

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
                Button {
                    store.previewInputOverlay()
                } label: {
                    Label("Preview", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(!store.showsInputOverlay)
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

                    TextField(commandPlaceholder, text: binding.command)

                    if isApplicationAction {
                        Text("Use an app name, bundle ID, or .app path. Toggle application requires Accessibility permission.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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
                .padding(4)
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
                Label("Wheel-center input remains unresolved because the remote has not exposed a unique HID report for it.", systemImage: "ladybug")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
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

    private var isApplicationAction: Bool {
        selectedAction == .openApplication || selectedAction == .toggleApplication
    }

    private var commandPlaceholder: String {
        isApplicationAction ? "Application name (for example, ChatGPT)" : "Command"
    }
}
