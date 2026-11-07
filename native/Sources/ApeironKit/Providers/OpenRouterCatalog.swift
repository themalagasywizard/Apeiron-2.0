import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenRouter's live model list (`GET /api/v1/models`), turned into
/// `ModelDescriptor`s so any of its hundreds of models can be picked.
public enum OpenRouterCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { model.apiModel }
        public var model: ModelDescriptor
        /// The vendor part of the slug, e.g. "deepseek" in "deepseek/deepseek-chat".
        public var vendor: String
        public var summary: String
        public var created: Date?

        public var isFree: Bool {
            (model.inputPrice ?? 1) == 0 && (model.outputPrice ?? 1) == 0
        }
    }

    public enum CatalogError: Error, LocalizedError {
        case badResponse(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "OpenRouter returned HTTP \(status)."
            case .malformed: return "OpenRouter's model list wasn't in the expected format."
            }
        }
    }

    /// Downloads the catalog. The list is public; the key is sent when present
    /// so account-specific routing settings apply.
    public static func fetch(apiKey: String = "", baseURL: URL? = nil) async throws -> [Entry] {
        let root = baseURL ?? ProviderKind.openRouter.defaultBaseURL
        var request = URLRequest(url: root.appendingPathComponent("models"))
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        let (data, status) = try await load(request)
        guard (200..<300).contains(status) else { throw CatalogError.badResponse(status) }
        return try parse(data)
    }

    private static func load(_ request: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(returning: (data ?? Data(), status))
                }
            }.resume()
        }
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        guard let items = try JSONValue.parse(data)["data"]?.arrayValue else {
            throw CatalogError.malformed
        }
        return items.compactMap(entry(from:)).sorted { lhs, rhs in
            (lhs.created ?? .distantPast) > (rhs.created ?? .distantPast)
        }
    }

    static func entry(from item: JSONValue) -> Entry? {
        guard let slug = item["id"]?.stringValue, !slug.isEmpty else { return nil }
        let name = item["name"]?.stringValue ?? slug
        let context = item["context_length"]?.intValue
            ?? item["top_provider"]?["context_length"]?.intValue
            ?? 128_000
        let maxOutput = item["top_provider"]?["max_completion_tokens"]?.intValue
            ?? min(32_000, max(4_096, context / 4))
        let parameters = Set((item["supported_parameters"]?.arrayValue ?? []).compactMap(\.stringValue))
        let inputs = Set((item["architecture"]?["input_modalities"]?.arrayValue ?? []).compactMap(\.stringValue))
        let pricing = item["pricing"]

        let model = ModelDescriptor(
            provider: .openRouter,
            apiModel: slug,
            displayName: cleanName(name),
            tagline: "via OpenRouter",
            contextWindow: context,
            maxOutputTokens: min(maxOutput, 64_000),
            supportsTools: parameters.isEmpty || parameters.contains("tools"),
            supportsVision: inputs.contains("image"),
            inputPrice: perMillion(pricing?["prompt"]),
            outputPrice: perMillion(pricing?["completion"]),
            cacheReadPrice: perMillion(pricing?["input_cache_read"]),
            isCustom: true
        )
        let vendor = slug.split(separator: "/").first.map(String.init) ?? slug
        let created = item["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        let summary = (item["description"]?.stringValue ?? "")
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Entry(model: model, vendor: vendor, summary: summary, created: created)
    }

    /// OpenRouter prices are USD per token, as strings; we store per million.
    static func perMillion(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        let perToken = value.doubleValue ?? value.stringValue.flatMap(Double.init)
        guard let perToken, perToken >= 0 else { return nil }
        return (perToken * 1_000_000 * 10_000).rounded() / 10_000
    }

    /// "DeepSeek: DeepSeek V3.2" reads better as "DeepSeek V3.2".
    static func cleanName(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        let rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// Simple ranked search across name, slug and vendor.
    public static func search(_ entries: [Entry], query: String, toolsOnly: Bool = false) -> [Entry] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return entries.filter { entry in
            if toolsOnly && !entry.model.supportsTools { return false }
            let haystack = "\(entry.model.displayName) \(entry.model.apiModel) \(entry.vendor)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}
