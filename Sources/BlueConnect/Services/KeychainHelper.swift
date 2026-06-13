import Foundation
import Security

enum KeychainHelper {
    // Derive the keychain service from the running app's bundle ID so the
    // v2 "Edict MDM" build (xyz.hellocomputer.EdictMDM) keeps its secrets in
    // a separate namespace from "BlueConnect Admin" when both are installed
    // side-by-side. Resolves identically to the old literal on the v1.5
    // BlueConnect Admin build, so existing users' stored secrets survive.
    static let service = Bundle.main.bundleIdentifier ?? "xyz.hellocomputer.BlueConnectAdmin"

    static func save(_ value: String, account: String) {
        let data = value.data(using: .utf8) ?? Data()
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        read(account: account, service: service)
    }

    /// Read from a specific service namespace — used by the one-time
    /// import that pulls secrets out of the legacy BlueConnect Admin
    /// keychain into this app's namespace.
    static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    /// All generic-password account names stored under `service`. Returns
    /// attributes only (not secret data), so it does not trigger keychain
    /// access prompts — used to discover what to migrate.
    static func accounts(inService service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
