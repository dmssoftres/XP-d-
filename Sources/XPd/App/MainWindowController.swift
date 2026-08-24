import AppKit
import SwiftUI

/// Owns the narrow AppKit edge needed to show a SwiftUI scene window after it
/// has been miniaturized or closed. The window remains SwiftUI-owned; retaining
/// its NSWindow lets a remote action restore the same scene without routing
/// XP[d] through the external-application Accessibility path.
@MainActor
final class MainWindowController {
    enum ToggleOperation: Equatable {
        case hide
        case show
    }

    typealias ActivationHandler = @MainActor () -> Void

    private var window: NSWindow?
    private let activateApplication: ActivationHandler

    init(
        activateApplication: @escaping ActivationHandler = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.activateApplication = activateApplication
    }

    func register(_ window: NSWindow) {
        // SwiftUI may remove a closed WindowGroup window from its scene graph.
        // Retaining this one window preserves its hosting hierarchy so the
        // hardware can bring it back without relying on Launch Services.
        window.isReleasedWhenClosed = false
        self.window = window
    }

    func toggle() -> ActionExecutionResult {
        guard let window else {
            return .failure("XP[d] window is not ready yet")
        }

        switch Self.operation(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isKeyWindow: window.isKeyWindow,
            applicationIsActive: NSApp.isActive
        ) {
        case .hide:
            window.orderOut(nil)
            return .success("Hid XP[d]")
        case .show:
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            activateApplication()
            return .success("Opened XP[d]")
        }
    }

    static func operation(
        isVisible: Bool,
        isMiniaturized: Bool,
        isKeyWindow: Bool,
        applicationIsActive: Bool
    ) -> ToggleOperation {
        isVisible && !isMiniaturized && isKeyWindow && applicationIsActive
            ? .hide
            : .show
    }
}

/// Captures the NSWindow created by the main SwiftUI scene. No view state is
/// duplicated here; the representable only reports its containing window.
struct MainWindowRegistrationView: NSViewRepresentable {
    let controller: MainWindowController

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(controller: controller)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.controller = controller
        nsView.registerContainingWindowIfAvailable()
    }

    @MainActor
    final class RegistrationView: NSView {
        weak var controller: MainWindowController?

        init(controller: MainWindowController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerContainingWindowIfAvailable()
        }

        func registerContainingWindowIfAvailable() {
            guard let window else { return }
            controller?.register(window)
        }
    }
}
