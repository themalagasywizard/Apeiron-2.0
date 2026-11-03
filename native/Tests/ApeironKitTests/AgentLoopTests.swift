import XCTest
@testable import ApeironKit

final class AgentLoopTests: XCTestCase {
    func testRunsToolsAndFeedsResultsBack() async throws {
        let workspace = try makeTempDirectory()
        try "hello world\nsecond line".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "c1", name: "read_file", input: ["path": "notes.txt"])], text: "Reading."),
            textResponse("The file says hello."),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace)
        let events = await collect(agent.send("What does notes.txt say?"))

        XCTAssertEqual(events.finishReason, .completed)
        XCTAssertEqual(provider.requestCount, 2)
        let second = provider.requests[1]
        let result = try XCTUnwrap(second.messages.last?.toolResults.first)
        XCTAssertEqual(result.toolCallID, "c1")
        XCTAssertTrue(result.content.contains("hello world"))
        XCTAssertFalse(result.isError)
        let history = await agent.history
        XCTAssertEqual(history.count, 4)
        assertToolCallsAnswered(history)
        let total = await agent.totalUsage
        XCTAssertEqual(total.outputTokens, 50)
    }

    func testReadOnlyCallsRunInParallelAndKeepOrder() async throws {
        let workspace = try makeTempDirectory()
        for name in ["a", "b", "c"] {
            try name.write(to: workspace.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
        let provider = ScriptedProvider([
            toolResponse(["a", "b", "c"].map { ToolCall(id: $0, name: "read_file", input: ["path": .string("\($0).txt")]) }),
            textResponse("done"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace)
        _ = await collect(agent.send("read all"))
        let results = provider.requests[1].messages.last?.toolResults.map(\.toolCallID)
        XCTAssertEqual(results, ["a", "b", "c"])
    }

    func testDeniedEditIsReportedToTheModel() async throws {
        let workspace = try makeTempDirectory()
        let prompter = RecordingPrompter(reply: .deny(feedback: "Use tabs instead"))
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "w1", name: "write_file", input: ["path": "new.txt", "content": "x"])]),
            textResponse("ok"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, prompter: prompter)
        let events = await collect(agent.send("write it"))
        XCTAssertEqual(prompter.requests.count, 1)
        XCTAssertEqual(prompter.requests.first?.toolName, "write_file")
        if case .diff(let path, _, let after)? = prompter.requests.first?.preview {
            XCTAssertEqual(path, "new.txt")
            XCTAssertEqual(after, "x")
        } else {
            XCTFail("expected a diff preview")
        }
        let result = try XCTUnwrap(provider.requests[1].messages.last?.toolResults.first)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Use tabs instead"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("new.txt").path))
        XCTAssertEqual(events.finishReason, .completed)
    }

    func testAutoEditModeWritesWithoutAsking() async throws {
        let workspace = try makeTempDirectory()
        let prompter = RecordingPrompter(reply: .deny(feedback: nil))
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "w1", name: "write_file", input: ["path": "src/new.txt", "content": "made"])]),
            textResponse("ok"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, mode: .autoEdit, prompter: prompter)
        _ = await collect(agent.send("write it"))
        XCTAssertTrue(prompter.requests.isEmpty)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("src/new.txt"), encoding: .utf8), "made")
    }

    func testAllowAlwaysAddsRule() async throws {
        let workspace = try makeTempDirectory()
        let rule = PermissionRule(tool: "bash", pattern: "echo:*")
        let prompter = RecordingPrompter(reply: .allowAlways(rule))
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "b1", name: "bash", input: ["command": "echo one"])]),
            toolResponse([ToolCall(id: "b2", name: "bash", input: ["command": "echo two"])]),
            textResponse("ok"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, prompter: prompter)
        let events = await collect(agent.send("echo"))
        XCTAssertEqual(prompter.requests.count, 1, "second echo should be allowed by the new rule")
        XCTAssertTrue(events.contains { if case .ruleAdded(let added) = $0 { return added == rule } else { return false } })
        let second = try XCTUnwrap(provider.requests[2].messages.last?.toolResults.first)
        XCTAssertTrue(second.content.contains("two"))
    }

    func testPlanModeBlocksWrites() async throws {
        let workspace = try makeTempDirectory()
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "w1", name: "write_file", input: ["path": "x.txt", "content": "x"])]),
            textResponse("Here is my plan."),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, mode: .plan)
        _ = await collect(agent.send("change things"))
        let result = try XCTUnwrap(provider.requests[1].messages.last?.toolResults.first)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Plan mode"))
        // The first request carries the plan-mode reminder.
        XCTAssertTrue(provider.requests[0].messages.first?.text.contains("Plan mode is on") ?? false)
    }

    func testUnknownToolAndBadInputBecomeErrorResults() async throws {
        let workspace = try makeTempDirectory()
        let provider = ScriptedProvider([
            toolResponse([
                ToolCall(id: "u1", name: "teleport", input: [:]),
                ToolCall(id: "u2", name: "read_file", input: [:]),
                ToolCall(id: "u3", name: "edit_file", input: [:], inputParseError: "Tool input was not valid JSON"),
            ]),
            textResponse("sorry"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace)
        _ = await collect(agent.send("go"))
        let results = try XCTUnwrap(provider.requests[1].messages.last?.toolResults)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy(\.isError))
        XCTAssertTrue(results[0].content.contains("Unknown tool"))
        XCTAssertTrue(results[1].content.contains("Missing required"))
        XCTAssertTrue(results[2].content.contains("not valid JSON"))
    }

    func testInterruptionLeavesValidHistory() async throws {
        let workspace = try makeTempDirectory()
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "s1", name: "bash", input: ["command": "sleep 5"])]),
            textResponse("never"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, mode: .fullAccess)
        let stream = agent.send("sleep")
        let consumer = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(600))
        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(800))
        let history = await agent.history
        assertToolCallsAnswered(history)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testRepairHistoryFillsMissingResults() async throws {
        let workspace = try makeTempDirectory()
        let broken: [ChatMessage] = [
            .user("hi"),
            ChatMessage(role: .assistant, blocks: [.toolCall(ToolCall(id: "x", name: "glob", input: ["pattern": "*"]))]),
        ]
        let provider = ScriptedProvider([textResponse("ok")])
        let agent = makeAgent(provider: provider, workspace: workspace, history: broken)
        _ = await collect(agent.send("continue"))
        let sent = provider.requests[0].messages
        assertToolCallsAnswered(sent)
        XCTAssertEqual(sent.last?.text, "continue")
    }

    func testLargeOutputIsSpilledToFile() async throws {
        let workspace = try makeTempDirectory()
        let big = String(repeating: "0123456789\n", count: 5_000)
        try big.write(to: workspace.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "big", name: "read_file", input: ["path": "big.txt"])]),
            textResponse("ok"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace) { $0.maxToolOutputCharacters = 2_000 }
        _ = await collect(agent.send("read"))
        let result = try XCTUnwrap(provider.requests[1].messages.last?.toolResults.first)
        XCTAssertLessThan(result.content.count, 3_000)
        XCTAssertTrue(result.content.contains("full output is saved"))
        let spilled = workspace.appendingPathComponent(".session/tool-output/big.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spilled.path))
    }

    func testAutoCompactionReplacesHistoryWithSummary() async throws {
        let workspace = try makeTempDirectory()
        let longHistory: [ChatMessage] = (0..<6).flatMap { index in
            [ChatMessage.user("question \(index) " + String(repeating: "x", count: 2_000)),
             ChatMessage(role: .assistant, blocks: [.text("answer \(index)")])]
        }
        let provider = ScriptedProvider([
            textResponse("SUMMARY OF WORK"),
            textResponse("continuing"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, history: longHistory) {
            $0.budget = ContextBudget(contextWindow: 4_000, compactThreshold: 0.5)
        }
        let events = await collect(agent.send("next"))
        XCTAssertTrue(events.contains { if case .compacted = $0 { return true } else { return false } })
        XCTAssertTrue(provider.requests[0].tools.isEmpty, "summary request has no tools")
        let history = await agent.history
        XCTAssertEqual(history.first?.kind, .compactionSummary)
        XCTAssertTrue(history.first?.text.contains("SUMMARY OF WORK") ?? false)
        XCTAssertEqual(provider.requests[1].messages.map(\.text).last, "next", "the new prompt survives compaction verbatim")
        XCTAssertEqual(events.finishReason, .completed)
    }

    func testPreToolUseHookCanBlock() async throws {
        let workspace = try makeTempDirectory()
        let hook = HookDefinition(event: .preToolUse, matcher: "bash", command: "echo 'no shell today' >&2; exit 2")
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "b", name: "bash", input: ["command": "ls"])]),
            textResponse("ok"),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace, mode: .fullAccess, hooks: [hook])
        _ = await collect(agent.send("list"))
        let result = try XCTUnwrap(provider.requests[1].messages.last?.toolResults.first)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("no shell today"))
    }

    func testStopHookKeepsAgentGoing() async throws {
        let workspace = try makeTempDirectory()
        let marker = workspace.appendingPathComponent("stopped-once")
        let hook = HookDefinition(event: .stop, command: "if [ -f '\(marker.path)' ]; then exit 0; else touch '\(marker.path)'; echo 'run the tests first' >&2; exit 2; fi")
        let provider = ScriptedProvider([textResponse("done?"), textResponse("tests pass")])
        let agent = makeAgent(provider: provider, workspace: workspace, hooks: [hook])
        let events = await collect(agent.send("fix it"))
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertTrue(provider.requests[1].messages.last?.text.contains("run the tests first") ?? false)
        XCTAssertEqual(events.finishReason, .completed)
    }

    func testSubagentReportsBack() async throws {
        let workspace = try makeTempDirectory()
        let provider = ScriptedProvider([
            toolResponse([ToolCall(id: "t", name: "task", input: ["description": "look around", "prompt": "List the files"])]),
            textResponse("Subagent report: nothing here."),  // consumed by the child
            textResponse("Parent done."),
        ])
        let agent = makeAgent(provider: provider, workspace: workspace)
        await agent.enableSubagents()
        let events = await collect(agent.send("delegate"))
        XCTAssertEqual(events.finishReason, .completed)
        let result = try XCTUnwrap(provider.requests[2].messages.last?.toolResults.first)
        XCTAssertEqual(result.content, "Subagent report: nothing here.")
        XCTAssertTrue(provider.requests[1].system.contains("You are a subagent"))
        XCTAssertFalse(provider.requests[1].tools.contains { $0.name == "write_file" })
    }

    func testMaxTurnsStopsRunawayLoops() async throws {
        let workspace = try makeTempDirectory()
        let provider = ScriptedProvider((0..<10).map { toolResponse([ToolCall(id: "g\($0)", name: "glob", input: ["pattern": "*"])]) })
        let agent = makeAgent(provider: provider, workspace: workspace) { $0.maxTurns = 3 }
        let events = await collect(agent.send("loop"))
        XCTAssertEqual(events.finishReason, .maxTurns)
        XCTAssertEqual(provider.requestCount, 3)
        assertToolCallsAnswered(await agent.history)
    }

    func testDemoProviderDrivesRealTools() async throws {
        let workspace = try makeTempDirectory()
        try "# Demo".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let agent = makeAgent(provider: DemoProvider(chunkDelay: .zero), workspace: workspace)
        let events = await collect(agent.send("Tell me about this project"))
        XCTAssertEqual(events.finishReason, .completed)
        let history = await agent.history
        XCTAssertTrue(history.last?.text.contains("Files by type") ?? false)
        XCTAssertTrue(history.last?.text.contains(".md") ?? false)
    }
}
