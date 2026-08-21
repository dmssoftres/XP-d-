import AppKit
import SwiftUI

@MainActor
final class InputOverlayController {
    private let model: InputOverlayModel
    private let panel: NSPanel
    private var visibilityGeneration = 0

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

        model.visibilityDidChange = { [weak self] hasVisibleEntries in
            self?.updatePanelVisibility(hasVisibleEntries)
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

    func recognize(control: RemoteControl, gesture: GestureKind) {
        model.recognize(control: control, gesture: gesture)
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

    func showMIDI(
        profileName: String,
        layer: MIDIMappingLayer = .primary,
        control: RemoteControl? = nil,
        summary: String? = nil
    ) {
        guard model.isEnabled else { return }
        ensureVisible()
        model.showMIDI(
            profileName: profileName,
            layer: layer,
            control: control,
            summary: summary
        )
    }

    func clearMIDI() {
        model.clearMIDI()
        if !model.isEnabled, model.profileSelection == nil {
            panel.orderOut(nil)
        }
    }

    private func ensureVisible() {
        visibilityGeneration &+= 1
        panel.alphaValue = 1
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    private func updatePanelVisibility(_ hasVisibleEntries: Bool) {
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        if hasVisibleEntries {
            panel.alphaValue = 1
            panel.contentView?.needsLayout = true
            panel.contentView?.needsDisplay = true
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
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
