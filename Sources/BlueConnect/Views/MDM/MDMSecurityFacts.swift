import Foundation

/// Firewall + SIP posture parsed from an MDM `SecurityInfo` command
/// response. Used by the dashboard's on-demand "Pull via MDM" action to
/// override MunkiReport for the Macs it can reach live. (Gatekeeper has no
/// MDM source, and the dashboard skips the second DeviceInformation command
/// for Activation Lock, so those stay MunkiReport-sourced.)
struct MDMSecurityFacts: Equatable, Codable {
    var firewallEnabled: Bool?
    var firewallBlockAll: Bool?
    var firewallStealth: Bool?
    var sipEnabled: Bool?

    init(securityInfo s: [String: Any]) {
        sipEnabled = s["SystemIntegrityProtectionEnabled"] as? Bool
        if let fw = s["FirewallSettings"] as? [String: Any] {
            firewallEnabled = fw["FirewallEnabled"] as? Bool
            firewallBlockAll = fw["BlockAllIncoming"] as? Bool
            firewallStealth = fw["StealthMode"] as? Bool
        }
    }

    /// True when the response actually carried firewall or SIP data, so the
    /// caller can avoid caching an all-nil "we got nothing" result.
    var hasData: Bool {
        firewallEnabled != nil || sipEnabled != nil
    }

    var firewallStateText: String {
        if firewallEnabled == false { return "Off" }
        if firewallBlockAll == true { return "Block all incoming" }
        if firewallEnabled == true { return "On" }
        return "—"
    }
    var stealthText: String { Self.onOff(firewallStealth) }
    var sipText: String { Self.onOff(sipEnabled) }
    private static func onOff(_ v: Bool?) -> String {
        guard let v else { return "—" }
        return v ? "On" : "Off"
    }
}
