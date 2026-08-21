import AppKit
import SwiftUI

enum KeyboardShortcutCaptureFormatter {
    static let separator = " → "

    static func keyboardToken(
        for event: NSEvent,
        excluding capturedModifiers: NSEvent.ModifierFlags = []
    ) -> String? {
        guard !event.isARepeat else { return nil }

        let key = keyLabel(for: event)
        guard !key.isEmpty else { return nil }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(capturedModifiers)
        let modifiers = [
            flags.contains(.command) ? "⌘" : nil,
            flags.contains(.option) ? "⌥" : nil,
            flags.contains(.control) ? "⌃" : nil,
            flags.contains(.shift) ? "⇧" : nil,
            flags.contains(.function) ? "fn" : nil
        ]
        .compactMap { $0 }
        .joined()

        return modifiers + key
    }

    /// Returns a token only for the press edge of a modifier key. `flagsChanged`
    /// events are also emitted when the key is released, so a release has no
    /// token and cannot add noise to the recorded sequence.
    static func modifierToken(for event: NSEvent) -> String? {
        guard event.type == .flagsChanged else { return nil }
        return modifierToken(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
    }

    static func modifierToken(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String? {
        guard let flag = modifierFlag(for: keyCode), modifierFlags.contains(flag) else { return nil }

        switch keyCode {
        case 54, 55: return "⌘"
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 56, 60: return "⇧"
        case 63: return "fn"
        default: return nil
        }
    }

    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        case 63: return .function
        default: return nil
        }
    }

    static func sequence(_ tokens: [String]) -> String {
        tokens.joined(separator: separator)
    }

    static func tokens(in sequence: String) -> [String] {
        sequence.isEmpty ? [] : sequence.components(separatedBy: separator)
    }

    static func sequence(removingTokenAt index: Int, from sequence: String) -> String {
        var tokens = tokens(in: sequence)
        guard tokens.indices.contains(index) else { return sequence }
        tokens.remove(at: index)
        return self.sequence(tokens)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return event.charactersIgnoringModifiers?
                .uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

/// A click-to-record field for mapping shortcuts. Keyboard input remains local
/// to XP[d] while recording; remote K-button capture is supplied by
/// `MappingStore` because its HID stream is intentionally owned there.
struct KeyboardShortcutCaptureField: View {
    @Binding var command: String
    let cancellationGeneration: Int
    let beginRemoteCapture: (@escaping (RemoteControl) -> Void) -> Void
    let endRemoteCapture: () -> Void

    @State private var isRecording = false
    @State private var originalCommand = ""
    @State private var capturedTokens: [String] = []
    @State private var didEditDraft = false
    @State private var pressedModifierKeyCodes: Set<UInt16> = []
    @State private var capturedModifierFlags: NSEvent.ModifierFlags = []
    @State private var eventMonitor: Any?

    private var draft: String {
        KeyboardShortcutCaptureFormatter.sequence(capturedTokens)
    }

    private var hasSequenceToClear: Bool {
        isRecording ? !capturedTokens.isEmpty || !originalCommand.isEmpty : !command.isEmpty
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
                .help(isRecording ? "Press keyboard keys or remote K buttons, then click to save." : "Click to record a shortcut")

                if hasSequenceToClear {
                    Button(action: clearSequence) {
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
            if isRecording, !capturedTokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(capturedTokens.enumerated()), id: \.offset) { index, token in
                            Button {
                                removeToken(at: index)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(token)
                                        .font(.caption.monospaced())
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(token)")
                            .help("Remove \(token) from the draft")
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

    private var displayValue: String {
        if isRecording {
            return capturedTokens.isEmpty
                ? "Recording — press keyboard keys or remote K buttons"
                : "Recording \(capturedTokens.count) key(s)"
        }
        return command.isEmpty ? "No shortcut recorded" : command
    }

    private var displayValueIsPlaceholder: Bool {
        (isRecording && capturedTokens.isEmpty) || (!isRecording && command.isEmpty)
    }

    private func toggleRecording() {
        isRecording ? stopRecording(commit: true) : startRecording()
    }

    private func startRecording() {
        originalCommand = command
        capturedTokens = []
        didEditDraft = false
        pressedModifierKeyCodes = []
        capturedModifierFlags = []
        isRecording = true
        beginRemoteCapture { control in
            append(control.rawValue)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    stopRecording(commit: false)
                } else if let token = KeyboardShortcutCaptureFormatter.keyboardToken(
                    for: event,
                    excluding: capturedModifierFlags
                ) {
                    append(token)
                }
            case .flagsChanged:
                // Track physical modifier keys so a repeated flagsChanged
                // event, or releasing one side while the other is held,
                // cannot append a duplicate token. A release can still report
                // the modifier flag when the other side is held, so an already
                // tracked keycode is always treated as the release edge.
                if pressedModifierKeyCodes.contains(event.keyCode) {
                    pressedModifierKeyCodes.remove(event.keyCode)
                    refreshCapturedModifierFlags()
                } else if let token = KeyboardShortcutCaptureFormatter.modifierToken(for: event) {
                    if pressedModifierKeyCodes.insert(event.keyCode).inserted {
                        refreshCapturedModifierFlags()
                        append(token)
                    }
                } else {
                    pressedModifierKeyCodes.remove(event.keyCode)
                }
            default:
                break
            }
            return nil
        }
    }

    private func refreshCapturedModifierFlags() {
        capturedModifierFlags = pressedModifierKeyCodes.reduce(into: []) { flags, keyCode in
            if let flag = KeyboardShortcutCaptureFormatter.modifierFlag(for: keyCode) {
                flags.insert(flag)
            }
        }
    }

    private func append(_ token: String) {
        guard isRecording, capturedTokens.count < 12 else { return }
        capturedTokens.append(token)
        didEditDraft = true
    }

    private func removeToken(at index: Int) {
        guard isRecording, capturedTokens.indices.contains(index) else { return }
        capturedTokens.remove(at: index)
        didEditDraft = true
    }

    private func clearSequence() {
        if isRecording {
            capturedTokens.removeAll()
            didEditDraft = true
        } else {
            command = ""
        }
    }

    private func stopRecording(commit: Bool) {
        guard isRecording else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        endRemoteCapture()
        isRecording = false
        if commit, didEditDraft {
            command = draft
        }
        capturedTokens = []
        didEditDraft = false
        pressedModifierKeyCodes = []
        capturedModifierFlags = []
    }
}
