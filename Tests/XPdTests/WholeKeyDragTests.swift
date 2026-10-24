import Foundation
import XCTest
@testable import XPd

@MainActor
final class WholeKeyDragTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.WholeKeyDragTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let finder = Mapping(action: .openApplication, command: "Finder")
    private let safari = Mapping(action: .openApplication, command: "Safari")
    private let notes = Mapping(action: .openApplication, command: "Notes")

    func testMoveCarriesEveryGestureLayerAndTitleButLeavesModCombos() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(finder, for: .k5, gesture: .tap)
        store.update(safari, for: .k5, gesture: .hold)
        store.update(notes, for: .k5, gesture: .tap, modifierControls: [.k10])
        store.updateStandardButtonTitle("Apps", for: .k5)
        // K10's own combo with K2 must not move when K10 is dragged later.
        store.update(finder, for: .k2, gesture: .tap, modifierControls: [.k10])

        let token = try XCTUnwrap(store.beginKeyDrag(from: .k5))
        XCTAssertEqual(store.dropKey(token: token, onto: .k3), .moved)

        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k3, gesture: .hold), safari)
        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap, modifierControls: [.k10]), notes)
        XCTAssertEqual(store.standardButtonTitle(for: .k3), "Apps")
        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap), Mapping())
        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), Mapping())
        XCTAssertEqual(store.standardButtonTitle(for: .k5), "")
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap, modifierControls: [.k10]), finder, "Other keys' combos untouched")
        XCTAssertTrue(store.isRemoteModifier(.k10))
    }

    func testOccupiedTargetSwapsEverything() throws {
        let store = makeStore()
        store.update(finder, for: .k1, gesture: .tap)
        store.updateStandardButtonTitle("One", for: .k1)
        store.update(safari, for: .k2, gesture: .doubleTap)
        store.updateStandardButtonTitle("Two", for: .k2)

        let token = try XCTUnwrap(store.beginKeyDrag(from: .k1))
        guard case .needsChoice(let proposal) = store.dropKey(token: token, onto: .k2) else {
            return XCTFail("Expected a Swap/Replace choice")
        }
        XCTAssertTrue(proposal.canSwap)
        XCTAssertTrue(store.resolveKeyDrop(proposal, swap: true))
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .doubleTap), safari)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "Two")
        XCTAssertEqual(store.standardButtonTitle(for: .k2), "One")

        XCTAssertTrue(store.undo(), "One undo step")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "One")
    }

    func testReplaceErasesTarget() throws {
        let store = makeStore()
        store.update(finder, for: .k1, gesture: .tap)
        store.update(safari, for: .k2, gesture: .hold)

        let token = try XCTUnwrap(store.beginKeyDrag(from: .k1))
        guard case .needsChoice(let proposal) = store.dropKey(token: token, onto: .k2) else {
            return XCTFail("Expected a choice")
        }
        XCTAssertTrue(store.resolveKeyDrop(proposal, swap: false))
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .hold), Mapping())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
    }

    func testCopyKeepsSourceAndDisarmsScripts() throws {
        let store = makeStore()
        let script = Mapping(action: .shellCommand, command: "echo hi", shellCommandContent: "echo hi", automationEnabled: true)
        store.update(script, for: .k1, gesture: .tap)
        store.updateStandardButtonTitle("Run", for: .k1)

        let token = try XCTUnwrap(store.beginKeyDrag(from: .k1))
        XCTAssertEqual(store.dropKey(token: token, onto: .k4, copy: true), .moved)
        XCTAssertTrue(store.mapping(for: .k1, gesture: .tap).automationEnabled)
        XCTAssertFalse(store.mapping(for: .k4, gesture: .tap).automationEnabled)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "Run")
        XCTAssertEqual(store.standardButtonTitle(for: .k4), "Run")
    }

    func testBlockedWhenSourceUsesTargetAsMod() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(finder, for: .k5, gesture: .tap, modifierControls: [.k10])
        let token = try XCTUnwrap(store.beginKeyDrag(from: .k5))
        XCTAssertEqual(store.dropKey(token: token, onto: .k10), .rejected)
        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), finder)
    }

    func testSwapNotOfferedWhenTargetUsesSourceAsMod() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(finder, for: .k10, gesture: .hold)
        store.update(safari, for: .k5, gesture: .tap, modifierControls: [.k10])
        let token = try XCTUnwrap(store.beginKeyDrag(from: .k10))
        guard case .needsChoice(let proposal) = store.dropKey(token: token, onto: .k5) else {
            return XCTFail("Expected a choice")
        }
        XCTAssertFalse(proposal.canSwap)
        XCTAssertFalse(store.resolveKeyDrop(proposal, swap: true))
    }

    func testEmptyKeyCannotBeDraggedAndChangedKeyCancels() throws {
        let store = makeStore()
        XCTAssertNil(store.beginKeyDrag(from: .k7))
        store.update(finder, for: .k1, gesture: .tap)
        let token = try XCTUnwrap(store.beginKeyDrag(from: .k1))
        store.update(safari, for: .k1, gesture: .tap)
        XCTAssertEqual(store.dropKey(token: token, onto: .k2), .rejected)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), Mapping())
    }

    func testProfileChangeBeforeChoiceMovesNothing() throws {
        let store = makeStore()
        store.update(finder, for: .k1, gesture: .tap)
        store.update(safari, for: .k2, gesture: .tap)
        _ = try store.duplicateProfile(named: "Global", as: "Copy")
        let token = try XCTUnwrap(store.beginKeyDrag(from: .k1))
        guard case .needsChoice(let proposal) = store.dropKey(token: token, onto: .k2) else {
            return XCTFail("Expected a choice")
        }
        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertFalse(store.resolveKeyDrop(proposal, swap: true))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), safari)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
