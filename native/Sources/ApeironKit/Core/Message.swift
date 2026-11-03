import Foundation

public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var input: JSONValue
    /// Set when the model produced arguments that were not valid JSON
    /// (for example, output was cut off by `max_tokens`).
    public var inputParseError: String?

    public init(id: String, name: String, input: JSONValue, inputParseError: String? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.inputParseError = inputParseError
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var toolCallID: String
    public var content: String
    public var isError: Bool

    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

public struct ImageAttachment: Codable, Hashable, Sendable {
    public var mediaType: String
    public var base64: String
    public var filename: String?

    public init(mediaType: String, base64: String, filename: String? = nil) {
        self.mediaType = mediaType
        self.base64 = base64
        self.filename = filename
    }
}

/// One block of message content. Provider adapters translate these to and
/// from each vendor's wire format.
public enum ContentBlock: Hashable, Sendable {
    case text(String)
    case thinking(text: String, signature: String?)
    case redactedThinking(data: String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case image(ImageAttachment)
    /// A provider-specific block (for example an Anthropic `fallback` block)
    /// that must be replayed byte-for-byte to the same provider.
    case opaque(provider: String, json: JSONValue)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, signature, data, toolCall, toolResult, image, provider, json
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(
                text: try container.decode(String.self, forKey: .text),
                signature: try container.decodeIfPresent(String.self, forKey: .signature)
            )
        case "redacted_thinking":
            self = .redactedThinking(data: try container.decode(String.self, forKey: .data))
        case "tool_call":
            self = .toolCall(try container.decode(ToolCall.self, forKey: .toolCall))
        case "tool_result":
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        case "image":
            self = .image(try container.decode(ImageAttachment.self, forKey: .image))
        case "opaque":
            self = .opaque(
                provider: try container.decode(String.self, forKey: .provider),
                json: try container.decode(JSONValue.self, forKey: .json)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown block \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let text, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(signature, forKey: .signature)
        case .redactedThinking(let data):
            try container.encode("redacted_thinking", forKey: .type)
            try container.encode(data, forKey: .data)
        case .toolCall(let call):
            try container.encode("tool_call", forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try container.encode("tool_result", forKey: .type)
            try container.encode(result, forKey: .toolResult)
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(image, forKey: .image)
        case .opaque(let provider, let json):
            try container.encode("opaque", forKey: .type)
            try container.encode(provider, forKey: .provider)
            try container.encode(json, forKey: .json)
        }
    }
}

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var role: Role
    public var blocks: [ContentBlock]
    public var createdAt: Date
    /// Model that produced an assistant message.
    public var modelID: String?
    public var usage: Usage?
    /// Marks harness-generated messages (compaction summaries, interruption
    /// notices) so the UI can render them differently.
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        case normal
        case compactionSummary
        case synthetic
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        blocks: [ContentBlock],
        createdAt: Date = Date(),
        modelID: String? = nil,
        usage: Usage? = nil,
        kind: Kind = .normal
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.createdAt = createdAt
        self.modelID = modelID
        self.usage = usage
        self.kind = kind
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(text)])
    }

    public var text: String {
        blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    public var toolCalls: [ToolCall] {
        blocks.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }
            return nil
        }
    }

    public var toolResults: [ToolResult] {
        blocks.compactMap { block -> ToolResult? in
            if case .toolResult(let result) = block { return result }
            return nil
        }
    }

    public var images: [ImageAttachment] {
        blocks.compactMap { block -> ImageAttachment? in
            if case .image(let image) = block { return image }
            return nil
        }
    }

    /// True for a user message that only carries tool results.
    public var isToolResultCarrier: Bool {
        role == .user && !toolResults.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct Usage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public static let zero = Usage()

    /// Everything the model saw as input on this request.
    public var promptTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }

    /// Tokens occupying the context window after this response.
    public var contextTokens: Int { promptTokens + outputTokens }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens
        )
    }

    public static func += (lhs: inout Usage, rhs: Usage) { lhs = lhs + rhs }

    /// Merges a streamed partial usage report into an accumulated one,
    /// keeping the larger value per field (providers report cumulative counts).
    public func merging(_ other: Usage) -> Usage {
        Usage(
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            cacheReadTokens: max(cacheReadTokens, other.cacheReadTokens),
            cacheWriteTokens: max(cacheWriteTokens, other.cacheWriteTokens)
        )
    }
}

public struct TodoItem: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: String
    public var content: String
    public var activeForm: String?
    public var status: Status

    public init(id: String = UUID().uuidString, content: String, activeForm: String? = nil, status: Status) {
        self.id = id
        self.content = content
        self.activeForm = activeForm
        self.status = status
    }
}
