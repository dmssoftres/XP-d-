import AppKit
import SwiftUI

/// Captures the modifier portion of a physical remote-button trigger. The
/// remote button itself arrives through MappingStore's temporary HID capture;
/// this view only tracks the keyboard modifiers while the mouse capture is
/// active and commits once the user clicks the field a second time.
struct RemoteTriggerChordCaptureField: View {
    let selectedControl: RemoteControl
    let currentModifiers: Set<KeyboardShortcut.Modifier>
    let currentFunctionKey: UInt16?
    let cancellationGeneration: Int
    let beginCapture: (@escaping (RemoteControl) -> Void) -> Void
    let endCapture: () -> Void
    let onCommit: (RemoteControl, Set<KeyboardShortcut.Modifier>, UInt16?) -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var draftControl: RemoteControl?
    @State private var draftModifiers: Set<KeyboardShortcut.Modifier> = []
    @State private var draftFunctionKey: UInt16?
    @State private var currentModifierFlags: NSEvent.ModifierFlags = []
    @State private var didCaptureButton = false
    @State private var eventMonitor: Any?

    private var hasDraft: Bool {
        draftControl != nil || !draftModifiers.isEmpty || draftFunctionKey != nil
    }

    private var hasModifiersToClear: Bool {
        isRecording
            ? !draftModifiers.isEmpty || draftFunctionKey != nil
            : !currentModifiers.isEmpty || currentFunctionKey != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: isRecording ? "record.circle.fill" : "rectangle.connected.to.line.below")
                            .foregroundStyle(isRecording ? Color.red : Color.secondary)
                        Text(displayValue)
                            .foregroundStyle(displayValueIsPlaceholder ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(isRecording ? "Click to stop" : "Click to record")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(isRecording ? "Recording remote trigger" : "Record remote trigger")
                .help(isRecording
                    ? "Hold modifiers, press a remote K button, then click to save."
                    : "Click to record a remote trigger chord")

                if hasModifiersToClear {
                    Button(action: clearTriggerKeys) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear remote trigger keys")
                    .help("Clear special keys and restore the plain remote button trigger")
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .contentShape(Rectangle())

            if isRecording, hasDraft {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(KeyboardShortcut.modifierOrder.filter { draftModifiers.contains($0) }, id: \.self) { modifier in
                            removableChip(label: modifier.symbol, accessibilityLabel: "Remove \(modifier.rawValue) modifier") {
                                draftModifiers.remove(modifier)
                            }
                        }

                        if let draftFunctionKey,
                           let label = KeyboardShortcut.functionKeyLabel(for: draftFunctionKey) {
                            removableChip(label: label, accessibilityLabel: "Remove \(label) function key") {
                                self.draftFunctionKey = nil
                            }
                        }

                        if let draftControl {
                            removableChip(label: draftControl.rawValue, accessibilityLabel: "Remove \(draftControl.rawValue) remote button") {
                                self.draftControl = nil
                                didCaptureButton = false
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: cancellationGeneration) { _, _ in
            stopRecording(commit: false)
        }
        .onDisappear {
            stopRecording(commit: false)
        }
    }

    private func removableChip(
        label: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption.monospaced())
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var displayValue: String {
        let control = isRecording ? draftControl : selectedControl
        let modifiers = isRecording ? draftModifiers : currentModifiers
        let prefix = KeyboardShortcut.modifierOrder
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        let functionKey = isRecording ? draftFunctionKey : currentFunctionKey
        let keyPrefix = functionKey.flatMap(KeyboardShortcut.functionKeyLabel(for:)) ?? ""

        if let control {
            return prefix + keyPrefix + control.rawValue
        }
        if isRecording {
            return prefix.isEmpty ? "Recording — press a remote K button" : "Recording \(prefix) — press a remote K button"
        }
        return "No remote trigger modifier"
    }

    private var displayValueIsPlaceholder: Bool {
        !isRecording && currentModifiers.isEmpty
    }

    private func toggleRecording() {
        isRecording ? stopRecording(commit: true) : startRecording()
    }

    private func startRecording() {
        draftControl = nil
        draftModifiers = []
        draftFunctionKey = nil
        currentModifierFlags = []
        didCaptureButton = false
        isRecording = true
        onRecordingChange(true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    stopRecording(commit: false)
                } else if KeyboardShortcut.functionKeyLabel(for: event.keyCode) != nil, !event.isARepeat {
                    draftFunctionKey = event.keyCode
                }
            case .flagsChanged:
                currentModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !didCaptureButton {
                    draftModifiers = KeyboardShortcutCaptureFormatter.modifierSet(for: currentModifierFlags)
                }
            default:
                break
            }
            return nil
        }

        beginCapture { control in
            guard isRecording else { return }
            draftControl = control
            draftModifiers = KeyboardShortcutCaptureFormatter.modifierSet(for: currentModifierFlags)
            didCaptureButton = true
        }
    }

    private func clearTriggerKeys() {
        if isRecording {
            draftModifiers.removeAll()
            draftFunctionKey = nil
        } else {
            onCommit(selectedControl, [], nil)
        }
    }

    private func stopRecording(commit: Bool) {
        guard isRecording else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        onRecordingChange(false)
        endCapture()

        if commit, didCaptureButton, let draftControl {
            onCommit(draftControl, draftModifiers, draftFunctionKey)
        }

        draftControl = nil
        draftModifiers = []
        draftFunctionKey = nil
        currentModifierFlags = []
        didCaptureButton = false
    }
}
