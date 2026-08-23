import AppKit
import SwiftUI

@MainActor
final class InputOverlayController {
    private let model: InputOverlayModel
    private let panel: NSPanel
    private let dismissPanel: NSPanel
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

        let dismissPanelSize = NSSize(width: 24, height: 24)
        dismissPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: dismissPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dismissPanel.contentView = NSHostingView(
            rootView: DismissInputOverlayButton(action: model.dismissNormalEntries)
        )
        dismissPanel.isOpaque = false
        dismissPanel.backgroundColor = .clear
        dismissPanel.hasShadow = false
        dismissPanel.level = .statusBar
        dismissPanel.ignoresMouseEvents = false
        dismissPanel.hidesOnDeactivate = false
        dismissPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        dismissPanel.isReleasedWhenClosed = false

        model.visibilityDidChange = { [weak self] hasVisibleEntries in
            self?.updatePanelVisibility(hasVisibleEntries)
        }
        model.regularEntriesVisibilityDidChange = { [weak self] hasVisibleRegularEntries in
            self?.updateDismissPanelVisibility(hasVisibleRegularEntries)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.positionOnActiveScreen()
                self?.positionDismissPanel()
            }
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

    func presentCompleted(control: RemoteControl, tap: Mapping, hold: Mapping, doubleTap: Mapping) {
        guard model.isEnabled else { return }
        ensureVisible()
        model.presentCompleted(
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

    func showStatusNotice(title: String, message: String, systemImage: String) {
        guard model.isEnabled else { return }
        ensureVisible()
        model.showStatusNotice(title: title, message: message, systemImage: systemImage)
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

    private func updateDismissPanelVisibility(_ hasVisibleRegularEntries: Bool) {
        if hasVisibleRegularEntries {
            positionDismissPanel()
            dismissPanel.orderFrontRegardless()
        } else {
            dismissPanel.orderOut(nil)
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

    private func positionDismissPanel() {
        // The newest card is always the first card at the top of the regular
        // stack. Keep the interactive panel small and over that card only;
        // the underlying HUD panel remains click-through everywhere else.
        let cardInset: CGFloat = 10
        let cornerInset: CGFloat = 8
        dismissPanel.setFrameOrigin(NSPoint(
            x: panel.frame.maxX - cardInset - cornerInset - dismissPanel.frame.width,
            y: panel.frame.maxY - cardInset - cornerInset - dismissPanel.frame.height
        ))
    }
}

private struct DismissInputOverlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.86))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.38), in: Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
        .contentShape(Circle())
        .accessibilityLabel("Dismiss input overlay")
        .accessibilityHint("Clears the current input HUD entries")
        .help("Dismiss input HUD")
    }
}
