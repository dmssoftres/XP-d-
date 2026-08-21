import AppKit
import XCTest
@testable import XPd

@MainActor
final class ActionRunnerForegroundingTests: XCTestCase {
    func testActiveVisibleWindowIsVerifiedAsForegrounded() {
        XCTAssertEqual(
            ActionRunner.foregroundVerification(
                applicationIsActive: true,
                applicationIsHidden: false,
                targetWindowIsMinimized: false
            ),
            .foregroundedWindowVisible
        )
    }

    func testActiveUnknownWindowStateIsDistinctFromVisibleWindow() {
        XCTAssertEqual(
            ActionRunner.foregroundVerification(
                applicationIsActive: true,
                applicationIsHidden: false,
                targetWindowIsMinimized: nil
            ),
            .foregroundedWindowStateUnknown
        )
    }

    func testHiddenOrMinimizedApplicationIsNotForegrounded() {
        XCTAssertEqual(
            ActionRunner.foregroundVerification(
                applicationIsActive: true,
                applicationIsHidden: true,
                targetWindowIsMinimized: false
            ),
            .notForegrounded
        )
        XCTAssertEqual(
            ActionRunner.foregroundVerification(
                applicationIsActive: true,
                applicationIsHidden: false,
                targetWindowIsMinimized: true
            ),
            .notForegrounded
        )
    }

    func testDirectActivationPollsThenFallsBackAfterVerificationBudget() {
        XCTAssertEqual(
            ActionRunner.activationDecision(
                directRequestAccepted: true,
                targetBecameActive: true,
                remainingAttempts: 2,
                allowWorkspaceFallback: true
            ),
            .completed
        )
        XCTAssertEqual(
            ActionRunner.activationDecision(
                directRequestAccepted: true,
                targetBecameActive: false,
                remainingAttempts: 2,
                allowWorkspaceFallback: true
            ),
            .retry
        )
        XCTAssertEqual(
            ActionRunner.activationDecision(
                directRequestAccepted: true,
                targetBecameActive: false,
                remainingAttempts: 0,
                allowWorkspaceFallback: true
            ),
            .workspaceFallback
        )
    }

    func testRejectedDirectActivationFallsBackImmediately() {
        XCTAssertEqual(
            ActionRunner.activationDecision(
                directRequestAccepted: false,
                targetBecameActive: false,
                remainingAttempts: 2,
                allowWorkspaceFallback: true
            ),
            .workspaceFallback
        )
    }

    func testFallbackVerificationDoesNotRetryWorkspaceOrCompleteWithoutForeground() {
        XCTAssertEqual(
            ActionRunner.activationDecision(
                directRequestAccepted: true,
                targetBecameActive: false,
                remainingAttempts: 0,
                allowWorkspaceFallback: false
            ),
            .failure(.notForegrounded)
        )
        XCTAssertEqual(
            ActionRunner.activationDecision(
                directRequestAccepted: true,
                targetBecameActive: true,
                remainingAttempts: 0,
                allowWorkspaceFallback: false
            ),
            .completed
        )
    }

    func testWorkspaceFallbackRejectsErrorsMissingAppsAndExactPathChanges() {
        XCTAssertEqual(
            ActionRunner.workspaceFallbackDecision(
                errorMessage: "Launch Services denied request",
                applicationReturned: false,
                exactPathMatches: false
            ),
            .failure(.workspaceError("Launch Services denied request"))
        )
        XCTAssertEqual(
            ActionRunner.workspaceFallbackDecision(
                errorMessage: nil,
                applicationReturned: false,
                exactPathMatches: false
            ),
            .failure(.missingApplication)
        )
        XCTAssertEqual(
            ActionRunner.workspaceFallbackDecision(
                errorMessage: nil,
                applicationReturned: true,
                exactPathMatches: false
            ),
            .failure(.exactApplicationPathChanged)
        )
    }

    func testWorkspaceFallbackCanProceedOnlyForAnExactReturnedApp() {
        XCTAssertEqual(
            ActionRunner.workspaceFallbackDecision(
                errorMessage: nil,
                applicationReturned: true,
                exactPathMatches: true
            ),
            .ready
        )
    }

    func testActivationCompletionDistinguishesUnknownWindowVisibility() {
        let visible = ActionRunner.activationResult(
            displayName: "Demo",
            promptForAccess: false,
            hasAccessibilityAccess: true,
            restoreFailed: false,
            verification: .foregroundedWindowVisible
        )
        XCTAssertEqual(visible, .success("Activated Demo"))

        let unknown = ActionRunner.activationResult(
            displayName: "Menu Bar Demo",
            promptForAccess: false,
            hasAccessibilityAccess: false,
            restoreFailed: false,
            verification: .foregroundedWindowStateUnknown
        )
        XCTAssertEqual(unknown, .success("Activated Menu Bar Demo; window visibility unavailable"))
    }

    func testActivationFailureCompletionIsUseful() {
        XCTAssertEqual(
            ActionRunner.activationFailureResult(
                displayName: "Demo",
                failure: .workspaceError("denied")
            ),
            .failure("Could not activate Demo: denied")
        )
        XCTAssertEqual(
            ActionRunner.activationFailureResult(
                displayName: "Demo",
                failure: .exactApplicationPathChanged
            ),
            .failure("Could not activate Demo: exact application path changed")
        )
    }

    func testWorkspaceFallbackReusesTheExactRunningApplication() {
        let configuration = ActionRunner.workspaceFallbackConfiguration()

        XCTAssertTrue(configuration.activates)
        XCTAssertFalse(configuration.createsNewApplicationInstance)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
    }

    func testHiddenActiveApplicationIsRestoredInsteadOfMinimized() {
        XCTAssertEqual(
            ActionRunner.toggleOperation(
                applicationIsActive: true,
                targetWindowIsMinimized: false,
                applicationIsHidden: true
            ),
            .restore
        )
        XCTAssertEqual(
            ActionRunner.toggleOperation(
                applicationIsActive: true,
                targetWindowIsMinimized: nil,
                applicationIsHidden: false
            ),
            .restore
        )
    }
}
