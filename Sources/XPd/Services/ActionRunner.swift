import AppKit
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
    private let workspace = NSWorkspace.shared

    func execute(
        mapping: Mapping,
        completion: @escaping @MainActor (ActionExecutionResult) -> Void
    ) {
        guard mapping.action == .openApplication else { return }

        let requestedName = mapping.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            completion(.failure("Application name is empty"))
            return
        }

        if let runningApplication = runningApplication(matching: requestedName) {
            let activated = runningApplication.activate(options: [.activateAllWindows])
            if activated {
                completion(.success("Activated \(displayName(for: runningApplication, fallback: requestedName))"))
            } else {
                completion(.failure("Could not activate \(requestedName)"))
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

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored])
            .lowercased()
    }

    private func displayName(for application: NSRunningApplication, fallback: String) -> String {
        application.localizedName ?? fallback
    }
}
