import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude via the Messages API (raw HTTP + SSE).
///
/// Harness choices:
/// - `anthropic-version: 2026-10-21`; no sampling parameters are sent.
/// - Adaptive thinking with summarised display so reasoning streams to the UI,
///   with depth controlled by `output_config.effort`.
/// - Thinking blocks (with signatures) and unknown blocks are replayed
///   unchanged; the harness keeps history append-only.
/// - Prompt caching: a breakpoint on the system prompt plus top-level
///   automatic caching of the conversation tail.
/// - `eager_input_streaming` on tools so large file writes stream; inputs are
///   parsed defensively and a bad parse becomes an error tool result.
/// - Server-side refusal fallbacks on models that support them.
public struct AnthropicProvider: LLMProvider {
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var apiKey: String
    public var baseURL: URL
    public var streamer: HTTPLineStreaming

    public init(apiKey: String, baseURL: URL = ProviderKind.anthropic.defaultBaseURL, streamer: HTTPLineStreaming = URLSessionLineStreamer()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.streamer = streamer
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request)
                    var assembler = AnthropicStreamAssembler()
                    for try await event in streamer.events(for: urlRequest) {
                        for output in try assembler.consume(event) {
                            continuation.yield(output)
                        }
                    }
                    continuation.yield(.completed(try assembler.finish()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(_ request: ModelRequest) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey("Anthropic") }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.model.supportsServerFallbacks {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = Self.body(for: request).data()
        return urlRequest
    }

    static func body(for request: ModelRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model.apiModel),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "stream": true,
            "messages": .array(wireMessages(request.messages)),
            // Automatic caching of the last cacheable block (conversation tail).
            "cache_control": ["type": "ephemeral"],
        ]
        if !request.system.isEmpty {
            body["system"] = [[
                "type": "text",
                "text": .string(request.system),
                "cache_control": ["type": "ephemeral"],
            ]]
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                    "eager_input_streaming": true,
                ]
            })
        }
        if request.model.supportsAdaptiveThinking {
            body["thinking"] = request.showThinking
                ? ["type": "adaptive", "display": "summarized"]
                : ["type": "adaptive"]
            if let effort = request.effort {
                body["output_config"] = ["effort": .string(effort.rawValue)]
            }
        }
        if request.model.supportsServerFallbacks {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    static func wireMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var wire: [JSONValue] = []
        for message in messages {
            let content = message.blocks.compactMap { wireBlock($0, role: message.role) }
            guard !content.isEmpty else { continue }
            wire.append([
                "role": .string(message.role.rawValue),
                "content": .array(content),
            ])
        }
        return wire
    }

    static func wireBlock(_ block: ContentBlock, role: Role) -> JSONValue? {
        switch block {
        case .text(let text):
            guard !text.isEmpty else { return nil }
            return ["type": "text", "text": .string(text)]
        case .thinking(let text, let signature):
            // Reasoning from other providers carries no signature; Claude can't
            // verify it, so it stays out of the request.
            guard role == .assistant, let signature, !signature.isEmpty else { return nil }
            return ["type": "thinking", "thinking": .string(text), "signature": .string(signature)]
        case .redactedThinking(let data):
            return ["type": "redacted_thinking", "data": .string(data)]
        case .toolCall(let call):
            let input: JSONValue = call.input.objectValue != nil ? call.input : [:]
            return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": input]
        case .toolResult(let result):
            var json: [String: JSONValue] = [
                "type": "tool_result",
                "tool_use_id": .string(result.toolCallID),
                "content": .string(result.content.isEmpty ? "(no output)" : result.content),
            ]
            if result.isError { json["is_error"] = true }
            return .object(json)
        case .image(let image):
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)],
            ]
        case .opaque(let provider, let json):
            guard provider == "anthropic" else { return nil }
            return json
        }
    }
}

/// Folds Anthropic SSE events into deltas and a final message.
struct AnthropicStreamAssembler {
    private enum Builder {
        case text(String)
        case thinking(String, signature: String?)
        case redacted(String)
        case toolUse(id: String, name: String, json: String)
        case other(JSONValue)
    }

    private var builders: [Int: Builder] = [:]
    private var order: [Int] = []
    private var usage = Usage()
    private var stopReason: StopReason = .endTurn
    private var servedModel: String?

    mutating func consume(_ event: SSEEvent) throws -> [StreamEvent] {
        guard let json = try? JSONValue.parse(event.data) else { return [] }
        let type = json["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "message_start":
            servedModel = json["message"]?["model"]?.stringValue
            if let raw = json["message"]?["usage"] {
                usage = usage.merging(Self.usage(from: raw))
                return [.usage(usage)]
            }
        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else { return [] }
            order.append(index)
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                builders[index] = .text(text)
                return text.isEmpty ? [] : [.textDelta(text)]
            case "thinking":
                builders[index] = .thinking(block["thinking"]?.stringValue ?? "", signature: block["signature"]?.stringValue)
            case "redacted_thinking":
                builders[index] = .redacted(block["data"]?.stringValue ?? "")
            case "tool_use":
                let id = block["id"]?.stringValue ?? UUID().uuidString
                let name = block["name"]?.stringValue ?? "unknown"
                builders[index] = .toolUse(id: id, name: name, json: "")
                return [.toolCallStarted(id: id, name: name)]
            default:
                builders[index] = .other(block)
            }
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"], let builder = builders[index] else { return [] }
            switch (delta["type"]?.stringValue, builder) {
            case ("text_delta", .text(let text)):
                let piece = delta["text"]?.stringValue ?? ""
                builders[index] = .text(text + piece)
                return [.textDelta(piece)]
            case ("thinking_delta", .thinking(let text, let signature)):
                let piece = delta["thinking"]?.stringValue ?? ""
                builders[index] = .thinking(text + piece, signature: signature)
                return piece.isEmpty ? [] : [.thinkingDelta(piece)]
            case ("signature_delta", .thinking(let text, let signature)):
                let piece = delta["signature"]?.stringValue ?? ""
                builders[index] = .thinking(text, signature: (signature ?? "") + piece)
            case ("input_json_delta", .toolUse(let id, let name, let partial)):
                let piece = delta["partial_json"]?.stringValue ?? ""
                builders[index] = .toolUse(id: id, name: name, json: partial + piece)
                return [.toolInputDelta(id: id, partialJSON: piece)]
            default:
                break
            }
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                stopReason = StopReason(rawValue: reason) ?? .other
            }
            if let raw = json["usage"] {
                usage = usage.merging(Self.usage(from: raw))
                return [.usage(usage)]
            }
        case "error":
            let type = json["error"]?["type"]?.stringValue ?? "error"
            let message = json["error"]?["message"]?.stringValue ?? event.data
            throw ProviderError.api(type: type, message: message)
        default:
            break
        }
        return []
    }

    func finish() throws -> ModelResponse {
        var blocks: [ContentBlock] = []
        for index in order {
            guard let builder = builders[index] else { continue }
            switch builder {
            case .text(let text):
                if !text.isEmpty { blocks.append(.text(text)) }
            case .thinking(let text, let signature):
                blocks.append(.thinking(text: text, signature: signature))
            case .redacted(let data):
                blocks.append(.redactedThinking(data: data))
            case .toolUse(let id, let name, let json):
                blocks.append(.toolCall(Self.parseToolCall(id: id, name: name, json: json)))
            case .other(let raw):
                blocks.append(.opaque(provider: "anthropic", json: raw))
            }
        }
        return ModelResponse(blocks: blocks, stopReason: stopReason, usage: usage, servedModel: servedModel)
    }

    static func parseToolCall(id: String, name: String, json: String) -> ToolCall {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ToolCall(id: id, name: name, input: [:]) }
        do {
            let value = try JSONValue.parse(trimmed)
            guard value.objectValue != nil else {
                return ToolCall(id: id, name: name, input: [:], inputParseError: "Tool input must be a JSON object")
            }
            return ToolCall(id: id, name: name, input: value)
        } catch {
            return ToolCall(id: id, name: name, input: [:], inputParseError: "Tool input was not valid JSON (it may have been cut off)")
        }
    }

    static func usage(from json: JSONValue) -> Usage {
        Usage(
            inputTokens: json["input_tokens"]?.intValue ?? 0,
            outputTokens: json["output_tokens"]?.intValue ?? 0,
            cacheReadTokens: json["cache_read_input_tokens"]?.intValue ?? 0,
            cacheWriteTokens: json["cache_creation_input_tokens"]?.intValue ?? 0
        )
    }
}
