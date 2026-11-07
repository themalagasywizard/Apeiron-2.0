import Foundation

/// An offline, scripted model. It streams like a real provider and drives the
/// real tools (read-only ones), so the whole harness and UI can be explored
/// and tested without an API key.
public struct DemoProvider: LLMProvider {
    public var chunkDelay: Duration

    public init(chunkDelay: Duration = .milliseconds(12)) {
        self.chunkDelay = chunkDelay
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let blocks = Self.script(for: request)
                    for block in blocks {
                        switch block {
                        case .thinking(let text, _):
                            for piece in Self.chunks(text) {
                                try await Task.sleep(for: chunkDelay)
                                continuation.yield(.thinkingDelta(piece))
                            }
                        case .text(let text):
                            for piece in Self.chunks(text) {
                                try await Task.sleep(for: chunkDelay)
                                continuation.yield(.textDelta(piece))
                            }
                        case .toolCall(let call):
                            continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                            continuation.yield(.toolInputDelta(id: call.id, partialJSON: call.input.serialized()))
                        default:
                            break
                        }
                    }
                    let hasCalls = blocks.contains { if case .toolCall = $0 { return true } else { return false } }
                    let promptChars = request.system.count + request.messages.reduce(0) { $0 + $1.text.count + $1.toolResults.reduce(0) { $0 + $1.content.count } }
                    let usage = Usage(inputTokens: promptChars / 4, outputTokens: blocks.count * 60)
                    continuation.yield(.usage(usage))
                    continuation.yield(.completed(ModelResponse(
                        blocks: blocks,
                        stopReason: hasCalls ? .toolUse : .endTurn,
                        usage: usage,
                        servedModel: request.model.apiModel
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n", current.count >= 3 {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Picks the next scripted turn from where the conversation is.
    static func script(for request: ModelRequest) -> [ContentBlock] {
        // Summarisation requests (compaction) get a summary back.
        if request.tools.isEmpty {
            return [.text("## Summary\nThe user is exploring Apeiron in demo mode. The assistant listed the workspace, scanned its files and reported back. Continue helping from here.")]
        }
        let lastPromptIndex = request.messages.lastIndex { $0.role == .user && !$0.isToolResultCarrier } ?? 0
        let prompt = request.messages.indices.contains(lastPromptIndex) ? request.messages[lastPromptIndex].text : ""
        let step = request.messages[lastPromptIndex...].filter { $0.role == .assistant }.count
        let toolNames = Set(request.tools.map(\.name))
        let id = { (suffix: String) in "demo_\(suffix)_\(UUID().uuidString.prefix(6))" }

        switch step {
        case 0:
            var blocks: [ContentBlock] = [
                .thinking(text: "The user said: “\(prompt.prefix(120))”. I don't have a live model in demo mode, so I'll show how I work: look at the workspace, keep a short task list, then report what I found.", signature: nil),
                .text("I'll start by getting my bearings in this workspace."),
            ]
            if toolNames.contains("todo_write") {
                blocks.append(.toolCall(ToolCall(id: id("todo"), name: "todo_write", input: [
                    "todos": [
                        ["content": "Survey the workspace layout", "status": "in_progress", "activeForm": "Surveying the workspace"],
                        ["content": "Find the main source files", "status": "pending", "activeForm": "Finding source files"],
                        ["content": "Summarise what I found", "status": "pending", "activeForm": "Summarising"],
                    ],
                ])))
            }
            if toolNames.contains("list_directory") {
                blocks.append(.toolCall(ToolCall(id: id("ls"), name: "list_directory", input: ["path": "."])))
            }
            return blocks
        case 1:
            var blocks: [ContentBlock] = [.text("Now let me find the source files.")]
            if toolNames.contains("glob") {
                blocks.append(.toolCall(ToolCall(id: id("glob"), name: "glob", input: ["pattern": "**/*.{swift,ts,tsx,js,py,md,rs,go}"])))
            }
            if toolNames.contains("todo_write") {
                blocks.append(.toolCall(ToolCall(id: id("todo"), name: "todo_write", input: [
                    "todos": [
                        ["content": "Survey the workspace layout", "status": "completed"],
                        ["content": "Find the main source files", "status": "completed"],
                        ["content": "Summarise what I found", "status": "in_progress", "activeForm": "Summarising"],
                    ],
                ])))
            }
            return blocks
        default:
            let globOutput = request.messages.last?.toolResults.first?.content ?? ""
            let files = globOutput.split(separator: "\n").filter { !$0.hasPrefix("(") && !$0.isEmpty }
            var extensionCounts: [String: Int] = [:]
            for file in files {
                let ext = (String(file) as NSString).pathExtension
                if !ext.isEmpty { extensionCounts[ext, default: 0] += 1 }
            }
            let table = extensionCounts.sorted { $0.value > $1.value }.prefix(6)
                .map { "| `.\($0.key)` | \($0.value) |" }
                .joined(separator: "\n")
            let sample = files.prefix(5).map { "- `\($0)`" }.joined(separator: "\n")
            let body = """
            Here's what I found in this workspace.

            ### Files by type
            | Extension | Files |
            |---|---|
            \(table.isEmpty ? "| — | 0 |" : table)

            ### Recently changed
            \(sample.isEmpty ? "_No source files matched._" : sample)

            ### What happens with a real model
            With an API key, I'd read the important files, plan changes with you, and edit code. Edits and shell commands ask for your approval first, unless you switch to **Auto-edit** or **Full access**.

            ```bash
            # Add a key in Settings → Providers, then pick a model in the toolbar.
            ```
            """
            return [.text(body)]
        }
    }
}
