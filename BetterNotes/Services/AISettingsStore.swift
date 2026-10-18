import Combine
import Foundation
import Security

struct AIProviderConfiguration: Sendable, Equatable {
    let apiKey: String
    let baseURL: String
    let model: String
    var sendsPageImages: Bool = false
}

@MainActor
final class AISettingsStore: ObservableObject {
    @Published private(set) var isRemoteConfigured = false
    @Published private(set) var baseURL = "https://api.deepseek.com/v1"
    @Published private(set) var model = "deepseek-chat"
    @Published private(set) var sendsPageImages = false

    private var apiKey = ""
    private let defaults: UserDefaults
    private let keychainService: String

    /// `ephemeralKey` configures the store for this launch only, without
    /// touching the Keychain. It exists for the UI-testing provider stub: a
    /// test that called `update` would write a fake key into the real Keychain
    /// of whatever device it ran on, and leave the app pointed at a dead
    /// provider long after the test finished.
    init(defaults: UserDefaults = .standard, keychainService: String = "com.betternotes.app.ai-provider", ephemeralKey: String? = nil) {
        self.defaults = defaults
        self.keychainService = keychainService
        sendsPageImages = defaults.bool(forKey: "ai.sendsPageImages")
        apiKey = ephemeralKey ?? AIKeychainStore.load(service: keychainService) ?? ""
        // Re-check the stored URL rather than trusting it. update() validates
        // on the way in, but UserDefaults is not a trust boundary the way the
        // Keychain is — a plain-HTTP URL written by an older build or a synced
        // plist would otherwise be used unchecked, and the user's API key
        // would cross the wire in clear.
        if let stored = defaults.string(forKey: "ai.baseURL"), Self.isAllowedProviderURL(stored) {
            baseURL = stored
        }
        model = defaults.string(forKey: "ai.model") ?? model
        isRemoteConfigured = !apiKey.isEmpty
    }

    var configuration: AIProviderConfiguration? {
        guard isRemoteConfigured else { return nil }
        return AIProviderConfiguration(apiKey: apiKey, baseURL: baseURL, model: model, sendsPageImages: sendsPageImages)
    }

    func setSendsPageImages(_ value: Bool) {
        sendsPageImages = value
        defaults.set(value, forKey: "ai.sendsPageImages")
    }

    /// Validate a connection-test draft without saving its fields or key.
    func testConfiguration(apiKey: String?, baseURL: String, model: String) throws -> AIProviderConfiguration {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard Self.isAllowedProviderURL(url) else { throw AIConfigurationError.invalidURL }
        let key = (apiKey ?? self.apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIConfigurationError.missingAPIKey }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIProviderConfiguration(apiKey: key, baseURL: url, model: model.isEmpty ? "deepseek-chat" : model, sendsPageImages: sendsPageImages)
    }

    func update(apiKey: String?, baseURL: String, model: String) throws {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard Self.isAllowedProviderURL(trimmedURL) else { throw AIConfigurationError.invalidURL }

        if let apiKey {
            let newKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try AIKeychainStore.save(newKey, service: keychainService)
            self.apiKey = newKey
        }
        self.baseURL = trimmedURL
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedModel.isEmpty ? "deepseek-chat" : trimmedModel
        defaults.set(self.baseURL, forKey: "ai.baseURL")
        defaults.set(self.model, forKey: "ai.model")
        isRemoteConfigured = !self.apiKey.isEmpty
    }

    func clear() {
        apiKey = ""
        AIKeychainStore.delete(service: keychainService)
        isRemoteConfigured = false
    }

    nonisolated static func isAllowedProviderURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

enum AIConfigurationError: LocalizedError {
    case invalidURL
    case missingAPIKey
    case secureStorage(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return AppLocalization.text("Enter an HTTPS provider URL. Plain HTTP is allowed only for localhost.")
        case .missingAPIKey:
            return AppLocalization.text("Enter an API key before testing the connection.")
        case .secureStorage(let status):
            return "The API key could not be stored securely (Keychain error \(status))."
        }
    }
}

private enum AIKeychainStore {
    private static let account = "api-key"

    static func save(_ value: String, service: String) throws {
        guard !value.isEmpty else { delete(service: service); return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AIConfigurationError.secureStorage(updateStatus) }
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw AIConfigurationError.secureStorage(status) }
    }

    static func load(service: String) -> String? {
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

    static func delete(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
