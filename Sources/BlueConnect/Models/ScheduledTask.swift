import Foundation

/// A recurring automation Edict runs while the app is open. Lightweight,
/// interval-based (no cron) — the MSP leaves the console running on an
/// always-on Mac and these keep the fleet in line between glances.
struct ScheduledTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: Kind
    var intervalHours: Double = 6
    var enabled: Bool = true
    /// Epoch seconds of the last run (0 = never). Persisted.
    var lastRunEpoch: Double = 0
    /// Target smart group (for group-scoped kinds). nil = all devices.
    var groupID: UUID?
    /// Saved profile to (re)apply, for .reapplyProfile.
    var savedProfileID: UUID?

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case fleetCheck = "Fleet check + notify"
        case remediateFileVault = "Auto-enable FileVault on non-compliant"
        case reapplyProfile = "Re-apply a saved profile to a group"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .fleetCheck: return "Refresh the device list and push notifications for new enrollments, non-compliance, and cert expiry — even when you're not looking."
            case .remediateFileVault: return "Push the FileVault profile to any Mac reporting FileVault off."
            case .reapplyProfile: return "Re-deploy a saved profile to a smart group's members to correct drift."
            }
        }
    }

    var lastRun: Date? { lastRunEpoch == 0 ? nil : Date(timeIntervalSince1970: lastRunEpoch) }
    func isDue(now: Date) -> Bool {
        guard enabled else { return false }
        guard let last = lastRun else { return true }
        return now.timeIntervalSince(last) >= intervalHours * 3600
    }
}
