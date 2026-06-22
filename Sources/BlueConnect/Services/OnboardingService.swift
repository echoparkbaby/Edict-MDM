import Foundation

/// Applies the onboarding baseline — the saved profiles + DDM sets every new
/// Mac should receive — to a freshly-enrolled device. The enrollment profile
/// only enrolls a Mac; this is what actually installs the baseline afterward.
///
/// Auto-runs from the fleet refresh for devices that enrolled after onboarding
/// was switched on, and is also callable per-device from the Onboard button.
@MainActor
struct OnboardingService {
    let settings: SettingsStore
    let activity: ActivityLog

    struct Outcome { var profiles: Int; var sets: Int; var failures: Int }

    /// Devices an auto-run should baseline: real, enabled Macs that enrolled
    /// at/after the cutoff and haven't been onboarded yet. Pure + testable.
    nonisolated static func devicesToOnboard(_ enrollments: [MDMEnrollment],
                                             enabledAt: Double,
                                             onboarded: Set<String>) -> [MDMEnrollment] {
        enrollments.filter { d in
            d.isDevice && d.isEnabled && !onboarded.contains(d.id)
                && (d.createdDate.map { $0.timeIntervalSince1970 >= enabledAt } ?? false)
        }
    }

    /// Apply the baseline to one device: associate the chosen DDM sets (KMFDDM
    /// then pushes their declarations) and install the chosen saved profiles.
    /// Records deployments for drift tracking and marks the device onboarded.
    @discardableResult
    func onboard(_ enrollmentID: String, deviceLabel: String) async -> Outcome {
        var profiles = 0, sets = 0, failures = 0

        let kmf = KMFDDMService(settings: settings)
        for set in settings.mdmOnboardSets {
            do { try await kmf.assign(enrollmentID: enrollmentID, toSet: set); sets += 1 }
            catch { failures += 1 }
        }

        let saved = SavedProfilesStore.load()
        let nano = NanoMDMService(settings: settings)
        for pid in settings.mdmOnboardProfileIDs {
            guard let sp = saved.first(where: { $0.id == pid }) else { continue }
            do {
                _ = try await nano.installProfile(enrollmentID: enrollmentID, profile: sp.data)
                _ = try? await nano.push(enrollmentIDs: enrollmentID)
                DeploymentLog.record(profileData: sp.data, name: sp.name, to: [enrollmentID],
                                     nowEpoch: Date().timeIntervalSince1970)
                profiles += 1
            } catch { failures += 1 }
        }

        settings.markOnboarded(enrollmentID)
        activity.record(.category, title: "Onboarded \(deviceLabel)",
                        detail: "\(profiles) profile\(profiles == 1 ? "" : "s"), \(sets) set\(sets == 1 ? "" : "s")"
                              + (failures > 0 ? ", \(failures) failed" : ""))
        return Outcome(profiles: profiles, sets: sets, failures: failures)
    }

    /// The union of sets + profile IDs from the smart groups a device matches
    /// — its "group policy" baseline. Pure + testable.
    nonisolated static func groupBaseline(for facts: SmartGroup.DeviceFacts,
                                          in groups: [SmartGroup],
                                          requireFileVault: Bool, minOS: String)
    -> (sets: [String], profiles: [UUID]) {
        var sets: [String] = [], profiles: [UUID] = []
        for g in groups where g.hasOnboardingBaseline
            && g.contains(facts, requireFileVault: requireFileVault, minOS: minOS) {
            for s in g.onboardSets where !sets.contains(s) { sets.append(s) }
            for p in g.onboardProfileIDs where !profiles.contains(p) { profiles.append(p) }
        }
        return (sets, profiles)
    }

    /// Ensure every device has the baseline of each smart group it matches —
    /// the group-policy enforcement. Idempotent: a set is assigned once per
    /// device (tracked in settings) and a profile is installed only if the
    /// deployment log doesn't already have it. Runs each refresh, so a Mac
    /// that starts matching a group later (once it reports facts) is covered.
    /// Returns how many devices were changed.
    @discardableResult
    func enforceGroupBaselines(_ devices: [(id: String, facts: SmartGroup.DeviceFacts)]) async -> Int {
        let groups = settings.smartGroups.filter(\.hasOnboardingBaseline)
        guard !groups.isEmpty else { return 0 }
        let saved = SavedProfilesStore.load()
        let deployed = DeploymentLog.load()
        var payloadCache: [UUID: String?] = [:]
        func payloadID(_ pid: UUID) -> String? {
            if let c = payloadCache[pid] { return c }
            let v = saved.first { $0.id == pid }.flatMap { DeploymentLog.payloadIdentifier($0.data) }
            payloadCache[pid] = v
            return v
        }
        let kmf = KMFDDMService(settings: settings)
        let nano = NanoMDMService(settings: settings)
        var changed = 0
        for (id, facts) in devices {
            let bl = Self.groupBaseline(for: facts, in: groups,
                                        requireFileVault: settings.mdmRequireFileVault,
                                        minOS: settings.mdmMinOSVersion)
            guard !bl.sets.isEmpty || !bl.profiles.isEmpty else { continue }
            var did = false
            for set in bl.sets where !settings.hasAppliedGroupSet(deviceID: id, set: set) {
                do {
                    try await kmf.assign(enrollmentID: id, toSet: set)
                    settings.markAppliedGroupSet(deviceID: id, set: set)
                    did = true
                } catch {}
            }
            let already = Set((deployed[id] ?? []).map(\.identifier))
            for pid in bl.profiles {
                guard let payload = payloadID(pid), !already.contains(payload),
                      let sp = saved.first(where: { $0.id == pid }) else { continue }
                do {
                    _ = try await nano.installProfile(enrollmentID: id, profile: sp.data)
                    _ = try? await nano.push(enrollmentIDs: id)
                    DeploymentLog.record(profileData: sp.data, name: sp.name, to: [id],
                                         nowEpoch: Date().timeIntervalSince1970)
                    did = true
                } catch {}
            }
            if did {
                changed += 1
                let label = settings.mdmDevices.first { $0.id == id }?.label ?? id
                activity.record(.category, title: "Applied group baseline to \(label)",
                                detail: "\(bl.sets.count) set\(bl.sets.count == 1 ? "" : "s"), \(bl.profiles.count) profile\(bl.profiles.count == 1 ? "" : "s")")
            }
        }
        return changed
    }

    /// Auto-onboard every newly-enrolled device. Returns how many were done.
    @discardableResult
    func autoOnboardNewDevices(_ enrollments: [MDMEnrollment]) async -> Int {
        guard settings.mdmOnboardingEnabled, settings.hasOnboardingBaseline else { return 0 }
        let targets = Self.devicesToOnboard(enrollments,
                                            enabledAt: settings.mdmOnboardingEnabledAt,
                                            onboarded: settings.mdmOnboardedIDs)
        for d in targets {
            let label = settings.mdmDevices.first { $0.id == d.id }?.label
                ?? d.serialNumber ?? String(d.id.prefix(8))
            _ = await onboard(d.id, deviceLabel: label)
        }
        return targets.count
    }
}
