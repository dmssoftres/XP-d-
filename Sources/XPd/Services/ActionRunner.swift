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

    private enum WindowMutationResult {
        case success(Int)
        case failure(AXError)
    }

    private let workspace = NSWorkspace.shared

    /// Pure seams shared by the AX implementation and focused tests.
    static func orderedWindowCandidates<T>(focused: T?, main: T?) -> [T] {
        [focused, main].compactMap { $0 }
    }

    static func toggleOperation(
        applicationIsActive: Bool,
        targetWindowIsMinimized: Bool?
    ) -> ToggleOperation {
        applicationIsActive && targetWindowIsMinimized != true ? .minimize : .restore
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
                completion(toggle(runningApplication, requestedName: requestedName))
            } else {
                completion(restore(runningApplication, requestedName: requestedName, promptForAccess: false))
            }
            return
        }

        guard let applicationURL = applicationURL(for: requestedName) else {
            completion(.failure("Application not found: \(requestedName)"))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration) { application, error in
            let result: ActionExecutionResult
            if let error {
                result = .failure("Could not open \(requestedName): \(error.localizedDescription)")
            } else if let application {
                result = .success("Opened \(application.localizedName ?? requestedName)")
            } else {
                result = .failure("Could not open \(requestedName)")
            }

            Task { @MainActor in
                completion(result)
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
        requestedName: String
    ) -> ActionExecutionResult {
        // A physical button press is not an explicit permission request.  A
        // failed preflight should produce a stable status message, not a
        // repeated system prompt on every press.
        guard hasAccessibilityAccess(prompt: false) else {
            return .failure("Allow XP[d] in Accessibility, then press again")
        }

        if Self.toggleOperation(
            applicationIsActive: application.isActive,
            targetWindowIsMinimized: targetWindowIsMinimized(application)
        ) == .minimize {
            return minimize(application, requestedName: requestedName)
        }
        return restore(application, requestedName: requestedName, promptForAccess: true)
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
        promptForAccess: Bool
    ) -> ActionExecutionResult {
        let name = displayName(for: application, fallback: requestedName)
        // Restoration may be reached from a physical button press.  Keep the
        // check silent for all action execution; the inspector's explicit
        // access button is the only place that may prompt macOS.
        let hasAccess = hasAccessibilityAccess(prompt: false)
        var restoreFailed = false

        if hasAccess, case .failure = setMinimized(false, for: application) {
            restoreFailed = true
        }

        guard application.activate(options: [.activateAllWindows]) else {
            return .failure("Could not activate \(name)")
        }

        if promptForAccess, !hasAccess {
            return .failure("Activated \(name); allow XP[d] in Accessibility to restore minimized windows")
        }
        if restoreFailed {
            return .failure("Activated \(name), but could not restore its windows")
        }
        return .success("Activated \(name)")
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
