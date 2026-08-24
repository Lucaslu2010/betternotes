import Foundation
import Security

/// Thin wrapper around the iOS Keychain for storing the sync bearer token.
/// We use a kSecClassGenericPassword item with a fixed service name and the
/// user's email as the account. The token itself is the stored "password".
struct KeychainTokenStore {
    private static let service = "com.betternotes.app.sync-token"

    static func saveToken(_ token: String, for email: String) {
        let account = email.lowercased()
        let data = Data(token.utf8)

        // Delete any existing item for this account first so the add doesn't
        // fail with errSecDuplicateItem.
        deleteToken(for: email)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] save failed: \(status)")
        }
    }

    static func loadToken(for email: String) -> String? {
        let account = email.lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(for email: String) {
        let account = email.lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Wipes the stored email + token from UserDefaults + Keychain.
    static func clearAll() {
        // Delete every keychain item under our service (any account).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "sync.email")
        UserDefaults.standard.removeObject(forKey: "sync.userName")
    }
}
