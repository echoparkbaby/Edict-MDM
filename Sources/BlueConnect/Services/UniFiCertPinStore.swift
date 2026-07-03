import Foundation
import CryptoKit

/// Trust-on-first-use certificate pinning for the UniFi controller.
///
/// Home UniFi controllers ship a self-signed TLS cert, so the app can't
/// rely on system trust. Instead of trusting *any* cert (the old behavior —
/// a machine-in-the-middle could present its own cert and harvest the API
/// key), we record the exact leaf-certificate fingerprint the first time we
/// connect to a host and require every later connection to present the same
/// one. Same model as SSH `known_hosts`.
///
/// The fingerprint is a SHA-256 of the DER cert — public information, not a
/// secret — so it lives in `UserDefaults` (thread-safe, reachable from the
/// URLSession delegate queue without a main-actor hop), keyed by host.
enum UniFiCertPinStore {
    static let keyPrefix = "unifiCertPin."

    /// The pinned fingerprint for `host`, or nil if this host hasn't been
    /// seen yet (first use).
    static func pin(forHost host: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: keyPrefix + host)
    }

    /// Record the fingerprint trusted for `host` (first use).
    static func setPin(_ fingerprint: String, forHost host: String,
                       defaults: UserDefaults = .standard) {
        defaults.set(fingerprint, forKey: keyPrefix + host)
    }

    /// Forget every pinned host — the "re-trust" escape hatch for when a
    /// controller legitimately gets a new cert (reinstall/upgrade). The next
    /// connection re-pins.
    static func clearAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether any host is currently pinned (drives the settings UI).
    static func hasAnyPin(defaults: UserDefaults = .standard) -> Bool {
        defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(keyPrefix) }
    }

    /// Lowercase hex SHA-256 of a certificate's DER bytes — the fingerprint
    /// we pin and compare.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
