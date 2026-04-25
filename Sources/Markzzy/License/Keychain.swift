import Foundation
import Security

/// Thin wrapper around Keychain for storing a single generic-password item.
enum Keychain {
    /// Use the running bundle's identifier so each build (local dev =
    /// `dev.markzzy.app`, production = `tech.markzzy.Markzzy`) keeps its
    /// own keychain items with ACLs that match its signing identity.
    /// Hard-coding the production ID here would make local dev builds
    /// prompt for keychain access every launch because the saved
    /// item's ACL doesn't include the dev identity.
    private static let service: String = {
        Bundle.main.bundleIdentifier ?? "tech.markzzy.Markzzy"
    }()

    static func set(_ value: String, for account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
