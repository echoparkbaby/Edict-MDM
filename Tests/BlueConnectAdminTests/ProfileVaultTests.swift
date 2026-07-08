import Testing
import Foundation
import CryptoKit
@testable import BlueConnectAdmin

/// The at-rest crypto for the profile stores: a seal→open roundtrip must
/// recover the bytes, and open() must reject anything not sealed with this
/// key — including legacy plaintext JSON, which is how load() knows to fall
/// back and re-encrypt.
@Suite("ProfileVault")
struct ProfileVaultTests {
    @Test func sealOpenRoundtrips() {
        let key = SymmetricKey(size: .bits256)
        let plain = Data(#"[{"name":"Wi-Fi","dataBase64":"c2VjcmV0"}]"#.utf8)
        let sealed = try! #require(ProfileVault.seal(plain, key: key))
        #expect(sealed != plain)                       // actually encrypted
        #expect(ProfileVault.open(sealed, key: key) == plain)
    }

    @Test func openRejectsLegacyPlaintext() {
        let key = SymmetricKey(size: .bits256)
        let plaintextJSON = Data(#"[{"name":"x"}]"#.utf8)
        #expect(ProfileVault.open(plaintextJSON, key: key) == nil)  // → caller falls back
    }

    @Test func openRejectsWrongKey() {
        let sealed = try! #require(ProfileVault.seal(Data("hi".utf8), key: SymmetricKey(size: .bits256)))
        #expect(ProfileVault.open(sealed, key: SymmetricKey(size: .bits256)) == nil)
    }
}
