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

    func testKeyboardShortcutPlaybackPreservesArrowKeyAndSecondaryFunctionFlag() {
        let shortcut = KeyboardShortcut(
            keyCode: 123,
            modifiers: [.function],
            displayString: "fn←"
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

        XCTAssertEqual(result, .success("Sent fn←"))
        XCTAssertEqual(postedEvents.count, 2)
        XCTAssertEqual(
            postedEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [123, 123]
        )
        XCTAssertEqual(postedEvents.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(
            postedEvents.map(\.flags),
            [CGEventFlags.maskSecondaryFn, CGEventFlags.maskSecondaryFn]
        )
    }

    func testControlLeftPlaybackAddsImplicitSecondaryFunctionFlagToBothEvents() {
        let shortcut = KeyboardShortcut(
            keyCode: 123,
            modifiers: [.control],
            displayString: "⌃←"
        )
        let postedEvents = executeAndCollect(shortcut)
        let expectedFlags: CGEventFlags = [.maskControl, .maskSecondaryFn]

        XCTAssertEqual(postedEvents.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(
            postedEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [123, 123]
        )
        XCTAssertEqual(postedEvents.map(\.flags), [expectedFlags, expectedFlags])
    }

    func testPlainNavigationPlaybackAddsImplicitSecondaryFunctionFlag() {
        for keyCode in [UInt16(115), 116, 117, 119, 121, 123, 124, 125, 126] {
            let shortcut = KeyboardShortcut(
                keyCode: keyCode,
                modifiers: [],
                displayString: "arrow"
            )
            let postedEvents = executeAndCollect(shortcut)

            XCTAssertEqual(postedEvents.map(\.type), [.keyDown, .keyUp])
            XCTAssertEqual(
                postedEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                [Int64(keyCode), Int64(keyCode)]
            )
            XCTAssertEqual(
                postedEvents.map(\.flags),
                [CGEventFlags.maskSecondaryFn, CGEventFlags.maskSecondaryFn],
                "Navigation key code \(keyCode) should carry macOS's implicit secondary-function flag"
            )
        }
    }

    func testF1PlaybackDoesNotAddImplicitSecondaryFunctionFlagWithoutExplicitFn() {
        let shortcut = KeyboardShortcut(
            keyCode: 122,
            modifiers: [],
            displayString: "F1"
        )
        let postedEvents = executeAndCollect(shortcut)

        XCTAssertEqual(postedEvents.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(
            postedEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [122, 122]
        )
        XCTAssertEqual(postedEvents.map(\.flags), [CGEventFlags(), CGEventFlags()])
    }

    func testControlLetterPlaybackDoesNotAddSecondaryFunctionFlag() {
        let shortcut = KeyboardShortcut(
            keyCode: 35,
            modifiers: [.control],
            displayString: "⌃P"
        )
        let postedEvents = executeAndCollect(shortcut)

        XCTAssertEqual(postedEvents.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(
            postedEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) },
            [35, 35]
        )
        XCTAssertEqual(
            postedEvents.map(\.flags),
            [CGEventFlags.maskControl, CGEventFlags.maskControl]
        )
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

    private func executeAndCollect(_ shortcut: KeyboardShortcut) -> [CGEvent] {
        var postedEvents: [CGEvent] = []
        let runner = ActionRunner(
            postEventAccessProvider: { true },
            eventPoster: { postedEvents.append($0) }
        )

        runner.execute(
            mapping: Mapping(
                action: .keyboardShortcut,
                command: shortcut.displayString,
                keyboardShortcut: shortcut
            ),
            completion: { _ in }
        )

        return postedEvents
    }
}
