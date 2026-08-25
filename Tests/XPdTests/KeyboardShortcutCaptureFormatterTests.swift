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

    func testCapturesArrowKeysWhenCharacterPayloadIsEmpty() throws {
        let expectedLabels: [UInt16: String] = [
            123: "←",
            124: "→",
            125: "↓",
            126: "↑"
        ]

        for (keyCode, expectedLabel) in expectedLabels {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ))

            let shortcut = try XCTUnwrap(KeyboardShortcutCaptureFormatter.shortcut(for: event))
            XCTAssertEqual(shortcut.keyCode, keyCode)
            XCTAssertTrue(shortcut.modifiers.isEmpty)
            XCTAssertEqual(shortcut.displayString, expectedLabel)
        }
    }

    func testRetainsModifiersWhenCapturingArrowWithFunction() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .control, .option, .shift, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123
        ))

        let shortcut = try XCTUnwrap(KeyboardShortcutCaptureFormatter.shortcut(for: event))
        XCTAssertEqual(shortcut.keyCode, 123)
        XCTAssertEqual(
            shortcut.modifiers,
            [.command, .control, .option, .shift, .function]
        )
        XCTAssertEqual(shortcut.displayString, "⌘⌃⌥⇧fn←")
    }

    func testFunctionKeyCodeIsModifierOnlyDuringCapture() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 63
        ))

        XCTAssertEqual(KeyboardShortcutCaptureFormatter.modifier(for: 63), .function)
        XCTAssertEqual(KeyboardShortcutCaptureFormatter.modifierFlag(for: 63), .function)
        XCTAssertNil(KeyboardShortcutCaptureFormatter.shortcut(for: event))
    }

    @MainActor
    func testResponderConsumesArrowKeyAndRoutesEscapeToCancellation() throws {
        let responder = KeyboardShortcutCaptureResponderView(frame: .zero)
        var capturedKeyCodes: [UInt16] = []
        var capturedModifierEvents: [(keyCode: UInt16, flags: NSEvent.ModifierFlags)] = []
        var cancellationCount = 0
        responder.onKeyDown = { capturedKeyCodes.append($0.keyCode) }
        responder.onFlagsChanged = {
            capturedModifierEvents.append((keyCode: $0.keyCode, flags: $0.modifierFlags))
        }
        responder.onEscape = { cancellationCount += 1 }

        let arrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123
        ))
        responder.keyDown(with: arrow)

        XCTAssertEqual(capturedKeyCodes, [123])
        XCTAssertEqual(cancellationCount, 0)

        let commandRight = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ))
        XCTAssertTrue(responder.performKeyEquivalent(with: commandRight))

        XCTAssertEqual(capturedKeyCodes, [123, 124])

        let functionFlagsChanged = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 63
        ))
        responder.flagsChanged(with: functionFlagsChanged)

        XCTAssertEqual(capturedModifierEvents.count, 1)
        XCTAssertEqual(capturedModifierEvents.first?.keyCode, 63)
        XCTAssertTrue(capturedModifierEvents.first?.flags.contains(.function) == true)

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))
        responder.keyDown(with: escape)

        XCTAssertEqual(capturedKeyCodes, [123, 124])
        XCTAssertEqual(cancellationCount, 1)
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
