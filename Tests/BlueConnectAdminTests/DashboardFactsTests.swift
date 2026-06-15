import Testing
@testable import BlueConnectAdmin

/// `DashboardFacts` is the per-device logic the Prism dashboard's device
/// table and breakdown chart both run on — compliance, labels, BlueSky
/// matching, search, attention scoring, and bucketing. It used to live
/// inline in the view (untestable); now it's a value type, so these pin
/// the behavior a refactor could silently break.
@Suite("DashboardFacts")
struct DashboardFactsTests {

    private func enrollment(id: String = "A", enabled: Bool = true,
                            serial: String? = "S") -> MDMEnrollment {
        MDMEnrollment(id: id, type: "Device", enabled: enabled ? 1 : 0,
                      lastSeenAt: nil, createdAt: nil, serialNumber: serial)
    }

    private func host(serial: String, id: Int = 5) -> BlueSkyHost {
        BlueSkyHost(blueskyid: id, hostname: "mac", sharingname: nil, username: nil,
                    status: nil, lastSeen: nil, timestamp: 0, active: true,
                    sshPort: 22, vncPort: 5900, category: nil, favorite: nil,
                    notes: nil, serialnum: serial, notify: nil, alert: nil, email: nil)
    }

    private func facts(os: [String: String] = [:], fv: [String: String] = [:],
                       models: [String: String] = [:], hosts: [BlueSkyHost] = [],
                       labels: [String: String] = [:],
                       requireFV: Bool = false, minOS: String = "") -> DashboardFacts {
        DashboardFacts(osVersions: os, fileVault: fv, models: models, hosts: hosts,
                       deviceLabels: labels, requireFileVault: requireFV, minOS: minOS,
                       driftMissing: [:], deploymentCounts: [:])
    }

    @Test func complianceReflectsFileVaultAndOS() {
        let d = enrollment()
        #expect(facts(os: ["A": "15.5"], fv: ["A": "true"], requireFV: true, minOS: "15").compliant(for: d) == true)
        #expect(facts(os: ["A": "15.5"], fv: ["A": "false"], requireFV: true, minOS: "15").compliant(for: d) == false)
        // FileVault required but never reported → can't tell.
        #expect(facts(os: ["A": "15.5"], requireFV: true, minOS: "15").compliant(for: d) == nil)
        // FileVault on but OS below the floor → non-compliant.
        #expect(facts(os: ["A": "14.0"], fv: ["A": "true"], requireFV: true, minOS: "15").compliant(for: d) == false)
    }

    @Test func bucketsByAttribute() {
        let d = enrollment()
        let f = facts(os: ["A": "14.6"], fv: ["A": "false"], models: ["A": "MacBookPro18,3"])
        #expect(f.bucket(for: d, attribute: .osVersion) == "14.6")
        #expect(f.bucket(for: d, attribute: .fileVault) == "Off")
        #expect(f.bucket(for: d, attribute: .enrollment) == "Enrolled")
        #expect(f.bucket(for: d, attribute: .blueSky) == "MDM-only")
        #expect(facts().bucket(for: d, attribute: .osVersion) == "Not reported")
    }

    @Test func labelPrefersOperatorThenHostThenSerial() {
        let d = enrollment(serial: "SERIAL-9")
        #expect(facts(labels: ["A": "front-desk"]).label(for: d) == "front-desk")
        let h = host(serial: "SERIAL-9")
        #expect(facts(hosts: [h]).label(for: d) == h.displayName)
        #expect(facts().label(for: d) == "SERIAL-9")
        let noSerial = enrollment(id: "LONGUUIDVALUE12345", serial: nil)
        #expect(facts().label(for: noSerial) == "LONGUUID")   // id.prefix(8)
    }

    @Test func hostIDMatchedVsSynthetic() {
        let d = enrollment(serial: "MATCH")
        #expect(facts(hosts: [host(serial: "match", id: 42)]).hostID(for: d) == 42)   // case-insensitive
        #expect(facts().hostID(for: d) < 0)                                            // synthetic, negative
    }

    @Test func searchUnderstandsClausesAndFreeText() {
        let d = enrollment()
        let f = facts(os: ["A": "14.6"], fv: ["A": "false"], labels: ["A": "kiosk"])
        #expect(f.matchesQuery(d, "filevault off"))
        #expect(f.matchesQuery(d, "filevault on") == false)
        #expect(f.matchesQuery(d, "sonoma"))                 // macOS 14
        #expect(f.matchesQuery(d, "sequoia") == false)       // macOS 15
        #expect(f.matchesQuery(d, "kiosk"))                  // free-text against the label
        #expect(f.matchesQuery(d, "frontdesk") == false)
    }

    @Test func attentionScoreFlagsFileVaultAndCheckout() {
        let d = enrollment(enabled: false)
        let r = facts(os: ["A": "15.5"], fv: ["A": "false"]).attentionScore(d)
        #expect(r.score >= 6)
        #expect(r.issues.contains("FileVault off"))
        #expect(r.issues.contains("Checked out of MDM"))
    }
}
