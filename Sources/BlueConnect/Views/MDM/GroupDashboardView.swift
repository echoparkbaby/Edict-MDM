import SwiftUI

/// A fleet-health rollup for a chosen smart group (or the whole fleet).
/// Where the Devices view is per-machine, this answers "how is this slice
/// of the fleet doing" at a glance — compliance, FileVault, OS spread,
/// model mix, and managed-profile drift. Read-only; deeper actions live
/// in Devices.
struct GroupDashboardView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) private var hostStore

    @State private var enrollments: [MDMEnrollment] = []
    @State private var osVersions: [String: String] = [:]
    @State private var fileVault: [String: String] = [:]
    @State private var models: [String: String] = [:]
    @State private var loading = false
    @State private var loadError: String?

    /// nil = every enrolled device. Otherwise a smart group's id.
    @State private var selectedGroupID: UUID?

    // Drift sweep (on demand — it queries ProfileList per device).
    @State private var driftMissing: [String: [DeploymentLog.Entry]] = [:]
    @State private var driftChecking = false
    @State private var driftCheckedAt: Date?

    /// Which summary card is expanded to its device list (nil = none).
    @State private var drillKey: String?

    var body: some View {
        Group {
            if !settings.mdmEnabled || !settings.mdmConfigured {
                notConfigured
            } else if settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                needsDevicesAPI
            } else {
                content
            }
        }
        .task { await refresh() }
    }

    // MARK: - Membership / facts

    private var allDevices: [MDMEnrollment] { enrollments.filter(\.isDevice) }

    private func facts(for enr: MDMEnrollment) -> SmartGroup.DeviceFacts {
        SmartGroup.DeviceFacts(
            osVersion: osVersions[enr.id],
            fileVaultOn: fileVault[enr.id].map { $0 == "true" || $0 == "1" },
            model: models[enr.id],
            matchedBlueSky: bscHost(for: enr) != nil,
            enrolled: enr.isEnabled
        )
    }

    private var selectedGroup: SmartGroup? {
        guard let gid = selectedGroupID else { return nil }
        return settings.smartGroups.first(where: { $0.id == gid })
    }

    /// Devices in scope: a smart group's members, or everything.
    private var scoped: [MDMEnrollment] {
        guard let group = selectedGroup else { return allDevices }
        return allDevices.filter {
            group.contains(facts(for: $0),
                           requireFileVault: settings.mdmRequireFileVault,
                           minOS: settings.mdmMinOSVersion)
        }
    }

    private func bscHost(for enr: MDMEnrollment) -> BlueSkyHost? {
        guard let serial = enr.serialNumber, !serial.isEmpty else { return nil }
        return hostStore.hosts.first {
            ($0.serialnum ?? "").caseInsensitiveCompare(serial) == .orderedSame
        }
    }

    // MARK: - Rollups

    private struct Tally { var compliant = 0, nonCompliant = 0, unknown = 0 }

    private var compliance: Tally {
        var t = Tally()
        for d in scoped {
            switch SmartGroup.compliant(facts(for: d),
                                        requireFileVault: settings.mdmRequireFileVault,
                                        minOS: settings.mdmMinOSVersion) {
            case .some(true): t.compliant += 1
            case .some(false): t.nonCompliant += 1
            case nil: t.unknown += 1
            }
        }
        return t
    }

    private var fileVaultTally: Tally {
        var t = Tally()
        for d in scoped {
            switch facts(for: d).fileVaultOn {
            case .some(true): t.compliant += 1
            case .some(false): t.nonCompliant += 1
            case nil: t.unknown += 1
            }
        }
        return t
    }

    /// Count by value, descending — used for OS-version and model spreads.
    private func distribution(_ pick: (MDMEnrollment) -> String?) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for d in scoped {
            let key = pick(d)?.trimmingCharacters(in: .whitespaces)
            counts[(key?.isEmpty == false ? key! : "Unknown"), default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { (label: $0.key, count: $0.value) }
    }

    private var driftDeviceCount: Int { driftMissing.values.filter { !$0.isEmpty }.count }
    private var driftProfileCount: Int { driftMissing.values.reduce(0) { $0 + $1.count } }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                groupPicker
                if let err = loadError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if loading && enrollments.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Loading fleet…").foregroundStyle(.secondary) }
                } else if scoped.isEmpty {
                    emptyScope
                } else {
                    summaryRow
                    if let drillKey, !drillDevices(drillKey).isEmpty {
                        drillList(drillKey)
                    }
                    breakdownRow
                    distributionRow
                    assignmentsCard
                    driftCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupPicker: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fleet Dashboard").font(.title2).bold()
                Text(selectedGroup.map { "Smart group: \($0.name)" } ?? "All enrolled devices")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selectedGroupID) {
                Text("All devices").tag(UUID?.none)
                ForEach(settings.smartGroups) { g in
                    Text(g.name).tag(UUID?.some(g.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            Button {
                Task { await refresh() }
            } label: {
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .help("Refresh")
            .disabled(loading)
        }
    }

    private var summaryRow: some View {
        let c = compliance
        let total = scoped.count
        let pct = total > 0 ? Int((Double(c.compliant) / Double(total) * 100).rounded()) : 0
        return HStack(spacing: 12) {
            statCard("Devices", "\(total)", "laptopcomputer", .accentColor, drill: "all")
            statCard("Compliant", "\(pct)%", "checkmark.seal.fill",
                     pct >= 90 ? .green : (pct >= 70 ? .yellow : .red),
                     subtitle: "\(c.compliant) of \(total)", drill: "compliant")
            statCard("Out of compliance", "\(c.nonCompliant)", "xmark.seal.fill",
                     c.nonCompliant == 0 ? .secondary : .red, drill: "nonCompliant")
            statCard("Unknown", "\(c.unknown)", "questionmark.circle",
                     c.unknown == 0 ? .secondary : .yellow,
                     subtitle: c.unknown > 0 ? "haven't reported" : nil, drill: "unknown")
        }
    }

    /// Devices matching a summary-card category, for the drill-down list.
    private func drillDevices(_ key: String) -> [MDMEnrollment] {
        switch key {
        case "all": return scoped
        case "compliant", "nonCompliant", "unknown":
            return scoped.filter { d in
                switch SmartGroup.compliant(facts(for: d),
                                            requireFileVault: settings.mdmRequireFileVault,
                                            minOS: settings.mdmMinOSVersion) {
                case .some(true): return key == "compliant"
                case .some(false): return key == "nonCompliant"
                case nil: return key == "unknown"
                }
            }
        default: return []
        }
    }

    private func drillList(_ key: String) -> some View {
        let title: String = ["all": "All devices", "compliant": "Compliant devices",
                             "nonCompliant": "Out of compliance", "unknown": "Not yet reported"][key] ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Button { drillKey = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            ForEach(drillDevices(key), id: \.id) { d in
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    Text(label(for: d)).font(.callout)
                    Spacer()
                    if let os = osVersions[d.id] { Text("macOS \(os)").font(.caption).foregroundStyle(.secondary) }
                    fileVaultChip(for: d)
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func fileVaultChip(for enr: MDMEnrollment) -> some View {
        switch facts(for: enr).fileVaultOn {
        case .some(true): Label("FV", systemImage: "lock.fill").font(.caption2).foregroundStyle(.green)
        case .some(false): Label("FV off", systemImage: "lock.open").font(.caption2).foregroundStyle(.red)
        case nil: EmptyView()
        }
    }

    private var breakdownRow: some View {
        let fv = fileVaultTally
        return VStack(alignment: .leading, spacing: 8) {
            Text("FileVault").font(.headline)
            segmentedBar([
                .init(label: "On", count: fv.compliant, color: .green),
                .init(label: "Off", count: fv.nonCompliant, color: .red),
                .init(label: "Unknown", count: fv.unknown, color: .gray.opacity(0.5))
            ])
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var distributionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            distributionCard("macOS versions", distribution { osVersions[$0.id] })
            distributionCard("Models", distribution { models[$0.id] })
        }
    }

    private var driftCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Managed-profile drift").font(.headline)
                Spacer()
                Button {
                    Task { await checkDrift() }
                } label: {
                    if driftChecking { ProgressView().controlSize(.small) }
                    else { Label("Check now", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(driftChecking)
            }
            if let at = driftCheckedAt {
                if driftProfileCount == 0 {
                    Label("All tracked profiles present across \(scoped.count) device(s).",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Label("\(driftProfileCount) profile(s) missing on \(driftDeviceCount) device(s).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                    ForEach(driftRows, id: \.id) { row in
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                            Text(row.device).font(.caption.bold())
                            Text(row.profiles).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                Text("Last checked \(at, style: .time) — the Scheduling tab can re-push these automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Compares each device's installed profiles against what Edict deployed. Runs a live ProfileList query per device, so it's on demand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var driftRows: [(id: String, device: String, profiles: String)] {
        scoped.compactMap { d in
            guard let missing = driftMissing[d.id], !missing.isEmpty else { return nil }
            return (id: d.id,
                    device: label(for: d),
                    profiles: missing.map(\.name).joined(separator: ", "))
        }
    }

    // MARK: - Reusable bits

    private func statCard(_ title: String, _ value: String, _ icon: String,
                          _ tint: Color, subtitle: String? = nil, drill: String? = nil) -> some View {
        let isOpen = drill != nil && drillKey == drill
        let card = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if drill != nil {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.accentColor.opacity(isOpen ? 0.6 : 0), lineWidth: 1.5))
        return Group {
            if let drill {
                Button { drillKey = (drillKey == drill) ? nil : drill } label: { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
    }

    /// A compact device × profile matrix from the deployment log — at a
    /// glance, which Edict-deployed profiles each device is supposed to
    /// have. Columns are the distinct profile names across the scope.
    private var assignmentsCard: some View {
        let log = DeploymentLog.load()
        let rows = scoped.compactMap { d -> (enr: MDMEnrollment, ids: Set<String>)? in
            let entries = log[d.id] ?? []
            return entries.isEmpty ? nil : (enr: d, ids: Set(entries.map(\.identifier)))
        }
        // Distinct profiles across the scope, keyed by identifier → name.
        var nameByID: [String: String] = [:]
        for d in scoped { for e in (log[d.id] ?? []) where nameByID[e.identifier] == nil { nameByID[e.identifier] = e.name } }
        let columns = nameByID.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Profile assignments").font(.headline)
            if rows.isEmpty {
                Text("Edict hasn't deployed any profiles to these devices yet. Deploys you make from the Profiles tab show up here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Header row of profile names (rotated would be nicer
                        // but vertical text is fiddly — keep them readable).
                        HStack(spacing: 0) {
                            Text("Device").font(.caption2.bold()).frame(width: 150, alignment: .leading)
                            ForEach(columns, id: \.key) { col in
                                Text(col.value).font(.caption2).frame(width: 84, alignment: .center)
                                    .lineLimit(2).truncationMode(.tail)
                            }
                        }
                        Divider()
                        ForEach(rows, id: \.enr.id) { row in
                            HStack(spacing: 0) {
                                Text(label(for: row.enr)).font(.caption).frame(width: 150, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle)
                                ForEach(columns, id: \.key) { col in
                                    Image(systemName: row.ids.contains(col.key) ? "checkmark.circle.fill" : "minus")
                                        .font(.caption)
                                        .foregroundStyle(row.ids.contains(col.key) ? Color.green : Color.secondary.opacity(0.3))
                                        .frame(width: 84, alignment: .center)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
                Text("A ✓ means Edict deployed that profile to the device. Run a drift check below to confirm it's still installed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private struct Segment { var label: String; var count: Int; var color: Color }

    @ViewBuilder
    private func segmentedBar(_ segments: [Segment]) -> some View {
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments.filter { $0.count > 0 }, id: \.label) { s in
                        Rectangle().fill(s.color)
                            .frame(width: max(2, geo.size.width * CGFloat(s.count) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(segments, id: \.label) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text("\(s.label) \(s.count)").font(.caption)
                    }
                }
            }
        }
    }

    private func distributionCard(_ title: String, _ rows: [(label: String, count: Int)]) -> some View {
        let maxCount = max(1, rows.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows.prefix(8), id: \.label) { row in
                    HStack(spacing: 8) {
                        Text(row.label).font(.caption).frame(width: 120, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.accentColor.opacity(0.15))
                                Capsule().fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(4, geo.size.width * CGFloat(row.count) / CGFloat(maxCount)))
                            }
                        }
                        .frame(height: 12)
                        Text("\(row.count)").font(.caption.monospacedDigit())
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func label(for enr: MDMEnrollment) -> String {
        if let stored = settings.mdmDevices.first(where: { $0.id == enr.id })?.label,
           !stored.isEmpty { return stored }
        if let host = bscHost(for: enr) { return host.displayName }
        return enr.serialNumber ?? String(enr.id.prefix(8))
    }

    private var emptyScope: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(selectedGroup == nil ? "No enrolled devices yet" : "No devices match this group")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var notConfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Device Management isn't configured").font(.headline)
            Text("Set the NanoMDM and KMFDDM server URLs and API keys in Settings → Device Management, then come back here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsDevicesAPI: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Devices API not set").font(.headline)
            Text("Enter the Devices API URL in Settings → Device Management. The dashboard fills itself from there.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    @MainActor
    private func refresh() async {
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            enrollments = try await EnrollmentsAPI(settings: settings).list()
            let svc = KMFDDMService(settings: settings)
            var os: [String: String] = [:], fv: [String: String] = [:], mdl: [String: String] = [:]
            for d in allDevices {
                if let values = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.device.operating-system.version"), let v = values.first?.value { os[d.id] = v }
                if let values = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.diskmanagement.filevault.enabled"), let v = values.first?.value { fv[d.id] = v }
                if let values = try? await svc.statusValues(enrollmentID: d.id, pathPrefix: ".StatusItems.device.model.marketing-name"), let v = values.first?.value { mdl[d.id] = v }
            }
            osVersions = os; fileVault = fv; models = mdl
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// For each scoped device, ask for its installed ProfileList and diff
    /// against what Edict deployed. Read-only — surfaces what's missing.
    @MainActor
    private func checkDrift() async {
        driftChecking = true
        defer { driftChecking = false }
        let nano = NanoMDMService(settings: settings)
        let api = EnrollmentsAPI(settings: settings)
        let log = DeploymentLog.load()
        var result: [String: [DeploymentLog.Entry]] = [:]
        for d in scoped {
            let tracked = log[d.id] ?? []
            guard !tracked.isEmpty else { continue }
            guard let uuid = try? await nano.requestProfileList(enrollmentID: d.id) else { continue }
            _ = try? await nano.push(enrollmentIDs: d.id)
            var installed: Set<String>?
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                if let res = try? await api.commandResult(uuid: uuid) {
                    installed = Set(res.array("ProfileList").compactMap { $0["PayloadIdentifier"] as? String })
                    break
                }
            }
            guard let present = installed else { continue }
            let missing = tracked.filter { !present.contains($0.identifier) }
            if !missing.isEmpty { result[d.id] = missing }
        }
        driftMissing = result
        driftCheckedAt = Date()
    }
}
