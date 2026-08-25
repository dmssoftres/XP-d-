import Foundation
import XCTest
@testable import XPd

@MainActor
final class StandardNonApplicationRouteTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.StandardNonApplicationRouteTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testBaseRouteDeduplicatesConfiguredGestures() {
        let store = makeStore()
        store.update(
            Mapping(
                action: .keyboardShortcut,
                command: "⌘K",
                keyboardShortcut: KeyboardShortcut(keyCode: 40, modifiers: [.command], displayString: "⌘K")
            ),
            for: .k1,
            gesture: .tap
        )
        store.update(
            Mapping(action: .mediaControl, command: MediaControlAction.playPause.rawValue),
            for: .k1,
            gesture: .hold
        )
        store.update(
            Mapping(action: .switchProfile, command: "Global"),
            for: .k1,
            gesture: .doubleTap
        )

        let routes = store.standardNonApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first?.modifierControls, [])
        XCTAssertTrue(routes.first?.isBase == true)
    }

    func testExactModifierLayersAreOrderedAndCombinedLayersArePreserved() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k3, enabled: true))
        XCTAssertTrue(store.setRemoteModifier(.k4, enabled: true))

        let mappings: [(Set<RemoteControl>, Mapping)] = [
            ([.k3, .k4], Mapping(action: .switchProfile, command: "Global")),
            ([.k4], Mapping(action: .windowDisplay, command: WindowDisplayAction.minimize.rawValue)),
            ([], Mapping(action: .mediaControl, command: MediaControlAction.mute.rawValue)),
            ([.k3], Mapping(
                action: .keyboardShortcut,
                command: "⌘⇧K",
                keyboardShortcut: KeyboardShortcut(
                    keyCode: 40,
                    modifiers: [.command, .shift],
                    displayString: "⌘⇧K"
                )
            ))
        ]
        for (modifiers, mapping) in mappings {
            store.update(mapping, for: .k1, gesture: .tap, modifierControls: modifiers)
        }

        let routes = store.standardNonApplicationRoutes(for: .k1)

        XCTAssertEqual(routes.map(\.modifierControls), [[], [.k3], [.k4], [.k3, .k4]])
        XCTAssertEqual(routes.map(\.isBase), [true, false, false, false])
    }

    func testInactiveModifierLayerIsOmitted() {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(
            Mapping(
                action: .keyboardShortcut,
                command: "⌘K",
                keyboardShortcut: KeyboardShortcut(keyCode: 40, modifiers: [.command], displayString: "⌘K")
            ),
            for: .k1,
            gesture: .tap,
            modifierControls: [.k10]
        )
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: false))

        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)

        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        XCTAssertEqual(store.standardNonApplicationRoutes(for: .k1).map(\.modifierControls), [[.k10]])
    }

    func testNoActionApplicationIncompleteAndReviewRequiredMappingsAreOmitted() {
        let store = makeStore()
        store.update(Mapping(action: .noAction), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .openApplication, command: "/Applications/Finder.app"),
            for: .k1,
            gesture: .hold
        )
        store.update(Mapping(action: .keyboardShortcut, command: "   "), for: .k1, gesture: .doubleTap)

        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)

        store.update(
            Mapping(action: .macOSShortcut, command: "Morning Setup"),
            for: .k1,
            gesture: .tap
        )
        store.update(
            Mapping(action: .appleScript, command: "tell application \"Finder\" to activate"),
            for: .k1,
            gesture: .hold
        )
        store.update(
            Mapping(action: .shellCommand, command: "echo ready"),
            for: .k1,
            gesture: .doubleTap
        )

        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)
    }

    func testKeyboardShortcutRequiresExecutableStructuredPayload() {
        let store = makeStore()
        store.update(
            Mapping(action: .keyboardShortcut, command: "⌘K"),
            for: .k1,
            gesture: .tap
        )
        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)

        store.update(
            Mapping(
                action: .keyboardShortcut,
                command: "⌘K",
                keyboardShortcut: KeyboardShortcut(keyCode: 128, modifiers: [.command], displayString: "⌘K")
            ),
            for: .k1,
            gesture: .tap
        )
        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)

        store.update(
            Mapping(
                action: .keyboardShortcut,
                command: "⌘K",
                keyboardShortcut: KeyboardShortcut(keyCode: 40, modifiers: [.command], displayString: " ")
            ),
            for: .k1,
            gesture: .tap
        )
        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)

        store.update(
            Mapping(
                action: .keyboardShortcut,
                command: "⌘K",
                keyboardShortcut: KeyboardShortcut(keyCode: 40, modifiers: [.command], displayString: "⌘K")
            ),
            for: .k1,
            gesture: .tap
        )
        XCTAssertEqual(store.standardNonApplicationRoutes(for: .k1).map(\.modifierControls), [[]])
    }

    func testToggleXPdWindowActionIsOmittedBecauseItHasAnIcon() {
        let store = makeStore()
        store.update(
            Mapping(action: .windowDisplay, command: WindowDisplayAction.toggleXPd.rawValue),
            for: .k1,
            gesture: .tap
        )

        XCTAssertTrue(store.hasMainWindowToggleMapping(for: .k1))
        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)
    }

    func testConfiguredNonApplicationActionKindsProduceRoutes() {
        let store = makeStore()
        let layers: [(Set<RemoteControl>, Mapping)] = [
            ([], Mapping(
                action: .keyboardShortcut,
                command: "⌘K",
                keyboardShortcut: KeyboardShortcut(keyCode: 40, modifiers: [.command], displayString: "⌘K")
            )),
            ([.k2], Mapping(action: .mediaControl, command: MediaControlAction.nextTrack.rawValue)),
            ([.k3], Mapping(action: .windowDisplay, command: WindowDisplayAction.minimize.rawValue)),
            ([.k4], Mapping(action: .switchProfile, command: "Global")),
            ([.k5], Mapping(action: .macOSShortcut, command: "Morning Setup", automationEnabled: true)),
            ([.k6], Mapping(
                action: .appleScript,
                command: "tell application \"Finder\" to activate",
                automationEnabled: true
            )),
            ([.k7], Mapping(action: .shellCommand, command: "echo ready", automationEnabled: true))
        ]

        for (modifiers, mapping) in layers {
            if !modifiers.isEmpty {
                for modifier in modifiers {
                    XCTAssertTrue(store.setRemoteModifier(modifier, enabled: true))
                }
            }
            store.update(mapping, for: .k1, gesture: .tap, modifierControls: modifiers)
        }

        XCTAssertEqual(
            store.standardNonApplicationRoutes(for: .k1).map(\.modifierControls),
            [[], [.k2], [.k3], [.k4], [.k5], [.k6], [.k7]]
        )
    }

    func testOnlyStandardKButtonsCanHaveRoutes() throws {
        let store = makeStore()
        store.update(
            Mapping(action: .mediaControl, command: MediaControlAction.playPause.rawValue),
            for: .wheelCW,
            gesture: .tap
        )
        XCTAssertTrue(store.standardNonApplicationRoutes(for: .wheelCW).isEmpty)

        _ = try store.addMIDIProfile(named: "Performance")
        store.update(
            Mapping(action: .mediaControl, command: MediaControlAction.playPause.rawValue),
            for: .k1,
            gesture: .tap
        )
        XCTAssertEqual(store.activeRealm, .midi)
        XCTAssertTrue(store.standardNonApplicationRoutes(for: .k1).isEmpty)
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }
}
