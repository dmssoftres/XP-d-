import Foundation
import XCTest
@testable import XPd

@MainActor
final class AutoSwitchProfileTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "XPdTests.AutoSwitchProfileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let chrome = "com.google.Chrome"

    func testOffByDefaultAndDoesNothingWhenOff() throws {
        let store = makeStore()
        XCTAssertFalse(store.autoSwitchProfilesEnabled)
        let web = try store.addProfile(named: "Web")
        XCTAssertEqual(store.addAutoSwitchApplication(chrome, to: web), .added)
        XCTAssertTrue(store.selectProfile("Global"))

        store.frontmostApplicationChanged(bundleIdentifier: chrome)
        XCTAssertEqual(store.profileName, "Global")
    }

    func testSwitchesToAssignedProfileWhenOn() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        XCTAssertTrue(store.selectProfile("Global"))
        store.autoSwitchProfilesEnabled = true

        store.frontmostApplicationChanged(bundleIdentifier: "COM.GOOGLE.CHROME")
        XCTAssertEqual(store.profileName, web, "Bundle IDs match case-insensitively")
    }

    func testUnlistedAppKeepsCurrentProfile() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        store.autoSwitchProfilesEnabled = true

        store.frontmostApplicationChanged(bundleIdentifier: "com.apple.Notes")
        XCTAssertEqual(store.profileName, web)
        store.frontmostApplicationChanged(bundleIdentifier: nil)
        XCTAssertEqual(store.profileName, web)
    }

    func testNeverLeavesMIDILock() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        let midi = try store.addMIDIProfile(named: "Live")
        XCTAssertEqual(store.profileName, midi)
        store.autoSwitchProfilesEnabled = true

        store.frontmostApplicationChanged(bundleIdentifier: chrome)
        XCTAssertEqual(store.profileName, midi)
    }

    func testOneAppBelongsToOneProfileAndMIDIProfilesCannotHaveApps() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        let work = try store.addProfile(named: "Work")
        XCTAssertEqual(store.addAutoSwitchApplication(chrome, to: web), .added)
        XCTAssertEqual(store.addAutoSwitchApplication("com.google.chrome", to: work), .alreadyAssigned(profile: web))
        XCTAssertEqual(store.addAutoSwitchApplication("  ", to: work), .invalid)

        let midi = try store.addMIDIProfile(named: "Live")
        XCTAssertEqual(store.addAutoSwitchApplication("com.apple.logic10", to: midi), .invalid)
    }

    func testRemoveApplication() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        store.removeAutoSwitchApplication("com.google.chrome", from: web)
        XCTAssertEqual(store.autoSwitchApplications(for: web), [])
    }

    func testListSurvivesEditsRenameAndRestart() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        store.update(Mapping(action: .openApplication, command: "Finder"), for: .k1, gesture: .tap)
        XCTAssertEqual(store.autoSwitchApplications(for: web), [chrome], "Editing the active profile keeps its apps")

        let renamed = try store.renameProfile(named: web, to: "Browser")
        XCTAssertEqual(store.autoSwitchApplications(for: renamed), [chrome])
        store.autoSwitchProfilesEnabled = true

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.autoSwitchProfilesEnabled)
        XCTAssertEqual(reloaded.autoSwitchApplications(for: renamed), [chrome])
    }

    func testExportImportRoundTripKeepsApps() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        let data = try XCTUnwrap(store.exportConfiguration())
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(chrome))

        let other = makeStore(suffix: "other")
        XCTAssertTrue(other.importConfiguration(data))
        XCTAssertEqual(other.autoSwitchApplications(for: web), [chrome])
    }

    func testImportRejectsAppAssignedTwice() throws {
        let profiles = [
            XPdConfiguration.Profile(name: "Global", mappings: [], hidBindings: [], autoSwitchApplications: [chrome]),
            XPdConfiguration.Profile(name: "Web", mappings: [], hidBindings: [], autoSwitchApplications: ["com.google.chrome"])
        ]
        XCTAssertThrowsError(try XPdConfiguration.validateAutoSwitchApplications(profiles))
        let midi = [XPdConfiguration.Profile(
            name: "Live", mappings: [], hidBindings: [], realm: .midi, autoSwitchApplications: [chrome]
        )]
        XCTAssertThrowsError(try XPdConfiguration.validateAutoSwitchApplications(midi))
    }

    func testAddingAnAppIsUndoable() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.autoSwitchApplications(for: web), [])
    }


    func testSwitchWaitsUntilHeldRemoteButtonIsReleased() async throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        XCTAssertTrue(store.selectProfile("Global"))
        store.autoSwitchProfilesEnabled = true

        store.simulateHIDInputForTesting("r6:03 1D 00 00 00 00 00") // K10 held
        store.frontmostApplicationChanged(bundleIdentifier: chrome)
        XCTAssertEqual(store.profileName, "Global", "No switch mid-press")

        store.simulateHIDInputForTesting(nil) // release
        for _ in 0..<200 where store.profileName != web {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.profileName, web, "Switch applies after release")
    }

    func testNoSwitchWhileLearning() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        XCTAssertTrue(store.selectProfile("Global"))
        store.autoSwitchProfilesEnabled = true

        store.selectedControl = .k1
        store.learnSelectedControl()
        store.frontmostApplicationChanged(bundleIdentifier: chrome)
        XCTAssertEqual(store.profileName, "Global")
        store.cancelLearning()
        store.frontmostApplicationChanged(bundleIdentifier: chrome)
        XCTAssertEqual(store.profileName, web)
    }

    func testToggleIsNotAnUndoStep() {
        let store = makeStore()
        store.autoSwitchProfilesEnabled = true
        XCTAssertFalse(store.canUndo)
    }

    func testAppsCanBeAssignedToStandardProfileWhileMIDIIsActive() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        let midi = try store.addMIDIProfile(named: "Live")
        XCTAssertEqual(store.profileName, midi)
        XCTAssertEqual(store.addAutoSwitchApplication(chrome, to: web), .added)
        XCTAssertEqual(store.autoSwitchApplications(for: web), [chrome])
        XCTAssertEqual(store.autoSwitchApplications(for: midi), [])
    }

    func testImportOfDocumentAssigningAnAppTwiceIsRejected() throws {
        let store = makeStore()
        let web = try store.addProfile(named: "Web")
        store.addAutoSwitchApplication(chrome, to: web)
        let data = try XCTUnwrap(store.exportConfiguration())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        let globalIndex = try XCTUnwrap(profiles.firstIndex { $0["name"] as? String == "Global" })
        profiles[globalIndex]["autoSwitchApplications"] = ["COM.GOOGLE.CHROME"]
        json["profiles"] = profiles
        let tampered = try JSONSerialization.data(withJSONObject: json)

        let other = makeStore(suffix: "tampered")
        XCTAssertFalse(other.importConfiguration(tampered))
        XCTAssertEqual(other.autoSwitchApplications(for: "Global"), [])
    }

    func testDuplicateCopiesKeysButNotApps() throws {
        let store = makeStore()
        XCTAssertTrue(store.setRemoteModifier(.k10, enabled: true))
        let finder = Mapping(action: .openApplication, command: "Finder")
        store.update(finder, for: .k1, gesture: .tap)
        store.update(finder, for: .k5, gesture: .hold, modifierControls: [.k10])
        store.updateStandardButtonTitle("Files", for: .k1)
        store.addAutoSwitchApplication(chrome, to: "Global")

        let copy = try store.duplicateProfile(named: "Global", as: "Chrome")
        XCTAssertEqual(store.profileName, copy, "The copy becomes active")
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
        XCTAssertEqual(store.mapping(for: .k5, gesture: .hold, modifierControls: [.k10]), finder)
        XCTAssertEqual(store.standardButtonTitle(for: .k1), "Files")
        XCTAssertTrue(store.isRemoteModifier(.k10))
        XCTAssertEqual(store.autoSwitchApplications(for: copy), [])
        XCTAssertEqual(store.autoSwitchApplications(for: "Global"), [chrome])

        // Independent afterwards.
        store.update(Mapping(action: .openApplication, command: "Safari"), for: .k1, gesture: .tap)
        XCTAssertTrue(store.selectProfile("Global"))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), finder)
    }

    func testDuplicateRejectsBadNamesAndIsUndoable() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.duplicateProfile(named: "Global", as: "global"))
        XCTAssertThrowsError(try store.duplicateProfile(named: "Missing", as: "New"))
        let copy = try store.duplicateProfile(named: "Global", as: "Copy")
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.availableProfiles.contains(copy))
    }

    func testDuplicateOfMIDIProfileStaysMIDI() throws {
        let store = makeStore()
        let midi = try store.addMIDIProfile(named: "Live")
        let copy = try store.duplicateProfile(named: midi, as: "Live 2")
        XCTAssertEqual(store.profileRealm(for: copy), .midi)
        XCTAssertEqual(store.activeRealm, .midi)
    }

    private func makeStore(suffix: String? = nil) -> MappingStore {
        guard let suffix else {
            return MappingStore(userDefaults: defaults, startHardware: false)
        }
        let name = "\(suiteName).\(suffix)"
        let other = UserDefaults(suiteName: name)!
        other.removePersistentDomain(forName: name)
        addTeardownBlock { other.removePersistentDomain(forName: name) }
        return MappingStore(userDefaults: other, startHardware: false)
    }
}
