import Foundation
import Observation

struct InputOverlayPresentation: Equatable {
    let shortcutTokens: [String]
    let title: String
    let isConfigured: Bool

    init(mapping: Mapping) {
        let command = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)

        if mapping.action == .keyboardShortcut, !command.isEmpty {
            shortcutTokens = Self.shortcutTokens(from: command)
            title = command
            isConfigured = true
        } else if mapping.action == .noAction {
            shortcutTokens = []
            title = "No action"
            isConfigured = true
        } else if !command.isEmpty {
            shortcutTokens = []
            if mapping.action == .openApplication || mapping.action == .toggleApplication {
                title = URL(fileURLWithPath: command)
                    .deletingPathExtension()
                    .lastPathComponent
            } else {
                title = command
            }
            isConfigured = true
        } else {
            shortcutTokens = []
            title = "Not set"
            isConfigured = false
        }
    }

    private static func shortcutTokens(from command: String) -> [String] {
        let replacements = [
            "Command": "⌘", "Cmd": "⌘", "Control": "⌃", "Ctrl": "⌃",
            "Option": "⌥", "Alt": "⌥", "Shift": "⇧"
        ]
        var normalized = command
        for (word, glyph) in replacements {
            normalized = normalized.replacingOccurrences(
                of: word,
                with: glyph,
                options: [.caseInsensitive]
            )
        }

        let pieces = normalized
            .split(whereSeparator: { $0 == "+" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? [command] : pieces
    }
}

extension RemoteControl {
    var overlayLabel: String {
        switch self {
        case .wheelCCW: "↶"
        case .wheelCW: "↷"
        case .wheelCenter: "Wheel"
        default: rawValue
        }
    }
}

struct InputOverlayEntry: Identifiable, Equatable {
    let id = UUID()
    let control: RemoteControl
    let tap: InputOverlayPresentation
    let hold: InputOverlayPresentation
    let doubleTap: InputOverlayPresentation
    let pressedAt: Date
    var releasedAt: Date?
    var recognizedGesture: GestureKind?

    var isPressed: Bool { releasedAt == nil }
}

struct ProfileOverlaySelection: Equatable {
    let profiles: [String]
    let selectedProfile: String
}

/// The compact, persistent status card shown while a MIDI profile owns the
/// remote.  A nil summary means the workspace is armed but no control is
/// currently held; the profile and layer remain visible in that state.
struct MIDIOverlayPresentation: Equatable {
    let profileName: String
    let layer: MIDIMappingLayer
    let control: RemoteControl?
    let summary: String?

    var lockTitle: String { "MIDI LOCK" }

    var layerTitle: String {
        layer == .function ? "FN LAYER" : "PRIMARY"
    }
}

struct InputOverlayStatusNotice: Equatable {
    let title: String
    let message: String
    let systemImage: String
}

@Observable
@MainActor
final class InputOverlayModel {
    private(set) var entries: [InputOverlayEntry] = []
    private(set) var profileSelection: ProfileOverlaySelection?
    private(set) var midiPresentation: MIDIOverlayPresentation?
    private(set) var statusNotice: InputOverlayStatusNotice?
    var midiState: MIDIOverlayPresentation? { midiPresentation }
    var isEnabled = true
    private(set) var displayDuration: TimeInterval
    @ObservationIgnored var visibilityDidChange: ((Bool) -> Void)?
    @ObservationIgnored private var midiDismissalTimer: Timer?
    @ObservationIgnored private var statusNoticeDismissalTimer: Timer?

    init(displayDuration: TimeInterval = 4) {
        self.displayDuration = displayDuration
    }

    var visibleEntries: [InputOverlayEntry] {
        Array(entries.suffix(3).reversed())
    }

    func press(
        control: RemoteControl,
        tap: InputOverlayPresentation,
        hold: InputOverlayPresentation,
        doubleTap: InputOverlayPresentation
    ) {
        guard isEnabled else { return }
        guard !entries.contains(where: { $0.control == control && $0.isPressed }) else { return }

        entries.append(InputOverlayEntry(
            control: control,
            tap: tap,
            hold: hold,
            doubleTap: doubleTap,
            pressedAt: Date(),
            recognizedGesture: nil
        ))
        if entries.count > 12 {
            entries.removeFirst(entries.count - 12)
        }
        visibilityDidChange?(true)
    }

    func release(control: RemoteControl) {
        guard let index = entries.lastIndex(where: { $0.control == control && $0.isPressed }) else { return }
        let id = entries[index].id
        entries[index].releasedAt = Date()
        let duration = displayDuration

        let expirationTimer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.entries.removeAll { $0.id == id }
                self.visibilityDidChange?(self.hasVisibleContent)
            }
        }
        RunLoop.main.add(expirationTimer, forMode: .common)
    }

    func recognize(control: RemoteControl, gesture: GestureKind) {
        guard let index = entries.lastIndex(where: { $0.control == control }) else { return }
        entries[index].recognizedGesture = gesture
    }

    func setDisplayDuration(_ duration: TimeInterval) {
        displayDuration = max(1, duration)
    }

    func showProfiles(_ profiles: [String], selectedProfile: String) {
        profileSelection = ProfileOverlaySelection(
            profiles: profiles,
            selectedProfile: selectedProfile
        )
        visibilityDidChange?(true)
    }

    func hideProfiles() {
        profileSelection = nil
        visibilityDidChange?(hasVisibleContent)
    }

    func showMIDI(
        profileName: String,
        layer: MIDIMappingLayer = .primary,
        control: RemoteControl? = nil,
        summary: String? = nil
    ) {
        guard isEnabled else { return }
        statusNoticeDismissalTimer?.invalidate()
        statusNoticeDismissalTimer = nil
        statusNotice = nil
        midiPresentation = MIDIOverlayPresentation(
            profileName: profileName,
            layer: layer,
            control: control,
            summary: summary
        )
        visibilityDidChange?(true)
        scheduleMIDIDismissal()
    }

    func clearMIDI() {
        guard midiPresentation != nil else { return }
        midiDismissalTimer?.invalidate()
        midiDismissalTimer = nil
        midiPresentation = nil
        visibilityDidChange?(hasVisibleContent)
    }

    func showStatusNotice(title: String, message: String, systemImage: String) {
        guard isEnabled else { return }
        statusNotice = InputOverlayStatusNotice(
            title: title,
            message: message,
            systemImage: systemImage
        )
        visibilityDidChange?(true)
        statusNoticeDismissalTimer?.invalidate()
        let timer = Timer(timeInterval: displayDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearStatusNotice()
            }
        }
        statusNoticeDismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func clearStatusNotice() {
        guard statusNotice != nil else { return }
        statusNoticeDismissalTimer?.invalidate()
        statusNoticeDismissalTimer = nil
        statusNotice = nil
        visibilityDidChange?(hasVisibleContent)
    }

    func reset() {
        entries.removeAll()
        midiDismissalTimer?.invalidate()
        midiDismissalTimer = nil
        midiPresentation = nil
        statusNoticeDismissalTimer?.invalidate()
        statusNoticeDismissalTimer = nil
        statusNotice = nil
        visibilityDidChange?(hasVisibleContent)
    }

    private var hasVisibleContent: Bool {
        profileSelection != nil || midiPresentation != nil || statusNotice != nil || !entries.isEmpty
    }

    private func scheduleMIDIDismissal() {
        midiDismissalTimer?.invalidate()
        let timer = Timer(timeInterval: displayDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearMIDI()
            }
        }
        midiDismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
