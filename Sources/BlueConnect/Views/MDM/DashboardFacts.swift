import Foundation

/// A render-time snapshot of the per-device facts the dashboard derives —
/// compliance, friendly labels, BlueSky links, attention scoring, and the
/// Prism bucketing. Pulling this out of `GroupDashboardView` lets the
/// device table and breakdown chart be their own `View` structs (each
/// re-rendering on its own) and makes the logic unit-testable. It's a pure
/// value type: build it once from the dashboard's loaded state and hand it
/// down.
struct DashboardFacts {
    var osVersions: [String: String]
    var fileVault: [String: String]
    var models: [String: String]
    let hosts: [BlueSkyHost]
    /// enrollmentID → operator label (non-empty only).
    var deviceLabels: [String: String]
    /// enrollmentID → computer name reported by MunkiReport, so an MDM-only Mac
    /// with no hostname reads as its real name instead of a raw serial.
    var mrNames: [String: String] = [:]
    var requireFileVault: Bool
    var minOS: String
    var driftMissing: [String: [DeploymentLog.Entry]]
    var deploymentCounts: [String: Int]
    /// lowercased serial → BlueSky host, built once so per-cell / per-sort
    /// `bscHost(for:)` lookups don't rescan `hosts`.
    private let hostsBySerial: [String: BlueSkyHost]

    init(osVersions: [String: String], fileVault: [String: String], models: [String: String],
         hosts: [BlueSkyHost], deviceLabels: [String: String], mrNames: [String: String] = [:],
         requireFileVault: Bool, minOS: String,
         driftMissing: [String: [DeploymentLog.Entry]], deploymentCounts: [String: Int]) {
        self.osVersions = osVersions; self.fileVault = fileVault; self.models = models
        self.hosts = hosts; self.deviceLabels = deviceLabels; self.mrNames = mrNames
        self.requireFileVault = requireFileVault; self.minOS = minOS
        self.driftMissing = driftMissing; self.deploymentCounts = deploymentCounts
        var idx: [String: BlueSkyHost] = [:]
        // First match wins, same as the old linear `first(where:)` scan.
        for h in hosts { if let s = h.serialnum, !s.isEmpty { idx[s.lowercased()] = idx[s.lowercased()] ?? h } }
        hostsBySerial = idx
    }

    /// An all-empty snapshot, used as the dashboard's initial cached value
    /// before the first load.
    static let empty = DashboardFacts(osVersions: [:], fileVault: [:], models: [:], hosts: [],
                                      deviceLabels: [:], requireFileVault: false, minOS: "",
                                      driftMissing: [:], deploymentCounts: [:])

    func facts(for enr: MDMEnrollment) -> SmartGroup.DeviceFacts {
        SmartGroup.DeviceFacts(
            osVersion: osVersions[enr.id],
            fileVaultOn: fileVault[enr.id].map { $0 == "true" || $0 == "1" },
            model: models[enr.id],
            matchedBlueSky: bscHost(for: enr) != nil,
            enrolled: enr.isEnabled
        )
    }

    func compliant(for d: MDMEnrollment) -> Bool? {
        SmartGroup.compliant(facts(for: d), requireFileVault: requireFileVault, minOS: minOS)
    }

    func fileVaultOn(for d: MDMEnrollment) -> Bool? { facts(for: d).fileVaultOn }

    func bscHost(for enr: MDMEnrollment) -> BlueSkyHost? {
        guard let serial = enr.serialNumber, !serial.isEmpty else { return nil }
        return hostsBySerial[serial.lowercased()]
    }

    /// The fleet-table row id this device maps to: its BlueSky host if
    /// matched by serial, else the synthetic MDM-only row's negative id.
    func hostID(for d: MDMEnrollment) -> Int {
        if let h = bscHost(for: d) { return h.blueskyid }
        return -abs(BlueSkyHost.stableHash(d.id))
    }

    func label(for enr: MDMEnrollment) -> String {
        if let stored = deviceLabels[enr.id], !stored.isEmpty { return stored }
        if let host = bscHost(for: enr) { return host.displayName }
        if let name = mrNames[enr.id], !name.isEmpty { return name }
        return enr.serialNumber ?? String(enr.id.prefix(8))
    }

    func lastSeenText(_ d: MDMEnrollment) -> String {
        guard let date = d.lastSeenDate else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }

    func deviceIcon(_ d: MDMEnrollment) -> String {
        let m = (models[d.id] ?? "").lowercased()
        if m.contains("iphone") { return "iphone" }
        if m.contains("ipad") { return "ipad" }
        if m.contains("apple tv") || m.contains("appletv") { return "appletv" }
        return "laptopcomputer"
    }

    func osRank(_ s: String?) -> Int {
        let p = (s ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (p.count > 0 ? p[0] : 0) * 10000 + (p.count > 1 ? p[1] : 0) * 100 + (p.count > 2 ? p[2] : 0)
    }

    /// Heuristic risk score + the reasons, for the "Needs Attention" lens.
    func attentionScore(_ d: MDMEnrollment) -> (score: Int, issues: [String]) {
        var score = 0; var issues: [String] = []
        let f = facts(for: d)
        if f.fileVaultOn == false { score += 3; issues.append("FileVault off") }
        if !d.isEnabled { score += 3; issues.append("Checked out of MDM") }
        let minOSt = minOS.trimmingCharacters(in: .whitespaces)
        if let os = f.osVersion, !minOSt.isEmpty, !SmartGroup.atLeast(os, minOSt) {
            score += 2; issues.append("macOS \(os) < \(minOSt)")
        }
        if let seen = d.lastSeenDate {
            let days = Int(Date().timeIntervalSince(seen) / 86400)
            if days >= 7 { score += 2; issues.append("No check-in \(days)d") }
        }
        if let missing = driftMissing[d.id], !missing.isEmpty {
            score += 2; issues.append("\(missing.count) profile(s) drifted")
        }
        // Not reporting DDM facts is an onboarding/reporting state, not a risk:
        // a Mac too old for DDM (e.g. macOS 12), or one not yet subscribed to
        // status reporting, will always look this way and would otherwise sit
        // in Needs Attention forever. Note it only as context when the Mac is
        // already flagged for a real reason — it no longer scores on its own.
        if f.osVersion == nil && score > 0 { issues.append("not reporting DDM facts") }
        return (score, issues)
    }

    /// Lightweight natural-language matcher for the Devices table filter.
    /// Understands clauses like "filevault off", "not enrolled", "out of
    /// compliance", OS marketing names ("sonoma"), and bare versions; ANDs
    /// recognized clauses, falls back to substring for anything else.
    func matchesQuery(_ d: MDMEnrollment, _ q: String) -> Bool {
        var rest = q.lowercased()
        let f = facts(for: d)
        var matched = true
        // Consume the first matching phrase, AND its predicate, and strip it
        // so leftover words fall through to free-text matching.
        func clause(_ phrases: [String], _ ok: @autoclosure () -> Bool) {
            for p in phrases where rest.contains(p) {
                matched = matched && ok()
                rest = rest.replacingOccurrences(of: p, with: " ")
                return
            }
        }
        // Negations before positives so "not compliant" doesn't read as compliant.
        clause(["filevault off", "fv off", "no filevault"], f.fileVaultOn == false)
        clause(["filevault on", "fv on"], f.fileVaultOn == true)
        clause(["not enrolled", "checked out", "unenrolled"], !d.isEnabled)
        clause(["enrolled"], d.isEnabled)
        clause(["out of compliance", "non-compliant", "noncompliant", "not compliant"], compliant(for: d) == false)
        clause(["compliant"], compliant(for: d) == true)
        clause(["needs attention", "at risk"], attentionScore(d).score > 0)
        for (name, major) in [("ventura", 13), ("sonoma", 14), ("sequoia", 15), ("tahoe", 26)] {
            clause([name], (f.osVersion?.split(separator: ".").first).flatMap { Int($0) } == major)
        }
        guard matched else { return false }
        // AND any leftover free text against the visible fields.
        for token in rest.split(separator: " ").map(String.init) where !token.isEmpty {
            let hit = label(for: d).localizedCaseInsensitiveContains(token)
                || (d.serialNumber ?? "").localizedCaseInsensitiveContains(token)
                || (osVersions[d.id] ?? "").contains(token)
                || (models[d.id] ?? "").localizedCaseInsensitiveContains(token)
            if !hit { return false }
        }
        return true
    }

    /// The bucket label a device falls into for the given Prism attribute.
    func bucket(for d: MDMEnrollment, attribute: PrismView.Attribute) -> String {
        switch attribute {
        case .osVersion: return osVersions[d.id] ?? "Not reported"
        case .model: return models[d.id] ?? "Not reported"
        case .fileVault:
            switch facts(for: d).fileVaultOn {
            case .some(true): return "On"
            case .some(false): return "Off"
            case nil: return "Not reported"
            }
        case .compliance:
            switch compliant(for: d) {
            case .some(true): return "Compliant"
            case .some(false): return "Out of compliance"
            case nil: return "Unknown"
            }
        case .enrollment: return d.isEnabled ? "Enrolled" : "Checked out"
        case .blueSky: return bscHost(for: d) != nil ? "Linked to BlueSky" : "MDM-only"
        case .profileCount:
            switch deploymentCounts[d.id] ?? 0 {
            case 0: return "No profiles"
            case 1...2: return "1–2 profiles"
            default: return "3+ profiles"
            }
        }
    }
}
