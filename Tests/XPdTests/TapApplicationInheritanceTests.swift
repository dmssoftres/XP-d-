import Foundation
import XCTest
@testable import XPd

@MainActor
final class TapApplicationInheritanceTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.TapApplicationInheritanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testHoldInheritsCurrentTapApplication() throws {
        let store = makeStore()
        store.update(
            Mapping(action: .openApplication, command: "Finder"),
            for: .k1,
            gesture: .tap
        )
        store.update(
            Mapping(action: .toggleApplication, command: "Other", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )

        let resolved = try XCTUnwrap(try? store.resolvedMapping(for: .k1, gesture: .hold).get())
        XCTAssertEqual(resolved.action, .toggleApplication)
        XCTAssertEqual(resolved.command, "Finder")
        XCTAssertFalse(resolved.usesTapApplication)
    }

    func testDisabledInheritanceKeepsIndependentApplication() throws {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "Calculator", usesTapApplication: false),
            for: .k1,
            gesture: .doubleTap
        )

        let resolved = try XCTUnwrap(try? store.resolvedMapping(for: .k1, gesture: .doubleTap).get())
        XCTAssertEqual(resolved.command, "Calculator")
        XCTAssertFalse(resolved.usesTapApplication)
    }

    func testInheritedTargetReactsWhenTapChanges() throws {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "Ignored", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )

        XCTAssertEqual(try XCTUnwrap(try? store.resolvedMapping(for: .k1, gesture: .hold).get()).command, "Finder")
        store.update(Mapping(action: .toggleApplication, command: "Calculator"), for: .k1, gesture: .tap)
        XCTAssertEqual(try XCTUnwrap(try? store.resolvedMapping(for: .k1, gesture: .hold).get()).command, "Calculator")
    }

    func testHUDPresentationUsesResolvedInheritedApplication() {
        let store = makeStore()
        store.update(Mapping(action: .openApplication, command: "/Applications/Finder.app"), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "Stale hidden target", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )

        let presentation = InputOverlayPresentation(
            mapping: store.overlayMapping(for: .k1, gesture: .hold)
        )
        XCTAssertEqual(presentation.title, "Finder")
        XCTAssertTrue(presentation.isConfigured)
    }

    func testHUDPresentationDoesNotExposeStaleTargetWhenInheritanceIsInvalid() {
        let store = makeStore()
        store.update(Mapping(action: .noAction), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "Stale hidden target", usesTapApplication: true),
            for: .k1,
            gesture: .doubleTap
        )

        let presentation = InputOverlayPresentation(
            mapping: store.overlayMapping(for: .k1, gesture: .doubleTap)
        )
        XCTAssertEqual(presentation.title, "Not set")
        XCTAssertFalse(presentation.isConfigured)
    }

    func testMissingNonApplicationAndBlankTapTargetsFailSafely() {
        let store = makeStore()
        let hold = Mapping(action: .toggleApplication, command: "Ignored", usesTapApplication: true)
        store.update(hold, for: .k1, gesture: .hold)

        store.update(Mapping(action: .noAction, command: ""), for: .k1, gesture: .tap)
        XCTAssertEqual(
            store.resolvedMapping(for: .k1, gesture: .hold),
            .failure(.tapMappingMustBeApplication)
        )

        store.update(Mapping(action: .openApplication, command: "   "), for: .k1, gesture: .tap)
        XCTAssertEqual(
            store.resolvedMapping(for: .k1, gesture: .hold),
            .failure(.tapApplicationMissing)
        )
    }

    func testInvalidInheritanceExecutionReportsFailureWithoutRunningAction() {
        let store = makeStore()
        store.update(Mapping(action: .noAction), for: .k1, gesture: .tap)
        store.update(
            Mapping(action: .toggleApplication, command: "Calculator", usesTapApplication: true),
            for: .k1,
            gesture: .hold
        )

        let expectation = expectation(description: "invalid inheritance completes")
        store.executeMapping(for: .k1, gesture: .hold) { result in
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.message, "Tap must use Open application or Toggle application before it can be inherited.")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testAutosaveAndImportExportPreserveInheritanceFlag() throws {
        let source = makeStore()
        source.update(Mapping(action: .openApplication, command: "Finder"), for: .k2, gesture: .tap)
        source.update(
            Mapping(action: .toggleApplication, command: "Ignored", usesTapApplication: true),
            for: .k2,
            gesture: .doubleTap
        )

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.mapping(for: .k2, gesture: .doubleTap).usesTapApplication)
        XCTAssertEqual(try XCTUnwrap(try? reloaded.resolvedMapping(for: .k2, gesture: .doubleTap).get()).command, "Finder")

        let data = try XCTUnwrap(source.exportConfiguration())
        let target = makeStore()
        XCTAssertTrue(target.importConfiguration(data))
        XCTAssertTrue(target.mapping(for: .k2, gesture: .doubleTap).usesTapApplication)
        XCTAssertEqual(try XCTUnwrap(try? target.resolvedMapping(for: .k2, gesture: .doubleTap).get()).command, "Finder")
    }

    func testMissingFlagInOlderJSONDefaultsToFalse() throws {
        let oldJSON = Data(#"{"action":"Toggle application","command":"Calculator"}"#.utf8)
        let mapping = try JSONDecoder().decode(Mapping.self, from: oldJSON)
        XCTAssertFalse(mapping.usesTapApplication)

        let source = makeStore()
        source.update(Mapping(action: .toggleApplication, command: "Calculator"), for: .k1, gesture: .hold)
        let data = try XCTUnwrap(source.exportConfiguration())
        let oldData = try removingInheritanceFlags(from: data)
        let target = makeStore()
        XCTAssertTrue(target.importConfiguration(oldData))
        XCTAssertFalse(target.mapping(for: .k1, gesture: .hold).usesTapApplication)
    }

    func testWindowResolutionPrefersFocusedAndFallsBackToMain() {
        XCTAssertEqual(
            ActionRunner.orderedWindowCandidates(focused: "focused", main: "main"),
            ["focused", "main"]
        )
        XCTAssertEqual(
            ActionRunner.orderedWindowCandidates(focused: nil, main: "main"),
            ["main"]
        )
        XCTAssertTrue(
            ActionRunner.orderedWindowCandidates(focused: nil as String?, main: nil).isEmpty
        )
    }

    func testToggleMinimizesOnlyFrontmostUnminimizedTargetAndOtherwiseRestores() {
        XCTAssertEqual(
            ActionRunner.toggleOperation(applicationIsActive: true, targetWindowIsMinimized: false),
            .minimize
        )
        XCTAssertEqual(
            ActionRunner.toggleOperation(applicationIsActive: true, targetWindowIsMinimized: true),
            .restore
        )
        XCTAssertEqual(
            ActionRunner.toggleOperation(applicationIsActive: false, targetWindowIsMinimized: false),
            .restore
        )
    }

    func testApplicationPathMatchingDoesNotResolveAnUnrelatedRunningApp() {
        let runningURL = URL(fileURLWithPath: "/Applications/Finder.app")
        XCTAssertTrue(
            ActionRunner.applicationPathsMatch(
                requestedPath: "/Applications/Utilities/../Finder.app",
                runningURL: runningURL
            )
        )
        XCTAssertFalse(
            ActionRunner.applicationPathsMatch(
                requestedPath: "/Applications/Calculator.app",
                runningURL: runningURL
            )
        )
        XCTAssertFalse(
            ActionRunner.allowsBundleIdentifierFallback(
                for: "/Applications/XP[d].app"
            )
        )
        XCTAssertFalse(
            ActionRunner.allowsBundleIdentifierFallback(
                for: "/tmp/development/XP[d].app"
            )
        )
        XCTAssertTrue(
            ActionRunner.allowsBundleIdentifierFallback(
                for: "com.dmssoftres.xpd"
            )
        )
    }

    private func makeStore() -> MappingStore {
        MappingStore(userDefaults: defaults, startHardware: false)
    }

    private func removingInheritanceFlags(from data: Data) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        for profileIndex in profiles.indices {
            var profile = profiles[profileIndex]
            var mappings = try XCTUnwrap(profile["mappings"] as? [[String: Any]])
            for mappingIndex in mappings.indices {
                var entry = mappings[mappingIndex]
                var mapping = try XCTUnwrap(entry["mapping"] as? [String: Any])
                mapping.removeValue(forKey: "usesTapApplication")
                entry["mapping"] = mapping
                mappings[mappingIndex] = entry
            }
            profile["mappings"] = mappings
            profiles[profileIndex] = profile
        }
        root["profiles"] = profiles
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
