import Foundation

struct MDMDriftAssessment {
    enum Outcome { case verified, waiting, failed, untracked }
    var outcome: Outcome
    var missing: [DeploymentLog.Entry] = []
    var detail: String?
    var checkedAt: Date = Date()

    static func evaluate(_ result: CommandResult?, tracked: [DeploymentLog.Entry]) -> Self {
        guard !tracked.isEmpty else { return Self(outcome: .untracked) }
        guard let result else { return Self(outcome: .waiting, detail: "No device response yet") }
        guard result.status != "NotNow" else { return Self(outcome: .waiting, detail: "Deferred by device") }
        do {
            let profiles = try result.acknowledgedArray("ProfileList")
            let ids = Set(profiles.compactMap { $0["PayloadIdentifier"] as? String })
            guard profiles.allSatisfy({ ($0["PayloadIdentifier"] as? String)?.isEmpty == false }) else {
                return Self(outcome: .failed, detail: "ProfileList contained an invalid profile identifier")
            }
            return Self(outcome: .verified, missing: tracked.filter { !ids.contains($0.identifier) })
        } catch { return Self(outcome: .failed, detail: error.localizedDescription) }
    }
}
