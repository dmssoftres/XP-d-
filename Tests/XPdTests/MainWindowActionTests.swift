import AppKit
import XCTest
@testable import XPd

@MainActor
final class MainWindowActionTests: XCTestCase {
    func testToggleHidesOnlyVisibleKeyWindowOfActiveApplication() {
        XCTAssertEqual(
            MainWindowController.operation(
                isVisible: true,
                isMiniaturized: false,
                isKeyWindow: true,
                applicationIsActive: true
            ),
            .hide
        )
    }

    func testToggleShowsMinimizedClosedAndBackgroundWindows() {
        XCTAssertEqual(
            MainWindowController.operation(
                isVisible: true,
                isMiniaturized: true,
                isKeyWindow: false,
                applicationIsActive: true
            ),
            .show
        )
        XCTAssertEqual(
            MainWindowController.operation(
                isVisible: false,
                isMiniaturized: false,
                isKeyWindow: false,
                applicationIsActive: true
            ),
            .show
        )
        XCTAssertEqual(
            MainWindowController.operation(
                isVisible: true,
                isMiniaturized: false,
                isKeyWindow: false,
                applicationIsActive: false
            ),
            .show
        )
    }

    func testRegisteredClosedWindowCanBeShownAgain() {
        _ = NSApplication.shared
        let controller = MainWindowController(activateApplication: {})
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        controller.register(window)
        window.orderFront(nil)
        window.close()

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.toggle(), .success("Opened XP[d]"))
        XCTAssertTrue(window.isVisible)

        window.close()
    }

    func testStoreRoutesShowHideActionToMainWindowController() {
        let suiteName = "MainWindowActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var toggleCount = 0
        let store = MappingStore(
            userDefaults: defaults,
            startHardware: false,
            mainWindowToggle: {
                toggleCount += 1
                return .success("Opened XP[d]")
            }
        )
        store.update(
            Mapping(action: .windowDisplay, command: WindowDisplayAction.toggleXPd.rawValue),
            for: .k1,
            gesture: .tap
        )

        var result: ActionExecutionResult?
        store.executeMapping(for: .k1, gesture: .tap) {
            result = $0
        }

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(result, .success("Opened XP[d]"))

        let reloaded = MappingStore(userDefaults: defaults, startHardware: false)
        XCTAssertEqual(
            reloaded.mapping(for: .k1, gesture: .tap),
            Mapping(action: .windowDisplay, command: WindowDisplayAction.toggleXPd.rawValue)
        )
    }

    func testStoreReportsUnavailableWindowController() {
        let suiteName = "MainWindowActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MappingStore(userDefaults: defaults, startHardware: false)
        store.update(
            Mapping(action: .windowDisplay, command: WindowDisplayAction.toggleXPd.rawValue),
            for: .k1,
            gesture: .tap
        )

        var result: ActionExecutionResult?
        store.executeMapping(for: .k1, gesture: .tap) {
            result = $0
        }

        XCTAssertEqual(result, .failure("XP[d] window action is unavailable"))
    }

    func testScreenDestinationPersistsThroughStoreReload() {
        let suiteName = "MainWindowActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let destination = WindowScreenDestination(
            displayID: 9,
            name: "Editing Display",
            identity: .init(vendor: 101, model: 202, serial: 303, unit: 1)
        )
        let mapping = Mapping(action: .windowDisplay, command: destination.command)
        let store = MappingStore(userDefaults: defaults, startHardware: false)
        store.update(mapping, for: .k2, gesture: .doubleTap)

        let reloaded = MappingStore(userDefaults: defaults, startHardware: false)
        XCTAssertEqual(reloaded.mapping(for: .k2, gesture: .doubleTap), mapping)
    }

    func testStoreReportsMainWindowBadgeForBaseAndEnabledModifierMappings() {
        let suiteName = "MainWindowActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MappingStore(userDefaults: defaults, startHardware: false)
        let toggle = Mapping(
            action: .windowDisplay,
            command: WindowDisplayAction.toggleXPd.rawValue
        )

        XCTAssertFalse(store.hasMainWindowToggleMapping(for: .k1))
        store.update(toggle, for: .k1, gesture: .hold)
        XCTAssertTrue(store.hasMainWindowToggleMapping(for: .k1))
        XCTAssertFalse(store.hasMainWindowToggleMapping(for: .k2))

        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        store.update(toggle, for: .k2, gesture: .doubleTap, modifierControls: [.k10])
        XCTAssertTrue(store.hasMainWindowToggleMapping(for: .k2))

        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: false))
        XCTAssertFalse(store.hasMainWindowToggleMapping(for: .k2))
    }
}
