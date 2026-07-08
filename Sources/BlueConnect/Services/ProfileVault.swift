import Foundation
import CryptoKit

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
    static func key() -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let b64 = KeychainHelper.read(account: keyAccount),
           let raw = Data(base64Encoded: b64), raw.count == 32 {
            let k = SymmetricKey(data: raw); cached = k; return k
        }
        let k = SymmetricKey(size: .bits256)
        KeychainHelper.save(k.withUnsafeBytes { Data($0) }.base64EncodedString(), account: keyAccount)
        cached = k
        return k
    }

    static func seal(_ data: Data) -> Data? { seal(data, key: key()) }
    static func open(_ data: Data) -> Data? { open(data, key: key()) }

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
