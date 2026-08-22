import AppKit
import XCTest
@testable import XPd

@MainActor
final class ActionRunnerKeyboardShortcutTests: XCTestCase {
    func testKeyboardShortcutPostsKeyDownThenKeyUpWithCapturedKeyAndFlags() throws {
        let shortcut = KeyboardShortcut(
            keyCode: 35,
            modifiers: [.command, .control, .option, .shift, .function],
            displayString: "⌘⌃⌥⇧fnP"
        )
        var postedEvents: [CGEvent] = []
        let runner = ActionRunner(
            postEventAccessProvider: { true },
            eventPoster: { postedEvents.append($0) }
        )
        var result: ActionExecutionResult?

        runner.execute(
            mapping: Mapping(
                action: .keyboardShortcut,
                command: shortcut.displayString,
                keyboardShortcut: shortcut
            )
        ) { result = $0 }

        XCTAssertEqual(result, .success("Sent ⌘⌃⌥⇧fnP"))
        XCTAssertEqual(postedEvents.count, 2)

        let expectedFlags = ActionRunner.cgEventFlags(for: shortcut.modifiers)
        XCTAssertEqual(postedEvents[0].type, .keyDown)
        XCTAssertEqual(postedEvents[1].type, .keyUp)
        XCTAssertEqual(
            postedEvents[0].getIntegerValueField(.keyboardEventKeycode),
            Int64(shortcut.keyCode)
        )
        XCTAssertEqual(
            postedEvents[1].getIntegerValueField(.keyboardEventKeycode),
            Int64(shortcut.keyCode)
        )
        XCTAssertEqual(postedEvents[0].flags, expectedFlags)
        XCTAssertEqual(postedEvents[1].flags, expectedFlags)
    }

    func testKeyboardShortcutFailsWithoutPostEventAccessAndDoesNotPost() {
        let shortcut = KeyboardShortcut(keyCode: 35, modifiers: [.command], displayString: "⌘P")
        var postedEvents: [CGEvent] = []
        let runner = ActionRunner(
            postEventAccessProvider: { false },
            eventPoster: { postedEvents.append($0) }
        )
        var result: ActionExecutionResult?

        runner.execute(
            mapping: Mapping(
                action: .keyboardShortcut,
                command: shortcut.displayString,
                keyboardShortcut: shortcut
            )
        ) { result = $0 }

        XCTAssertEqual(result, .failure("Allow XP[d] in Accessibility, then press again"))
        XCTAssertTrue(postedEvents.isEmpty)
    }

    func testEmptyAndLegacyCommandOnlyMappingsRequireRerecording() {
        let runner = ActionRunner(
            postEventAccessProvider: { true },
            eventPoster: { _ in XCTFail("Malformed mappings must not post events") }
        )

        var emptyResult: ActionExecutionResult?
        runner.execute(mapping: Mapping(action: .keyboardShortcut), completion: { emptyResult = $0 })
        XCTAssertEqual(emptyResult, .failure("Record a keyboard shortcut first"))

        var legacyResult: ActionExecutionResult?
        runner.execute(
            mapping: Mapping(action: .keyboardShortcut, command: "⌘ → P"),
            completion: { legacyResult = $0 }
        )
        XCTAssertEqual(legacyResult, .failure("This shortcut uses an old format; re-record it"))
    }

    func testShortcutWithEmptyDisplayStringIsRejectedAsMalformed() {
        let shortcut = KeyboardShortcut(keyCode: 35, modifiers: [.command], displayString: " ")
        let runner = ActionRunner(
            postEventAccessProvider: { true },
            eventPoster: { _ in XCTFail("Malformed mappings must not post events") }
        )
        var result: ActionExecutionResult?

        runner.execute(
            mapping: Mapping(
                action: .keyboardShortcut,
                keyboardShortcut: shortcut
            )
        ) { result = $0 }

        XCTAssertEqual(result, .failure("Keyboard shortcut is incomplete; re-record it"))
    }

    func testShortcutWithOutOfRangeVirtualKeyIsRejectedAsMalformed() {
        let shortcut = KeyboardShortcut(keyCode: 128, modifiers: [.command], displayString: "⌘P")
        let runner = ActionRunner(
            postEventAccessProvider: { true },
            eventPoster: { _ in XCTFail("Malformed mappings must not post events") }
        )
        var result: ActionExecutionResult?

        runner.execute(
            mapping: Mapping(
                action: .keyboardShortcut,
                command: shortcut.displayString,
                keyboardShortcut: shortcut
            )
        ) { result = $0 }

        XCTAssertEqual(result, .failure("Keyboard shortcut has an invalid key; re-record it"))
    }
}
