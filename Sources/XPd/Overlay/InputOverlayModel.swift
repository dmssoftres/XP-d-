import Foundation
import Observation

struct InputOverlayPresentation: Equatable {
    let tokens: [String]
    let detail: String

    init(control: RemoteControl, mapping: Mapping) {
        let command = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)

        if mapping.action == .keyboardShortcut, !command.isEmpty {
            tokens = Self.shortcutTokens(from: command)
            detail = control.rawValue
        } else {
            tokens = [control.overlayLabel]
            detail = command.isEmpty ? mapping.action.rawValue : command
        }
    }

    static func configured(control: RemoteControl, mapping: Mapping) -> InputOverlayPresentation? {
        let command = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mapping.action != .noAction else { return nil }
        guard mapping.action != .keyboardShortcut || !command.isEmpty else { return nil }
        return InputOverlayPresentation(control: control, mapping: mapping)
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

private extension RemoteControl {
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
    let hold: InputOverlayPresentation?
    let pressedAt: Date
    var releasedAt: Date?

    var isPressed: Bool { releasedAt == nil }
}

@Observable
@MainActor
final class InputOverlayModel {
    private(set) var entries: [InputOverlayEntry] = []
    var isEnabled = true

    var visibleEntries: [InputOverlayEntry] {
        Array(entries.suffix(3).reversed())
    }

    func press(
        control: RemoteControl,
        tap: InputOverlayPresentation,
        hold: InputOverlayPresentation?
    ) {
        guard isEnabled else { return }
        guard !entries.contains(where: { $0.control == control && $0.isPressed }) else { return }

        entries.append(InputOverlayEntry(
            control: control,
            tap: tap,
            hold: hold,
            pressedAt: Date()
        ))
        if entries.count > 12 {
            entries.removeFirst(entries.count - 12)
        }
    }

    func release(control: RemoteControl) {
        guard let index = entries.lastIndex(where: { $0.control == control && $0.isPressed }) else { return }
        let id = entries[index].id
        entries[index].releasedAt = Date()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_350))
            self?.entries.removeAll { $0.id == id }
        }
    }

    func reset() {
        entries.removeAll()
    }
}
