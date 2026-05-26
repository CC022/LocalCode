import Foundation
import Security

/// Thin wrapper over `SecItem*` for storing API keys. Account is the API
/// endpoint URL (so two providers don't collide); service is a fixed string.
/// Errors are deliberately collapsed to `nil` on read — a missing key is the
/// common case and not exceptional.
enum Keychain {
    static let service = "LocalCode.APIKey"

    /// Insert or update. Empty `secret` deletes the entry instead.
    static func save(_ secret: String, for account: String) {
        guard !account.isEmpty else { return }
        if secret.isEmpty { delete(account); return }
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func load(_ account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
