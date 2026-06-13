import Foundation

/// One-time import of settings + secrets from the v1.5 "BlueConnect Admin"
/// app into this side-by-side "Edict MDM" build. Edict deliberately keeps
/// its own UserDefaults domain and keychain namespace (so the two don't
/// collide), which means a fresh Edict install starts blank. This copies
/// the old app's preferences (gap-fill — never clobbers anything the user
/// already set in Edict) and its keychain secrets across, so MunkiReport,
/// UniFi, Munki repo creds, etc. come over without re-entry.
enum LegacyMigration {
    static let oldBundleID = "xyz.hellocomputer.BlueConnectAdmin"
    private static let doneKey = "didImportFromBlueConnectAdmin"

    private static var currentBundleID: String { Bundle.main.bundleIdentifier ?? "" }

    private static var legacyDefaults: [String: Any]? {
        UserDefaults.standard.persistentDomain(forName: oldBundleID)
    }
    private static var legacyAccounts: [String] {
        KeychainHelper.accounts(inService: oldBundleID)
    }

    /// True when this is a side-by-side build (not the v1.5 app itself),
    /// the import hasn't run yet, and BlueConnect Admin left data behind.
    /// Reads attributes/prefs only, so checking this never prompts.
    static var isAvailable: Bool {
        guard currentBundleID != oldBundleID else { return false }
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return false }
        return (legacyDefaults?.isEmpty == false) || !legacyAccounts.isEmpty
    }

    /// Copy preferences (gap-fill) and secrets from BlueConnect Admin.
    /// Reading the old keychain items may surface a macOS "Always Allow"
    /// prompt per secret — that's expected for cross-app keychain access.
    @MainActor
    @discardableResult
    static func run(settings: SettingsStore) -> (defaults: Int, secrets: Int) {
        var defaultsCopied = 0, secretsCopied = 0

        if let old = legacyDefaults {
            let std = UserDefaults.standard
            for (key, value) in old where std.object(forKey: key) == nil {
                std.set(value, forKey: key)
                defaultsCopied += 1
            }
        }

        for account in legacyAccounts {
            // Don't overwrite a secret Edict already holds.
            if KeychainHelper.read(account: account) != nil { continue }
            if let secret = KeychainHelper.read(account: account, service: oldBundleID) {
                KeychainHelper.save(secret, account: account)
                secretsCopied += 1
            }
        }

        markDone()
        rehydrate(settings)
        return (defaultsCopied, secretsCopied)
    }

    /// Record the import as handled without copying (user chose Skip).
    static func markDone() {
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Pull the just-migrated secrets into the in-memory settings so the
    /// UI reflects them immediately, no relaunch needed.
    @MainActor
    private static func rehydrate(_ settings: SettingsStore) {
        settings.loadPasswordFromKeychain()
        settings.loadRepoPasswordsFromKeychain()
        settings.loadMunkiSecretFromKeychain()
        settings.loadMunkiReportTokenFromKeychain()
        settings.loadUnifiAPIKeyFromKeychain()
        settings.loadMDMKeysFromKeychain()
        settings.loadSCEPChallengeFromKeychain()
    }
}
