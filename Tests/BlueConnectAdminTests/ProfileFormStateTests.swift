import Testing
import Foundation
@testable import BlueConnectAdmin

/// `ProfileFormState` holds the profile-template form fields plus the
/// validation + .mobileconfig build logic that used to be inline in
/// ProfilesView (untestable). These pin the bits a refactor could quietly
/// break: the per-template "is this form complete" gate, and the profile
/// name a build produces.
@Suite("ProfileFormState")
struct ProfileFormStateTests {

    @Test func simpleTemplatesAreAlwaysValid() {
        let s = ProfileFormState()
        #expect(s.isValid(for: .fileVault))
        #expect(s.isValid(for: .firewall))
        #expect(s.isValid(for: .gatekeeper))
    }

    @Test func wifiNeedsAnSSID() {
        var s = ProfileFormState()
        #expect(!s.isValid(for: .wifi))
        s.ssid = "Office"
        #expect(s.isValid(for: .wifi))
    }

    @Test func customNeedsXML() {
        var s = ProfileFormState()
        #expect(!s.isValid(for: .custom))
        s.customXML = "<plist/>"
        #expect(s.isValid(for: .custom))
    }

    @Test func certificateNeedsPEMMarker() {
        var s = ProfileFormState()
        s.certPEM = "not a cert"
        #expect(!s.isValid(for: .certificate))
        s.certPEM = "-----BEGIN CERTIFICATE-----\nMII...\n-----END CERTIFICATE-----"
        #expect(s.isValid(for: .certificate))
    }

    @Test func mailNeedsDescriptionAddressAndHost() {
        var s = ProfileFormState()
        s.mailDesc = "Work"
        #expect(!s.isValid(for: .mail))           // address + host still missing
        s.mailAddress = "a@b.com"
        s.mailHost = "mail.b.com"
        #expect(s.isValid(for: .mail))
    }

    @Test func pppcNeedsIdentifierCodeReqAndOneService() {
        var s = ProfileFormState()
        s.pppcID = "com.example.app"
        s.pppcCodeReq = "identifier \"x\""
        s.pppcFDA = false; s.pppcAccessibility = false; s.pppcScreen = false; s.pppcInput = false
        #expect(!s.isValid(for: .pppc))           // no service selected
        s.pppcScreen = true
        #expect(s.isValid(for: .pppc))
    }

    @Test func buildNamesTheProfile() throws {
        var s = ProfileFormState()
        let fv = try s.build(for: .fileVault)
        #expect(fv.name == "FileVault")
        #expect(!fv.data.isEmpty)

        s.ssid = "Net"
        #expect(try s.build(for: .wifi).name == "Wi-Fi “Net”")

        s.mailDesc = "Work"; s.mailAddress = "a@b.com"; s.mailHost = "mail.b.com"
        #expect(try s.build(for: .mail).name == "Mail: Work")
    }
}
