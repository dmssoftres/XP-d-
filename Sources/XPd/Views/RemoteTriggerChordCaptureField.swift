import AppKit
import SwiftUI

/// Edits one fixed physical remote chord. The destination K is never
/// replaceable: designated K modifiers can be added from the menu or by
/// pressing them while recording, alongside zero or one ordinary keyboard
/// key and any macOS modifier flags.
struct RemoteTriggerChordCaptureField: View {
    let selectedControl: RemoteControl
    let modifierControls: Set<RemoteControl>
    let availableModifierControls: [RemoteControl]
    let currentModifiers: Set<KeyboardShortcut.Modifier>
    let currentFunctionKey: UInt16?
    let currentKeyCode: UInt16?
    let currentKeyDisplay: String?
    let cancellationGeneration: Int
    let beginRemoteCapture: (@escaping (RemoteControl) -> Void) -> Void
    let endRemoteCapture: () -> Void
    let onModifierControlsChange: (Set<RemoteControl>) -> Void
    let onKeyboardConditionCommit: (
        Set<RemoteControl>,
        Set<KeyboardShortcut.Modifier>,
        UInt16?,
        String?
    ) -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var draftModifierControls: Set<RemoteControl> = []
    @State private var draftModifiers: Set<KeyboardShortcut.Modifier> = []
    @State private var draftKeyCode: UInt16?
    @State private var draftKeyDisplay = ""
    @State private var currentModifierFlags: NSEvent.ModifierFlags = []
    @State private var didEditKeyboardCondition = false
    @State private var eventMonitor: Any?

    private var hasDraft: Bool {
        draftKeyCode != nil || !draftModifiers.isEmpty || !draftModifierControls.isEmpty
    }

    private var hasConditionsToClear: Bool {
        isRecording
            ? didEditKeyboardCondition || !draftModifiers.isEmpty || draftKeyCode != nil
            : !currentModifiers.isEmpty || currentFunctionKey != nil || currentKeyCode != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                            .foregroundStyle(isRecording ? Color.red : Color.secondary)
                        Text(displayValue)
                            .foregroundStyle(.primary)
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
                .accessibilityLabel(isRecording ? "Recording trigger chord" : "Record trigger chord")
                .help(isRecording
                    ? "Press designated K modifiers and optionally hold keyboard modifiers or one key, then click to save."
                    : "Click to record this remote and keyboard chord")

                if !availableModifierControls.isEmpty {
                    Menu {
                        ForEach(availableModifierControls) { control in
                            Toggle(
                                control.rawValue,
                                isOn: Binding(
                                    get: { displayedModifierControls.contains(control) },
                                    set: { enabled in
                                        updateModifierControl(control, enabled: enabled)
                                    }
                                )
                            )
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Choose K modifier conditions")
                    .help("Add or remove designated K modifiers; \(selectedControl.rawValue) remains the destination")
                }

                if hasConditionsToClear {
                    Button(action: clearTriggerKeys) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear keyboard condition")
                    .help("Clear the optional keyboard condition")
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
                                didEditKeyboardCondition = true
                            }
                        }

                        ForEach(RemoteControl.allCases.filter { draftModifierControls.contains($0) }) { control in
                            removableChip(
                                label: control.rawValue,
                                accessibilityLabel: "Remove \(control.rawValue) K modifier"
                            ) {
                                guard draftModifierControls.count > 1 else { return }
                                draftModifierControls.remove(control)
                            }
                        }

                        if draftKeyCode != nil {
                            removableChip(
                                label: draftKeyDisplay,
                                accessibilityLabel: "Remove \(draftKeyDisplay) key"
                            ) {
                                draftKeyCode = nil
                                draftKeyDisplay = ""
                                didEditKeyboardCondition = true
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

    private var remoteChordLabel: String {
        let modifiers = RemoteControl.allCases
            .filter { displayedModifierControls.contains($0) }
            .map(\.rawValue)
        return (modifiers + [selectedControl.rawValue]).joined(separator: " + ")
    }

    private var displayedModifierControls: Set<RemoteControl> {
        isRecording ? draftModifierControls : modifierControls
    }

    private var keyboardConditionLabel: String? {
        let modifiers = KeyboardShortcut.modifierOrder
            .filter { (isRecording ? draftModifiers : currentModifiers).contains($0) }
            .map(\.symbol)
        let keyCode = isRecording ? draftKeyCode : (currentKeyCode ?? currentFunctionKey)
        let key = isRecording
            ? (draftKeyCode == nil ? nil : draftKeyDisplay)
            : keyCode.map {
                (currentKeyDisplay?.isEmpty == false ? currentKeyDisplay : nil)
                    ?? KeyboardShortcut.functionKeyLabel(for: $0)
                    ?? "Key \($0)"
            }
        let values = modifiers + (key.map { [$0] } ?? [])
        return values.isEmpty ? nil : values.joined(separator: " + ")
    }

    private var displayValue: String {
        if isRecording {
            if let keyboardConditionLabel {
                return "Recording \(keyboardConditionLabel) + \(remoteChordLabel)"
            }
            return "Recording \(remoteChordLabel) — optional key"
        }
        if let keyboardConditionLabel {
            return "\(keyboardConditionLabel) + \(remoteChordLabel)"
        }
        return remoteChordLabel
    }

    private func toggleRecording() {
        isRecording ? stopRecording(commit: true) : startRecording()
    }

    private func startRecording() {
        draftModifierControls = modifierControls
        draftModifiers = currentModifiers
        draftKeyCode = currentKeyCode ?? currentFunctionKey
        draftKeyDisplay = currentKeyDisplay
            ?? currentFunctionKey.flatMap(KeyboardShortcut.functionKeyLabel(for:))
            ?? draftKeyCode.map { "Key \($0)" }
            ?? ""
        currentModifierFlags = []
        didEditKeyboardCondition = false
        isRecording = true
        beginRemoteCapture { control in
            guard control != selectedControl,
                  availableModifierControls.contains(control),
                  isRecording else { return }
            draftModifierControls.insert(control)
        }
        onRecordingChange(true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if let captured = KeyboardShortcutCaptureFormatter.shortcut(for: event) {
                    draftKeyCode = captured.keyCode
                    draftKeyDisplay = KeyboardShortcutCaptureFormatter.keyLabel(for: event)
                    draftModifiers = captured.modifiers
                    didEditKeyboardCondition = true
                }
            case .flagsChanged:
                currentModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if draftKeyCode == nil {
                    draftModifiers = KeyboardShortcutCaptureFormatter.modifierSet(for: currentModifierFlags)
                    didEditKeyboardCondition = true
                }
            default:
                break
            }
            return nil
        }
    }

    private func clearTriggerKeys() {
        if isRecording {
            draftModifiers.removeAll()
            draftKeyCode = nil
            draftKeyDisplay = ""
            didEditKeyboardCondition = true
        } else {
            onKeyboardConditionCommit(modifierControls, [], nil, nil)
        }
    }

    private func stopRecording(commit: Bool) {
        guard isRecording else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        endRemoteCapture()
        onRecordingChange(false)

        if commit, draftModifierControls != modifierControls {
            onModifierControlsChange(draftModifierControls)
        }
        if commit, didEditKeyboardCondition {
            onKeyboardConditionCommit(
                draftModifierControls,
                draftModifiers,
                draftKeyCode,
                draftKeyDisplay.isEmpty ? nil : draftKeyDisplay
            )
        }

        draftModifierControls = []
        draftModifiers = []
        draftKeyCode = nil
        draftKeyDisplay = ""
        currentModifierFlags = []
        didEditKeyboardCondition = false
    }

    private func updateModifierControl(_ control: RemoteControl, enabled: Bool) {
        guard control != selectedControl,
              availableModifierControls.contains(control) else { return }

        var next = displayedModifierControls
        if enabled {
            next.insert(control)
        } else {
            next.remove(control)
        }
        guard modifierControls.isEmpty || !next.isEmpty else { return }

        if isRecording {
            draftModifierControls = next
        } else {
            onModifierControlsChange(next)
        }
    }
}
