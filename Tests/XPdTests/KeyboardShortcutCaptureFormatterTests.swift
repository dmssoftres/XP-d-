import AppKit
import XCTest
@testable import XPd

final class KeyboardShortcutCaptureFormatterTests: XCTestCase {
    func testFormatsKeyboardEventWithModifiersInStableOrder() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        )

        let keyboardEvent = try! XCTUnwrap(event)
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.keyboardToken(for: keyboardEvent), "⌘⌥⇧P")
        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.keyboardToken(for: keyboardEvent, excluding: [.command, .option]),
            "⇧P"
        )
    }

    func testFormatsSpecialKeysAndSequences() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )

        XCTAssertEqual(KeyboardShortcutCaptureFormatter.keyboardToken(for: try! XCTUnwrap(event)), "⌘↩")
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.sequence(["⌘P", "K4"]), "⌘P → K4")
    }

    func testFormatsModifierPressButNotRelease() {
        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.modifierToken(keyCode: 55, modifierFlags: [.command]),
            "⌘"
        )
        XCTAssertNil(
            KeyboardShortcutCaptureFormatter.modifierToken(keyCode: 55, modifierFlags: [])
        )
    }

    func testRemovesIndividualTokensAndClearsSequence() {
        let sequence = KeyboardShortcutCaptureFormatter.sequence(["⌘", "P", "K4"])

        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.sequence(removingTokenAt: 1, from: sequence),
            "⌘ → K4"
        )
        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.sequence(removingTokenAt: 0, from: "K4"),
            ""
        )
        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.sequence(removingTokenAt: 99, from: sequence),
            sequence
        )
    }
}
