import AppKit
import XCTest
@testable import XPd

@MainActor
final class ActionRunnerOpenLinkTests: XCTestCase {
    private let existing: (String) -> Bool = { $0 == "/Users/me/Notes.pdf" || $0 == NSHomeDirectory() + "/Docs" }

    func testWebMailAndBareDomain() {
        XCTAssertEqual(OpenLinkTarget.resolve("https://pubmed.ncbi.nlm.nih.gov", fileExists: existing),
                       .success(.web(URL(string: "https://pubmed.ncbi.nlm.nih.gov")!)))
        XCTAssertEqual(OpenLinkTarget.resolve("  HTTP://example.com/a  ", fileExists: existing),
                       .success(.web(URL(string: "HTTP://example.com/a")!)))
        XCTAssertEqual(OpenLinkTarget.resolve("mailto:clinic@example.com", fileExists: existing),
                       .success(.mail(URL(string: "mailto:clinic@example.com")!)))
        XCTAssertEqual(OpenLinkTarget.resolve("example.com/path", fileExists: existing),
                       .success(.web(URL(string: "https://example.com/path")!)))
    }

    func testFilesAndFolders() {
        XCTAssertEqual(OpenLinkTarget.resolve("/Users/me/Notes.pdf", fileExists: existing),
                       .success(.file(URL(fileURLWithPath: "/Users/me/Notes.pdf"))))
        XCTAssertEqual(OpenLinkTarget.resolve("~/Docs", fileExists: existing),
                       .success(.file(URL(fileURLWithPath: NSHomeDirectory() + "/Docs"))))
        XCTAssertEqual(OpenLinkTarget.resolve("file:///Users/me/Notes.pdf", fileExists: existing),
                       .success(.file(URL(string: "file:///Users/me/Notes.pdf")!)))
        XCTAssertEqual(OpenLinkTarget.resolve("/missing.pdf", fileExists: existing), .failure(.missingFile("/missing.pdf")))
    }

    func testOtherSchemesAndJunkAreRefused() {
        for command in ["zoommtg://zoom.us/join?confno=1", "javascript:alert(1)", "ssh://host", "hello world", "plain", "https://"] {
            XCTAssertEqual(OpenLinkTarget.resolve(command, fileExists: existing), .failure(.unsupported(command)), command)
        }
        XCTAssertEqual(OpenLinkTarget.resolve("   ", fileExists: existing), .failure(.empty))
    }

    func testExecuteOpensResolvedURLOrExplains() {
        var opened: [URL] = []
        let runner = ActionRunner(urlOpener: { opened.append($0); return true })
        var result: ActionExecutionResult?

        runner.execute(mapping: Mapping(action: .openLink, command: "https://example.com")) { result = $0 }
        XCTAssertEqual(result, .success("Opened example.com"))
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])

        runner.execute(mapping: Mapping(action: .openLink, command: "zoommtg://x")) { result = $0 }
        XCTAssertEqual(result, .failure("Only web links, e-mail addresses and files can be opened"))
        runner.execute(mapping: Mapping(action: .openLink, command: "")) { result = $0 }
        XCTAssertEqual(result, .failure("Enter a link or choose a file first"))
        runner.execute(mapping: Mapping(action: .openLink, command: "/definitely/missing/file.pdf")) { result = $0 }
        XCTAssertEqual(result, .failure("File or folder not found; choose it again"))
        XCTAssertEqual(opened.count, 1)
    }

    func testOverlayAndActionSwitching() throws {
        let folder = try temporaryFolder()
        let pdf = folder.appendingPathComponent("My Notes.pdf")
        try Data("x".utf8).write(to: pdf)
        XCTAssertEqual(InputOverlayPresentation(mapping: Mapping(action: .openLink, command: "https://www.nejm.org/x")).title, "Open · www.nejm.org")
        XCTAssertEqual(InputOverlayPresentation(mapping: Mapping(action: .openLink, command: pdf.path)).title, "Open · My Notes.pdf")
        XCTAssertEqual(InputOverlayPresentation(mapping: Mapping(action: .openLink, command: pdf.absoluteString)).title, "Open · My Notes.pdf")
        XCTAssertEqual(InputOverlayPresentation(mapping: Mapping(action: .openLink, command: "mailto:a@b.com")).title, "Mail · a@b.com")
        let broken = InputOverlayPresentation(mapping: Mapping(action: .openLink, command: "plain"))
        XCTAssertFalse(broken.isConfigured)
        XCTAssertEqual(Mapping(action: .typeText, command: "secret").selectingAction(.openLink).command, "")
    }

    func testAppsScriptsAndLinkFilesAreRefused() throws {
        let folder = try temporaryFolder()
        for name in ["run.command", "setup.sh", "go.webloc", "x.terminal"] {
            let url = folder.appendingPathComponent(name)
            try Data("echo hi".utf8).write(to: url)
            XCTAssertEqual(OpenLinkTarget.resolve(url.path), .failure(.runnable(url.path)), name)
        }
        let tool = folder.appendingPathComponent("tool")
        try Data("#!/bin/sh\necho hi".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertEqual(OpenLinkTarget.resolve(tool.path), .failure(.runnable(tool.path)), "Executable file")
        XCTAssertEqual(OpenLinkTarget.resolve("/System/Applications/Calculator.app"),
                       .failure(.runnable("/System/Applications/Calculator.app")))
        XCTAssertEqual(OpenLinkTarget.resolve(folder.path), .success(.file(URL(fileURLWithPath: folder.path))), "Plain folders are fine")

        var opened: [URL] = []
        let runner = ActionRunner(urlOpener: { opened.append($0); return true })
        var result: ActionExecutionResult?
        runner.execute(mapping: Mapping(action: .openLink, command: tool.path)) { result = $0 }
        XCTAssertEqual(result, .failure("Apps and scripts can't be opened here; use Open application or Run shell command"))
        XCTAssertTrue(opened.isEmpty)
    }

    func testFileNamesAndVersionsAreNotGuessedAsWebsites() {
        for command in ["Notes.pdf", "v1.2", "report.docx", "evil.command"] {
            XCTAssertEqual(OpenLinkTarget.resolve(command, fileExists: existing), .failure(.unsupported(command)), command)
        }
        XCTAssertEqual(OpenLinkTarget.resolve("nejm.org", fileExists: existing), .success(.web(URL(string: "https://nejm.org")!)))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XPdOpenLink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
