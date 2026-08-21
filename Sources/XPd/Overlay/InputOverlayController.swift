import AppKit
import SwiftUI

@MainActor
final class InputOverlayController {
    private let model: InputOverlayModel
    private let panel: NSPanel

    init(displayDuration: TimeInterval = 4) {
        model = InputOverlayModel(displayDuration: displayDuration)
        let size = NSSize(width: 316, height: 324)
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

        model.visibilityDidChange = { [weak panel] hasVisibleEntries in
            guard let panel else { return }
            if hasVisibleEntries {
                panel.contentView?.needsLayout = true
                panel.contentView?.needsDisplay = true
            } else {
                panel.orderOut(nil)
            }
        }

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
            if model.profileSelection == nil {
                panel.orderOut(nil)
            }
        }
    }

    func setDisplayDuration(_ duration: TimeInterval) {
        model.setDisplayDuration(duration)
    }

    func press(control: RemoteControl, tap: Mapping, hold: Mapping, doubleTap: Mapping) {
        guard model.isEnabled else { return }
        ensureVisible()
        model.press(
            control: control,
            tap: InputOverlayPresentation(mapping: tap),
            hold: InputOverlayPresentation(mapping: hold),
            doubleTap: InputOverlayPresentation(mapping: doubleTap)
        )
    }

    func release(control: RemoteControl) {
        model.release(control: control)
    }

    func pulse(control: RemoteControl, tap: Mapping, hold: Mapping, doubleTap: Mapping) {
        press(control: control, tap: tap, hold: hold, doubleTap: doubleTap)
        // Common-mode timers keep firing while macOS is tracking the pointer.
        let releaseTimer = Timer(timeInterval: 1.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.release(control: control)
            }
        }
        RunLoop.main.add(releaseTimer, forMode: .common)
    }

    func showProfileSelector(profiles: [String], selectedProfile: String) {
        ensureVisible()
        model.showProfiles(profiles, selectedProfile: selectedProfile)
    }

    func hideProfileSelector() {
        model.hideProfiles()
        if !model.isEnabled {
            panel.orderOut(nil)
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
