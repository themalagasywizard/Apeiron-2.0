import ApeironKit
import Foundation
import Security

struct AppSettings: Codable, Equatable {
    var defaultModelID: String = ModelCatalog.defaultModelID
    var defaultMode: PermissionMode = .ask
    var effort: Effort = .high
    var showThinking = true
    var accent: AccentChoice = .ember
    var readingFont: ReadingFont = .serif
    var textScale: Double = 1
    var customModels: [ModelDescriptor] = []
    var baseURLOverrides: [String: String] = [:]
    var rules = PermissionRules()
    var recentWorkspaces: [String] = []
    var maxTurns = 100
    var compactThreshold = 0.8
    var hasCompletedOnboarding = false

    private static let key = "apeiron.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    init() {}

    // Tolerant decoding so new fields never wipe existing settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        defaultModelID = (try? c.decode(String.self, forKey: .defaultModelID)) ?? defaults.defaultModelID
        defaultMode = (try? c.decode(PermissionMode.self, forKey: .defaultMode)) ?? defaults.defaultMode
        effort = (try? c.decode(Effort.self, forKey: .effort)) ?? defaults.effort
        showThinking = (try? c.decode(Bool.self, forKey: .showThinking)) ?? defaults.showThinking
        accent = (try? c.decode(AccentChoice.self, forKey: .accent)) ?? defaults.accent
        readingFont = (try? c.decode(ReadingFont.self, forKey: .readingFont)) ?? defaults.readingFont
        textScale = (try? c.decode(Double.self, forKey: .textScale)) ?? defaults.textScale
        customModels = (try? c.decode([ModelDescriptor].self, forKey: .customModels)) ?? []
        baseURLOverrides = (try? c.decode([String: String].self, forKey: .baseURLOverrides)) ?? [:]
        rules = (try? c.decode(PermissionRules.self, forKey: .rules)) ?? PermissionRules()
        recentWorkspaces = (try? c.decode([String].self, forKey: .recentWorkspaces)) ?? []
        maxTurns = (try? c.decode(Int.self, forKey: .maxTurns)) ?? defaults.maxTurns
        compactThreshold = (try? c.decode(Double.self, forKey: .compactThreshold)) ?? defaults.compactThreshold
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? false
    }

    var theme: Theme {
        Theme(accent: accent, readingFont: readingFont, textScale: CGFloat(textScale))
    }
}

/// API keys live in the macOS Keychain, never in UserDefaults.
struct KeychainStore {
    let service = "app.apeiron.api-keys"

    func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
