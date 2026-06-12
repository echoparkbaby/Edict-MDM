import Foundation

/// A criterion in a smart group. A device matches a group when it
/// satisfies every rule (AND). Modeled on Jamf smart groups, scoped to
/// the facts Edict already collects from devices.
struct SmartGroupRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var field: Field
    var value: String = ""

    enum Field: String, Codable, CaseIterable, Identifiable {
        case osAtLeast = "macOS version ≥"
        case osBelow = "macOS version <"
        case fileVaultOn = "FileVault is on"
        case fileVaultOff = "FileVault is off"
        case compliant = "Meets compliance baseline"
        case nonCompliant = "Out of compliance"
        case modelContains = "Model contains"
        case blueSky = "Matched to BlueSky"
        case enrolled = "Currently enrolled"
        var id: String { rawValue }
        /// Needs a free-text value (version string or model substring).
        var needsValue: Bool {
            self == .osAtLeast || self == .osBelow || self == .modelContains
        }
    }
}

/// A named, dynamic group of Macs defined by rules. Membership is
/// computed live from reported device facts — never stored.
struct SmartGroup: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var rules: [SmartGroupRule] = []
}
