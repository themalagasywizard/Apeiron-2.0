import XCTest
@testable import ApeironKit

final class OpenRouterTests: XCTestCase {
    let fixture = #"""
    {"data":[
      {"id":"deepseek/deepseek-v3.2","name":"DeepSeek: DeepSeek V3.2","created":1760000000,
       "description":"Fast open model.\nMore text.","context_length":163840,
       "architecture":{"input_modalities":["text"]},
       "pricing":{"prompt":"0.00000027","completion":"0.0000004","input_cache_read":"0.00000007"},
       "top_provider":{"context_length":163840,"max_completion_tokens":65536},
       "supported_parameters":["tools","reasoning","max_tokens"]},
      {"id":"z-ai/glm-4.6","name":"Z.AI: GLM 4.6","created":1770000000,
       "context_length":200000,"architecture":{"input_modalities":["text","image"]},
       "pricing":{"prompt":"0","completion":"0"},
       "supported_parameters":["max_tokens"]},
      {"name":"missing id"}
    ]}
    """#

    func testParsesCatalog() throws {
        let entries = try OpenRouterCatalog.parse(Data(fixture.utf8))
        XCTAssertEqual(entries.map(\.id), ["z-ai/glm-4.6", "deepseek/deepseek-v3.2"], "newest first, invalid rows dropped")

        let deepseek = try XCTUnwrap(entries.first { $0.vendor == "deepseek" })
        XCTAssertEqual(deepseek.model.displayName, "DeepSeek V3.2")
        XCTAssertEqual(deepseek.model.provider, .openRouter)
        XCTAssertEqual(deepseek.model.contextWindow, 163_840)
        XCTAssertEqual(deepseek.model.maxOutputTokens, 64_000)
        XCTAssertTrue(deepseek.model.supportsTools)
        XCTAssertFalse(deepseek.model.supportsVision)
        XCTAssertEqual(deepseek.model.inputPrice ?? 0, 0.27, accuracy: 0.0001)
        XCTAssertEqual(deepseek.model.outputPrice ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(deepseek.summary, "Fast open model.")
        XCTAssertEqual(deepseek.model.id, "openRouter/deepseek/deepseek-v3.2")

        let glm = try XCTUnwrap(entries.first { $0.vendor == "z-ai" })
        XCTAssertFalse(glm.model.supportsTools)
        XCTAssertTrue(glm.model.supportsVision)
        XCTAssertTrue(glm.isFree)

        XCTAssertEqual(OpenRouterCatalog.search(entries, query: "glm").count, 1)
        XCTAssertEqual(OpenRouterCatalog.search(entries, query: "", toolsOnly: true).map(\.vendor), ["deepseek"])
    }

    func testClaudeViaOpenRouterGetsCacheBreakpoints() {
        let model = ModelDescriptor(provider: .openRouter, apiModel: "anthropic/claude-sonnet-5.5", displayName: "Claude")
        let request = ModelRequest(
            model: model,
            system: "You are Apeiron.",
            messages: [ChatMessage(role: .user, blocks: [.text("Hi")])],
            tools: [],
            maxOutputTokens: 1000
        )
        let body = OpenAICompatibleProvider.body(for: request, kind: .openRouter)
        let messages = body["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.first?["content"]?[0]?["cache_control"]?["type"]?.stringValue, "ephemeral")
        XCTAssertEqual(messages.last?["content"]?[0]?["cache_control"]?["type"]?.stringValue, "ephemeral")

        let other = ModelRequest(
            model: ModelDescriptor(provider: .openRouter, apiModel: "deepseek/deepseek-v3.2", displayName: "DS"),
            system: "You are Apeiron.",
            messages: [ChatMessage(role: .user, blocks: [.text("Hi")])],
            tools: [],
            maxOutputTokens: 1000
        )
        let plain = OpenAICompatibleProvider.body(for: other, kind: .openRouter)
        XCTAssertEqual(plain["messages"]?[0]?["content"]?.stringValue, "You are Apeiron.")
    }
}
