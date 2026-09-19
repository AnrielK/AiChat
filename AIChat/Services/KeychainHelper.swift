import Foundation
import Security

enum KeychainAccount: String {
    case claude = "api.claude"
    case gemini = "api.gemini"
    case huggingFace = "hf.token"
}

/// API klíče se ukládají do Klíčenky, nikdy do UserDefaults.
enum KeychainHelper {
    private static let service = (Bundle.main.bundleIdentifier ?? "AIChat") + ".apikeys"

    static func save(_ value: String, for account: KeychainAccount) {
        delete(account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ account: KeychainAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func delete(_ account: KeychainAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
