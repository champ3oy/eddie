import Foundation
import Security

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case deepSeek, gemini, openAI, claude
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        case .deepSeek: return "DeepSeek"
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.8-flash"
        case .openAI: return "gpt-5.5"
        case .claude: return "claude-opus-5"
        case .deepSeek: return "deepseek-flash"
        }
    }

    var environmentKey: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        case .openAI: return "OPENAI_API_KEY"
        case .claude: return "ANTHROPIC_API_KEY"
        case .deepSeek: return "DEEPSEEK_API_KEY"
        }
    }

    var keyURL: URL {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }
}

/// Which provider is active, model names (UserDefaults) and API keys (Keychain).
enum AISettings {
    private static let defaults = UserDefaults.standard

    static var provider: ProviderKind {
        get { defaults.string(forKey: "ai.provider").flatMap(ProviderKind.init(rawValue:)) ?? .deepSeek }
        set { defaults.set(newValue.rawValue, forKey: "ai.provider") }
    }

    static func model(for kind: ProviderKind) -> String {
        let m = defaults.string(forKey: "ai.model.\(kind.rawValue)")?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? kind.defaultModel : m
    }

    static func setModel(_ model: String, for kind: ProviderKind) {
        defaults.set(model, forKey: "ai.model.\(kind.rawValue)")
    }

    /// Keys read this session. The Keychain is only touched when a key is actually needed (an AI call or
    /// Settings), never while drawing the UI: a Keychain read can block on a macOS permission prompt.
    @MainActor private static var keyCache: [ProviderKind: String] = [:]

    /// Keychain first, then the environment variable.
    @MainActor static func apiKey(for kind: ProviderKind) -> String {
        if let cached = keyCache[kind] { return cached }
        var key = Keychain.read(account: kind.rawValue) ?? ""
        if key.isEmpty { key = ProcessInfo.processInfo.environment[kind.environmentKey] ?? "" }
        keyCache[kind] = key
        return key
    }

    @MainActor static func setAPIKey(_ key: String, for kind: ProviderKind) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: kind.rawValue) } else { Keychain.write(trimmed, account: kind.rawValue) }
        keyCache[kind] = trimmed
    }

    /// "DeepSeek (deepseek-flash)" — for display; doesn't read the key.
    static func displayName(_ kind: ProviderKind = provider) -> String { "\(kind.label) (\(model(for: kind)))" }

    @MainActor static func makeModel(_ kind: ProviderKind = provider) -> VisionModel {
        let key = apiKey(for: kind), model = model(for: kind)
        switch kind {
        case .gemini: return GeminiProvider(apiKey: key, model: model)
        case .openAI: return OpenAICompatibleProvider.openAI(apiKey: key, model: model)
        case .claude: return ClaudeProvider(apiKey: key, model: model)
        case .deepSeek: return OpenAICompatibleProvider.deepSeek(apiKey: key, model: model)
        }
    }
}

enum Keychain {
    private static let service = "Eddie API Keys"
    /// The name used by earlier builds; keys found there are moved over once.
    private static let oldService = "co.morpheusgh.eddie.apikeys"

    static func read(account: String) -> String? {
        if let value = read(account: account, service: service) { return value }
        guard let old = read(account: account, service: oldService) else { return nil }
        write(old, account: account)
        delete(account: account, service: oldService)
        return old
    }

    static func write(_ value: String, account: String) {
        delete(account: account, service: service)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Eddie API key (\(account))",
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete(account: String) {
        delete(account: account, service: service)
        delete(account: account, service: oldService)
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
