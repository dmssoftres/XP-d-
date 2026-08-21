import XCTest
@testable import XPd

final class InputOverlayModelTests: XCTestCase {
    @MainActor
    func testProfileSelectorKeepsOverlayVisibleUntilExplicitlyHidden() {
        let model = InputOverlayModel()
        var visibilityChanges: [Bool] = []
        model.visibilityDidChange = { visibilityChanges.append($0) }

        model.showProfiles(["Global", "Finder"], selectedProfile: "Global")
        model.reset()

        XCTAssertEqual(model.profileSelection?.selectedProfile, "Global")
        XCTAssertEqual(visibilityChanges, [true, true])

        model.hideProfiles()

        XCTAssertNil(model.profileSelection)
        XCTAssertEqual(visibilityChanges.last, false)
    }
}
