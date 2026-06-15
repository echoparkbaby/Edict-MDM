import Testing
import Foundation
@testable import BlueConnectAdmin

/// The dashboard's Application Firewall + Gatekeeper categories read these
/// models. Column names match MunkiReport's real schema — firewall uses
/// `globalstate`/`stealthenabled`/`loggingenabled` (no underscores), and
/// Gatekeeper/SIP/Activation Lock come from the `security` module as
/// strings. The models decode from `blueconnect_api.php`'s `SELECT *` rows,
/// which carry extra columns the decoder must ignore.
@Suite("MunkiReport security models")
struct MunkiReportSecurityTests {

    @Test func firewallStateMapping() {
        #expect(MRFirewall(globalstate: 0, stealthenabled: 0, loggingenabled: 0).stateText == "Off")
        #expect(MRFirewall(globalstate: 1, stealthenabled: 1, loggingenabled: 1).stateText == "On")
        #expect(MRFirewall(globalstate: 2, stealthenabled: nil, loggingenabled: nil).stateText == "Block all incoming")
        #expect(MRFirewall(globalstate: nil, stealthenabled: nil, loggingenabled: nil).stateText == "—")
        #expect(MRFirewall(globalstate: 1, stealthenabled: 1, loggingenabled: 0).stealthText == "On")
        #expect(MRFirewall(globalstate: 1, stealthenabled: 0, loggingenabled: 0).loggingText == "Off")
    }

    @Test func securityValuesPassThroughExceptNotSupported() {
        let s = MRSecurity(gatekeeper: "Active", sip: "Disabled", activation_lock: "Enabled", firewall_state: 1)
        #expect(s.gatekeeperText == "Active")
        #expect(s.sipText == "Disabled")
        #expect(s.activationLockText == "Enabled")
        // The collector's "not_supported" sentinel is prettified; empty → dash.
        #expect(MRSecurity(gatekeeper: nil, sip: "not_supported", activation_lock: "", firewall_state: nil).sipText == "Not supported")
        #expect(MRSecurity(gatekeeper: nil, sip: "", activation_lock: nil, firewall_state: nil).gatekeeperText == "—")
    }

    /// The PHP endpoint uses `SELECT *`, so rows include id/serial_number/
    /// version the model doesn't declare — Codable must ignore them, not fail.
    @Test func firewallDecodesFromSelectStarRow() throws {
        let json = #"{"id": 5, "serial_number": "X", "globalstate": 2, "stealthenabled": 1, "loggingenabled": 0, "version": "1.7", "applications": "[]"}"#
        let fw = try JSONDecoder().decode(MRFirewall.self, from: Data(json.utf8))
        #expect(fw.stateText == "Block all incoming")
        #expect(fw.stealthText == "On")
        #expect(fw.loggingText == "Off")
    }

    @Test func securityDecodesFromSelectStarRow() throws {
        let json = #"{"id": 9, "serial_number": "X", "sip": "Active", "gatekeeper": "Active", "activation_lock": "Disabled", "firmwarepw": "No", "firewall_state": 1}"#
        let s = try JSONDecoder().decode(MRSecurity.self, from: Data(json.utf8))
        #expect(s.gatekeeperText == "Active")
        #expect(s.activationLockText == "Disabled")
    }
}
