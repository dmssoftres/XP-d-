import AppKit
import Foundation
import XCTest
@testable import XPd

private final class ProcessInvocationRecorder: @unchecked Sendable {
    struct Invocation: Equatable {
        let executableURL: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private var stored: [Invocation] = []

    func append(executableURL: URL, arguments: [String]) {
        lock.withLock {
            stored.append(Invocation(executableURL: executableURL, arguments: arguments))
        }
    }

    var invocations: [Invocation] {
        lock.withLock { stored }
    }
}

private actor ProcessGate {
    private var waiters: [String: [CheckedContinuation<ActionRunner.ProcessExecutionOutcome, Never>]] = [:]

    func hold(key: String) async -> ActionRunner.ProcessExecutionOutcome {
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(key: String, with outcome: ActionRunner.ProcessExecutionOutcome = .exited(0)) {
        let continuations = waiters.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume(returning: outcome)
        }
    }

    var waitingCount: Int {
        waiters.values.reduce(0) { $0 + $1.count }
    }
}

@MainActor
final class ActionRunnerMappedActionsTests: XCTestCase {
    func testAutomationDisabledBlocksProcessBackedActions() async {
        let recorder = ProcessInvocationRecorder()
        let runner = ActionRunner(
            processExecutor: { executableURL, arguments in
                recorder.append(executableURL: executableURL, arguments: arguments)
                return .exited(0)
            }
        )

        let result = await execute(
            runner,
            Mapping(action: .shellCommand, command: "open -a Notes")
        )

        XCTAssertEqual(
            result,
            .failure("Enable automation for this mapping before running it")
        )
        XCTAssertTrue(recorder.invocations.isEmpty)
    }

    func testProcessBackedActionsUseExactExecutablesAndArguments() async {
        let recorder = ProcessInvocationRecorder()
        let runner = ActionRunner(
            processExecutor: { executableURL, arguments in
                recorder.append(executableURL: executableURL, arguments: arguments)
                return .exited(0)
            }
        )

        let shortcut = await execute(runner, enabled(Mapping(action: .macOSShortcut, command: "Morning Setup")))
        let appleScript = await execute(
            runner,
            enabled(Mapping(action: .appleScript, command: "tell application \"Finder\" to activate"))
        )
        let shell = await execute(runner, enabled(Mapping(action: .shellCommand, command: "open -a Notes")))

        XCTAssertEqual(shortcut, .success("Ran shortcut Morning Setup"))
        XCTAssertEqual(appleScript, .success("Ran AppleScript"))
        XCTAssertEqual(shell, .success("Ran shell command"))
        XCTAssertEqual(
            recorder.invocations,
            [
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
                    arguments: ["run", "Morning Setup"]
                ),
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", "tell application \"Finder\" to activate"]
                ),
                .init(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: ["-c", "open -a Notes"]
                )
            ]
        )
    }

    func testProcessFailureReportsExitStatusAndLaunchFailure() async {
        let failedExit = ActionRunner(processExecutor: { _, _ in .exited(7) })
        let exitResult = await execute(
            failedExit,
            enabled(Mapping(action: .shellCommand, command: "false"))
        )
        XCTAssertEqual(exitResult, .failure("Shell command failed with exit status 7"))

        let failedLaunch = ActionRunner(processExecutor: { _, _ in .launchFailure("missing") })
        let launchResult = await execute(
            failedLaunch,
            enabled(Mapping(action: .appleScript, command: "return 1"))
        )
        XCTAssertEqual(launchResult, .failure("Could not run AppleScript: missing"))
    }

    func testBlankProcessActionsFailWithoutLaunching() async {
        let recorder = ProcessInvocationRecorder()
        let runner = ActionRunner(processExecutor: { executableURL, arguments in
            recorder.append(executableURL: executableURL, arguments: arguments)
            return .exited(0)
        })

        let shortcut = await execute(runner, enabled(Mapping(action: .macOSShortcut, command: "  ")))
        let appleScript = await execute(runner, enabled(Mapping(action: .appleScript, command: "\n")))
        let shell = await execute(runner, enabled(Mapping(action: .shellCommand, command: "")))
        XCTAssertEqual(shortcut, .failure("Choose a macOS Shortcut first"))
        XCTAssertEqual(appleScript, .failure("Enter AppleScript code first"))
        XCTAssertEqual(shell, .failure("Enter a shell command first"))
        XCTAssertTrue(recorder.invocations.isEmpty)
    }

    func testDuplicateProcessInvocationIsRejectedAndSlotReleases() async {
        let gate = ProcessGate()
        let runner = ActionRunner(
            processExecutor: { _, arguments in
                await gate.hold(key: arguments.last ?? "")
            }
        )
        let mapping = enabled(Mapping(action: .shellCommand, command: "same"))

        let first = Task { await execute(runner, mapping) }
        await waitForWaiters(gate, count: 1)

        let duplicate = await execute(runner, mapping)
        XCTAssertEqual(duplicate, .failure("This action is already running"))

        await gate.release(key: "same")
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .success("Ran shell command"))

        let recycled = Task { await execute(runner, mapping) }
        await waitForWaiters(gate, count: 1)
        await gate.release(key: "same")
        let recycledResult = await recycled.value
        XCTAssertEqual(recycledResult, .success("Ran shell command"))
    }

    func testGlobalProcessCapRejectsFifthAndReleasesAllSlots() async {
        let gate = ProcessGate()
        let runner = ActionRunner(
            processExecutor: { _, arguments in
                await gate.hold(key: arguments.last ?? "")
            }
        )
        let keys = ["one", "two", "three", "four"]
        let tasks = keys.map { key in
            Task {
                await execute(
                    runner,
                    enabled(Mapping(action: .shellCommand, command: key))
                )
            }
        }
        await waitForWaiters(gate, count: 4)

        let rejected = await execute(
            runner,
            enabled(Mapping(action: .shellCommand, command: "five"))
        )
        XCTAssertEqual(
            rejected,
            .failure("Too many actions are already running; try again")
        )

        for key in keys {
            await gate.release(key: key)
        }
        for task in tasks {
            let result = await task.value
            XCTAssertEqual(result, .success("Ran shell command"))
        }

        let recycled = Task {
            await execute(
                runner,
                enabled(Mapping(action: .shellCommand, command: "five"))
            )
        }
        await waitForWaiters(gate, count: 1)
        await gate.release(key: "five")
        let recycledResult = await recycled.value
        XCTAssertEqual(recycledResult, .success("Ran shell command"))
    }

    func testTimedOutProcessReportsDistinctOutcome() async {
        let runner = ActionRunner(processExecutor: { _, _ in .timedOut })
        let result = await execute(
            runner,
            enabled(Mapping(action: .shellCommand, command: "slow"))
        )

        XCTAssertEqual(
            result,
            .failure("Shell command timed out after 30 seconds")
        )
    }

    func testTimedOutCompletionReleasesInvocationForASecondTrigger() async {
        let recorder = ProcessInvocationRecorder()
        let runner = ActionRunner(
            processExecutor: { executableURL, arguments in
                recorder.append(executableURL: executableURL, arguments: arguments)
                return .timedOut
            }
        )
        let mapping = enabled(Mapping(action: .shellCommand, command: "slow"))

        let first = await execute(runner, mapping)
        let second = await execute(runner, mapping)

        XCTAssertEqual(first, .failure("Shell command timed out after 30 seconds"))
        XCTAssertEqual(second, .failure("Shell command timed out after 30 seconds"))
        XCTAssertEqual(recorder.invocations.count, 2)
    }

    func testRealProcessTimeoutWaitsForOriginalChildTermination() async {
        let startedAt = Date()
        let result = await ActionRunner.runProcessForTesting(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["1"],
            timeout: 0.02
        )

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.8)
    }

    func testMediaControlPostsPressAndReleaseAfterPermissionPreflight() async {
        var postedEvents: [CGEvent] = []
        let runner = ActionRunner(
            postEventAccessProvider: { true },
            eventPoster: { postedEvents.append($0) }
        )

        let result = await execute(
            runner,
            Mapping(action: .mediaControl, command: MediaControlAction.playPause.rawValue)
        )

        XCTAssertEqual(result, .success("Play / pause"))
        XCTAssertEqual(postedEvents.count, 2)
    }

    func testMediaControlAndWindowActionValidateTypedValues() async {
        let runner = ActionRunner(
            windowActionOverride: { action in .success("Window: \(action.rawValue)") }
        )

        let media = await execute(runner, Mapping(action: .mediaControl, command: "Unknown"))
        let invalidWindow = await execute(runner, Mapping(action: .windowDisplay, command: "Unknown"))
        let validWindow = await execute(
            runner,
            Mapping(action: .windowDisplay, command: WindowDisplayAction.toggleFullScreen.rawValue)
        )
        XCTAssertEqual(media, .failure("Choose a media control first"))
        XCTAssertEqual(invalidWindow, .failure("Choose a window or display action first"))
        XCTAssertEqual(validWindow, .success("Window: Toggle full screen"))
    }

    func testScreenDestinationCommandRoutesExactIdentity() async {
        let identity = WindowScreenDestination.Identity(vendor: 10, model: 20, serial: 30, unit: 1)
        var receivedIdentity: WindowScreenDestination.Identity?
        let runner = ActionRunner(
            screenMoveOverride: { screenIdentity in
                receivedIdentity = screenIdentity
                return .success("Moved")
            }
        )
        let destination = WindowScreenDestination(
            displayID: 42,
            name: "Studio Display",
            identity: identity
        )

        let result = await execute(
            runner,
            Mapping(action: .windowDisplay, command: destination.command)
        )

        XCTAssertEqual(receivedIdentity, identity)
        XCTAssertEqual(result, .success("Moved"))
    }

    func testScreenDestinationCommandParsingAndCenteredPlacement() {
        let identity = WindowScreenDestination.Identity(vendor: 11, model: 22, serial: 33, unit: 2)
        let destination = WindowScreenDestination(
            displayID: 73,
            name: "Side Display",
            identity: identity
        )
        XCTAssertEqual(WindowScreenDestination.identity(from: destination.command), identity)
        XCTAssertNil(WindowScreenDestination.identity(from: "Send frontmost window to screen:v1:"))
        XCTAssertNil(WindowScreenDestination.identity(from: "Send frontmost window to screen:v1:0:0:0:0"))
        XCTAssertNil(WindowScreenDestination.identity(from: "Send frontmost window to screen:v1:1:2:3:999999999999"))
        XCTAssertNil(WindowScreenDestination.identity(from: "Unknown:73"))
        XCTAssertTrue(identity.matches(.init(vendor: 11, model: 22, serial: 33, unit: 9)))
        XCTAssertFalse(identity.matches(.init(vendor: 11, model: 22, serial: 44, unit: 2)))
        XCTAssertTrue(
            WindowScreenDestination.Identity(vendor: 11, model: 22, serial: 0, unit: 2)
                .matches(.init(vendor: 11, model: 22, serial: 0, unit: 2))
        )
        let movedUnit = WindowScreenDestination(
            displayID: 74,
            name: "Side Display",
            identity: .init(vendor: 11, model: 22, serial: 33, unit: 9)
        )
        XCTAssertEqual(
            WindowScreenDestination.resolve(identity, among: [movedUnit]),
            movedUnit
        )
        let duplicateSerial = WindowScreenDestination(
            displayID: 75,
            name: "Duplicate",
            identity: .init(vendor: 11, model: 22, serial: 33, unit: 10)
        )
        XCTAssertNil(
            WindowScreenDestination.resolve(identity, among: [movedUnit, duplicateSerial])
        )
        XCTAssertEqual(
            WindowScreenDestination.resolve(identity, among: [movedUnit, destination]),
            destination
        )

        XCTAssertEqual(
            ActionRunner.centeredWindowOrigin(
                windowSize: CGSize(width: 800, height: 600),
                displayBounds: CGRect(x: -1600, y: -1000, width: 1600, height: 1000)
            ),
            CGPoint(x: -1200, y: -800)
        )
        XCTAssertEqual(
            ActionRunner.centeredWindowOrigin(
                windowSize: CGSize(width: 1800, height: 1200),
                displayBounds: CGRect(x: -1600, y: -1000, width: 1600, height: 1000)
            ),
            CGPoint(x: -1600, y: -1000)
        )
        XCTAssertEqual(
            WindowScreenDestination.accessibilityVisibleBounds(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 61, width: 1512, height: 888),
                displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)
            ),
            CGRect(x: 0, y: 33, width: 1512, height: 888)
        )
    }

    func testDisconnectedScreenDestinationFailsBeforeWindowMutation() async {
        let destination = WindowScreenDestination(
            displayID: UInt32.max,
            name: "Missing",
            identity: .init(vendor: UInt32.max, model: UInt32.max, serial: UInt32.max, unit: UInt32.max)
        )

        let result = await execute(
            ActionRunner(),
            Mapping(action: .windowDisplay, command: destination.command)
        )

        XCTAssertEqual(result, .failure("Selected screen is disconnected or ambiguous"))
    }

    func testNoActionCompletesBenignly() async {
        let result = await execute(ActionRunner(), Mapping(action: .noAction))
        XCTAssertEqual(result, .success("No action"))
    }

    private func execute(_ runner: ActionRunner, _ mapping: Mapping) async -> ActionExecutionResult {
        await withCheckedContinuation { continuation in
            runner.execute(mapping: mapping) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func enabled(_ mapping: Mapping) -> Mapping {
        var mapping = mapping
        mapping.automationEnabled = true
        return mapping
    }

    private func waitForWaiters(_ gate: ProcessGate, count: Int) async {
        for _ in 0..<1_000 {
            if await gate.waitingCount >= count {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for (count) process invocation(s)")
    }
}
