import Foundation
import XCTest
@testable import XPd

@MainActor
final class MappingDragDropTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.MappingDragDropTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDropOnEmptyKeyMovesActionAndKeepsGesture() throws {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .hold)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .hold))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k2), .moved)

        XCTAssertEqual(store.mapping(for: .k1, gesture: .hold), Mapping())
        XCTAssertEqual(store.mapping(for: .k2, gesture: .hold), source)
        XCTAssertNil(store.mappingDrag)
    }

    func testDropOnOccupiedKeyAsksThenSwaps() throws {
        let store = makeStore()
        let first = Mapping(action: .openApplication, command: "Finder")
        let second = Mapping(action: .openApplication, command: "Safari")
        store.update(first, for: .k1, gesture: .tap)
        store.update(second, for: .k2, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2) else {
            return XCTFail("Expected a Swap/Replace choice")
        }
        XCTAssertTrue(proposal.canSwap)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), first, "Nothing changes before the choice")

        XCTAssertTrue(store.resolveMappingDrop(proposal, swap: true))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), second)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), first)
    }

    func testReplaceErasesDestinationAndClearsSource() throws {
        let store = makeStore()
        let first = Mapping(action: .openApplication, command: "Finder")
        store.update(first, for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "Safari"), for: .k2, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2) else {
            return XCTFail("Expected a Swap/Replace choice")
        }
        XCTAssertTrue(store.resolveMappingDrop(proposal, swap: false))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), first)
    }

    func testCancelledChoiceChangesNothing() throws {
        let store = makeStore()
        let first = Mapping(action: .openApplication, command: "Finder")
        let second = Mapping(action: .openApplication, command: "Safari")
        store.update(first, for: .k1, gesture: .tap)
        store.update(second, for: .k2, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2) else {
            return XCTFail("Expected a Swap/Replace choice")
        }
        store.cancelMappingDrag()
        XCTAssertFalse(store.resolveMappingDrop(proposal, swap: true))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), first)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), second)
    }

    func testModActionMovesWithinItsModLayer() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k5, gesture: .tap, modifierControls: [.k10])

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k5, gesture: .tap, modifierControls: [.k10]))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k3), .moved)

        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), Mapping())
        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap, modifierControls: [.k10]), source)
        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap), Mapping(), "Base layer is untouched")
    }

    func testModActionCannotDropOnItsOwnModButtonOrWheel() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k5, gesture: .tap, modifierControls: [.k10])

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k5, gesture: .tap, modifierControls: [.k10]))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k10), .rejected)
        XCTAssertEqual(store.dropMapping(token: token, onto: .wheelCenter), .rejected)
        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), source)
    }

    func testForeignTokenAndSameKeyAreIgnored() throws {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        XCTAssertEqual(store.dropMapping(token: "some dragged text", onto: .k2), .rejected)
        XCTAssertEqual(store.dropMapping(token: token, onto: .k1), .rejected)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), source)
    }

    func testSourceEditedDuringDragCancelsMove() throws {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        let edited = Mapping(action: .openApplication, command: "Safari")
        store.update(edited, for: .k1, gesture: .tap)

        XCTAssertEqual(store.dropMapping(token: token, onto: .k2), .rejected)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), edited)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), Mapping())
    }

    func testEmptyOrIncompleteActionCannotBeDragged() {
        let store = makeStore()
        XCTAssertNil(store.beginMappingDrag(from: .k1, gesture: .tap))
        store.update(Mapping(action: .openApplication, command: "  "), for: .k1, gesture: .tap)
        XCTAssertNil(store.beginMappingDrag(from: .k1, gesture: .tap))
    }

    func testIncompleteDestinationOffersReplaceOnly() throws {
        let store = makeStore()
        let source = Mapping(action: .openApplication, command: "Finder")
        store.update(source, for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: ""), for: .k2, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2) else {
            return XCTFail("Expected a Replace choice")
        }
        XCTAssertFalse(proposal.canSwap)
        XCTAssertFalse(store.resolveMappingDrop(proposal, swap: true))
        XCTAssertTrue(store.resolveMappingDrop(proposal, swap: false))
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), source)
    }

    func testMovedTapInheritedHoldGetsConcreteTarget() throws {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .hold))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k2), .moved)

        let moved = store.mapping(for: .k2, gesture: .hold)
        XCTAssertFalse(moved.usesTapApplication)
        XCTAssertEqual(moved.command, "Finder")
    }

    func testModApplicationChipMovesToAnotherKeyLikeThePhoto() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        let calculator = Mapping(action: .openApplication, command: "Calculator")
        store.update(calculator, for: .k5, gesture: .tap, modifierControls: [.k10])

        let chip = try XCTUnwrap(store.standardApplicationRoutes(for: .k5).first { !$0.isBase })
        let token = try XCTUnwrap(store.beginApplicationRouteDrag(from: .k5, route: chip))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k3), .moved)

        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), Mapping())
        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap, modifierControls: [.k10]), calculator)
        XCTAssertTrue(store.standardApplicationRoutes(for: .k5).isEmpty)
        XCTAssertEqual(store.standardApplicationRoutes(for: .k3).count, 1)
    }

    func testApplicationChipMovesEveryGestureForThatAppAndKeepsInheritance() throws {
        let store = makeStore()
        let tap = Mapping(action: .openApplication, command: "Finder")
        let hold = Mapping(action: .toggleApplication, command: "", usesTapApplication: true)
        let other = Mapping(action: .openApplication, command: "Safari")
        store.update(tap, for: .k1, gesture: .tap)
        store.update(hold, for: .k1, gesture: .hold)
        store.update(other, for: .k1, gesture: .doubleTap)

        let chip = try XCTUnwrap(store.standardApplicationRoutes(for: .k1).first { $0.target == "Finder" })
        let token = try XCTUnwrap(store.beginApplicationRouteDrag(from: .k1, route: chip))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k2), .moved)

        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), tap)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .hold), hold, "Inheritance travels with its Tap")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .doubleTap), other, "Other app chip stays")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), Mapping())
    }

    func testNonApplicationMarkerMovesOnlyNonApplicationGestures() throws {
        let store = makeStore()
        let shortcut = Mapping(
            action: .keyboardShortcut,
            command: "⌘C",
            keyboardShortcut: KeyboardShortcut(keyCode: 8, modifiers: [.command], displayString: "⌘C")
        )
        let app = Mapping(action: .openApplication, command: "Finder")
        store.update(shortcut, for: .k1, gesture: .hold)
        store.update(app, for: .k1, gesture: .tap)

        let token = try XCTUnwrap(store.beginNonApplicationMarkerDrag(from: .k1, modifierControls: []))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k4), .moved)

        XCTAssertEqual(store.mapping(for: .k4, gesture: .hold), shortcut)
        XCTAssertEqual(store.mapping(for: .k1, gesture: .hold), Mapping())
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), app)
    }

    func testChipSwapAsksOnlyAboutOccupiedGestures() throws {
        let store = makeStore()
        let finder = Mapping(action: .openApplication, command: "Finder")
        let safari = Mapping(action: .openApplication, command: "Safari")
        store.update(finder, for: .k1, gesture: .tap)
        store.update(safari, for: .k2, gesture: .tap)

        let chip = try XCTUnwrap(store.standardApplicationRoutes(for: .k1).first)
        let token = try XCTUnwrap(store.beginApplicationRouteDrag(from: .k1, route: chip))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2) else {
            return XCTFail("Expected a Swap/Replace choice")
        }
        XCTAssertEqual(proposal.occupiedGestures, [.tap])
        XCTAssertTrue(store.resolveMappingDrop(proposal, swap: true))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), safari)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), finder)
    }

    func testCommandCopyKeepsSourceAndDuplicatesChip() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        let calculator = Mapping(action: .openApplication, command: "Calculator")
        store.update(calculator, for: .k5, gesture: .tap, modifierControls: [.k10])

        let chip = try XCTUnwrap(store.standardApplicationRoutes(for: .k5).first)
        let token = try XCTUnwrap(store.beginApplicationRouteDrag(from: .k5, route: chip))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k3, copy: true), .moved)

        XCTAssertEqual(store.mapping(for: .k5, gesture: .tap, modifierControls: [.k10]), calculator)
        XCTAssertEqual(store.mapping(for: .k3, gesture: .tap, modifierControls: [.k10]), calculator)
    }

    func testCopyOntoOccupiedKeyOffersReplaceOnly() throws {
        let store = makeStore()
        let finder = Mapping(action: .openApplication, command: "Finder")
        store.update(finder, for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "Safari"), for: .k2, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        guard case .needsChoice(let proposal) = store.dropMapping(token: token, onto: .k2, copy: true) else {
            return XCTFail("Expected a Replace choice")
        }
        XCTAssertTrue(proposal.isCopy)
        XCTAssertFalse(proposal.canSwap)
        XCTAssertTrue(store.resolveMappingDrop(proposal, swap: false))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k2, gesture: .tap), finder)
    }

    func testCopiedScriptStaysOffUntilReapproved() throws {
        let store = makeStore()
        let script = Mapping(
            action: .shellCommand,
            command: "echo hi",
            shellCommandContent: "echo hi",
            automationEnabled: true
        )
        store.update(script, for: .k1, gesture: .tap)

        let token = try XCTUnwrap(store.beginMappingDrag(from: .k1, gesture: .tap))
        XCTAssertEqual(store.dropMapping(token: token, onto: .k2, copy: true), .moved)

        XCTAssertTrue(store.mapping(for: .k1, gesture: .tap).automationEnabled)
        XCTAssertFalse(store.mapping(for: .k2, gesture: .tap).automationEnabled)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
