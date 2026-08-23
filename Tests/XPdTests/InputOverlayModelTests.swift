import XCTest
@testable import XPd

final class InputOverlayModelTests: XCTestCase {
    func testEmptyMappingIsNotConfigured() {
        let presentation = InputOverlayPresentation(mapping: Mapping())

        XCTAssertEqual(presentation.title, "Not set")
        XCTAssertFalse(presentation.isConfigured)
    }

    func testScriptAndStructuredActionsUseConciseHUDTitles() {
        XCTAssertEqual(
            InputOverlayPresentation(
                mapping: Mapping(
                    action: .appleScript,
                    command: "tell application \"Finder\" to activate",
                    automationEnabled: true
                )
            ).title,
            "AppleScript"
        )
        XCTAssertEqual(
            InputOverlayPresentation(
                mapping: Mapping(
                    action: .shellCommand,
                    command: "open -a Notes",
                    automationEnabled: true
                )
            ).title,
            "Shell command"
        )
        XCTAssertEqual(
            InputOverlayPresentation(
                mapping: Mapping(
                    action: .macOSShortcut,
                    command: "Morning Setup",
                    automationEnabled: true
                )
            ).title,
            "Shortcut · Morning Setup"
        )
        XCTAssertEqual(
            InputOverlayPresentation(
                mapping: Mapping(action: .switchProfile, command: "Logic Pro")
            ).title,
            "Profile · Logic Pro"
        )
    }

    @MainActor
    func testProfileSelectorKeepsOverlayVisibleUntilExplicitlyHidden() {
        let model = InputOverlayModel()
        var visibilityChanges: [Bool] = []
        model.visibilityDidChange = { visibilityChanges.append($0) }

        model.showProfiles(["Global", "Finder"], selectedProfile: "Global")
        model.reset()

        XCTAssertEqual(model.profileSelection?.selectedProfile, "Global")
        XCTAssertEqual(visibilityChanges, [true, true])

        model.hideProfiles()

        XCTAssertNil(model.profileSelection)
        XCTAssertEqual(visibilityChanges.last, false)
    }

    @MainActor
    func testRecognizedGestureUpdatesLatestMatchingEntry() {
        let model = InputOverlayModel()
        let presentation = InputOverlayPresentation(mapping: Mapping(action: .noAction))
        model.press(
            control: .k1,
            tap: presentation,
            hold: presentation,
            doubleTap: presentation
        )
        model.release(control: .k1)

        model.recognize(control: .k1, gesture: .doubleTap)

        XCTAssertEqual(model.entries.last?.recognizedGesture, .doubleTap)
    }

    @MainActor
    func testCompletedPressExpiresUsingConfiguredDuration() {
        let model = InputOverlayModel(displayDuration: 0.01)
        let presentation = InputOverlayPresentation(mapping: Mapping(action: .noAction))
        let expired = expectation(description: "completed HUD entry expires")
        model.visibilityDidChange = { isVisible in
            if !isVisible {
                expired.fulfill()
            }
        }

        model.presentCompleted(
            control: .k1,
            tap: presentation,
            hold: presentation,
            doubleTap: presentation
        )

        XCTAssertFalse(model.entries.last?.isPressed ?? true)
        wait(for: [expired], timeout: 1)
        XCTAssertTrue(model.entries.isEmpty)
    }

    @MainActor
    func testDismissNormalEntriesImmediatelyClearsCardsAndHidesOverlay() {
        let model = InputOverlayModel(displayDuration: 0.01)
        let presentation = InputOverlayPresentation(mapping: Mapping(action: .noAction))
        var visibilityChanges: [Bool] = []
        var regularEntriesVisibilityChanges: [Bool] = []
        model.visibilityDidChange = { visibilityChanges.append($0) }
        model.regularEntriesVisibilityDidChange = { regularEntriesVisibilityChanges.append($0) }

        model.press(control: .k1, tap: presentation, hold: presentation, doubleTap: presentation)
        model.release(control: .k1)
        model.dismissNormalEntries()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(visibilityChanges.suffix(2), [true, false])
        XCTAssertEqual(regularEntriesVisibilityChanges.suffix(2), [true, false])

        let invalidatedTimerDidNotNotify = expectation(description: "dismissed entry timer stays invalidated")
        invalidatedTimerDidNotNotify.isInverted = true
        model.visibilityDidChange = { _ in invalidatedTimerDidNotNotify.fulfill() }
        wait(for: [invalidatedTimerDidNotNotify], timeout: 0.1)
    }

    @MainActor
    func testDismissNormalEntriesPreservesProfileSelector() {
        let model = InputOverlayModel()
        let presentation = InputOverlayPresentation(mapping: Mapping(action: .noAction))

        model.press(control: .k1, tap: presentation, hold: presentation, doubleTap: presentation)
        model.showProfiles(["Global", "Finder"], selectedProfile: "Global")
        model.dismissNormalEntries()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.profileSelection?.selectedProfile, "Global")
    }

    @MainActor
    func testMIDIOverlayShowsLockProfileLayerAndMessage() {
        let model = InputOverlayModel()

        model.showMIDI(
            profileName: "Performance",
            layer: .primary,
            control: .k1,
            summary: "K1 · Note 36 · Ch 1 · Vel 110"
        )

        XCTAssertEqual(model.midiPresentation?.lockTitle, "MIDI LOCK")
        XCTAssertEqual(model.midiPresentation?.layerTitle, "PRIMARY")
        XCTAssertEqual(model.midiPresentation?.profileName, "Performance")
        XCTAssertEqual(model.midiPresentation?.control, .k1)
        XCTAssertEqual(model.midiPresentation?.summary, "K1 · Note 36 · Ch 1 · Vel 110")
    }

    @MainActor
    func testMIDIOverlayMarksFnLayerWithoutTreatingFnAsPlayedControl() {
        let model = InputOverlayModel()

        model.showMIDI(profileName: "Performance", layer: .function)

        XCTAssertEqual(model.midiPresentation?.layerTitle, "FN LAYER")
        XCTAssertNil(model.midiPresentation?.control)
        XCTAssertNil(model.midiPresentation?.summary)
    }

    @MainActor
    func testResetAndRealmClearRemoveMIDIOverlay() {
        let model = InputOverlayModel()
        model.showMIDI(profileName: "Performance", layer: .function, control: .k2, summary: "Note 60")

        model.reset()

        XCTAssertNil(model.midiPresentation)

        model.showMIDI(profileName: "Performance", control: .k3, summary: "Note 62")
        model.clearMIDI()

        XCTAssertNil(model.midiPresentation)
    }

    @MainActor
    func testStatusNoticeShowsAndClears() {
        let model = InputOverlayModel()

        model.showStatusNotice(
            title: "XP[d] UNLOCKED",
            message: "Standard mappings active",
            systemImage: "lock.open"
        )

        XCTAssertEqual(model.statusNotice?.title, "XP[d] UNLOCKED")
        XCTAssertEqual(model.statusNotice?.message, "Standard mappings active")
        XCTAssertEqual(model.statusNotice?.systemImage, "lock.open")

        model.clearStatusNotice()

        XCTAssertNil(model.statusNotice)
    }
}
