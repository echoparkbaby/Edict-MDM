import Foundation
import SwiftUI

/// Runs Edict's scheduled automation while the app is open. A single
/// async loop wakes every few minutes, runs any due ScheduledTask
/// headlessly (building services from settings), and stamps lastRun.
/// Not a daemon — tasks only run while the console is running, which is
/// the intended model (leave it open on an always-on Mac).
@MainActor
@Observable
final class MDMScheduler {
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private weak var notifier: HostStateNotifier?
    @ObservationIgnored private weak var activity: ActivityLog?

    /// Human-readable record of the last run, surfaced in the UI.
    private(set) var lastActivity: String?

    func start(settings: SettingsStore, notifier: HostStateNotifier, activity: ActivityLog) {
        self.settings = settings
        self.notifier = notifier
        self.activity = activity
        guard task == nil else { return }
        task = Task { await loop() }
    }

    private func loop() async {
        // Wait a bit after launch so the app settles, then tick every 5 min.
        try? await Task.sleep(for: .seconds(90))
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// Run all due tasks. Public so a "Run now" button can force a pass.
    func tick() async {
        guard let settings, settings.mdmEnabled, settings.mdmConfigured else { return }
        let now = Date()
        var tasks = settings.scheduledTasks
        var changed = false
        for idx in tasks.indices where tasks[idx].isDue(now: now) {
            await run(tasks[idx])
            tasks[idx].lastRunEpoch = now.timeIntervalSince1970
            changed = true
        }
        if changed { settings.scheduledTasks = tasks }
    }

    private func run(_ t: ScheduledTask) async {
        guard let settings else { return }
        switch t.kind {
        case .fleetCheck:        await fleetCheck(settings)
        case .remediateFileVault: await remediateFileVault(settings)
        case .reapplyProfile:    await reapply(t, settings)
        }
    }

    // MARK: - Task implementations

    private func enrolledDevices(_ settings: SettingsStore) async -> [MDMEnrollment] {
        guard !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              let list = try? await EnrollmentsAPI(settings: settings).list()
        else { return [] }
        return list.filter(\.isDevice)
    }

    private func facts(_ devices: [MDMEnrollment], _ settings: SettingsStore)
        async -> [String: SmartGroup.DeviceFacts] {
        let svc = KMFDDMService(settings: settings)
        var out: [String: SmartGroup.DeviceFacts] = [:]
        for d in devices {
            let os = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.device.operating-system.version").first?.value
            let fv = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.diskmanagement.filevault.enabled").first?.value
            let mdl = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.device.model.marketing-name").first?.value
            out[d.id] = SmartGroup.DeviceFacts(
                osVersion: os ?? nil,
                fileVaultOn: (fv ?? nil).map { $0 == "true" || $0 == "1" },
                model: mdl ?? nil,
                matchedBlueSky: false,
                enrolled: d.isEnabled)
        }
        return out
    }

    private func fleetCheck(_ settings: SettingsStore) async {
        let devices = await enrolledDevices(settings)
        // Cert expiry
        if let cert = try? await EnrollmentsAPI(settings: settings).pushCert(),
           let days = cert.daysLeft, days < 30 {
            notifier?.notify(title: "MDM push certificate expiring",
                             body: "Expires in \(days) days. Renew before then or MDM goes dark.",
                             identifier: "edict-cert")
        }
        note("Fleet check: \(devices.count) devices")
    }

    private func remediateFileVault(_ settings: SettingsStore) async {
        let devices = await enrolledDevices(settings)
        let f = await facts(devices, settings)
        let nano = NanoMDMService(settings: settings)
        var fixed = 0
        for d in devices where f[d.id]?.fileVaultOn == false {
            if (try? await nano.installProfile(enrollmentID: d.id,
                                               profile: ProfilePayloads.fileVault(deferEnable: true))) != nil {
                _ = try? await nano.push(enrollmentIDs: d.id)
                fixed += 1
            }
        }
        if fixed > 0 {
            notifier?.notify(title: "FileVault remediation", body: "Pushed FileVault to \(fixed) device(s).", identifier: "edict-sched")
            activity?.record(.category, title: "Scheduled: FileVault pushed to \(fixed) device(s)")
        }
        note("FileVault sweep: \(fixed) remediated")
    }

    private func reapply(_ t: ScheduledTask, _ settings: SettingsStore) async {
        guard let gid = t.groupID, let group = settings.smartGroups.first(where: { $0.id == gid }),
              let pid = t.savedProfileID,
              let profile = SavedProfilesStore.load().first(where: { $0.id == pid })
        else { return }
        let devices = await enrolledDevices(settings)
        let f = await facts(devices, settings)
        let nano = NanoMDMService(settings: settings)
        var n = 0
        for d in devices {
            guard let facts = f[d.id],
                  group.contains(facts, requireFileVault: settings.mdmRequireFileVault, minOS: settings.mdmMinOSVersion)
            else { continue }
            if (try? await nano.installProfile(enrollmentID: d.id, profile: profile.data)) != nil {
                _ = try? await nano.push(enrollmentIDs: d.id)
                n += 1
            }
        }
        if n > 0 {
            activity?.record(.category, title: "Scheduled: re-applied \(profile.name) to \(n) in \(group.name)")
        }
        note("Re-applied \(profile.name) → \(n) in \(group.name)")
    }

    private func note(_ s: String) {
        let f = DateFormatter(); f.timeStyle = .short
        lastActivity = "\(f.string(from: Date())) — \(s)"
    }
}
