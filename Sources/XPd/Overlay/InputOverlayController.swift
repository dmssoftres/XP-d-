import AppKit
import SwiftUI

@MainActor
final class InputOverlayController {
    private let model = InputOverlayModel()
    private let panel: NSPanel

    init() {
        let size = NSSize(width: 280, height: 210)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: InputOverlayView(model: model))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionOnActiveScreen() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        model.isEnabled = enabled
        if enabled {
            ensureVisible()
        } else {
            model.reset()
            panel.orderOut(nil)
        }
    }

    func press(control: RemoteControl, tap: Mapping, hold: Mapping) {
        guard model.isEnabled else { return }
        ensureVisible()
        model.press(
            control: control,
            tap: InputOverlayPresentation(control: control, mapping: tap),
            hold: InputOverlayPresentation.configured(control: control, mapping: hold)
        )
    }

    func release(control: RemoteControl) {
        model.release(control: control)
    }

    func pulse(control: RemoteControl, tap: Mapping, hold: Mapping) {
        press(control: control, tap: tap, hold: hold)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            self?.release(control: control)
        }
    }

    private func ensureVisible() {
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let margin: CGFloat = 18
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - margin,
            y: visible.maxY - panel.frame.height - margin
        ))
    }
}
