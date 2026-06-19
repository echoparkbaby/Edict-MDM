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
        #expect(s.isValid(for: .wifi) == false)
        s.ssid = "Office"
        #expect(s.isValid(for: .wifi))
    }

    @Test func customNeedsXML() {
        var s = ProfileFormState()
        #expect(s.isValid(for: .custom) == false)
        s.customXML = "<plist/>"
        #expect(s.isValid(for: .custom))
    }

    @Test func certificateNeedsPEMMarker() {
        var s = ProfileFormState()
        s.certPEM = "not a cert"
        #expect(s.isValid(for: .certificate) == false)
        s.certPEM = "-----BEGIN CERTIFICATE-----\nMII...\n-----END CERTIFICATE-----"
        #expect(s.isValid(for: .certificate))
    }

    @Test func mailNeedsDescriptionAddressAndHost() {
        var s = ProfileFormState()
        s.mailDesc = "Work"
        #expect(s.isValid(for: .mail) == false)           // address + host still missing
        s.mailAddress = "a@b.com"
        s.mailHost = "mail.b.com"
        #expect(s.isValid(for: .mail))
    }

    @Test func pppcNeedsIdentifierCodeReqAndOneService() {
        var s = ProfileFormState()
        s.pppcID = "com.example.app"
        s.pppcCodeReq = "identifier \"x\""
        s.pppcFDA = false; s.pppcAccessibility = false; s.pppcScreen = false; s.pppcInput = false
        #expect(s.isValid(for: .pppc) == false)           // no service selected
        s.pppcScreen = true
        #expect(s.isValid(for: .pppc))
    }

    @Test func screenTimeBuildsContentAndWebPayloads() throws {
        var s = ProfileFormState()
        s.stRegion = "gb"; s.stSiriFilter = true; s.stLimitWeb = true; s.stMovies = 400
        let data = try s.build(for: .screenTime).data
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payloads = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 2)   // restrictions + web content filter
        let access = try #require(payloads.first { ($0["PayloadType"] as? String) == "com.apple.applicationaccess" })
        #expect(access["ratingRegion"] as? String == "gb")
        #expect(access["forceAssistantProfanityFilter"] as? Bool == true)
        #expect(access["ratingMovies"] as? Int == 400)
        let web = try #require(payloads.first { ($0["PayloadType"] as? String) == "com.apple.webcontent-filter" })
        #expect(web["AutoFilterEnabled"] as? Bool == true)
    }

    @Test func screenTimeOmitsWebPayloadAndDefaultsRegion() throws {
        let data = try ProfileFormState().build(for: .screenTime).data
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payloads = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 1)   // no web filter when the toggle is off
        #expect((payloads[0]["ratingRegion"] as? String) == "us")
    }

    @Test func buildNamesTheProfile() throws {
        var s = ProfileFormState()
        let fv = try s.build(for: .fileVault)
        #expect(fv.name == "FileVault")
        #expect(fv.data.isEmpty == false)

        s.ssid = "Net"
        #expect(try s.build(for: .wifi).name == "Wi-Fi “Net”")

        s.mailDesc = "Work"; s.mailAddress = "a@b.com"; s.mailHost = "mail.b.com"
        #expect(try s.build(for: .mail).name == "Mail: Work")
    }
}
