import AppKit
import XCTest
@testable import XPd

final class KeyboardShortcutCaptureFormatterTests: XCTestCase {
    func testFormatsSimultaneousCommandShiftPChord() throws {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        )

        let shortcut = try XCTUnwrap(KeyboardShortcutCaptureFormatter.shortcut(for: try XCTUnwrap(event)))
        XCTAssertEqual(shortcut.keyCode, 35)
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
        XCTAssertEqual(shortcut.displayString, "⌘⇧P")
        XCTAssertFalse(shortcut.displayString.contains("→"))
    }

    func testModifierFlagsAreStateOnlyAndIncludeFunction() {
        let modifiers = KeyboardShortcutCaptureFormatter.modifierSet(
            for: [.command, .control, .option, .shift, .function]
        )

        XCTAssertEqual(
            KeyboardShortcut.modifierOrder.filter { modifiers.contains($0) },
            [.command, .control, .option, .shift, .function]
        )
        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.displayString(key: "P", modifiers: modifiers),
            "⌘⌃⌥⇧fnP"
        )
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.modifier(for: 55), .command)
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.modifier(for: 63), .function)
    }

    func testLabelsFunctionKeysExplicitly() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 118
        ))

        XCTAssertEqual(KeyboardShortcutCaptureFormatter.keyLabel(for: event), "F4")
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.shortcut(for: event)?.displayString, "⌘F4")
        XCTAssertEqual(KeyboardShortcut.functionKeyLabel(for: 111), "F12")
    }

    func testRemovingModifierOrKeyLeavesOneChordAndClearCanBeEmpty() {
        let shortcut = KeyboardShortcut(
            keyCode: 35,
            modifiers: [.command, .shift],
            displayString: "⌘⇧P"
        )
        var editedModifiers = shortcut.modifiers
        editedModifiers.remove(.shift)

        XCTAssertEqual(
            KeyboardShortcutCaptureFormatter.displayString(key: "P", modifiers: editedModifiers),
            "⌘P"
        )
        XCTAssertTrue(editedModifiers.contains(.command))

        editedModifiers.removeAll()
        XCTAssertTrue(editedModifiers.isEmpty)
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.displayString(key: "P", modifiers: editedModifiers), "P")
    }

    func testMappingDecodesLegacyCommandOnlyShortcutWithoutExecutableModel() throws {
        let data = #"{"action":"Keyboard shortcut","command":"⌘P","usesTapApplication":false}"#.data(using: .utf8)!
        let mapping = try JSONDecoder().decode(Mapping.self, from: data)

        XCTAssertEqual(mapping.action, .keyboardShortcut)
        XCTAssertEqual(mapping.command, "⌘P")
        XCTAssertNil(mapping.keyboardShortcut)
        XCTAssertTrue(mapping.remoteTriggerModifiers.isEmpty)
    }

    func testMappingRoundTripsStructuredShortcutAndDisplayCommand() throws {
        let shortcut = KeyboardShortcut(
            keyCode: 35,
            modifiers: [.command, .shift],
            displayString: "⌘⇧P"
        )
        let mapping = Mapping(
            action: .keyboardShortcut,
            command: shortcut.displayString,
            keyboardShortcut: shortcut,
            remoteTriggerModifiers: [.command, .shift],
            remoteTriggerFunctionKey: 118
        )

        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(Mapping.self, from: data)

        XCTAssertEqual(decoded, mapping)
        XCTAssertEqual(decoded.command, "⌘⇧P")
        XCTAssertEqual(decoded.keyboardShortcut?.keyCode, 35)
        XCTAssertEqual(decoded.keyboardShortcut?.modifiers, [.command, .shift])
        XCTAssertEqual(decoded.remoteTriggerModifiers, [.command, .shift])
        XCTAssertEqual(decoded.remoteTriggerFunctionKey, 118)
    }
}
