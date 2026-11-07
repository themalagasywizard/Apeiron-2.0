import Foundation

/// Tracks how full the context window is and compacts history when needed.
///
/// Token counts come from the provider's usage report on the last response;
/// only messages appended since then are estimated locally.
public struct ContextBudget: Sendable, Equatable {
    public var contextWindow: Int
    /// Compact when usage passes this fraction of the window.
    public var compactThreshold: Double
    /// Hard cap so 1M-token models still compact at a sensible size.
    public var compactCeiling: Int

    public init(contextWindow: Int, compactThreshold: Double = 0.8, compactCeiling: Int = 400_000) {
        self.contextWindow = contextWindow
        self.compactThreshold = compactThreshold
        self.compactCeiling = compactCeiling
    }

    public var compactAt: Int {
        min(Int(Double(contextWindow) * compactThreshold), compactCeiling)
    }
}

public enum ContextEstimator {
    /// Estimated tokens in play for the next request.
    public static func tokens(
        history: [ChatMessage],
        systemPrompt: String,
        toolSpecs: [ToolSpec],
        lastUsage: Usage?,
        lastUsageMessageCount: Int
    ) -> Int {
        if let lastUsage, lastUsageMessageCount <= history.count, lastUsage.contextTokens > 0 {
            let appended = history[lastUsageMessageCount...].reduce(0) { $0 + TextUtils.estimateTokens($1) }
            return lastUsage.contextTokens + appended
        }
        let toolTokens = toolSpecs.reduce(0) { $0 + TextUtils.estimateTokens($1.description + $1.inputSchema.serialized()) }
        return TextUtils.estimateTokens(systemPrompt) + toolTokens + history.reduce(0) { $0 + TextUtils.estimateTokens($1) }
    }
}

public enum Compactor {
    static let systemPrompt = """
    You summarise an AI agent's working session so it can continue with a fresh context window. \
    Write a dense, faithful summary in Markdown with these sections:
    1. **Goal** – what the user wants, in their words where possible, including every explicit request and constraint.
    2. **Decisions and findings** – key facts learned, decisions made and why.
    3. **Files** – files read, created or modified, with what changed and important snippets or line references.
    4. **Commands and results** – builds, tests and commands run, with outcomes and unresolved errors.
    5. **Current state** – exactly where the work stopped, including anything in progress.
    6. **Next steps** – what remains, in order.
    Keep identifiers, paths, numbers and error messages exact. Do not invent anything. Do not address the user.
    """

    /// Renders history as a plain transcript for the summariser.
    public static func transcript(of history: [ChatMessage], maxCharactersPerResult: Int = 4_000) -> String {
        var lines: [String] = []
        for message in history {
            switch message.role {
            case .user:
                for block in message.blocks {
                    switch block {
                    case .text(let text): lines.append("USER: \(text)")
                    case .toolResult(let result):
                        let body = TextUtils.truncateMiddle(result.content, maxCharacters: maxCharactersPerResult)
                        lines.append("TOOL RESULT\(result.isError ? " (error)" : ""): \(body)")
                    case .image(let image): lines.append("USER: [image \(image.filename ?? image.mediaType)]")
                    default: break
                    }
                }
            case .assistant:
                for block in message.blocks {
                    switch block {
                    case .text(let text): lines.append("ASSISTANT: \(text)")
                    case .toolCall(let call):
                        lines.append("ASSISTANT CALLED \(call.name): \(TextUtils.truncateMiddle(call.input.serialized(), maxCharacters: 2_000))")
                    default: break
                    }
                }
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Summarises the whole history into one user message. Collapsing
    /// everything (rather than keeping a tail) keeps the new history
    /// append-only and free of orphaned tool calls or stale thinking blocks.
    public static func compact(
        history: [ChatMessage],
        todos: [TodoItem],
        provider: LLMProvider,
        model: ModelDescriptor,
        focus: String? = nil
    ) async throws -> (message: ChatMessage, usage: Usage) {
        var text = transcript(of: history)
        let budget = max(20_000, min(model.contextWindow, 400_000) * 3)  // characters, roughly ¾ of the window
        text = TextUtils.truncateMiddle(text, maxCharacters: budget, note: "middle of the session omitted for length")
        var instruction = "Summarise this session.\n\n<session>\n\(text)\n</session>"
        if let focus, !focus.isEmpty { instruction += "\n\nPay particular attention to: \(focus)" }

        let request = ModelRequest(
            model: model,
            system: systemPrompt,
            messages: [.user(instruction)],
            tools: [],
            maxOutputTokens: min(model.maxOutputTokens, 12_000),
            effort: .low,
            showThinking: false
        )
        let response = try await provider.complete(request)
        let summary = response.blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")

        var body = """
        <conversation-summary>
        This session was compacted to free up context. Summary of everything so far:

        \(summary)
        </conversation-summary>
        """
        if !todos.isEmpty {
            body += "\n\nCurrent task list:\n" + todos.map { "- [\($0.status.rawValue)] \($0.content)" }.joined(separator: "\n")
        }
        body += "\n\nContinue the work from where it stopped. Re-read any file before editing it."
        return (ChatMessage(role: .user, blocks: [.text(body)], kind: .compactionSummary), response.usage)
    }
}
