import XCTest
@testable import ApeironKit

final class FileAccessTests: XCTestCase {
    func testSearchFollowsSymlinkedWorkspace() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apeiron-link-\(UUID().uuidString)")
        let real = base.appendingPathComponent("Solar Kit")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "let panels = 12\n".write(to: real.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("Linked Kit")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let context = ToolContext(workspace: link, sessionDirectory: base.appendingPathComponent(".session"))
        let glob = try await GlobTool().run(["pattern": "**/*.swift"], context: context)
        XCTAssertEqual(glob.content, "src/main.swift")
        let grep = try await GrepTool().run(["pattern": "panels", "output_mode": "files"], context: context)
        XCTAssertTrue(grep.content.contains("main.swift"), grep.content)
        XCTAssertNil(FileAccess.checkReadable(link))
    }

    func testPermissionErrorsExplainTheFix() {
        let url = URL(fileURLWithPath: "/Users/someone/Desktop/Solar Kit")
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let message = FileAccessError(url: url, underlying: denied).errorDescription ?? ""
        XCTAssertTrue(message.contains("macOS blocked access"), message)
        XCTAssertTrue(message.contains("Privacy & Security"), message)

        let missing = FileAccessError(url: url, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
        XCTAssertEqual(missing.errorDescription, "/Users/someone/Desktop/Solar Kit doesn't exist.")
    }

    func testMissingWorkspaceIsAnErrorNotAnEmptyResult() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let context = ToolContext(workspace: missing, sessionDirectory: missing)
        do {
            _ = try await GlobTool().run(["pattern": "**/*"], context: context)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("doesn't exist"), error.localizedDescription)
        }
    }
}
