import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Any `/chat/completions` endpoint: OpenAI, OpenRouter, Gemini's OpenAI
/// layer, Mistral, DeepSeek, MiniMax and local Ollama.
public struct OpenAICompatibleProvider: LLMProvider {
    public var kind: ProviderKind
    public var apiKey: String
    public var baseURL: URL
    public var streamer: HTTPLineStreaming

    public init(kind: ProviderKind, apiKey: String, baseURL: URL? = nil, streamer: HTTPLineStreaming = URLSessionLineStreamer()) {
        self.kind = kind
        self.apiKey = apiKey
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.streamer = streamer
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request)
                    var assembler = OpenAIStreamAssembler()
                    for try await event in streamer.events(for: urlRequest) {
                        if event.data == "[DONE]" { break }
                        for output in try assembler.consume(event.data) {
                            continuation.yield(output)
                        }
                    }
                    continuation.yield(.completed(assembler.finish()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(_ request: ModelRequest) throws -> URLRequest {
        if kind.requiresAPIKey && apiKey.isEmpty { throw ProviderError.missingAPIKey(kind.displayName) }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        if kind == .openRouter {
            urlRequest.setValue("https://github.com/themalagasywizard/Apeiron-2.0", forHTTPHeaderField: "HTTP-Referer")
            urlRequest.setValue("Apeiron", forHTTPHeaderField: "X-Title")
        }
        urlRequest.httpBody = Self.body(for: request, kind: kind).data()
        return urlRequest
    }

    static func body(for request: ModelRequest, kind: ProviderKind) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model.apiModel),
            "stream": true,
            "messages": .array(wireMessages(system: request.system, messages: request.messages)),
        ]
        if kind == .openRouter && request.model.apiModel.hasPrefix("anthropic/") {
            body["messages"] = .array(addCacheBreakpoints(wireMessages(system: request.system, messages: request.messages)))
        }
        if kind != .ollama && kind != .mistral {
            body["stream_options"] = ["include_usage": true]
        }
        if kind == .openAI {
            body["max_completion_tokens"] = .number(Double(request.maxOutputTokens))
        } else {
            body["max_tokens"] = .number(Double(request.maxOutputTokens))
        }
        if !request.tools.isEmpty && request.model.supportsTools {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ],
                ]
            })
        }
        if kind == .openRouter, request.showThinking {
            body["reasoning"] = ["enabled": true]
        }
        return .object(body)
    }

    /// Claude via OpenRouter only caches with explicit breakpoints: mark the
    /// system prompt and the newest user or tool turn, so each request reuses
    /// everything before it.
    static func addCacheBreakpoints(_ messages: [JSONValue]) -> [JSONValue] {
        var messages = messages
        func mark(_ index: Int) {
            guard case .object(var message) = messages[index] else { return }
            let breakpoint: JSONValue = ["type": "ephemeral"]
            switch message["content"] {
            case .string(let text)?:
                message["content"] = .array([["type": "text", "text": .string(text), "cache_control": breakpoint]])
            case .array(var parts)? where !parts.isEmpty:
                if case .object(var last) = parts[parts.count - 1] {
                    last["cache_control"] = breakpoint
                    parts[parts.count - 1] = .object(last)
                }
                message["content"] = .array(parts)
            default:
                return
            }
            messages[index] = .object(message)
        }
        if let system = messages.firstIndex(where: { $0["role"]?.stringValue == "system" }) {
            mark(system)
        }
        if let last = messages.lastIndex(where: { ["user", "tool"].contains($0["role"]?.stringValue ?? "") }) {
            mark(last)
        }
        return messages
    }

    static func wireMessages(system: String, messages: [ChatMessage]) -> [JSONValue] {
        var wire: [JSONValue] = []
        if !system.isEmpty {
            wire.append(["role": "system", "content": .string(system)])
        }
        for message in messages {
            switch message.role {
            case .user:
                // Tool results must directly follow the assistant tool calls.
                for result in message.toolResults {
                    let content = result.isError ? "Error: \(result.content)" : result.content
                    wire.append([
                        "role": "tool",
                        "tool_call_id": .string(result.toolCallID),
                        "content": .string(content.isEmpty ? "(no output)" : content),
                    ])
                }
                let text = message.text
                let images = message.images
                if images.isEmpty {
                    if !text.isEmpty { wire.append(["role": "user", "content": .string(text)]) }
                } else {
                    var parts: [JSONValue] = []
                    if !text.isEmpty { parts.append(["type": "text", "text": .string(text)]) }
                    for image in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": .string("data:\(image.mediaType);base64,\(image.base64)")],
                        ])
                    }
                    wire.append(["role": "user", "content": .array(parts)])
                }
            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant"]
                let text = message.text
                entry["content"] = text.isEmpty ? .null : .string(text)
                let calls = message.toolCalls
                if !calls.isEmpty {
                    entry["tool_calls"] = .array(calls.map { call in
                        [
                            "id": .string(call.id),
                            "type": "function",
                            "function": [
                                "name": .string(call.name),
                                "arguments": .string(call.input.objectValue != nil ? call.input.serialized() : "{}"),
                            ],
                        ]
                    })
                }
                if text.isEmpty && calls.isEmpty { continue }
                wire.append(.object(entry))
            }
        }
        return wire
    }
}

struct OpenAIStreamAssembler {
    private struct PartialCall {
        var id: String
        var name: String
        var arguments: String
    }

    private var text = ""
    private var reasoning = ""
    private var calls: [Int: PartialCall] = [:]
    private var callOrder: [Int] = []
    private var finishReason: String?
    private var usage = Usage()
    private var servedModel: String?

    mutating func consume(_ data: String) throws -> [StreamEvent] {
        guard let json = try? JSONValue.parse(data) else { return [] }
        if let error = json["error"], !error.isNull {
            throw ProviderError.api(
                type: error["type"]?.stringValue ?? error["code"]?.stringValue ?? "error",
                message: error["message"]?.stringValue ?? data
            )
        }
        var events: [StreamEvent] = []
        if servedModel == nil { servedModel = json["model"]?.stringValue }
        if let rawUsage = json["usage"], !rawUsage.isNull {
            let cached = rawUsage["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
            let prompt = rawUsage["prompt_tokens"]?.intValue ?? 0
            usage = Usage(
                inputTokens: max(0, prompt - cached),
                outputTokens: rawUsage["completion_tokens"]?.intValue ?? 0,
                cacheReadTokens: cached
            )
            events.append(.usage(usage))
        }
        guard let choice = json["choices"]?[0] else { return events }
        if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }
        guard let delta = choice["delta"] else { return events }

        if let piece = delta["content"]?.stringValue, !piece.isEmpty {
            text += piece
            events.append(.textDelta(piece))
        }
        let reasoningPiece = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue
        if let piece = reasoningPiece, !piece.isEmpty {
            reasoning += piece
            events.append(.thinkingDelta(piece))
        }
        for rawCall in delta["tool_calls"]?.arrayValue ?? [] {
            let index = rawCall["index"]?.intValue ?? 0
            var call = calls[index] ?? PartialCall(id: "", name: "", arguments: "")
            let isNew = calls[index] == nil
            if let id = rawCall["id"]?.stringValue, !id.isEmpty { call.id = id }
            if let name = rawCall["function"]?["name"]?.stringValue, !name.isEmpty { call.name += name }
            let argumentPiece = rawCall["function"]?["arguments"]?.stringValue ?? ""
            call.arguments += argumentPiece
            if call.id.isEmpty { call.id = "call_\(index)_\(UUID().uuidString.prefix(8))" }
            calls[index] = call
            if isNew {
                callOrder.append(index)
                events.append(.toolCallStarted(id: call.id, name: call.name))
            }
            if !argumentPiece.isEmpty {
                events.append(.toolInputDelta(id: call.id, partialJSON: argumentPiece))
            }
        }
        return events
    }

    func finish() -> ModelResponse {
        var blocks: [ContentBlock] = []
        if !reasoning.isEmpty { blocks.append(.thinking(text: reasoning, signature: nil)) }
        if !text.isEmpty { blocks.append(.text(text)) }
        for index in callOrder {
            guard let call = calls[index] else { continue }
            blocks.append(.toolCall(AnthropicStreamAssembler.parseToolCall(id: call.id, name: call.name, json: call.arguments)))
        }
        let stop: StopReason
        switch finishReason {
        case "tool_calls", "function_call": stop = .toolUse
        case "length": stop = .maxTokens
        case "content_filter": stop = .refusal
        default: stop = callOrder.isEmpty ? .endTurn : .toolUse
        }
        return ModelResponse(blocks: blocks, stopReason: stop, usage: usage, servedModel: servedModel)
    }
}
