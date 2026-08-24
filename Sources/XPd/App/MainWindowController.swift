import AppKit
import SwiftUI

private final class MainWindowObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}

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
    typealias ExternalApplicationProvider = @MainActor () -> ExternalApplicationTarget?
    typealias ExternalApplicationActivationHandler = @MainActor (
        _ target: ExternalApplicationTarget
    ) -> ActionExecutionResult

    struct ExternalApplicationTarget: Equatable {
        let processIdentifier: pid_t
        let displayName: String

        init(processIdentifier: pid_t, displayName: String = "external application") {
            self.processIdentifier = processIdentifier
            self.displayName = displayName
        }
    }

    private var window: NSWindow?
    private let activateApplication: ActivationHandler
    private let externalApplicationActivation: ExternalApplicationActivationHandler
    private let workspaceNotificationCenter: NotificationCenter
    private var lastExternalApplication: ExternalApplicationTarget?
    private var activationObserver: MainWindowObserverToken?
    private var terminationObserver: MainWindowObserverToken?

    init(
        activateApplication: @escaping ActivationHandler = {
            NSApp.activate(ignoringOtherApps: true)
        },
        externalApplicationProvider: @escaping ExternalApplicationProvider = {
            MainWindowController.currentExternalApplicationTarget()
        },
        externalApplicationActivation: @escaping ExternalApplicationActivationHandler = {
            MainWindowController.activateExternalApplication($0)
        },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.activateApplication = activateApplication
        self.externalApplicationActivation = externalApplicationActivation
        self.workspaceNotificationCenter = workspaceNotificationCenter
        lastExternalApplication = Self.validatedExternalApplicationTarget(
            externalApplicationProvider()
        )
        observeWorkspaceApplications()
    }

    deinit {
        if let activationObserver {
            workspaceNotificationCenter.removeObserver(activationObserver.token)
        }
        if let terminationObserver {
            workspaceNotificationCenter.removeObserver(terminationObserver.token)
        }
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

    @discardableResult
    @MainActor
    func setRunMode(_ enabled: Bool) -> ActionExecutionResult {
        guard enabled else {
            return .success("Edit mode")
        }

        guard let window else {
            return .failure("XP[d] window is unavailable")
        }
        guard let target = lastExternalApplication else {
            return .failure("No external application is available")
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            // Ordering does not activate XP[d] or make it the key window.
            window.orderFrontRegardless()
        }

        return externalApplicationActivation(target)
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

    static func currentExternalApplicationTarget() -> ExternalApplicationTarget? {
        externalApplicationTarget(from: NSWorkspace.shared.frontmostApplication)
    }

    private static func externalApplicationTarget(
        from application: NSRunningApplication?
    ) -> ExternalApplicationTarget? {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else {
            return nil
        }
        return ExternalApplicationTarget(
            processIdentifier: application.processIdentifier,
            displayName: application.localizedName ?? "external application"
        )
    }

    private static func validatedExternalApplicationTarget(
        _ target: ExternalApplicationTarget?
    ) -> ExternalApplicationTarget? {
        guard let target,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return target
    }

    private static func activateExternalApplication(
        _ target: ExternalApplicationTarget
    ) -> ActionExecutionResult {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated else {
            return .failure("External application is no longer running")
        }
        guard application.activate(options: [.activateAllWindows]) else {
            return .failure("Could not return focus to \(target.displayName)")
        }
        return .success("Returned focus to \(target.displayName)")
    }

    private func observeWorkspaceApplications() {
        let activationObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                self?.recordExternalApplication(application)
            }
        }
        self.activationObserver = MainWindowObserverToken(activationObserver)

        let terminationObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                self?.clearTerminatedExternalApplication(application)
            }
        }
        self.terminationObserver = MainWindowObserverToken(terminationObserver)
    }

    private func recordExternalApplication(_ application: NSRunningApplication) {
        guard let target = Self.externalApplicationTarget(from: application) else { return }
        lastExternalApplication = target
    }

    private func clearTerminatedExternalApplication(_ application: NSRunningApplication) {
        guard application.processIdentifier == lastExternalApplication?.processIdentifier else {
            return
        }
        lastExternalApplication = nil
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
