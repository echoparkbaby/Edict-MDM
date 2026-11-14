import SwiftUI

struct MDMOverviewPane: View {
    let devices: [MDMEnrollment]
    let facts: DashboardFacts
    let snapshots: [String: MDMStatusSnapshot]
    let errors: [String: String]
    let loadError: String?
    let cert: PushCertInfo?
    let excludedIDs: Set<String>
    let onNavigate: (SidebarFilter) -> Void
    let onSelect: (MDMEnrollment) -> Void
    @Environment(MDMCommandStore.self) private var commands
    @Environment(MDMFleetIndex.self) private var fleet
    @Environment(MDMScheduler.self) private var scheduler
    @EnvironmentObject private var settings: SettingsStore

    private var evaluated: [MDMEnrollment] { devices.filter { !excludedIDs.contains($0.id) } }
    private var unknown: [MDMEnrollment] { evaluated.filter { facts.compliant(for: $0) == nil } }
    private var failing: [MDMEnrollment] { evaluated.filter { facts.compliant(for: $0) == false } }
    private var pending: [MDMCommandStore.Entry] {
        let ids = Set(devices.map(\.id))
        return commands.entries.filter { $0.server == settings.nanoMDMBaseURL && $0.state.isPending && ids.contains($0.target) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                health
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { metrics }
                    VStack(spacing: 12) { metrics }
                }
                workQueue
                recentActivity
                DisclosureGroup("Fleet composition") {
                    PrismChart(devices: devices, facts: facts, onSelect: onSelect).padding(.top, 8)
                }
                if !excludedIDs.isEmpty {
                    DisclosureGroup("\(excludedIDs.count) devices excluded from baseline evaluation") {
                        ForEach(devices.filter { excludedIDs.contains($0.id) }) { device in
                            HStack {
                                Text(facts.label(for: device))
                                Spacer()
                                Button("Include in evaluation") { settings.setIgnoredForAttention(device.id, false) }
                            }.padding(.vertical, 6)
                        }
                    }.font(.callout)
                }
            }.padding(20)
        }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Management health").font(.headline)
            HStack(spacing: 18) {
                Label(loadError == nil ? "Device inventory available" : "Device inventory unavailable",
                      systemImage: loadError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(loadError == nil ? Color.primary : .orange)
                if let days = cert?.daysLeft {
                    Label("Push certificate: \(days)d remaining", systemImage: "key.horizontal")
                        .foregroundStyle(days < 30 ? Color.orange : .secondary)
                } else { Label("Certificate status unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary) }
            }.font(.callout)
            Text("\(evaluated.count - unknown.count) of \(evaluated.count) devices have enough available evidence for the configured baseline.")
                .font(.callout).foregroundStyle(.secondary)
            if !settings.mdmComplianceConfigured {
                Label("No baseline configured. Set a minimum OS version or FileVault requirement in Settings.",
                      systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
            if !errors.isEmpty {
                Label("\(errors.count) device status reads failed. Last-known values are retained.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Text("Automation runs on this Mac while Edict is open. \(scheduler.lastActivity ?? "No runs recorded this session.")")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var metrics: some View {
        metric("Managed devices", count: devices.filter(\.isEnabled).count, icon: "laptopcomputer", route: .mdmDevices)
        metric("Outside baseline", count: failing.count, icon: "exclamationmark.shield", route: .mdmDevices)
        metric("Unknown evidence", count: unknown.count, icon: "questionmark.circle", route: .mdmDevices)
        metric("Pending commands", count: pending.count, icon: "clock", route: .mdmActivity)
    }

    private func metric(_ title: String, count: Int, icon: String, route: SidebarFilter) -> some View {
        Button {
            switch title {
            case "Unknown evidence": fleet.deviceQuery = "unknown"
            case "Outside baseline": fleet.deviceQuery = "not compliant"
            case "Managed devices": fleet.deviceQuery = "enrolled"
            default: fleet.deviceQuery = ""
            }
            fleet.activityPendingOnly = title == "Pending commands"
            onNavigate(route)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
                Text(count, format: .number).font(.largeTitle.monospacedDigit()).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var workQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs action").font(.headline)
            Text("Select a device to inspect its evidence and available actions.")
                .font(.callout).foregroundStyle(.secondary)
            let needs = evaluated.filter {
                facts.attentionScore($0).score > 0 || (settings.mdmComplianceConfigured && facts.compliant(for: $0) == nil)
                    || snapshots[$0.id]?.updateFailure != nil
            }
            if needs.isEmpty {
                ContentUnavailableView("No outstanding findings", systemImage: "checkmark.circle",
                                       description: Text("No issues were found in the available evidence for this scope."))
            } else {
                ForEach(needs) { device in
                    Button { onSelect(device) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(facts.label(for: device)).foregroundStyle(.primary)
                                Text(reasons(device)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(facts.lastSeenText(device)).font(.callout).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func reasons(_ device: MDMEnrollment) -> String {
        var reasons = facts.attentionScore(device).issues
        if let error = errors[device.id] { reasons.append("Status read failed: \(error)") }
        else if facts.compliant(for: device) == nil {
            reasons.append(settings.mdmComplianceConfigured ? "Evidence missing or stale" : "Baseline not configured")
        }
        if let failure = snapshots[device.id]?.updateFailure { reasons.append("Update failed: \(failure)") }
        return reasons.joined(separator: " · ")
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent commands").font(.headline)
                Spacer()
                Button("View activity", systemImage: "arrow.right") { onNavigate(.mdmActivity) }
            }
            let ids = Set(devices.map(\.id))
            let recent = commands.entries.filter { $0.server == settings.nanoMDMBaseURL && ids.contains($0.target) }
            if recent.isEmpty {
                Text("Commands issued from this console will appear here with device results.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(recent.prefix(5))) { command in
                HStack {
                    Text(command.kind)
                    Spacer()
                    Text(command.state.rawValue).foregroundStyle(.secondary)
                    Text(command.createdAt, style: .relative).foregroundStyle(.secondary)
                }.font(.callout)
            }
        }
    }
}
