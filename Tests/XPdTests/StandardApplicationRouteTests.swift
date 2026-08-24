import Foundation
import XCTest
@testable import XPd

@MainActor
final class StandardApplicationRouteTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.StandardApplicationRouteTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testBaseRoutesAreOrderedAndPrimaryIsFirstDistinctTarget() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(Mapping(action: .toggleApplication, command: "Calculator"), for: .k1, gesture: .hold)
        store.update(Mapping(action: .openApplication, command: "Safari"), for: .k1, gesture: .doubleTap)

        let routes = store.standardApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.map(\.target), ["Finder", "Calculator", "Safari"])
        XCTAssertEqual(routes.map(\.gesture), [.tap, .hold, .doubleTap])
        XCTAssertTrue(routes.allSatisfy(\.isBase))
    }

    func testHoldAndDoubleInheritanceAreResolvedAndDeduplicated() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "stale", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )
        store.update(
            Mapping(action: .openApplication, command: "Finder", usesTapApplication: false),
            for: .k1,
            gesture: .doubleTap
        )

        let routes = store.standardApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first?.target, "Finder")
        XCTAssertEqual(routes.first?.gesture, .tap)
    }

    func testBaseDeduplicationUsesNormalizedTargetIdentity() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: " Finder "), for: .k1, gesture: .tap)
        store.update(Mapping(action: .toggleApplication, command: "finder"), for: .k1, gesture: .hold)

        let routes = store.standardApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first?.target, "Finder")
    }

    func testEmptyAndNonApplicationMappingsAreOmitted() {
        let store = makeStore()
        store.update(Mapping(action: .noAction), for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "   "), for: .k1, gesture: .hold)
        store.update(Mapping(action: .keyboardShortcut, command: "⌘K"), for: .k1, gesture: .doubleTap)

        XCTAssertTrue(store.standardApplicationRoutes(for: .k1).isEmpty)
    }

    func testOnlyActiveExecutableModifierLayersAreIncluded() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "Calculator"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k10]
        )
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: false))

        XCTAssertTrue(store.standardApplicationRoutes(for: .k1).isEmpty)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))

        let routes = store.standardApplicationRoutes(for: .k1)
        XCTAssertEqual(routes.map(\.target), ["Calculator"])
        XCTAssertEqual(routes.first?.modifierControls, [.k10])
    }

    func testModifierSetsAreDeterministicAndSameAppIsPreservedAcrossLayers() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: true))
        XCTAssertTrue(store.setRemoteModifier(.k4, enabled: true))

        for (modifiers, target) in [
            (Set([RemoteControl.k3]), "Finder"),
            (Set([RemoteControl.k4]), "Finder"),
            (Set([RemoteControl.k3, .k4]), "Calculator")
        ] {
            store.update(
                Mapping(action: .toggleApplication, command: target),
                for: .k1,
                gesture: .tap,
                modifierControls: modifiers
            )
        }

        let routes = store.standardApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.map(\.modifierControls), [[.k3], [.k4], [.k3, .k4]])
        XCTAssertEqual(routes.map(\.target), ["Finder", "Finder", "Calculator"])
    }

    func testModifierLayerInheritanceDeduplicatesWithinLayer() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "Finder"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k10]
        )
        store.update(
            Mapping(action: .toggleApplication, command: "stale", usesTapApplication: true),
            for: .k1,
            gesture: .hold,
            modifierControls: [.k10]
        )

        let routes = store.standardApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first?.target, "Finder")
        XCTAssertEqual(routes.first?.modifierControls, [.k10])
    }

    func testOverflowSourceRoutesRemainDeterministicForFourPositionPresentation() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "One"), for: .k1, gesture: .tap)
        store.update(Mapping(action: .openApplication, command: "Two"), for: .k1, gesture: .hold)
        store.update(Mapping(action: .openApplication, command: "Three"), for: .k1, gesture: .doubleTap)
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "Four"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k10]
        )
        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: true))
        store.update(
            Mapping(action: .openApplication, command: "Five"),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k10, .k3]
        )

        let routes = store.standardApplicationRoutes(for: .k1)
        let selection = standardApplicationRouteDisplaySelection(routes)
        let repeatedSelection = standardApplicationRouteDisplaySelection(routes)

        XCTAssertEqual(routes.map(\.target), ["One", "Two", "Three", "Four", "Five"])
        XCTAssertEqual(selection.visible.map(\.target), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(selection.hiddenCount, 1)
        XCTAssertEqual(selection.visible.last?.modifierControls, [.k10])
        XCTAssertEqual(repeatedSelection.visible.map(\.target), selection.visible.map(\.target))
        XCTAssertEqual(repeatedSelection.visible.map(\.modifierControls), selection.visible.map(\.modifierControls))
        XCTAssertEqual(repeatedSelection.hiddenCount, selection.hiddenCount)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
