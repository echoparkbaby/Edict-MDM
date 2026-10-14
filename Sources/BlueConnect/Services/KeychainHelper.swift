import Foundation
import Security

enum KeychainHelper {
    // Derive the keychain service from the running app's bundle ID so the
    // v2 "Edict MDM" build (xyz.hellocomputer.EdictMDM) keeps its secrets in
    // a separate namespace from "BlueConnect Admin" when both are installed
    // side-by-side. Resolves identically to the old literal on the v1.5
    // BlueConnect Admin build, so existing users' stored secrets survive.
    static let service = Bundle.main.bundleIdentifier ?? "xyz.hellocomputer.BlueConnectAdmin"

    /// Admin secrets are device-only: readable after the first unlock (so the
    /// app works after a reboot without the screen being unlocked) but never
    /// included in an encrypted backup and never restored onto a different Mac
    /// via Migration Assistant. Prevents fleet-admin credentials from leaving
    /// this machine.
    private static let accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Update-in-place if the item exists, else add. Never deletes first
    /// (a failed re-add used to silently drop the old secret). Returns
    /// whether the write succeeded.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            // A locked keychain / ACL / interaction-not-allowed failure here
            // means the secret survives only in memory this session and is
            // gone next launch — the classic "works on one Mac, 401s on
            // another". Callers historically discard the Bool, so log it
            // (account name + status only, never the secret value).
            Log.error("Keychain", "Couldn't update “\(account)”: OSStatus \(updateStatus). It won't persist to next launch.")
            return false
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.error("Keychain", "Couldn't store “\(account)”: OSStatus \(addStatus). It won't persist to next launch.")
            return false
        }
        return true
    }

    /// One-time upgrade of every stored secret's accessibility to
    /// `…ThisDeviceOnly` (see `accessible`). Older builds wrote secrets with
    /// plain `AfterFirstUnlock`, which stayed eligible for encrypted-backup
    /// migration to another Mac. Updates each item **in place** (never
    /// deletes — a failed re-add would drop the secret), is idempotent, and
    /// only marks itself done once every item upgrades, so a transiently
    /// locked keychain retries on the next launch. Cheap to call every start.
    static func migrateAccessibilityToThisDeviceOnlyIfNeeded() {
        let flag = "keychainThisDeviceOnlyMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let names = accounts(inService: service)
        guard !names.isEmpty else {
            UserDefaults.standard.set(true, forKey: flag)   // nothing to migrate
            return
        }
        var allUpgraded = true
        for account in names {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecAttrAccessible as String: accessible] as CFDictionary
            )
            if status != errSecSuccess {
                allUpgraded = false
                Log.warn("Keychain", "Couldn't set device-only accessibility on “\(account)”: OSStatus \(status)")
            }
        }
        if allUpgraded { UserDefaults.standard.set(true, forKey: flag) }
    }

    static func read(account: String) -> String? {
        read(account: account, service: service)
    }

    /// Read from a specific service namespace — used by the one-time
    /// import that pulls secrets out of the legacy BlueConnect Admin
    /// keychain into this app's namespace.
    static func read(account: String, service: String) -> String? {
        readWithStatus(account: account, service: service).value
    }

    /// Like `read`, but also returns the OSStatus so callers can tell
    /// "not stored" (`errSecItemNotFound`) from "keychain locked / denied".
    static func readWithStatus(account: String, service: String = service) -> (value: String?, status: OSStatus) {
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
        else { return (nil, status) }
        return (str, status)
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
