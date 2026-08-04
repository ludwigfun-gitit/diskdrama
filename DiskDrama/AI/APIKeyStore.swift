import Foundation
import Security

/// The Anthropic API key, in the Keychain.
///
/// Not `UserDefaults`. A02 resolves that personal API keys are acceptable for
/// v1, and a personal key is still a credential that bills a real account —
/// `defaults read com.bloo.diskdrama` must never print it, and it must not ride
/// along in a preferences file that gets backed up in the clear.
///
/// Marked `kSecAttrAccessibleWhenUnlocked` and **not** synchronizable: this is
/// one machine's key for one machine's app, and pushing it into iCloud Keychain
/// would spread a billable secret further than the user asked.
enum APIKeyStore {

    private static let service = "com.bloo.diskdrama.anthropic"
    private static let account = "api-key"

    /// True when a key is present, without reading it. Lets the UI decide
    /// whether to offer the feature at all — asking for an explanation the app
    /// cannot generate is worse than not offering one.
    static var hasKey: Bool { read() != nil }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String:      Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        // Update first, then add — SecItemAdd fails with errSecDuplicateItem
        // rather than replacing, so a plain add would silently keep a stale key
        // after the user pastes a new one.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Log.app.error("keychain update failed: \(updated, privacy: .public)")
            return false
        }

        let status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status != errSecSuccess {
            Log.app.error("keychain add failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
