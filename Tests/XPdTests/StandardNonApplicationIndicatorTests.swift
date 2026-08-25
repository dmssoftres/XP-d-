import XCTest
@testable import XPd

@MainActor
final class StandardNonApplicationIndicatorTests: XCTestCase {
    func testApplicationRouteSelectorRetainsFourRoutesWithoutMarkers() {
        let routes = [
            StandardApplicationRoute(target: "One", gesture: .tap),
            StandardApplicationRoute(target: "Two", gesture: .hold),
            StandardApplicationRoute(target: "Three", gesture: .doubleTap),
            StandardApplicationRoute(target: "Layer", gesture: .tap, modifierControls: [.k10])
        ]

        let selection = standardApplicationRouteDisplaySelection(routes)

        XCTAssertEqual(selection.visible.map(\.target), ["One", "Two", "Three", "Layer"])
        XCTAssertEqual(selection.hiddenCount, 0)
    }

    func testApplicationRouteSelectorReservesBottomRowForMarkers() {
        let routes = [
            StandardApplicationRoute(target: "One", gesture: .tap),
            StandardApplicationRoute(target: "Two", gesture: .hold),
            StandardApplicationRoute(target: "Three", gesture: .doubleTap),
            StandardApplicationRoute(target: "Layer", gesture: .tap, modifierControls: [.k10])
        ]

        let selection = standardApplicationRouteDisplaySelection(
            routes,
            hasNonApplicationMarkers: true
        )

        XCTAssertEqual(selection.visible.map(\.target), ["One", "Layer"])
        XCTAssertEqual(selection.hiddenCount, 2)
        XCTAssertEqual(selection.visible.last?.modifierControls, [.k10])
    }

    func testMarkerSelectorDeduplicatesAndOrdersBaseAndModifierGroups() {
        let routes = [
            StandardNonApplicationRoute(modifierControls: [.k4, .k2]),
            StandardNonApplicationRoute(modifierControls: []),
            StandardNonApplicationRoute(modifierControls: [.k2]),
            StandardNonApplicationRoute(modifierControls: [.k4, .k2]),
            StandardNonApplicationRoute(modifierControls: [])
        ]

        let selection = standardNonApplicationMarkerDisplaySelection(routes)

        XCTAssertEqual(selection.visible.map(\.modifierControls), [[], [.k2], [.k2, .k4]])
        XCTAssertEqual(selection.visible.map(\.isBase), [true, false, false])
        XCTAssertEqual(selection.hiddenCount, 0)
    }

    func testMarkerSelectorBoundsOverflowByRouteGroup() {
        let routes = [StandardNonApplicationRoute(modifierControls: [])]
            + RemoteControl.allCases
                .filter(\.isMIDIButton)
                .map { StandardNonApplicationRoute(modifierControls: [$0]) }

        let selection = standardNonApplicationMarkerDisplaySelection(routes)

        XCTAssertEqual(selection.visible.count, 8)
        XCTAssertEqual(selection.hiddenCount, 3)
    }

    func testMarkerSelectorKeepsCombinedLayerDotsTogetherWithinOverflowBudget() {
        let combinedModifiers: Set<RemoteControl> = [
            .k1, .k2, .k3, .k4, .k5, .k6, .k7, .k8, .k9
        ]
        let secondCombinedModifiers: Set<RemoteControl> = [
            .k1, .k2, .k3, .k4, .k5, .k6, .k7, .k8, .k10
        ]
        let routes = [
            StandardNonApplicationRoute(modifierControls: combinedModifiers),
            StandardNonApplicationRoute(modifierControls: secondCombinedModifiers)
        ]

        let selection = standardNonApplicationMarkerDisplaySelection(routes)

        XCTAssertEqual(selection.visible.count, 1)
        XCTAssertEqual(selection.visible.first?.modifierControls.count, 9)
        XCTAssertEqual(selection.hiddenCount, 1)
        XCTAssertLessThanOrEqual(
            standardNonApplicationMarkerDisplayWidth(for: selection),
            standardNonApplicationMarkerRailWidth
        )
    }

    func testMarkerSelectorBudgetsSimultaneousApplicationAndMarkerOverflow() {
        let firstCombinedModifiers: Set<RemoteControl> = [
            .k1, .k2, .k3, .k4, .k5, .k6, .k7
        ]
        let secondCombinedModifiers: Set<RemoteControl> = [
            .k1, .k2, .k3, .k4, .k5, .k6, .k8
        ]
        let routes = [
            StandardNonApplicationRoute(modifierControls: firstCombinedModifiers),
            StandardNonApplicationRoute(modifierControls: secondCombinedModifiers)
        ]

        let selection = standardNonApplicationMarkerDisplaySelection(
            routes,
            applicationHiddenCount: 2
        )

        XCTAssertEqual(selection.visible.count, 1)
        XCTAssertEqual(selection.visible.first?.modifierControls.count, 7)
        XCTAssertEqual(selection.hiddenCount, 1)
        XCTAssertEqual(selection.applicationHiddenCount, 2)
        XCTAssertLessThanOrEqual(
            standardNonApplicationMarkerDisplayWidth(for: selection),
            standardNonApplicationMarkerRailWidth
        )
    }

    func testMarkerSelectorOrdersModifiersByRemoteControlOrderInsideCluster() {
        let routes = [
            StandardNonApplicationRoute(modifierControls: [.k4, .k2, .k10])
        ]

        let selection = standardNonApplicationMarkerDisplaySelection(routes)

        XCTAssertEqual(selection.visible.first?.modifierControls, [.k2, .k4, .k10])
        XCTAssertFalse(selection.visible.first?.isBase ?? true)
    }
}
