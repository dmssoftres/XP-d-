import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingClipboardTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MappingClipboardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCopyPastePreservesFullMappingFieldsAndSource() {
        let store = makeStore()
        let shortcut = KeyboardShortcut(keyCode: 12, modifiers: [.command, .shift], displayString: "⌘⇧Q")
        let source = Mapping(
            action: .keyboardShortcut,
            command: "⌘⇧Q",
            macOSShortcutContent: "unused",
            appleScriptContent: "tell application \"Finder\" to activate",
            shellCommandContent: "echo retained",
            automationEnabled: true,
            keyboardShortcut: shortcut,
            remoteTriggerModifiers: [.option],
            remoteTriggerFunctionKey: 122,
            remoteTriggerKeyCode: 45,
            remoteTriggerKeyDisplay: "n"
        )
        store.update(source, for: .k1, gesture: .tap)

        XCTAssertTrue(store.copyMapping(from: .k1, gesture: .tap))
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .hold), .succeeded)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .hold), source)
    }

    func testCopyIsRepeatableAndCutIsDeferred() {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)

        XCTAssertTrue(store.copyMapping(from: .k1, gesture: .tap))
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .succeeded)
        XCTAssertEqual(store.pasteMapping(to: .k3, gesture: .tap), .succeeded)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap), source)

        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
        XCTAssertEqual(
            store.mappingClipboardOperation(for: .k1, gesture: .tap),
            .cut
        )
    }

    func testCutPasteClearsSourceAndClipboard() {
        let store = makeStore()
        let source = Mapping(action: .toggleApplication, command: "Calculator")
        store.update(source, for: .k1, gesture: .doubleTap)

        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .doubleTap))
        XCTAssertFalse(store.canPasteMapping(to: .k1, gesture: .doubleTap))
        XCTAssertEqual(store.pasteMapping(to: .k4, gesture: .tap), .succeeded)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .doubleTap), Mapping())
        XCTAssertEqual(store.mapping(for: .k4, gesture: .tap), source)
        XCTAssertFalse(store.hasMappingClipboard)
    }

    func testCrossProfileCutClearsInactiveSourceAndWritesDestination() {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))

        store.profileName = "Finder"
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .hold), .succeeded)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .hold), source)

        store.profileName = "Global"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
    }

    func testSameLocationCutAndOccupiedPasteDoNotMutateWithoutConfirmation() {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        let existing = Mapping(action: .openApplication, command: "Calculator")
        store.update(source, for: .k1, gesture: .tap)
        store.update(existing, for: .k2, gesture: .tap)

        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        XCTAssertFalse(store.canPasteMapping(to: .k1, gesture: .tap))
        XCTAssertEqual(store.pasteMapping(to: .k1, gesture: .tap), .sameLocation)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)

        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .destinationOccupied)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), existing)
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap, replacingExisting: true), .succeeded)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), source)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
    }

    func testPasteRejectsChangedExpectedDestinationWithoutMutation() {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        let originalDestination = Mapping(action: .openApplication, command: "Calculator")
        let changedDestination = Mapping(action: .openApplication, command: "Reminders")
        store.update(source, for: .k1, gesture: .tap)
        store.update(originalDestination, for: .k2, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))

        let snapshot = store.mappingDestinationSnapshot(for: .k2, gesture: .tap)
        store.update(changedDestination, for: .k2, gesture: .tap)

        XCTAssertEqual(store.pasteMapping(to: snapshot, replacingExisting: true), .destinationChanged)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), changedDestination)
        XCTAssertEqual(store.mappingClipboardOperation(for: .k1, gesture: .tap), .cut)
    }

    func testPasteRejectsMissingExplicitDestinationWithoutMutatingCut() {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))

        let missing = MappingDestinationSnapshot(
            location: MappingClipboardLocation(
                profileName: "Deleted profile",
                control: .k2,
                gesture: .hold
            ),
            expectedMapping: Mapping()
        )
        XCTAssertEqual(store.pasteMapping(to: missing), .invalidDestination)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
        XCTAssertEqual(missing.expectedMapping, Mapping())
        XCTAssertEqual(store.mappingClipboardOperation(for: .k1, gesture: .tap), .cut)
    }

    func testPasteRejectsNonStandardExplicitDestinationWithoutMutatingCut() throws {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        _ = try store.addMIDIProfile(named: "Pads")

        let midiDestination = store.mappingDestinationSnapshot(
            for: .k2,
            gesture: .tap,
            profileName: "Pads"
        )
        XCTAssertEqual(store.pasteMapping(to: midiDestination), .invalidDestination)
        store.profileName = "Global"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
        XCTAssertEqual(store.mappingClipboardOperation(for: .k1, gesture: .tap), .cut)
    }

    func testStaleCutFailsWithoutDataLossAndCancelsClipboard() {
        let store = makeStore()
        let original = Mapping(action: .openApplication, command: "Finder")
        let changed = Mapping(action: .openApplication, command: "Calculator")
        store.update(original, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        store.update(changed, for: .k1, gesture: .tap)

        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .staleSource)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), changed)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), Mapping())
        XCTAssertFalse(store.hasMappingClipboard)
    }

    func testInheritedTapApplicationIsMaterializedForClipboard() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        let inherited = Mapping(
            action: .toggleApplication,
            command: "stale target",
            usesTapApplication: true
        )
        store.update(inherited, for: .k1, gesture: .hold)

        XCTAssertTrue(store.copyMapping(from: .k1, gesture: .hold))
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .succeeded)
        let pasted = store.mapping(for: .k2, gesture: .tap)
        XCTAssertEqual(pasted.action, .toggleApplication)
        XCTAssertEqual(pasted.command, "Finder")
        XCTAssertFalse(pasted.usesTapApplication)
    }

    func testCopyDisarmsProcessAutomationWhileCutPreservesIt() {
        let store = makeStore()
        let enabled = Mapping(
            action: .shellCommand,
            command: "echo hello",
            shellCommandContent: "echo hello",
            automationEnabled: true
        )
        store.update(enabled, for: .k1, gesture: .tap)

        XCTAssertTrue(store.copyMapping(from: .k1, gesture: .tap))
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .succeeded)
        XCTAssertFalse(store.mapping(for: .k2, gesture: .tap).automationEnabled)

        store.update(enabled, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        XCTAssertEqual(store.pasteMapping(to: .k3, gesture: .tap), .succeeded)
        XCTAssertTrue(store.mapping(for: .k3, gesture: .tap).automationEnabled)
    }

    func testDeleteResetsMappingAndConfigurationStatus() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        XCTAssertTrue(store.destinationHasMapping(for: .k1, gesture: .tap))
        XCTAssertTrue(store.deleteMapping(for: .k1, gesture: .tap))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
        XCTAssertFalse(store.destinationHasMapping(for: .k1, gesture: .tap))
        XCTAssertFalse(store.isMappingConfigured(for: .k1, gesture: .tap))
        XCTAssertFalse(store.deleteMapping(for: .k1, gesture: .tap))
    }

    func testPendingCutRetargetsOnRenameAndCancelsOnDeleteOrImport() throws {
        let store = makeStore()
        store.profileName = "Finder"
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))

        XCTAssertEqual(try store.renameProfile(named: "Finder", to: "Renamed"), "Renamed")
        store.profileName = "Global"
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .succeeded)
        store.profileName = "Renamed"
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())

        store.update(source, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        try store.deleteProfile(named: "Renamed")
        XCTAssertFalse(store.hasMappingClipboard)

        store.update(source, for: .k1, gesture: .tap)
        XCTAssertTrue(store.cutMapping(from: .k1, gesture: .tap))
        let exported = try XCTUnwrap(store.exportConfiguration())
        XCTAssertTrue(store.importConfiguration(exported))
        XCTAssertFalse(store.hasMappingClipboard)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
