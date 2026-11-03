import XCTest
@testable import ApeironKit

final class ProviderTests: XCTestCase {
    func testSSEParser() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed("event: message_start"))
        XCTAssertNil(parser.feed("data: {\"a\":1}"))
        XCTAssertNil(parser.feed(": keep-alive"))
        let event = parser.feed("")
        XCTAssertEqual(event, SSEEvent(event: "message_start", data: "{\"a\":1}"))
        XCTAssertNil(parser.feed(""))
        _ = parser.feed("data: line1")
        _ = parser.feed("data: line2")
        XCTAssertEqual(parser.flush()?.data, "line1\nline2")
    }

    func testAnthropicStreamAssembly() throws {
        let lines: [(String, String)] = [
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think."}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"there"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\": \"RE"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ADME.md\"}"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]
        var assembler = AnthropicStreamAssembler()
        var text = ""
        var thinking = ""
        for (event, data) in lines {
            for output in try assembler.consume(SSEEvent(event: event, data: data)) {
                if case .textDelta(let piece) = output { text += piece }
                if case .thinkingDelta(let piece) = output { thinking += piece }
            }
        }
        let response = try assembler.finish()
        XCTAssertEqual(text, "Hello there")
        XCTAssertEqual(thinking, "Let me think.")
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.usage, Usage(inputTokens: 10, outputTokens: 42, cacheReadTokens: 90))
        XCTAssertEqual(response.blocks.count, 4)
        XCTAssertEqual(response.blocks[0], .thinking(text: "Let me think.", signature: "sig123"))
        XCTAssertEqual(response.blocks[2], .toolCall(ToolCall(id: "toolu_1", name: "read_file", input: ["path": "README.md"])))
        if case .opaque(let provider, let json) = response.blocks[3] {
            XCTAssertEqual(provider, "anthropic")
            XCTAssertEqual(json["type"], "fallback")
        } else {
            XCTFail("unknown blocks are preserved")
        }
    }

    func testAnthropicStreamErrorThrows() {
        var assembler = AnthropicStreamAssembler()
        XCTAssertThrowsError(try assembler.consume(SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))) { error in
            XCTAssertTrue((error as? ProviderError)?.isRetryable ?? false)
        }
    }

    func testTruncatedToolInputIsFlagged() {
        let call = AnthropicStreamAssembler.parseToolCall(id: "x", name: "write_file", json: #"{"path": "a.txt", "content": "unterminated"#)
        XCTAssertNotNil(call.inputParseError)
        XCTAssertEqual(AnthropicStreamAssembler.parseToolCall(id: "y", name: "glob", json: "").input, [:])
    }

    func testAnthropicRequestBody() throws {
        let model = try XCTUnwrap(ModelCatalog.model(id: "anthropic/claude-opus-5-5"))
        let history: [ChatMessage] = [
            .user("hi"),
            ChatMessage(role: .assistant, blocks: [
                .thinking(text: "hmm", signature: "sig"),
                .thinking(text: "unsigned from another provider", signature: nil),
                .text("calling"),
                .toolCall(ToolCall(id: "t1", name: "glob", input: ["pattern": "*"])),
                .opaque(provider: "anthropic", json: ["type": "fallback"]),
                .opaque(provider: "openai", json: ["type": "nope"]),
            ]),
            ChatMessage(role: .user, blocks: [.toolResult(ToolResult(toolCallID: "t1", content: "", isError: true))]),
        ]
        let request = ModelRequest(model: model, system: "sys", messages: history, tools: [GlobTool().spec], effort: .high)
        let body = AnthropicProvider.body(for: request)
        XCTAssertEqual(body["model"], "claude-opus-5-5")
        XCTAssertEqual(body["stream"], true)
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["thinking"]?["type"], "adaptive")
        XCTAssertEqual(body["thinking"]?["display"], "summarized")
        XCTAssertEqual(body["output_config"]?["effort"], "high")
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertEqual(body["cache_control"]?["type"], "ephemeral")
        XCTAssertEqual(body["system"]?[0]?["cache_control"]?["type"], "ephemeral")
        XCTAssertEqual(body["tools"]?[0]?["eager_input_streaming"], true)
        let assistant = try XCTUnwrap(body["messages"]?[1]?["content"]?.arrayValue)
        XCTAssertEqual(assistant.count, 4, "unsigned thinking and foreign opaque blocks are dropped")
        XCTAssertEqual(assistant[0]["signature"], "sig")
        let toolResult = try XCTUnwrap(body["messages"]?[2]?["content"]?[0])
        XCTAssertEqual(toolResult["type"], "tool_result")
        XCTAssertEqual(toolResult["is_error"], true)
        XCTAssertEqual(toolResult["content"], "(no output)")

        let urlRequest = try AnthropicProvider(apiKey: "k").makeURLRequest(request)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testMissingKeyIsReported() {
        let request = ModelRequest(model: testModel, system: "", messages: [.user("hi")])
        XCTAssertThrowsError(try AnthropicProvider(apiKey: "").makeURLRequest(request))
    }

    func testOpenAIMessageTranslation() {
        let history: [ChatMessage] = [
            .user("hi"),
            ChatMessage(role: .assistant, blocks: [.text(""), .toolCall(ToolCall(id: "c1", name: "glob", input: ["pattern": "*"]))]),
            ChatMessage(role: .user, blocks: [.toolResult(ToolResult(toolCallID: "c1", content: "a.txt")), .text("and?")]),
        ]
        let wire = OpenAICompatibleProvider.wireMessages(system: "sys", messages: history)
        XCTAssertEqual(wire.count, 5)
        XCTAssertEqual(wire[0]["role"], "system")
        XCTAssertEqual(wire[2]["tool_calls"]?[0]?["function"]?["arguments"], #"{"pattern":"*"}"#)
        XCTAssertEqual(wire[2]["content"], .null)
        XCTAssertEqual(wire[3]["role"], "tool")
        XCTAssertEqual(wire[3]["tool_call_id"], "c1")
        XCTAssertEqual(wire[4]["content"], "and?")
    }

    func testOpenAIStreamAssembly() throws {
        var assembler = OpenAIStreamAssembler()
        let chunks = [
            #"{"model":"gpt","choices":[{"delta":{"reasoning_content":"thinking"}}]}"#,
            #"{"choices":[{"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"x\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":60}}}"#,
        ]
        for chunk in chunks { _ = try assembler.consume(chunk) }
        let response = assembler.finish()
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.blocks, [
            .thinking(text: "thinking", signature: nil),
            .text("Hi"),
            .toolCall(ToolCall(id: "call_9", name: "read_file", input: ["path": "x"])),
        ])
        XCTAssertEqual(response.usage, Usage(inputTokens: 40, outputTokens: 7, cacheReadTokens: 60))
    }

    func testProviderErrorsAndRetryability() {
        XCTAssertTrue(ProviderError.http(status: 529, body: "", retryAfter: nil).isRetryable)
        XCTAssertTrue(ProviderError.http(status: 429, body: "", retryAfter: 3).isRetryable)
        XCTAssertFalse(ProviderError.http(status: 400, body: #"{"error":{"message":"bad"}}"#, retryAfter: nil).isRetryable)
        XCTAssertEqual(ProviderError.http(status: 400, body: #"{"error":{"message":"bad"}}"#, retryAfter: nil).errorDescription, "HTTP 400: bad")
    }

    func testRetriesTransientErrors() async throws {
        final class FlakyProvider: LLMProvider, @unchecked Sendable {
            var calls = 0
            func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                calls += 1
                let fail = calls == 1
                return AsyncThrowingStream { continuation in
                    if fail {
                        continuation.finish(throwing: ProviderError.http(status: 529, body: "overloaded", retryAfter: 0.01))
                    } else {
                        continuation.yield(.completed(textResponse("ok")))
                        continuation.finish()
                    }
                }
            }
        }
        let provider = FlakyProvider()
        let agent = makeAgent(provider: provider, workspace: try makeTempDirectory()) { $0.maxRetries = 2 }
        let events = await collect(agent.send("hi"))
        XCTAssertEqual(events.finishReason, .completed)
        XCTAssertTrue(events.contains { if case .retrying = $0 { return true } else { return false } })
        XCTAssertEqual(provider.calls, 2)
    }
}
