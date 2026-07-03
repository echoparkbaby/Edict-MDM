import Testing
import Foundation
@testable import BlueConnectAdmin

/// TOFU pinning for the UniFi controller: pins are per-host, first-use
/// records them, a re-trust forgets them, and the fingerprint is a real
/// SHA-256. Uses a throwaway UserDefaults suite so it never touches the
/// app's actual pins.
@Suite("UniFi cert pin store")
struct UniFiCertPinStoreTests {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "unifi-pin-test-\(UUID().uuidString)")!
    }

    @Test func firstUseIsUnpinnedThenRecords() {
        let d = tempDefaults()
        #expect(UniFiCertPinStore.pin(forHost: "10.0.0.1", defaults: d) == nil)
        UniFiCertPinStore.setPin("abc123", forHost: "10.0.0.1", defaults: d)
        #expect(UniFiCertPinStore.pin(forHost: "10.0.0.1", defaults: d) == "abc123")
    }

    @Test func pinsArePerHost() {
        let d = tempDefaults()
        UniFiCertPinStore.setPin("aaa", forHost: "host-a", defaults: d)
        UniFiCertPinStore.setPin("bbb", forHost: "host-b", defaults: d)
        #expect(UniFiCertPinStore.pin(forHost: "host-a", defaults: d) == "aaa")
        #expect(UniFiCertPinStore.pin(forHost: "host-b", defaults: d) == "bbb")
    }

    @Test func clearAllForgetsEveryPin() {
        let d = tempDefaults()
        UniFiCertPinStore.setPin("aaa", forHost: "host-a", defaults: d)
        UniFiCertPinStore.setPin("bbb", forHost: "host-b", defaults: d)
        #expect(UniFiCertPinStore.hasAnyPin(defaults: d))
        UniFiCertPinStore.clearAll(defaults: d)
        #expect(!UniFiCertPinStore.hasAnyPin(defaults: d))
        #expect(UniFiCertPinStore.pin(forHost: "host-a", defaults: d) == nil)
    }

    @Test func sha256HexMatchesKnownVectors() {
        // NIST test vectors — proves we hash DER bytes correctly.
        #expect(UniFiCertPinStore.sha256Hex(Data()) ==
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(UniFiCertPinStore.sha256Hex(Data("abc".utf8)) ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
