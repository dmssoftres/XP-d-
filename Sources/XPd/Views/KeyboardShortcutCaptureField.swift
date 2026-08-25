import AppKit
import SwiftUI

enum KeyboardShortcutCaptureFormatter {
    static func shortcut(
        for event: NSEvent,
        isFunctionModifierPressed: Bool? = nil
    ) -> KeyboardShortcut? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        guard KeyboardShortcutCaptureFormatter.modifier(for: event.keyCode) == nil else {
            return nil
        }

        let key = keyLabel(for: event)
        guard !key.isEmpty else { return nil }

        var modifiers = modifierSet(for: event.modifierFlags)
        if let isFunctionModifierPressed {
            if isFunctionModifierPressed {
                modifiers.insert(.function)
            } else {
                // AppKit marks navigation keys as function-key events on some
                // keyboards even when Globe/Fn is not physically held. Only
                // the key-63 flagsChanged state is authoritative for capture.
                modifiers.remove(.function)
            }
        }
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

/// A non-hit-testing AppKit responder used while a SwiftUI capture field is
/// recording. SwiftUI controls are allowed to handle arrow keys and key
/// equivalents as focus/navigation commands; a dedicated first responder
/// keeps those events inside the recorder without changing the click-to-start
/// and click-to-commit interaction.
struct KeyboardShortcutCaptureResponder: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void
    let onFlagsChanged: (NSEvent) -> Void
    let onEscape: (() -> Void)?

    func makeNSView(context: Context) -> KeyboardShortcutCaptureResponderView {
        let view = KeyboardShortcutCaptureResponderView()
        view.onKeyDown = onKeyDown
        view.onFlagsChanged = onFlagsChanged
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyboardShortcutCaptureResponderView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onFlagsChanged = onFlagsChanged
        nsView.onEscape = onEscape
        nsView.beginCapturing()
    }

    static func dismantleNSView(_ nsView: KeyboardShortcutCaptureResponderView, coordinator: ()) {
        nsView.endCapturing()
    }
}

final class KeyboardShortcutCaptureResponderView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?
    var onFlagsChanged: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    private weak var previousFirstResponder: NSResponder?
    private var hasRequestedFirstResponder = false
    private var firstResponderRequestScheduled = false
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var isObservingApplicationLifecycle = false
    private weak var observedCaptureWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        beginCapturing()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            endCapturing()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The SwiftUI button underneath remains responsible for mouse clicks,
        // including the click that commits a completed draft.
        nil
    }

    func beginCapturing() {
        installCaptureLifecycleObserversIfNeeded()
        requestFirstResponder()
        startEventTapIfNeeded()
    }

    func endCapturing() {
        removeCaptureLifecycleObservers()
        stopEventTap()
        restorePreviousFirstResponder()
    }

    private func requestFirstResponder() {
        guard let window else { return }
        guard window.firstResponder !== self else { return }

        if !hasRequestedFirstResponder {
            previousFirstResponder = window.firstResponder
            hasRequestedFirstResponder = true
        }

        if window.makeFirstResponder(self) {
            return
        }

        guard !firstResponderRequestScheduled else { return }
        firstResponderRequestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.firstResponderRequestScheduled = false
            guard let window = self.window else { return }
            if window.firstResponder !== self {
                _ = window.makeFirstResponder(self)
            }
        }
    }

    func restorePreviousFirstResponder() {
        guard let window, window.firstResponder === self else { return }
        _ = window.makeFirstResponder(previousFirstResponder)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {
            onEscape()
        } else {
            onKeyDown?(event)
        }
        // Consume repeats and unrecognized keys while recording so arrow and
        // navigation input cannot escape into SwiftUI focus movement.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, let onEscape {
            onEscape()
        } else {
            onKeyDown?(event)
        }
        // Command/control key equivalents (including command-arrow) are
        // offered here before keyDown; route them through the same formatter.
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        onFlagsChanged?(event)
    }

    /// A session event tap is active only while this view exists in the key
    /// recording window. It captures Control-arrow before Mission Control can
    /// consume that system shortcut, while the first-responder path remains a
    /// permission-free fallback for ordinary input.
    private func startEventTapIfNeeded() {
        guard eventTap == nil,
              NSApp.isActive,
              window?.isKeyWindow == true else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installCaptureLifecycleObserversIfNeeded() {
        let center = NotificationCenter.default
        if !isObservingApplicationLifecycle {
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )
            center.addObserver(
                self,
                selector: #selector(captureLifecycleDidResign),
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )
            isObservingApplicationLifecycle = true
        }

        guard let window else { return }
        if observedCaptureWindow !== window {
            if let observedCaptureWindow {
                center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedCaptureWindow)
                center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedCaptureWindow)
            }
            center.addObserver(
                self,
                selector: #selector(recordingWindowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(captureLifecycleDidResign),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            observedCaptureWindow = window
        }
    }

    private func removeCaptureLifecycleObservers() {
        let center = NotificationCenter.default
        if isObservingApplicationLifecycle {
            center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
            center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp)
            isObservingApplicationLifecycle = false
        }
        if let observedCaptureWindow {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedCaptureWindow)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedCaptureWindow)
            self.observedCaptureWindow = nil
        }
    }

    @objc private func applicationDidBecomeActive() {
        requestFirstResponder()
        startEventTapIfNeeded()
    }

    @objc private func recordingWindowDidBecomeKey() {
        requestFirstResponder()
        startEventTapIfNeeded()
    }

    @objc private func captureLifecycleDidResign() {
        stopEventTap()
    }

    private func stopEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let view = Unmanaged<KeyboardShortcutCaptureResponderView>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = view.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard NSApp.isActive, view.window?.isKeyWindow == true else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if let appKitEvent = NSEvent(cgEvent: event) {
                view.keyDown(with: appKitEvent)
            }
            return nil
        case .keyUp:
            // Keep the matching release away from the system shortcut handler.
            return nil
        default:
            return Unmanaged.passUnretained(event)
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
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var draftKeyCode: UInt16?
    @State private var draftKeyLabel = ""
    @State private var draftModifiers: Set<KeyboardShortcut.Modifier> = []
    @State private var currentModifierFlags: NSEvent.ModifierFlags = []
    @State private var didEditDraft = false

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
        .overlay {
            if isRecording {
                KeyboardShortcutCaptureResponder(
                    onKeyDown: { event in
                        guard let captured = KeyboardShortcutCaptureFormatter.shortcut(
                            for: event,
                            isFunctionModifierPressed: currentModifierFlags.contains(.function)
                        ) else {
                            return
                        }
                        draftKeyCode = captured.keyCode
                        draftKeyLabel = KeyboardShortcutCaptureFormatter.keyLabel(for: event)
                        draftModifiers = captured.modifiers
                        didEditDraft = true
                    },
                    onFlagsChanged: { event in
                        guard let modifierFlag = KeyboardShortcutCaptureFormatter.modifierFlag(for: event.keyCode) else {
                            return
                        }
                        if event.modifierFlags.contains(modifierFlag) {
                            currentModifierFlags.insert(modifierFlag)
                        } else {
                            currentModifierFlags.remove(modifierFlag)
                        }

                        // Before the final key is pressed, show held
                        // modifiers as removable chips. Once a key is
                        // captured, keep the draft stable so releasing a
                        // modifier cannot mutate the saved chord.
                        if draftKeyCode == nil {
                            draftModifiers = KeyboardShortcutCaptureFormatter.modifierSet(for: currentModifierFlags)
                        }
                    },
                    onEscape: {
                        stopRecording(commit: false)
                    }
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
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
        onRecordingChange(true)
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
        isRecording = false
        onRecordingChange(false)
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
