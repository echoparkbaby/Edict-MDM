import Foundation
import CryptoKit
import Security

/// Encrypts the file-backed profile stores at rest. Saved profiles and the
/// deployment log hold full .mobileconfig bytes, which routinely embed
/// secrets (Wi-Fi PSKs, SCEP challenge, VPN shared secrets) — plaintext JSON
/// under Application Support ends up in Time Machine backups. We AES-GCM the
/// whole file with one 256-bit key kept in the keychain (device-only, like
/// every other admin secret), rather than moving each blob into its own
/// keychain item.
enum ProfileVault {
    private static let keyAccount = "EdictMDM.profileStoreKey"
    private static let lock = NSLock()
    private static var cached: SymmetricKey?

    /// The store key, created on first use. Locked so two stores encrypting
    /// concurrently on first launch can't generate two keys (the loser's file
    /// would then be undecryptable).
    /// nil when the keychain can't be read right now (locked, denied):
    /// minting a fresh key then would orphan the existing encrypted files,
    /// and the next save would overwrite them with an empty store. Only a
    /// genuinely missing key (`errSecItemNotFound`) creates a new one.
    static func key() -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let (b64, status) = KeychainHelper.readWithStatus(account: keyAccount)
        if let b64, let raw = Data(base64Encoded: b64), raw.count == 32 {
            let k = SymmetricKey(data: raw); cached = k; return k
        }
        guard status == errSecItemNotFound || status == errSecSuccess else {
            Log.error("ProfileVault", "Keychain unavailable (OSStatus \(status)); not reading or writing profile stores this time.")
            return nil
        }
        let k = SymmetricKey(size: .bits256)
        guard KeychainHelper.save(k.withUnsafeBytes { Data($0) }.base64EncodedString(), account: keyAccount) else { return nil }
        cached = k
        return k
    }

    static func seal(_ data: Data) -> Data? { key().flatMap { seal(data, key: $0) } }
    static func open(_ data: Data) -> Data? { key().flatMap { open(data, key: $0) } }

    // Pure crypto (explicit key) so the roundtrip is testable without the keychain.
    static func seal(_ data: Data, key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(data, using: key).combined
    }
    /// Returns nil if `data` isn't a valid sealed box for this key — including
    /// legacy plaintext JSON, so callers fall back and re-encrypt on next save.
    static func open(_ data: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
