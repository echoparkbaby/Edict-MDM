import Testing
import Foundation
@testable import BlueConnectAdmin

/// The dashboard's Application Firewall + Gatekeeper categories read these
/// models. The int→text mappings encode real semantics (firewall
/// global_state 2 = "block all incoming", not just "on"), and the models
/// decode from `blueconnect_api.php`'s `SELECT *` rows — which carry extra
/// columns (id, serial_number, module) the decoder must ignore.
@Suite("MunkiReport security models")
struct MunkiReportSecurityTests {

    @Test func firewallStateMapping() {
        #expect(MRFirewall(global_state: 0, stealth_enabled: 0, logging_enabled: 0).stateText == "Off")
        #expect(MRFirewall(global_state: 1, stealth_enabled: 1, logging_enabled: 1).stateText == "On")
        #expect(MRFirewall(global_state: 2, stealth_enabled: nil, logging_enabled: nil).stateText == "Block all incoming")
        #expect(MRFirewall(global_state: nil, stealth_enabled: nil, logging_enabled: nil).stateText == "—")
        #expect(MRFirewall(global_state: 1, stealth_enabled: 1, logging_enabled: 0).stealthText == "On")
        #expect(MRFirewall(global_state: 1, stealth_enabled: 0, logging_enabled: 0).loggingText == "Off")
    }

    @Test func gatekeeperMapping() {
        #expect(MRGatekeeper(gatekeeper: 1, assessments: 0, version: "1.0").enabledText == "On")
        #expect(MRGatekeeper(gatekeeper: 0, assessments: 1, version: nil).assessmentsText == "On")
        #expect(MRGatekeeper(gatekeeper: nil, assessments: nil, version: nil).enabledText == "—")
    }

    /// The PHP endpoint uses `SELECT *`, so rows include id/serial_number/
    /// module the model doesn't declare — Codable must ignore them, not fail.
    @Test func decodesFromSelectStarRow() throws {
        let json = #"{"id": 5, "serial_number": "X", "module": "firewall", "global_state": 2, "stealth_enabled": 1, "logging_enabled": 0}"#
        let fw = try JSONDecoder().decode(MRFirewall.self, from: Data(json.utf8))
        #expect(fw.stateText == "Block all incoming")
        #expect(fw.stealthText == "On")
        #expect(fw.loggingText == "Off")
    }
}
