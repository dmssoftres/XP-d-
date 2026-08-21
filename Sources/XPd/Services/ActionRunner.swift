import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct ActionExecutionResult: Equatable {
    let succeeded: Bool
    let message: String

    static func success(_ message: String) -> Self {
        Self(succeeded: true, message: message)
    }

    static func failure(_ message: String) -> Self {
        Self(succeeded: false, message: message)
    }
}

/// Executes the small set of actions currently supported by the v0.1 input
/// path. Application mappings are intentionally resolved through Launch
/// Services/AppKit; no shell command is involved.
@MainActor
final class ActionRunner {
    enum ToggleOperation: Equatable {
        case minimize
        case restore
    }

    enum ForegroundVerification: Equatable {
        case notForegrounded
        case foregroundedWindowVisible
        case foregroundedWindowStateUnknown
    }

    enum ActivationFailure: Equatable {
        case workspaceError(String)
        case missingApplication
        case exactApplicationPathChanged
        case applicationPathUnavailable
        case notForegrounded
    }

    enum ActivationDecision: Equatable {
        case completed
        case retry
        case workspaceFallback
        case failure(ActivationFailure)
    }

    enum WorkspaceFallbackDecision: Equatable {
        case ready
        case failure(ActivationFailure)
    }

    private enum WindowMutationResult {
        case success(Int)
        case failure(AXError)
    }

    private let workspace = NSWorkspace.shared

    private static let activationVerificationAttempts = 6
    private static let activationVerificationDelay = Duration.milliseconds(50)

    /// Pure seams shared by the AX implementation and focused tests.
    static func orderedWindowCandidates<T>(focused: T?, main: T?) -> [T] {
        [focused, main].compactMap { $0 }
    }

    static func toggleOperation(
        applicationIsActive: Bool,
        targetWindowIsMinimized: Bool?,
        applicationIsHidden: Bool = false
    ) -> ToggleOperation {
        applicationIsActive && !applicationIsHidden && targetWindowIsMinimized == false
            ? .minimize
            : .restore
    }

    static func foregroundVerification(
        applicationIsActive: Bool,
        applicationIsHidden: Bool,
        targetWindowIsMinimized: Bool?
    ) -> ForegroundVerification {
        guard applicationIsActive, !applicationIsHidden else {
            return .notForegrounded
        }
        guard let targetWindowIsMinimized else {
            return .foregroundedWindowStateUnknown
        }
        return targetWindowIsMinimized
            ? .notForegrounded
            : .foregroundedWindowVisible
    }

    static func activationDecision(
        directRequestAccepted: Bool,
        targetBecameActive: Bool,
        remainingAttempts: Int,
        allowWorkspaceFallback: Bool
    ) -> ActivationDecision {
        guard directRequestAccepted else {
            return allowWorkspaceFallback
                ? .workspaceFallback
                : .failure(.notForegrounded)
        }
        if targetBecameActive {
            return .completed
        }
        if remainingAttempts > 0 {
            return .retry
        }
        if allowWorkspaceFallback {
            return .workspaceFallback
        }
        return .failure(.notForegrounded)
    }

    static func workspaceFallbackDecision(
        errorMessage: String?,
        applicationReturned: Bool,
        exactPathMatches: Bool
    ) -> WorkspaceFallbackDecision {
        if let errorMessage {
            return .failure(.workspaceError(errorMessage))
        }
        guard applicationReturned else {
            return .failure(.missingApplication)
        }
        guard exactPathMatches else {
            return .failure(.exactApplicationPathChanged)
        }
        return .ready
    }

    static func workspaceFallbackConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    static func applicationPathsMatch(requestedPath: String, runningURL: URL) -> Bool {
        let expandedPath = (requestedPath as NSString).expandingTildeInPath
        let requestedURL = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let normalizedRunningURL = runningURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return requestedURL == normalizedRunningURL
    }

    func execute(
        mapping: Mapping,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        guard mapping.action == .openApplication || mapping.action == .toggleApplication else { return }

        let requestedName = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            completion(.failure("Application name is empty"))
            return
        }

        if let runningApplication = runningApplication(matching: requestedName) {
            if mapping.action == .toggleApplication {
                toggle(
                    runningApplication,
                    requestedName: requestedName,
                    completion: completion
                )
            } else {
                restore(
                    runningApplication,
                    requestedName: requestedName,
                    promptForAccess: false,
                    completion: completion
                )
            }
            return
        }

        guard let applicationURL = applicationURL(for: requestedName) else {
            completion(.failure("Application not found: \(requestedName)"))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        workspace.openApplication(at: applicationURL, configuration: configuration) { application, error in
            Task { @MainActor in
                if let error {
                    completion(.failure("Could not open \(requestedName): \(error.localizedDescription)"))
                    return
                }

                guard let application else {
                    completion(.failure("Could not open \(requestedName)"))
                    return
                }

                if !Self.allowsBundleIdentifierFallback(for: requestedName) {
                    guard let returnedURL = application.bundleURL,
                          Self.applicationPathsMatch(
                              requestedPath: requestedName,
                              runningURL: returnedURL
                          ) else {
                        completion(.failure("Could not open \(requestedName): exact application path changed"))
                        return
                    }
                }

                self.restore(
                    application,
                    requestedName: requestedName,
                    promptForAccess: false,
                    completion: completion
                )
            }
        }
    }

    func scroll(
        direction: WheelScrollDirection,
        sensitivity: Double,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        // Posting a synthetic scroll event is a different capability from
        // reading another application's AX window tree.  Do not use
        // AXIsProcessTrustedWithOptions here: it can cause the system access
        // prompt to be evaluated for every wheel detent.  The preflight check
        // is silent and is the API that matches CGEvent.post's permission.
        guard hasPostEventAccess else {
            completion(.failure("Allow XP[d] in Accessibility, then rotate again"))
            return
        }

        let settings = WheelScrollSettings(sensitivity: sensitivity)
        let delta = settings.delta(for: direction)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else {
            completion(.failure("Could not create a scroll event"))
            return
        }

        event.post(tap: .cghidEventTap)
        completion(.success(direction == .up ? "Scrolled up" : "Scrolled down"))
    }

    func requestScrollingAccess() -> Bool {
        // This is only called by the explicit inspector button.  It is the
        // sole place where XP[d] asks macOS to show an access prompt.
        return requestPostEventAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        workspace.open(url)
    }

    var canPostScrollEvents: Bool {
        hasPostEventAccess
    }

    var canControlApplicationWindows: Bool {
        hasAccessibilityAccess(prompt: false)
    }

    private func runningApplication(matching requestedName: String) -> NSRunningApplication? {
        let applications = NSWorkspace.shared.runningApplications
        let normalizedName = normalized(requestedName)

        if !Self.allowsBundleIdentifierFallback(for: requestedName) {
            if let byExactBundlePath = applications.first(where: {
                guard let runningURL = $0.bundleURL else { return false }
                return Self.applicationPathsMatch(
                    requestedPath: requestedName,
                    runningURL: runningURL
                )
            }) {
                return byExactBundlePath
            }

            // An explicit path identifies one exact app copy. Falling back to
            // its bundle ID could target another installed/development copy.
            return nil
        }

        if let byBundleIdentifier = applications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(requestedName) == .orderedSame
        }) {
            return byBundleIdentifier
        }

        return applications.first(where: {
            guard let localizedName = $0.localizedName else { return false }
            return normalized(localizedName) == normalizedName
                || normalized(localizedName + ".app") == normalizedName
        })
    }

    static func allowsBundleIdentifierFallback(for requestedName: String) -> Bool {
        !requestedName.contains("/")
    }

    private func applicationURL(for requestedName: String) -> URL? {
        if requestedName.contains(".") && requestedName.split(separator: ".").count > 1,
           let bundleURL = workspace.urlForApplication(withBundleIdentifier: requestedName) {
            return bundleURL
        }

        let expandedPath = (requestedName as NSString).expandingTildeInPath
        let pathURL = URL(fileURLWithPath: expandedPath)
        if FileManager.default.fileExists(atPath: pathURL.path) {
            return pathURL
        }

        let appName = requestedName.hasSuffix(".app") ? requestedName : "\(requestedName).app"
        let searchDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(appName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func toggle(
        _ application: NSRunningApplication,
        requestedName: String,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        // A physical button press is not an explicit permission request.  A
        // failed preflight should produce a stable status message, not a
        // repeated system prompt on every press.
        guard hasAccessibilityAccess(prompt: false) else {
            completion(.failure("Allow XP[d] in Accessibility, then press again"))
            return
        }

        if Self.toggleOperation(
            applicationIsActive: application.isActive,
            targetWindowIsMinimized: targetWindowIsMinimized(application),
            applicationIsHidden: application.isHidden
        ) == .minimize {
            completion(minimize(application, requestedName: requestedName))
            return
        }

        // Toggle's minimize branch is synchronous because the AX mutation is
        // the requested operation. Restoration is asynchronous: success is
        // reported only after the application is actually frontmost.
        restore(
            application,
            requestedName: requestedName,
            promptForAccess: true,
            completion: completion
        )
    }

    private func minimize(
        _ application: NSRunningApplication,
        requestedName: String
    ) -> ActionExecutionResult {
        guard hasAccessibilityAccess(prompt: false) else {
            return .failure("Allow XP[d] in Accessibility, then press again")
        }

        let name = displayName(for: application, fallback: requestedName)
        switch setMinimized(true, for: application) {
        case .success(let affectedWindows) where affectedWindows > 0:
            return .success("Minimized \(name)")
        case .success:
            return .failure("No minimizable window found for \(name)")
        case .failure:
            return .failure("Could not minimize \(name)")
        }
    }

    private func restore(
        _ application: NSRunningApplication,
        requestedName: String,
        promptForAccess: Bool,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        let name = displayName(for: application, fallback: requestedName)
        // Restoration may be reached from a physical button press.  Keep the
        // check silent for all action execution; the inspector's explicit
        // access button is the only place that may prompt macOS.
        let hasAccess = hasAccessibilityAccess(prompt: false)
        var restoreFailed = false

        if hasAccess, case .failure = setMinimized(false, for: application) {
            restoreFailed = true
        }

        // Hidden applications do not reliably become visible from activate
        // alone.  unhide() is a non-AX AppKit request and never prompts.
        _ = application.unhide()
        let requestAccepted = application.activate(options: [.activateAllWindows])

        verifyActivation(
            application,
            requestedName: requestedName,
            displayName: name,
            promptForAccess: promptForAccess,
            hasAccessibilityAccess: hasAccess,
            restoreFailed: restoreFailed,
            directRequestAccepted: requestAccepted,
            remainingAttempts: requestAccepted ? Self.activationVerificationAttempts : 0,
            allowWorkspaceFallback: true,
            completion: completion
        )
    }

    private func verifyActivation(
        _ application: NSRunningApplication,
        requestedName: String,
        displayName name: String,
        promptForAccess: Bool,
        hasAccessibilityAccess: Bool,
        restoreFailed: Bool,
        directRequestAccepted: Bool,
        remainingAttempts: Int,
        allowWorkspaceFallback: Bool,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        let verification = foregroundVerification(for: application)
        let targetBecameActive = verification != .notForegrounded
        switch Self.activationDecision(
            directRequestAccepted: directRequestAccepted,
            targetBecameActive: targetBecameActive,
            remainingAttempts: remainingAttempts,
            allowWorkspaceFallback: allowWorkspaceFallback
        ) {
        case .completed:
            completion(Self.activationResult(
                displayName: name,
                promptForAccess: promptForAccess,
                hasAccessibilityAccess: hasAccessibilityAccess,
                restoreFailed: restoreFailed,
                verification: verification
            ))
        case .retry:
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.activationVerificationDelay)
                guard let self else { return }
                self.verifyActivation(
                    application,
                    requestedName: requestedName,
                    displayName: name,
                    promptForAccess: promptForAccess,
                    hasAccessibilityAccess: hasAccessibilityAccess,
                    restoreFailed: restoreFailed,
                    directRequestAccepted: directRequestAccepted,
                    remainingAttempts: remainingAttempts - 1,
                    allowWorkspaceFallback: allowWorkspaceFallback,
                    completion: completion
                )
            }
        case .workspaceFallback:
            reopenAndVerify(
                application,
                requestedName: requestedName,
                displayName: name,
                promptForAccess: promptForAccess,
                hasAccessibilityAccess: hasAccessibilityAccess,
                restoreFailed: restoreFailed,
                completion: completion
            )
        case .failure(let failure):
            completion(Self.activationFailureResult(displayName: name, failure: failure))
        }
    }

    private func reopenAndVerify(
        _ application: NSRunningApplication,
        requestedName: String,
        displayName name: String,
        promptForAccess: Bool,
        hasAccessibilityAccess: Bool,
        restoreFailed: Bool,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        guard let applicationURL = application.bundleURL else {
            completion(Self.activationFailureResult(
                displayName: name,
                failure: .applicationPathUnavailable
            ))
            return
        }

        let configuration = Self.workspaceFallbackConfiguration()
        workspace.openApplication(at: applicationURL, configuration: configuration) { [weak self] fallbackApplication, error in
            Task { @MainActor in
                guard let self else { return }
                let fallbackURL = fallbackApplication?.bundleURL
                let fallbackDecision = Self.workspaceFallbackDecision(
                    errorMessage: error?.localizedDescription,
                    applicationReturned: fallbackApplication != nil,
                    exactPathMatches: fallbackURL.map {
                        Self.applicationPathsMatch(
                            requestedPath: applicationURL.path,
                            runningURL: $0
                        )
                    } ?? false
                )
                guard case .ready = fallbackDecision else {
                    if case .failure(let failure) = fallbackDecision {
                        completion(Self.activationFailureResult(displayName: name, failure: failure))
                    }
                    return
                }

                guard let fallbackApplication else { return }
                _ = fallbackApplication.unhide()
                var fallbackRestoreFailed = restoreFailed
                if hasAccessibilityAccess,
                   case .failure = self.setMinimized(false, for: fallbackApplication) {
                    fallbackRestoreFailed = true
                }
                self.verifyActivation(
                    fallbackApplication,
                    requestedName: requestedName,
                    displayName: name,
                    promptForAccess: promptForAccess,
                    hasAccessibilityAccess: hasAccessibilityAccess,
                    restoreFailed: fallbackRestoreFailed,
                    directRequestAccepted: true,
                    remainingAttempts: Self.activationVerificationAttempts,
                    allowWorkspaceFallback: false,
                    completion: completion
                )
            }
        }
    }

    static func activationResult(
        displayName name: String,
        promptForAccess: Bool,
        hasAccessibilityAccess: Bool,
        restoreFailed: Bool,
        verification: ForegroundVerification
    ) -> ActionExecutionResult {
        if promptForAccess, !hasAccessibilityAccess {
            return .failure("Activated \(name); allow XP[d] in Accessibility to restore minimized windows")
        }
        if restoreFailed {
            return .failure("Activated \(name), but could not restore its windows")
        }
        switch verification {
        case .foregroundedWindowVisible:
            return .success("Activated \(name)")
        case .foregroundedWindowStateUnknown:
            return .success("Activated \(name); window visibility unavailable")
        case .notForegrounded:
            return .failure("Could not activate \(name)")
        }
    }

    static func activationFailureResult(
        displayName name: String,
        failure: ActivationFailure
    ) -> ActionExecutionResult {
        switch failure {
        case .workspaceError(let message):
            return .failure("Could not activate \(name): \(message)")
        case .exactApplicationPathChanged:
            return .failure("Could not activate \(name): exact application path changed")
        case .applicationPathUnavailable:
            return .failure("Could not activate \(name): application path is unavailable")
        case .missingApplication, .notForegrounded:
            return .failure("Could not activate \(name)")
        }
    }

    private func foregroundVerification(
        for application: NSRunningApplication
    ) -> ForegroundVerification {
        Self.foregroundVerification(
            applicationIsActive: application.isActive,
            applicationIsHidden: application.isHidden,
            targetWindowIsMinimized: targetWindowIsMinimized(application)
        )
    }

    private func hasAccessibilityAccess(prompt: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private var hasPostEventAccess: Bool {
        CGPreflightPostEventAccess()
    }

    private func requestPostEventAccess() -> Bool {
        if hasPostEventAccess {
            return true
        }
        return CGRequestPostEventAccess()
    }

    private func setMinimized(
        _ minimized: Bool,
        for application: NSRunningApplication
    ) -> WindowMutationResult {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var firstError: AXError?
        let minimizedValue: CFTypeRef = minimized ? kCFBooleanTrue! : kCFBooleanFalse!

        // Limit mutations to the focused window, falling back to the main
        // window.  Iterating kAXWindowsAttribute would minimize unrelated
        // documents belonging to the same application.
        for window in targetWindows(for: applicationElement) {
            var isSettable = DarwinBoolean(false)
            let settableResult = AXUIElementIsAttributeSettable(
                window,
                kAXMinimizedAttribute as CFString,
                &isSettable
            )
            guard settableResult == .success, isSettable.boolValue else { continue }

            let setResult = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                minimizedValue
            )
            if setResult == .success {
                return .success(1)
            } else if firstError == nil {
                firstError = setResult
            }
        }

        if let firstError {
            return .failure(firstError)
        }
        return .success(0)
    }

    private func targetWindowIsMinimized(_ application: NSRunningApplication) -> Bool? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = targetWindows(for: applicationElement).first else {
            return nil
        }

        var minimizedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &minimizedValue
        ) == .success else {
            return nil
        }
        return minimizedValue as? Bool
    }

    private func targetWindows(for applicationElement: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success,
           let focusedValue {
            candidates.append(focusedValue as! AXUIElement)
        }

        var mainValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            applicationElement,
            kAXMainWindowAttribute as CFString,
            &mainValue
        ) == .success,
           let mainValue {
            candidates.append(mainValue as! AXUIElement)
        }

        return Self.orderedWindowCandidates(
            focused: candidates.first,
            main: candidates.dropFirst().first
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored])
            .lowercased()
    }

    private func displayName(for application: NSRunningApplication, fallback: String) -> String {
        application.localizedName ?? fallback
    }
}
