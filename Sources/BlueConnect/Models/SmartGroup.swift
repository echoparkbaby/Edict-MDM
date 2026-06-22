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
    /// Onboarding baseline for this group — saved-profile IDs and KMFDDM set
    /// names every member should receive. Edict ensures matching Macs have
    /// these (applied once per device). Optional; empty = no group policy.
    var onboardProfileIDs: [UUID] = []
    var onboardSets: [String] = []

    var hasOnboardingBaseline: Bool { !onboardProfileIDs.isEmpty || !onboardSets.isEmpty }

    /// The resolved facts about one device, supplied by whichever view is
    /// evaluating membership (Devices, Profiles, …).
    struct DeviceFacts {
        var osVersion: String?
        var fileVaultOn: Bool?
        var model: String?
        var matchedBlueSky: Bool
        var enrolled: Bool
    }

    /// True when the device matches every rule. `requireFileVault` / `minOS`
    /// come from the compliance baseline so compliant/non-compliant rules
    /// agree with the Devices view.
    func contains(_ f: DeviceFacts, requireFileVault: Bool, minOS: String) -> Bool {
        rules.allSatisfy { rule in
            switch rule.field {
            case .osAtLeast:    return f.osVersion.map { Self.atLeast($0, rule.value) } ?? false
            case .osBelow:      return f.osVersion.map { !Self.atLeast($0, rule.value) } ?? false
            case .fileVaultOn:  return f.fileVaultOn == true
            case .fileVaultOff: return f.fileVaultOn == false
            case .compliant:    return Self.compliant(f, requireFileVault: requireFileVault, minOS: minOS) == true
            case .nonCompliant: return Self.compliant(f, requireFileVault: requireFileVault, minOS: minOS) == false
            case .modelContains:return (f.model ?? "").localizedCaseInsensitiveContains(rule.value)
            case .blueSky:      return f.matchedBlueSky
            case .enrolled:     return f.enrolled
            }
        }
    }

    /// Numeric segment-wise version compare: 15.10 ≥ 15.5.
    static func atLeast(_ v: String, _ target: String) -> Bool {
        let a = v.split(separator: ".").map { Int($0) ?? 0 }
        let b = target.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// nil when a required fact isn't reported (can't determine).
    static func compliant(_ f: DeviceFacts, requireFileVault: Bool, minOS: String) -> Bool? {
        var failed = false, unknown = false
        if requireFileVault {
            switch f.fileVaultOn {
            case .some(true): break
            case .some(false): failed = true
            case nil: unknown = true
            }
        }
        let m = minOS.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty {
            if let v = f.osVersion { if !atLeast(v, m) { failed = true } }
            else { unknown = true }
        }
        if failed { return false }
        if unknown { return nil }
        return true
    }
}
