import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingUndoTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MappingUndoTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let finder = Mapping(action: .openApplication, command: "Finder")
    private let safari = Mapping(action: .openApplication, command: "Safari")

    func testFreshStoreHasNothingToUndo() {
        let store = makeStore()
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
        XCTAssertFalse(store.undo())
        XCTAssertFalse(store.redo())
    }

    func testUndoAndRedoAnEdit() {
        let store = makeStore()
        let before = store.mapping(for: .k1, gesture: .tap)
        store.update(finder, for: .k1, gesture: .tap)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), before)
        XCTAssertTrue(store.canRedo)

        XCTAssertTrue(store.redo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertFalse(store.canRedo)
    }

    func testRapidEditsToSameFieldCoalesceButDifferentFieldsDoNot() {
        let store = makeStore()
        let before = store.mapping(for: .k1, gesture: .tap)
        for name in ["F", "Fi", "Fin", "Finder"] {
            store.update(Mapping(action: .openApplication, command: name), for: .k1, gesture: .tap)
        }
        store.update(safari, for: .k2, gesture: .tap)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap).command, "Finder")
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), before, "Typing is one step")
        XCTAssertFalse(store.canUndo)
    }

    func testSameFieldEditsApartInTimeAreSeparateSteps() {
        let store = makeStore()
        store.undoCoalescingInterval = 0
        store.update(finder, for: .k1, gesture: .tap)
        store.update(safari, for: .k1, gesture: .tap)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
    }

    func testNewEditClearsRedo() {
        let store = makeStore()
        store.update(finder, for: .k1, gesture: .tap)
        XCTAssertTrue(store.undo())
        store.update(safari, for: .k2, gesture: .tap)
        XCTAssertFalse(store.canRedo)
    }

    func testUndoDragMoveSwapAndCopy() throws {
        let store = makeStore()
        store.undoCoalescingInterval = 0
        store.update(finder, for: .k1, gesture: .tap)
        store.update(safari, for: .k2, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2) else {
            return XCTFail("Expected a choice")
        }
        XCTAssertTrue(store.resolveMappingDrop(proposal, swap: true))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), safari)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), safari)

        let copyToken = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        XCTAssertEqual(store.dropMapping(token: copyToken, onto: .k3, copy: true), .moved)
        XCTAssertTrue(store.undo())
        XCTAssertNotEqual(store.mapping(for: .k3, gesture: .tap), finder)
    }

    func testUndoPasteDeleteTitleAndModifier() {
        let store = makeStore()
        store.undoCoalescingInterval = 0
        store.update(finder, for: .k1, gesture: .tap)

        XCTAssertTrue(store.copyMapping(from: .k1, gesture: .tap))
        XCTAssertEqual(store.pasteMapping(to: .k2, gesture: .tap), .succeeded)
        XCTAssertTrue(store.undo())
        XCTAssertNotEqual(store.mapping(for: .k2, gesture: .tap), finder)

        XCTAssertTrue(store.deleteMapping(for: .k1, gesture: .tap))
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)

        store.updateStandardButtonTitle("Mail", for: .k4)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.standardButtonTitle(for: .k4), "")

        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        XCTAssertTrue(store.isRemoteModifier(.k10))
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isRemoteModifier(.k10))
    }

    func testProfileSwitchAloneIsNotAStepButUndoReturnsToEditedProfile() throws {
        let store = makeStore()
        let other = try store.addProfile(named: "Chrome")
        XCTAssertTrue(store.undo(), "Adding a profile is undoable")
        XCTAssertFalse(store.availableProfiles.contains(other))
        XCTAssertTrue(store.redo())
        XCTAssertTrue(store.availableProfiles.contains(other))

        store.update(finder, for: .k1, gesture: .tap)
        let stepsBefore = undoDepth(store)
        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertEqual(undoDepth(store), stepsBefore, "Switching profile is not an edit")

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.profileName, other, "Undo shows the profile where the edit was")
        XCTAssertNotEqual(store.mapping(for: .k1, gesture: .tap), finder)
    }

    func testUndoRenameAndDeleteProfile() throws {
        let store = makeStore()
        store.undoCoalescingInterval = 0
        let name = try store.addProfile(named: "Work")
        store.update(finder, for: .k1, gesture: .tap)
        let renamed = try store.renameProfile(named: name, to: "Clinic")
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.availableProfiles.contains(name))
        XCTAssertFalse(store.availableProfiles.contains(renamed))

        try store.deleteProfile(named: name)
        XCTAssertFalse(store.availableProfiles.contains(name))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.availableProfiles.contains(name))
        XCTAssertTrue(store.selectProfile(name))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
    }

    func testUndoImport() throws {
        let store = makeStore()
        store.undoCoalescingInterval = 0
        store.update(finder, for: .k1, gesture: .tap)
        let exported = try XCTUnwrap(store.exportConfiguration())
        store.update(safari, for: .k1, gesture: .tap)

        XCTAssertTrue(store.importConfiguration(exported))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), safari)
    }

    func testHistoryIsCappedAtLimit() {
        let store = makeStore()
        store.undoCoalescingInterval = 0
        for index in 0..<(MappingStore.undoLimit + 10) {
            store.update(Mapping(action: .openApplication, command: "App \(index)"), for: .k1, gesture: .tap)
        }
        XCTAssertEqual(undoDepth(store), MappingStore.undoLimit)
    }

    func testUndoneStateIsSavedToDisk() {
        let store = makeStore()
        store.update(finder, for: .k1, gesture: .tap)
        XCTAssertTrue(store.undo())

        let reloaded = makeStore()
        XCTAssertNotEqual(reloaded.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertFalse(reloaded.canUndo, "History is session-only")
    }

    func testFreshStoreProfileSwitchCreatesNoStep() throws {
        let store = makeStore()
        let other = try XCTUnwrap(store.availableProfiles.first { $0 != store.profileName })
        XCTAssertTrue(store.selectProfile(other))
        XCTAssertFalse(store.canUndo, "A bare profile switch must not be undoable")
        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertFalse(store.canUndo)
    }

    func testClearingAHardwareBindingIsNotAStep() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        let depth = undoDepth(store)
        store.clearHIDBinding(for: .k10)
        XCTAssertEqual(undoDepth(store), depth)
    }

    func testUndoKeepsTheModLayerBeingEdited() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.selectedControl = .k5
        store.selectedMappingModifiers = [.k10]
        store.update(finder, for: .k5, gesture: .tap, modifierControls: [.k10])

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.selectedMappingModifiers, [.k10])
        XCTAssertNotEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), finder)
    }

    private func undoDepth(_ store: MappingStore) -> Int {
        var count = 0
        while store.undo() { count += 1 }
        for _ in 0..<count { store.redo() }
        return count
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
