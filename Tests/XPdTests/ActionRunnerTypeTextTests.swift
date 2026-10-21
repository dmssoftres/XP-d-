import AppKit
import XCTest
@testable import XPd

@MainActor
final class ActionRunnerTypeTextTests: XCTestCase {
    func testShortTextIsOneChunk() {
        XCTAssertEqual(ActionRunner.typingSteps(for: "Kind regards"), [.text("Kind regards")])
    }

    func testLongTextIsSplitIntoChunksOfAtMostTwentyUnits() {
        let text = String(repeating: "a", count: 45)
        let steps = ActionRunner.typingSteps(for: text)
        XCTAssertEqual(steps, [
            .text(String(repeating: "a", count: 20)),
            .text(String(repeating: "a", count: 20)),
            .text(String(repeating: "a", count: 5))
        ])
    }

    func testEmojiAndAccentsAreNeverSplit() {
        let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units, one character
        let text = String(repeating: "é", count: 15) + family + "ç"
        let steps = ActionRunner.typingSteps(for: text)
        var rebuilt = ""
        for step in steps {
            guard case let .text(chunk) = step else { return XCTFail("Unexpected key") }
            XCTAssertLessThanOrEqual(chunk.utf16.count, TypeTextLimits.chunkLength)
            rebuilt += chunk
        }
        XCTAssertEqual(rebuilt, text)
        XCTAssertTrue(steps.contains { $0 == .text(family + "ç") }, "Emoji starts a new chunk intact")
    }

    func testLineBreaksAndTabsAreRealKeys() {
        XCTAssertEqual(ActionRunner.typingSteps(for: "Hi\nthere\r\nA\tB"), [
            .text("Hi"), .key(36), .text("there"), .key(36), .text("A"), .key(48), .text("B")
        ])
    }

    func testExecutePostsUnicodeEventsWithoutModifiers() {
        var posted: [CGEvent] = []
        let runner = ActionRunner(postEventAccessProvider: { true }, eventPoster: { posted.append($0) })
        var result: ActionExecutionResult?

        runner.execute(mapping: Mapping(action: .typeText, command: "Olá\nDr")) { result = $0 }

        XCTAssertEqual(result, .success("Typed Olá"))
        XCTAssertEqual(posted.count, 6) // "Olá" down/up, Return down/up, "Dr" down/up
        XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertEqual(unicode(of: posted[0]), "Olá")
        XCTAssertEqual(posted[2].getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertEqual(unicode(of: posted[4]), "Dr")
        XCTAssertTrue(posted.allSatisfy { $0.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty })
    }

    func testEmptyTextAndMissingPermissionFailWithoutTyping() {
        var posted: [CGEvent] = []
        let runner = ActionRunner(postEventAccessProvider: { false }, eventPoster: { posted.append($0) })
        var result: ActionExecutionResult?

        runner.execute(mapping: Mapping(action: .typeText, command: "")) { result = $0 }
        XCTAssertEqual(result, .failure("Enter the text to type first"))

        runner.execute(mapping: Mapping(action: .typeText, command: "Hello")) { result = $0 }
        XCTAssertEqual(result, .failure("Allow XP[d] in Accessibility, then press again"))
        XCTAssertTrue(posted.isEmpty)
    }

    func testTextBeyondLimitIsTruncated() {
        var posted: [CGEvent] = []
        let runner = ActionRunner(postEventAccessProvider: { true }, eventPoster: { posted.append($0) })
        let text = String(repeating: "x", count: TypeTextLimits.maximumLength + 100)
        runner.execute(mapping: Mapping(action: .typeText, command: text)) { _ in }
        let typed = posted.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { unicode(of: $0.element) }.joined()
        XCTAssertEqual(typed.count, TypeTextLimits.maximumLength)
    }

    func testOverlayShowsFirstLine() {
        let presentation = InputOverlayPresentation(mapping: Mapping(action: .typeText, command: "Kind regards,\nDr. Smith"))
        XCTAssertTrue(presentation.isConfigured)
        XCTAssertEqual(presentation.title, "Type · Kind regards,")
        XCTAssertFalse(InputOverlayPresentation(mapping: Mapping(action: .typeText, command: "")).isConfigured)
    }

    func testTypeTextSurvivesExportImport() throws {
        let suite = "XPdTests.TypeText.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MappingStore(userDefaults: defaults, startHardware: false)
        let mapping = Mapping(action: .typeText, command: "Line 1\nLine 2 ✓")
        store.update(mapping, for: .k1, gesture: .tap)
        let data = try XCTUnwrap(store.exportConfiguration())
        store.update(Mapping(), for: .k1, gesture: .tap)
        XCTAssertTrue(store.importConfiguration(data))
        XCTAssertEqual(store.mapping(for: .k1, gesture: .tap), mapping)
    }

    func testSwitchingToTypeTextNeverKeepsPreviousCommand() {
        let shell = Mapping(action: .shellCommand, command: "rm -rf ~/x", shellCommandContent: "rm -rf ~/x", automationEnabled: true)
        let typed = shell.selectingAction(.typeText)
        XCTAssertEqual(typed.action, .typeText)
        XCTAssertEqual(typed.command, "")
        XCTAssertEqual(Mapping(action: .openApplication, command: "Finder").selectingAction(.typeText).command, "")
    }

    private func unicode(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
