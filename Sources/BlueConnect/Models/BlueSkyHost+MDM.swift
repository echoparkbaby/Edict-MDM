import Foundation

extension BlueSkyHost {
    /// Synthesize a fleet-table row for a Mac that's enrolled in MDM but
    /// not present in the BlueSky inventory — so the merged table shows
    /// every managed Mac, BSC-reachable or not. The id is negative and
    /// derived from the enrollment UUID so it's stable across refreshes
    /// and never collides with a real BlueSky host's positive id. The row
    /// is not SSH-reachable (active == false), which keeps the BSC row
    /// actions disabled; MDM row actions are what apply to it.
    static func mdmOnly(enrollment enr: MDMEnrollment, label: String) -> BlueSkyHost {
        BlueSkyHost(
            blueskyid: -abs(stableHash(enr.id)),
            hostname: label,
            sharingname: enr.serialNumber,
            username: nil,
            status: enr.isEnabled ? "MDM-managed" : "MDM (checked out)",
            lastSeen: enr.lastSeenAt,
            timestamp: Int(enr.lastSeenDate?.timeIntervalSince1970 ?? 0),
            active: false,
            sshPort: 0,
            vncPort: 0,
            category: nil,
            favorite: false,
            notes: nil,
            serialnum: enr.serialNumber,
            notify: false,
            alert: false,
            email: nil)
    }

    /// True for a synthetic MDM-only row (negative id).
    var isMDMOnly: Bool { blueskyid < 0 }

    /// Stable 31-bit FNV-1a hash of a string. Deterministic across runs
    /// (unlike `hashValue`), so a synthetic row keeps the same id — and
    /// thus its selection state — between fleet refreshes.
    static func stableHash(_ s: String) -> Int {
        var h: UInt32 = 2166136261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        // Never 0 — a 0 hash would make the synthetic id 0, which reads as
        // a real (non-MDM-only) host.
        return Int(max(1, h & 0x7fff_ffff))
    }
}
