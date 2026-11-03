import XCTest
@testable import ApeironKit

final class ToolTests: XCTestCase {
    var workspace: URL!
    var context: ToolContext!

    override func setUp() async throws {
        workspace = try makeTempDirectory()
        context = ToolContext(workspace: workspace, sessionDirectory: workspace.appendingPathComponent(".session"))
    }

    func write(_ text: String, to path: String) throws {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadFileNumbersAndPages() async throws {
        try write((1...10).map { "line \($0)" }.joined(separator: "\n"), to: "a.txt")
        let output = try await ReadFileTool().run(["path": "a.txt", "offset": 3, "limit": 2], context: context)
        XCTAssertTrue(output.content.contains("     3\tline 3"))
        XCTAssertTrue(output.content.contains("     4\tline 4"))
        XCTAssertFalse(output.content.contains("line 5"))
        XCTAssertTrue(output.content.contains("offset=5"))
        let missing = try await ReadFileTool().run(["path": "nope.txt"], context: context)
        XCTAssertTrue(missing.isError)
    }

    func testEditRequiresReadAndUniqueMatch() async throws {
        try write("let a = 1\nlet b = 1\n", to: "x.swift")
        let edit = EditFileTool()
        let blocked = try await edit.run(["path": "x.swift", "old_string": "let a = 1", "new_string": "let a = 2"], context: context)
        XCTAssertTrue(blocked.isError)
        XCTAssertTrue(blocked.content.contains("read"))

        _ = try await ReadFileTool().run(["path": "x.swift"], context: context)
        let ambiguous = try await edit.run(["path": "x.swift", "old_string": "= 1", "new_string": "= 2"], context: context)
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.content.contains("2 times"))

        let ok = try await edit.run(["path": "x.swift", "old_string": "let a = 1", "new_string": "let a = 2"], context: context)
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("x.swift"), encoding: .utf8), "let a = 2\nlet b = 1\n")
        guard case .diff(_, let before, let after)? = ok.metadata else { return XCTFail("diff metadata") }
        XCTAssertNotEqual(before, after)

        let all = try await edit.run(["path": "x.swift", "old_string": "let", "new_string": "var", "replace_all": true], context: context)
        XCTAssertFalse(all.isError)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("x.swift"), encoding: .utf8), "var a = 2\nvar b = 1\n")
    }

    func testEditDetectsExternalChanges() async throws {
        try write("one", to: "f.txt")
        _ = try await ReadFileTool().run(["path": "f.txt"], context: context)
        try await Task.sleep(for: .milliseconds(1_100))
        try write("two", to: "f.txt")
        let result = try await EditFileTool().run(["path": "f.txt", "old_string": "two", "new_string": "three"], context: context)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("changed on disk"))
    }

    func testWriteCreatesAndGuardsOverwrite() async throws {
        let created = try await WriteFileTool().run(["path": "deep/dir/new.txt", "content": "hi"], context: context)
        XCTAssertFalse(created.isError)
        try write("existing", to: "e.txt")
        let blocked = try await WriteFileTool().run(["path": "e.txt", "content": "clobber"], context: context)
        XCTAssertTrue(blocked.isError)
    }

    func testGlobAndGrep() async throws {
        try write("struct App {}\n", to: "Sources/App.swift")
        try write("// TODO: fix\nlet x = 1\n", to: "Sources/Util/Helpers.swift")
        try write("hidden", to: "node_modules/pkg/index.swift")
        let glob = try await GlobTool().run(["pattern": "**/*.swift"], context: context)
        XCTAssertTrue(glob.content.contains("Sources/App.swift"))
        XCTAssertTrue(glob.content.contains("Sources/Util/Helpers.swift"))
        XCTAssertFalse(glob.content.contains("node_modules"))

        let files = try await GrepTool().run(["pattern": "TODO"], context: context)
        XCTAssertEqual(files.content.trimmingCharacters(in: .whitespacesAndNewlines), "Sources/Util/Helpers.swift")
        let content = try await GrepTool().run(["pattern": "todo", "case_insensitive": true, "output_mode": "content"], context: context)
        XCTAssertTrue(content.content.contains(":1:"))
        let none = try await GrepTool().run(["pattern": "zzz_nothing"], context: context)
        XCTAssertEqual(none.content, "(no matches)")
    }

    func testBashCapturesOutputAndExitCode() async throws {
        let ok = try await BashTool().run(["command": "echo hi && echo oops >&2"], context: context)
        XCTAssertTrue(ok.content.contains("hi"))
        XCTAssertTrue(ok.content.contains("[stderr]\noops"))
        XCTAssertTrue(ok.content.contains("[exit code 0]"))
        let failed = try await BashTool().run(["command": "exit 3"], context: context)
        XCTAssertTrue(failed.isError)
        let slow = try await BashTool().run(["command": "sleep 5", "timeout_seconds": 1], context: context)
        XCTAssertTrue(slow.content.contains("timed out"))
    }

    func testTodoWriteUpdatesStore() async throws {
        let output = try await TodoWriteTool().run(["todos": [
            ["content": "A", "status": "completed"],
            ["content": "B", "status": "in_progress", "activeForm": "Doing B"],
        ]], context: context)
        XCTAssertTrue(output.content.contains("1/2"))
        let items = await context.todos.items
        XCTAssertEqual(items.map(\.status), [.completed, .inProgress])
    }

    func testListDirectorySkipsHeavyFolders() async throws {
        try write("x", to: "src/a.txt")
        try write("x", to: ".git/HEAD")
        let output = try await ListDirectoryTool().run([:], context: context)
        XCTAssertTrue(output.content.contains("src/"))
        XCTAssertFalse(output.content.contains(".git/"))
    }
}
