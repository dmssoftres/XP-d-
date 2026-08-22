import AppKit
import SwiftUI

enum KeyboardShortcutCaptureFormatter {
    static func shortcut(for event: NSEvent) -> KeyboardShortcut? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        guard KeyboardShortcutCaptureFormatter.modifier(for: event.keyCode) == nil else {
            return nil
        }

        let key = keyLabel(for: event)
        guard !key.isEmpty else { return nil }

        let modifiers = modifierSet(for: event.modifierFlags)
        return KeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            displayString: displayString(key: key, modifiers: modifiers)
        )
    }

    static func displayString(key: String, modifiers: Set<KeyboardShortcut.Modifier>) -> String {
        let prefix = KeyboardShortcut.modifierOrder
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        return prefix + key
    }

    static func modifierSet(for flags: NSEvent.ModifierFlags) -> Set<KeyboardShortcut.Modifier> {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<KeyboardShortcut.Modifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }

    static func modifier(for keyCode: UInt16) -> KeyboardShortcut.Modifier? {
        switch keyCode {
        case 54, 55: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        case 63: return .function
        default: return nil
        }
    }

    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch modifier(for: keyCode) {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        case .function: return .function
        case nil: return nil
        }
    }

    static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Delete"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let functionKey = KeyboardShortcut.functionKeyLabel(for: event.keyCode) {
                return functionKey
            }
            return event.charactersIgnoringModifiers?
                .uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

/// A click-to-record field for one simultaneous keyboard chord.  Modifier
/// `flagsChanged` events update the current state only; a non-modifier
/// `keyDown` captures that state and replaces the single draft chord.
struct KeyboardShortcutCaptureField: View {
    @Binding var command: String
    @Binding var shortcut: KeyboardShortcut?
    let cancellationGeneration: Int

    @State private var isRecording = false
    @State private var draftKeyCode: UInt16?
    @State private var draftKeyLabel = ""
    @State private var draftModifiers: Set<KeyboardShortcut.Modifier> = []
    @State private var currentModifierFlags: NSEvent.ModifierFlags = []
    @State private var didEditDraft = false
    @State private var eventMonitor: Any?

    private var draftShortcut: KeyboardShortcut? {
        guard let keyCode = draftKeyCode, !draftKeyLabel.isEmpty else { return nil }
        return KeyboardShortcut(
            keyCode: keyCode,
            modifiers: draftModifiers,
            displayString: KeyboardShortcutCaptureFormatter.displayString(
                key: draftKeyLabel,
                modifiers: draftModifiers
            )
        )
    }

    private var hasDraft: Bool {
        draftKeyCode != nil || !draftModifiers.isEmpty
    }

    private var hasShortcutToClear: Bool {
        hasDraft || shortcut != nil || !command.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
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
                .accessibilityLabel(isRecording ? "Recording keyboard shortcut" : "Record keyboard shortcut")
                .help(isRecording ? "Hold modifier keys and press one key, then click to save." : "Click to record a shortcut")

                if hasShortcutToClear {
                    Button(action: clearShortcut) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isRecording ? "Clear recorded shortcut draft" : "Clear saved shortcut")
                    .help(isRecording ? "Clear the draft before saving" : "Clear the saved shortcut")
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
                                removeModifier(modifier)
                            }
                        }

                        if draftKeyCode != nil {
                            removableChip(label: draftKeyLabel, accessibilityLabel: "Remove \(draftKeyLabel) key") {
                                removeKey()
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
        if isRecording {
            if let draftShortcut {
                return "Recording \(draftShortcut.displayString)"
            }
            if !draftModifiers.isEmpty {
                let modifiers = KeyboardShortcut.modifierOrder
                    .filter { draftModifiers.contains($0) }
                    .map(\.symbol)
                    .joined()
                return "Recording \(modifiers) — press a key"
            }
            return "Recording — hold modifiers, then press a key"
        }
        if let shortcut, !shortcut.displayString.isEmpty {
            return shortcut.displayString
        }
        return command.isEmpty ? "No shortcut recorded" : command
    }

    private var displayValueIsPlaceholder: Bool {
        (isRecording && !hasDraft) || (!isRecording && shortcut == nil && command.isEmpty)
    }

    private func toggleRecording() {
        isRecording ? stopRecording(commit: true) : startRecording()
    }

    private func startRecording() {
        draftKeyCode = nil
        draftKeyLabel = ""
        draftModifiers = []
        currentModifierFlags = []
        didEditDraft = false
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    stopRecording(commit: false)
                } else if let captured = KeyboardShortcutCaptureFormatter.shortcut(for: event) {
                    draftKeyCode = captured.keyCode
                    draftKeyLabel = KeyboardShortcutCaptureFormatter.keyLabel(for: event)
                    draftModifiers = captured.modifiers
                    didEditDraft = true
                }
            case .flagsChanged:
                if let modifierFlag = KeyboardShortcutCaptureFormatter.modifierFlag(for: event.keyCode) {
                    if event.modifierFlags.contains(modifierFlag) {
                        currentModifierFlags.insert(modifierFlag)
                    } else {
                        currentModifierFlags.remove(modifierFlag)
                    }

                    // Before the final key is pressed, show held modifiers as
                    // removable chips.  Once a key is captured, keep the
                    // draft stable so releasing a modifier cannot mutate the
                    // saved chord.
                    if draftKeyCode == nil {
                        draftModifiers = KeyboardShortcutCaptureFormatter.modifierSet(for: currentModifierFlags)
                    }
                }
            default:
                break
            }
            return nil
        }
    }

    private func removeModifier(_ modifier: KeyboardShortcut.Modifier) {
        guard isRecording else { return }
        draftModifiers.remove(modifier)
        didEditDraft = true
    }

    private func removeKey() {
        guard isRecording else { return }
        draftKeyCode = nil
        draftKeyLabel = ""
        didEditDraft = true
    }

    private func clearShortcut() {
        if isRecording {
            draftKeyCode = nil
            draftKeyLabel = ""
            draftModifiers = []
            didEditDraft = true
        } else {
            shortcut = nil
            command = ""
        }
    }

    private func stopRecording(commit: Bool) {
        guard isRecording else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        if commit, didEditDraft {
            if let draftShortcut {
                shortcut = draftShortcut
                command = draftShortcut.displayString
            } else {
                shortcut = nil
                command = ""
            }
        }
        draftKeyCode = nil
        draftKeyLabel = ""
        draftModifiers = []
        currentModifierFlags = []
        didEditDraft = false
    }
}
