import Testing
import Foundation
@testable import BlueConnectAdmin

/// The dashboard's "Pull via MDM" action parses the MDM SecurityInfo
/// response into these facts to override MunkiReport. Pin the firewall
/// state precedence (off → block-all → on) and the has-data guard that
/// stops an empty reply from caching a blank override.
@Suite("MDMSecurityFacts (SecurityInfo parsing)")
struct MDMSecurityFactsTests {

    @Test func parsesFirewallAndSIP() {
        let s: [String: Any] = [
            "SystemIntegrityProtectionEnabled": true,
            "FirewallSettings": ["FirewallEnabled": true, "BlockAllIncoming": false, "StealthMode": true],
        ]
        let f = MDMSecurityFacts(securityInfo: s)
        #expect(f.hasData)
        #expect(f.firewallStateText == "On")
        #expect(f.stealthText == "On")
        #expect(f.sipText == "On")
    }

    @Test func blockAllTakesPrecedenceAndDisabledReads() {
        let blockAll = MDMSecurityFacts(securityInfo: ["FirewallSettings": ["FirewallEnabled": true, "BlockAllIncoming": true]])
        #expect(blockAll.firewallStateText == "Block all incoming")

        let off = MDMSecurityFacts(securityInfo: ["FirewallSettings": ["FirewallEnabled": false],
                                                  "SystemIntegrityProtectionEnabled": false])
        #expect(off.firewallStateText == "Off")
        #expect(off.sipText == "Off")
    }

    @Test func emptyResponseHasNoData() {
        let f = MDMSecurityFacts(securityInfo: [:])
        #expect(f.hasData == false)
        #expect(f.firewallStateText == "—")
        #expect(f.stealthText == "—")
        #expect(f.sipText == "—")
    }

    /// The facts are persisted (with a timestamp) so firewall/SIP survive
    /// relaunch as "checked Xm ago" — Codable must round-trip exactly.
    @Test func codableRoundTrip() throws {
        let original = MDMSecurityFacts(securityInfo: [
            "SystemIntegrityProtectionEnabled": false,
            "FirewallSettings": ["FirewallEnabled": true, "BlockAllIncoming": false, "StealthMode": true],
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MDMSecurityFacts.self, from: data)
        #expect(decoded == original)
        #expect(decoded.firewallStateText == "On")
        #expect(decoded.sipText == "Off")
    }
}
