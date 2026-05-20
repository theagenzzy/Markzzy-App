import Foundation
import Security

/// Thin wrapper around Keychain for storing a single generic-password item.
///
/// Dev builds (`dev.markzzy.app`) use a plain on-disk file instead of the
/// real Keychain. The macOS Keychain ties an item's ACL to the signing
/// identity of the binary that created it; every rebuild during
/// development re-prompts for the login password to re-authorize access
/// ("Markzzy wants to access key dev.markzzy.app"). That prompt on every
/// build is unworkable while iterating. Production (`tech.markzzy.Markzzy`,
/// notarized, stable identity) keeps using the real Keychain — gated on
/// bundle id so the file fallback can never ship in a release.
enum Keychain {
    private static let service: String = {
        Bundle.main.bundleIdentifier ?? "tech.markzzy.Markzzy"
    }()

    private static let isDevBuild: Bool =
        (Bundle.main.bundleIdentifier ?? "").hasPrefix("dev.")

    /// Dev fallback file: ~/Library/Application Support/Markzzy/dev-credentials.json
    private static let devStoreURL: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Markzzy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dev-credentials.json")
    }()

    private static func devLoad() -> [String: String] {
        guard let data = try? Data(contentsOf: devStoreURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func devSave(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: devStoreURL, options: .atomic)
        }
    }

    static func set(_ value: String, for account: String) {
        if isDevBuild {
            var dict = devLoad()
            dict[account] = value
            devSave(dict)
            return
        }
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
        if isDevBuild {
            return devLoad()[account]
        }
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
        if isDevBuild {
            var dict = devLoad()
            dict.removeValue(forKey: account)
            devSave(dict)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
