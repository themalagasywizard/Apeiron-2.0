import Foundation
import XCTest
@testable import ApeironKit

/// A provider that replays scripted responses and records requests.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ModelResponse]
    private(set) var requests: [ModelRequest] = []
    var delay: Duration = .zero

    init(_ responses: [ModelResponse]) {
        self.responses = responses
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let next = responses.isEmpty ? ModelResponse(blocks: [.text("(script exhausted)")], stopReason: .endTurn, usage: Usage()) : responses.removeFirst()
        lock.unlock()
        let delay = self.delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for block in next.blocks {
                        if case .text(let text) = block { continuation.yield(.textDelta(text)) }
                    }
                    if delay != .zero { try await Task.sleep(for: delay) }
                    continuation.yield(.completed(next))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }
}

/// Records permission prompts and answers with a fixed reply.
final class RecordingPrompter: PermissionPrompter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [PermissionRequest] = []
    let reply: PermissionReply

    init(reply: PermissionReply) { self.reply = reply }

    func requestPermission(_ request: PermissionRequest) async -> PermissionReply {
        lock.withLock { requests.append(request) }
        return reply
    }
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("apeiron-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func toolResponse(_ calls: [ToolCall], text: String? = nil) -> ModelResponse {
    var blocks: [ContentBlock] = []
    if let text { blocks.append(.text(text)) }
    blocks += calls.map { .toolCall($0) }
    return ModelResponse(blocks: blocks, stopReason: .toolUse, usage: Usage(inputTokens: 100, outputTokens: 20))
}

func textResponse(_ text: String) -> ModelResponse {
    ModelResponse(blocks: [.text(text)], stopReason: .endTurn, usage: Usage(inputTokens: 120, outputTokens: 30))
}

let testModel = ModelDescriptor(provider: .anthropic, apiModel: "claude-opus-5-5", displayName: "Test", contextWindow: 200_000, maxOutputTokens: 8_000)

func makeAgent(
    provider: LLMProvider,
    workspace: URL,
    mode: PermissionMode = .ask,
    rules: PermissionRules = PermissionRules(),
    prompter: PermissionPrompter = AutoApprovePrompter(),
    hooks: [HookDefinition] = [],
    history: [ChatMessage] = [],
    configure: (inout Agent.Configuration) -> Void = { _ in }
) -> Agent {
    var configuration = Agent.Configuration(model: testModel, maxRetries: 0)
    configure(&configuration)
    let context = ToolContext(workspace: workspace, sessionDirectory: workspace.appendingPathComponent(".session"))
    return Agent(
        provider: provider,
        configuration: configuration,
        systemPrompt: "test system prompt",
        tools: .standard(),
        policy: PermissionPolicy(mode: mode, rules: rules),
        prompter: prompter,
        hooks: HookRunner(hooks: hooks, workspace: workspace, sessionID: "test"),
        context: context,
        history: history
    )
}

func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}

extension Array where Element == AgentEvent {
    var finishReason: FinishReason? {
        for event in reversed() { if case .finished(let reason) = event { return reason } }
        return nil
    }
}

/// Asserts the core history invariant: each tool call is answered by the next message.
func assertToolCallsAnswered(_ history: [ChatMessage], file: StaticString = #filePath, line: UInt = #line) {
    for (index, message) in history.enumerated() where message.role == .assistant && !message.toolCalls.isEmpty {
        XCTAssertTrue(index + 1 < history.count, "tool calls at the end of history", file: file, line: line)
        guard index + 1 < history.count else { return }
        let results = Set(history[index + 1].toolResults.map(\.toolCallID))
        for call in message.toolCalls {
            XCTAssertTrue(results.contains(call.id), "missing result for \(call.id)", file: file, line: line)
        }
    }
}
