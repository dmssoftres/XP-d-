import AppKit
import SwiftUI

extension MIDIButtonMapping {
    /// Short two-part label shared by the remote picture and the key map.
    var displayDetail: (primary: String, secondary: String) {
        switch kind {
        case .note:
            return ("\(Self.noteName(note)) (\(note))", "Ch \(channel) · V \(velocity)")
        case .cc:
            return ("CC \(controller)", "Ch \(channel) · \(pressValue)/\(releaseValue)")
        case .program:
            return ("PC \(program)", "Ch \(channel)")
        case .chord:
            return (chord.map(String.init).joined(separator: ","), "Ch \(channel) · V \(velocity)")
        case .noAction:
            return ("No output", "")
        }
    }

    static func noteName(_ note: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        guard (0...127).contains(note) else { return "N" }
        return names[note % 12] + String(note / 12 - 2)
    }
}

/// What the on-screen key map shows: every K button of the active profile
/// with its actions (base and MOD layers), plus the wheel.
struct KeyMapPresentation: Equatable {
    struct Key: Equatable, Identifiable {
        let control: RemoteControl
        let title: String
        let isModifier: Bool
        let lines: [String]

        var id: RemoteControl { control }
    }

    static let maximumLinesPerKey = 5

    let profileName: String
    let isMIDI: Bool
    let keys: [Key]
    let wheelLines: [String]

    func key(_ control: RemoteControl) -> Key? {
        keys.first { $0.control == control }
    }

    /// Caps a key's lines, replacing the overflow with "+N more".
    static func capped(_ lines: [String]) -> [String] {
        guard lines.count > maximumLinesPerKey else { return lines }
        let shown = lines.prefix(maximumLinesPerKey - 1)
        return Array(shown) + ["+\(lines.count - shown.count) more"]
    }
}

/// A floating, non-activating panel centred on the active screen. A click
/// anywhere on the card hides it.
@MainActor
final class KeyMapOverlayController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ presentation: KeyMapPresentation, hideAfter seconds: TimeInterval) {
        let view = KeyMapCard(presentation: presentation) { [weak self] in
            self?.hide()
            self?.onDismiss?()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
            self?.onDismiss?()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// The key map laid out like the remote: K8/K9/K10 on the left, then
/// K4·K1, K5·K2, K6·K3 and K7 across the bottom.
struct KeyMapCard: View {
    let presentation: KeyMapPresentation
    let dismiss: () -> Void

    private static let rows: [[RemoteControl]] = [
        [.k8, .k4, .k1],
        [.k9, .k5, .k2],
        [.k10, .k6, .k3]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(presentation.profileName)
                    .font(.headline)
                Text(presentation.isMIDI ? "MIDI" : "Standard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Click to close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Self.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(Self.rows[row], id: \.self) { control in
                            cell(control)
                        }
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    cell(.k7).gridCellColumns(2)
                }
            }
            if !presentation.wheelLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wheel").font(.caption.weight(.semibold))
                    ForEach(presentation.wheelLines, id: \.self) { line in
                        Text(line).font(.caption).lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key map for \(presentation.profileName)")
    }

    private func cell(_ control: RemoteControl) -> some View {
        let key = presentation.key(control)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(control.rawValue).font(.caption.weight(.bold))
                if let title = key?.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if key?.isModifier == true {
                    Text("MOD")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(.yellow.opacity(0.5), in: Capsule())
                }
            }
            if let lines = key?.lines, !lines.isEmpty {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption2).lineLimit(1).truncationMode(.tail)
                }
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
