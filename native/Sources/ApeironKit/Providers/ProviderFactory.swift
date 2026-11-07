import Foundation

public enum ProviderFactory {
    /// Builds the provider for a model. `apiKey` may be empty for local or demo providers.
    public static func make(for model: ModelDescriptor, apiKey: String, baseURL: URL? = nil) -> LLMProvider {
        switch model.provider.apiStyle {
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey, baseURL: baseURL ?? ProviderKind.anthropic.defaultBaseURL)
        case .openAICompatible:
            return OpenAICompatibleProvider(kind: model.provider, apiKey: apiKey, baseURL: baseURL)
        case .demo:
            return DemoProvider()
        }
    }
}
