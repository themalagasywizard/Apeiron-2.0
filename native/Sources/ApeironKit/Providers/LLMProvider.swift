import Foundation

public struct ToolSpec: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum Effort: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

public struct ModelRequest: Sendable {
    public var model: ModelDescriptor
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var maxOutputTokens: Int
    public var effort: Effort?
    /// Ask the provider to stream readable reasoning when it supports it.
    public var showThinking: Bool

    public init(
        model: ModelDescriptor,
        system: String,
        messages: [ChatMessage],
        tools: [ToolSpec] = [],
        maxOutputTokens: Int? = nil,
        effort: Effort? = nil,
        showThinking: Bool = true
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens ?? model.maxOutputTokens
        self.effort = effort
        self.showThinking = showThinking
    }
}

public enum StopReason: String, Codable, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal
    case other
}

public struct ModelResponse: Sendable {
    public var blocks: [ContentBlock]
    public var stopReason: StopReason
    public var usage: Usage
    public var servedModel: String?

    public init(blocks: [ContentBlock], stopReason: StopReason, usage: Usage, servedModel: String? = nil) {
        self.blocks = blocks
        self.stopReason = stopReason
        self.usage = usage
        self.servedModel = servedModel
    }
}

/// Incremental events a provider streams while producing one response.
public enum StreamEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolInputDelta(id: String, partialJSON: String)
    case usage(Usage)
    case completed(ModelResponse)
}

public protocol LLMProvider: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public extension LLMProvider {
    /// Runs a request to completion, ignoring deltas.
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        for try await event in stream(request) {
            if case .completed(let response) = event { return response }
        }
        throw ProviderError.malformedResponse("Stream ended without a final message")
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case missingAPIKey(String)
    case http(status: Int, body: String, retryAfter: TimeInterval?)
    case api(type: String, message: String)
    case malformedResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key for \(provider). Add one in Settings → Providers."
        case .http(let status, let body, _):
            let detail = ProviderError.extractMessage(from: body) ?? String(body.prefix(400))
            return "HTTP \(status): \(detail)"
        case .api(let type, let message):
            return "\(type): \(message)"
        case .malformedResponse(let message):
            return "Unexpected response: \(message)"
        case .transport(let message):
            return "Network error: \(message)"
        }
    }

    /// Whether retrying the same request may succeed.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _):
            return status == 408 || status == 409 || status == 429 || status >= 500
        case .api(let type, _):
            return ["overloaded_error", "rate_limit_error", "api_error", "timeout_error"].contains(type)
        case .transport:
            return true
        case .missingAPIKey, .malformedResponse:
            return false
        }
    }

    public var retryAfter: TimeInterval? {
        if case .http(_, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    static func extractMessage(from body: String) -> String? {
        guard let json = try? JSONValue.parse(body) else { return nil }
        if let message = json["error"]?["message"]?.stringValue { return message }
        if let message = json["message"]?.stringValue { return message }
        if let message = json["error"]?.stringValue { return message }
        return nil
    }
}
