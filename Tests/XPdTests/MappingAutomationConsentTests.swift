import XCTest
@testable import XPd

final class MappingAutomationConsentTests: XCTestCase {
    func testLegacyMappingDecodesAutomationDisabled() throws {
        let data = Data(#"{"action":"Run shell command","command":"open -a Notes"}"#.utf8)

        let mapping = try JSONDecoder().decode(Mapping.self, from: data)

        XCTAssertEqual(mapping.action, .shellCommand)
        XCTAssertEqual(mapping.command, "open -a Notes")
        XCTAssertFalse(mapping.automationEnabled)
    }

    func testAutomationEnabledRoundTripsThroughCodable() throws {
        let source = Mapping(
            action: .macOSShortcut,
            command: "Morning Setup",
            automationEnabled: true
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(Mapping.self, from: data)

        XCTAssertTrue(decoded.automationEnabled)
        XCTAssertEqual(decoded.command, source.command)
    }

    func testActionTransitionPreservesCommandAndDisarmsAutomation() {
        let mapping = Mapping(
            action: .shellCommand,
            command: "open -a Notes",
            automationEnabled: true
        )

        let transitioned = mapping.selectingAction(.appleScript)

        XCTAssertEqual(transitioned.command, "")
        XCTAssertEqual(transitioned.shellCommandContent, "open -a Notes")
        XCTAssertFalse(transitioned.automationEnabled)
        XCTAssertEqual(transitioned.action, .appleScript)
    }

    func testProcessContentRoundTripsThroughTypedActions() {
        let cases: [(ActionKind, String, ActionKind, String?)] = [
            (.shellCommand, "echo shell", .mediaControl, nil),
            (.appleScript, "tell application \"Finder\" to activate", .windowDisplay, nil),
            (.macOSShortcut, "Morning Setup", .switchProfile, "Global")
        ]

        for (processAction, content, intermediateAction, profileName) in cases {
            let original = Mapping(
                action: processAction,
                command: content,
                automationEnabled: true
            )
            let intermediate = original.selectingAction(
                intermediateAction,
                profileName: profileName
            )
            let restored = intermediate.selectingAction(processAction)

            XCTAssertEqual(restored.action, processAction)
            XCTAssertEqual(restored.command, content)
            XCTAssertFalse(restored.automationEnabled)
        }
    }

    func testDistinctProcessActionsKeepIndependentContent() {
        let shell = Mapping(action: .shellCommand, command: "echo shell")
        let appleScript = shell
            .selectingAction(.appleScript)
            .editingCommand("tell application \"Finder\" to activate")
        let shortcut = appleScript
            .selectingAction(.macOSShortcut)
            .editingCommand("Morning Setup")
        let typed = shortcut.selectingAction(.mediaControl)

        let restoredShell = typed.selectingAction(.shellCommand)
        let restoredAppleScript = restoredShell.selectingAction(.appleScript)
        let restoredShortcut = restoredAppleScript.selectingAction(.macOSShortcut)

        XCTAssertEqual(restoredShell.command, "echo shell")
        XCTAssertEqual(restoredAppleScript.command, "tell application \"Finder\" to activate")
        XCTAssertEqual(restoredShortcut.command, "Morning Setup")
    }

    func testLegacyActiveProcessCommandIsStashedBeforeLeavingAction() throws {
        let data = Data(#"{"action":"Run shell command","command":"echo legacy"}"#.utf8)
        let legacy = try JSONDecoder().decode(Mapping.self, from: data)

        let typed = legacy.selectingAction(.windowDisplay)
        let restored = typed.selectingAction(.shellCommand)

        XCTAssertEqual(typed.shellCommandContent, "echo legacy")
        XCTAssertEqual(restored.command, "echo legacy")
    }

    func testDedicatedProcessContentRoundTripsThroughCodable() throws {
        let mapping = Mapping(action: .shellCommand, command: "echo shell")
            .selectingAction(.appleScript)
            .editingCommand("tell application \"Finder\" to activate")
            .selectingAction(.macOSShortcut)
            .editingCommand("Morning Setup")
            .selectingAction(.mediaControl)

        let decoded = try JSONDecoder().decode(
            Mapping.self,
            from: JSONEncoder().encode(mapping)
        )

        XCTAssertEqual(decoded, mapping)
        XCTAssertEqual(decoded.shellCommandContent, "echo shell")
        XCTAssertEqual(decoded.appleScriptContent, "tell application \"Finder\" to activate")
        XCTAssertEqual(decoded.macOSShortcutContent, "Morning Setup")
    }

    func testCommandEditPreservesNewContentButDisarmsAutomation() {
        let mapping = Mapping(
            action: .appleScript,
            command: "tell application \"Finder\" to activate",
            automationEnabled: true
        )

        let edited = mapping.editingCommand("tell application \"Notes\" to activate")

        XCTAssertEqual(edited.command, "tell application \"Notes\" to activate")
        XCTAssertEqual(edited.appleScriptContent, "tell application \"Notes\" to activate")
        XCTAssertFalse(edited.automationEnabled)
    }

    func testTypedDefaultsOnlyApplyDuringExplicitActionSelection() {
        let mapping = Mapping(action: .openApplication, command: "ChatGPT")

        let selected = mapping.selectingAction(.mediaControl)

        XCTAssertEqual(selected.command, MediaControlAction.playPause.rawValue)
        XCTAssertFalse(selected.automationEnabled)
        XCTAssertEqual(mapping.command, "ChatGPT", "The original mapping remains unchanged until explicitly selected")
    }

    func testSelectingEmptyClearsTheWholeMapping() {
        let mapping = Mapping(
            action: .shellCommand,
            command: "open -a Notes",
            shellCommandContent: "open -a Notes",
            automationEnabled: true,
            remoteTriggerModifiers: [.command]
        )

        XCTAssertEqual(mapping.selectingAction(.noAction), Mapping())
    }

    func testInvalidTypedValueRemainsVisibleToNonMutatingReaders() {
        let mapping = Mapping(action: .mediaControl, command: "legacy value")

        XCTAssertNil(MediaControlAction(rawValue: mapping.command))
        XCTAssertEqual(mapping.command, "legacy value")
    }

    func testHUDDoesNotExposeUnarmedAutomationContent() {
        let unarmed = InputOverlayPresentation(
            mapping: Mapping(action: .shellCommand, command: "rm -rf ~/Documents")
        )
        let armed = InputOverlayPresentation(
            mapping: Mapping(
                action: .shellCommand,
                command: "open -a Notes",
                automationEnabled: true
            )
        )

        XCTAssertEqual(unarmed.title, "Shell command · Review required")
        XCTAssertFalse(unarmed.isConfigured)
        XCTAssertFalse(unarmed.title.contains("rm -rf"))
        XCTAssertEqual(armed.title, "Shell command")
        XCTAssertTrue(armed.isConfigured)
    }
}
