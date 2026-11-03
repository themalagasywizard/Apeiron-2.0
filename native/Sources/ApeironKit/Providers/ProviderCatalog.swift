import Foundation

public enum APIStyle: String, Codable, Sendable {
    case anthropic
    case openAICompatible
    case demo
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case openRouter
    case google
    case mistral
    case deepSeek
    case miniMax
    case ollama
    case demo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .google: return "Google Gemini"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .miniMax: return "MiniMax"
        case .ollama: return "Ollama (local)"
        case .demo: return "Demo"
        }
    }

    public var apiStyle: APIStyle {
        switch self {
        case .anthropic: return .anthropic
        case .demo: return .demo
        default: return .openAICompatible
        }
    }

    public var defaultBaseURL: URL {
        let string: String
        switch self {
        case .anthropic: string = "https://api.anthropic.com"
        case .openAI: string = "https://api.openai.com/v1"
        case .openRouter: string = "https://openrouter.ai/api/v1"
        case .google: string = "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: string = "https://api.mistral.ai/v1"
        case .deepSeek: string = "https://api.deepseek.com/v1"
        case .miniMax: string = "https://api.minimax.io/v1"
        case .ollama: string = "http://localhost:11434/v1"
        case .demo: string = "about:blank"
        }
        return URL(string: string)!
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .ollama, .demo: return false
        default: return true
        }
    }

    /// Environment variable the CLI reads the key from.
    public var environmentKey: String {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openAI: return "OPENAI_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .google: return "GEMINI_API_KEY"
        case .mistral: return "MISTRAL_API_KEY"
        case .deepSeek: return "DEEPSEEK_API_KEY"
        case .miniMax: return "MINIMAX_API_KEY"
        case .ollama: return "OLLAMA_API_KEY"
        case .demo: return "APEIRON_DEMO"
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openAI: return "sk-…"
        case .openRouter: return "sk-or-…"
        case .google: return "AIza…"
        default: return "API key"
        }
    }

    /// Where to create a key.
    public var consoleURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .miniMax: return URL(string: "https://www.minimax.io/platform")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .demo: return nil
        }
    }
}

public struct ModelDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// Stable id: "<provider>/<api model>".
    public var id: String { "\(provider.rawValue)/\(apiModel)" }
    public var provider: ProviderKind
    public var apiModel: String
    public var displayName: String
    public var tagline: String
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var supportsTools: Bool
    public var supportsVision: Bool
    /// Anthropic adaptive thinking with `output_config.effort`.
    public var supportsAdaptiveThinking: Bool
    /// Anthropic server-side refusal fallbacks (`fallbacks: "default"`).
    public var supportsServerFallbacks: Bool
    /// USD per million tokens (input, output, cache read).
    public var inputPrice: Double?
    public var outputPrice: Double?
    public var cacheReadPrice: Double?
    public var isCustom: Bool

    public init(
        provider: ProviderKind,
        apiModel: String,
        displayName: String,
        tagline: String = "",
        contextWindow: Int = 128_000,
        maxOutputTokens: Int = 16_000,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsAdaptiveThinking: Bool = false,
        supportsServerFallbacks: Bool = false,
        inputPrice: Double? = nil,
        outputPrice: Double? = nil,
        cacheReadPrice: Double? = nil,
        isCustom: Bool = false
    ) {
        self.provider = provider
        self.apiModel = apiModel
        self.displayName = displayName
        self.tagline = tagline
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsAdaptiveThinking = supportsAdaptiveThinking
        self.supportsServerFallbacks = supportsServerFallbacks
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.cacheReadPrice = cacheReadPrice
        self.isCustom = isCustom
    }

    /// Estimated USD cost of a usage record, if pricing is known.
    public func cost(of usage: Usage) -> Double? {
        guard let inputPrice, let outputPrice else { return nil }
        let cacheRead = cacheReadPrice ?? inputPrice * 0.1
        let cacheWrite = inputPrice * 1.25
        let total = Double(usage.inputTokens) * inputPrice
            + Double(usage.outputTokens) * outputPrice
            + Double(usage.cacheReadTokens) * cacheRead
            + Double(usage.cacheWriteTokens) * cacheWrite
        return total / 1_000_000
    }
}

public enum ModelCatalog {
    public static let defaultModelID = "anthropic/claude-opus-5-5"

    public static let builtIn: [ModelDescriptor] = [
        // Anthropic – direct Messages API with adaptive thinking, caching, fallbacks.
        ModelDescriptor(
            provider: .anthropic, apiModel: "claude-opus-5-5", displayName: "Claude Opus 5.5",
            tagline: "Default · deep reasoning for real engineering work",
            contextWindow: 1_000_000, maxOutputTokens: 64_000, supportsVision: true,
            supportsAdaptiveThinking: true, supportsServerFallbacks: true,
            inputPrice: 4, outputPrice: 20, cacheReadPrice: 0.2
        ),
        ModelDescriptor(
            provider: .anthropic, apiModel: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5",
            tagline: "Fast and capable for everyday coding",
            contextWindow: 1_000_000, maxOutputTokens: 64_000, supportsVision: true,
            supportsAdaptiveThinking: true, supportsServerFallbacks: true,
            inputPrice: 2, outputPrice: 10, cacheReadPrice: 0.2
        ),
        ModelDescriptor(
            provider: .anthropic, apiModel: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
            tagline: "Quickest · great for subagents and summaries",
            contextWindow: 1_000_000, maxOutputTokens: 32_000, supportsVision: true,
            supportsAdaptiveThinking: true,
            inputPrice: 0.1, outputPrice: 0.5, cacheReadPrice: 0.01
        ),
        ModelDescriptor(
            provider: .anthropic, apiModel: "claude-fable-5-1", displayName: "Claude Fable 5.1",
            tagline: "Most capable · long-horizon agentic work",
            contextWindow: 1_000_000, maxOutputTokens: 64_000, supportsVision: true,
            supportsAdaptiveThinking: true, supportsServerFallbacks: true,
            inputPrice: 10, outputPrice: 50, cacheReadPrice: 0.25
        ),
        // OpenRouter – carried over from Apeiron 2.0's defaults.
        ModelDescriptor(
            provider: .openRouter, apiModel: "openai/gpt-5.2-chat", displayName: "GPT-5.2 Chat",
            tagline: "via OpenRouter", contextWindow: 400_000, maxOutputTokens: 32_000, supportsVision: true
        ),
        ModelDescriptor(
            provider: .openRouter, apiModel: "google/gemini-3-pro-preview", displayName: "Gemini 3 Pro",
            tagline: "via OpenRouter", contextWindow: 1_000_000, maxOutputTokens: 32_000, supportsVision: true
        ),
        ModelDescriptor(
            provider: .openRouter, apiModel: "deepseek/deepseek-r1-0528:free", displayName: "DeepSeek R1 (free)",
            tagline: "via OpenRouter", contextWindow: 128_000, maxOutputTokens: 16_000, supportsTools: false
        ),
        // Direct vendor APIs (OpenAI-compatible endpoints).
        ModelDescriptor(
            provider: .google, apiModel: "gemini-3-flash-preview", displayName: "Gemini 3 Flash",
            tagline: "Google AI Studio", contextWindow: 1_000_000, maxOutputTokens: 32_000, supportsVision: true
        ),
        ModelDescriptor(
            provider: .deepSeek, apiModel: "deepseek-chat", displayName: "DeepSeek Chat",
            tagline: "DeepSeek API", contextWindow: 128_000, maxOutputTokens: 8_000
        ),
        ModelDescriptor(
            provider: .mistral, apiModel: "mistral-large-latest", displayName: "Mistral Large",
            tagline: "Mistral API", contextWindow: 128_000, maxOutputTokens: 16_000
        ),
        ModelDescriptor(
            provider: .miniMax, apiModel: "MiniMax-M2.5", displayName: "MiniMax M2.5",
            tagline: "MiniMax API", contextWindow: 200_000, maxOutputTokens: 16_000
        ),
        ModelDescriptor(
            provider: .ollama, apiModel: "qwen3-coder", displayName: "Qwen3 Coder (Ollama)",
            tagline: "Runs locally", contextWindow: 64_000, maxOutputTokens: 8_000
        ),
        // Offline demo – scripted responses that drive real tools.
        ModelDescriptor(
            provider: .demo, apiModel: "apeiron-demo", displayName: "Demo (offline)",
            tagline: "Explore the app without an API key", contextWindow: 200_000, maxOutputTokens: 8_000
        ),
    ]

    public static func model(id: String, custom: [ModelDescriptor] = []) -> ModelDescriptor? {
        (custom + builtIn).first { $0.id == id }
    }

    /// Picks a cheaper sibling for background work (summaries, subagents).
    public static func lightweightSibling(of model: ModelDescriptor) -> ModelDescriptor {
        if model.provider == .anthropic, let haiku = builtIn.first(where: { $0.apiModel == "claude-haiku-5-5" }) {
            return haiku
        }
        return model
    }
}
