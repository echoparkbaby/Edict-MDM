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

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
