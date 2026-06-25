import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// A fleet-health rollup for a chosen smart group (or the whole fleet).
/// Where the Devices view is per-machine, this answers "how is this slice
/// of the fleet doing" at a glance — compliance, FileVault, OS spread,
/// model mix, and managed-profile drift. Read-only; deeper actions live
/// in Devices.
struct GroupDashboardView: View {
    /// The main window's host selection — clicking a row in the Prism
    /// table selects that Mac so the right-hand inspector opens on it.
    @Binding var selection: Set<Int>

    @EnvironmentObject private var settings: SettingsStore
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @Environment(MunkiReportInventoryStore.self) private var mrInventory

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

    // Prism saved views — now scope bookmarks (the Breakdown card shows every
    // attribute at once, so a view just captures which scope to flip to).
    @State private var savedViews: [PrismView] = []
    @State private var activeViewID: UUID?
    /// enrollmentID → count of profiles Edict deployed (for the profile
    /// attribute), loaded alongside the facts.
    @State private var deploymentCounts: [String: Int] = [:]
    /// Cached deployment log (enrollmentID → entries) loaded on refresh, so
    /// the profile-assignments matrix doesn't read the JSON file every render.
    @State private var deploymentLog: [String: [DeploymentLog.Entry]] = [:]
    @State private var showSaveView = false
    @State private var saveViewName = ""

    // Prism explorer: category rail + sortable device table. Mirrors
    // Kandji Prism's category list — each is a fleet-wide view of one
    // data domain, pulled from MunkiReport (via blueconnect_api.php) + MDM.
    enum Category: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case attention = "Needs Attention"
        case devices = "Devices"
        case security = "Security"
        case apps = "Apps"
        case profiles = "Profiles"
        case users = "Local Users"
        case storage = "Storage"
        case updates = "Software Updates"
        case drift = "Drift"
        case appFirewall = "Application Firewall"
        case gatekeeper = "Gatekeeper & SIP"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .summary: return "chart.bar.xaxis"
            case .attention: return "exclamationmark.triangle"
            case .devices: return "laptopcomputer"
            case .security: return "lock.shield"
            case .apps: return "app.badge"
            case .profiles: return "doc.on.doc"
            case .users: return "person.2"
            case .storage: return "internaldrive"
            case .updates: return "arrow.down.circle"
            case .drift: return "arrow.triangle.2.circlepath"
            case .appFirewall: return "firewall"
            case .gatekeeper: return "checkmark.shield"
            }
        }
    }
    @State private var category: Category = .devices
    @State private var tableSearch = ""
    /// Inventory-table sort: which column index, ascending or not. nil keeps
    /// the rows' natural (pre-sorted) order.
    @State private var invSortCol: Int?
    @State private var invSortAsc = true
    /// Per-category dragged column widths ({category: [width]}), persisted.
    @AppStorage("invColWidthsJSON") private var invColWidthsRaw = ""
    /// Column width captured at drag start (see PrismDeviceTable.resizeStart).
    @State private var invResizeStart: CGFloat?
    /// Searchable "narrow to one Mac" popover state — replaces a flat Picker
    /// that became unusable at fleet scale (100+ Macs in a dropdown).
    @State private var showDevicePicker = false
    @State private var devicePickerQuery = ""
    /// Which Mac the category tables (Apps, Local Users, …) are scoped to.
    /// nil = all Macs, rolled up; a value = just that machine's rows.
    @State private var inventoryDeviceID: String?
    /// A rolled-up Apps / Local Users row expanded to show which Macs it's on.
    @State private var expandedInventoryRow: String?
    /// Live firewall + SIP pulled from MDM (enrollmentID → facts), overriding
    /// MunkiReport for those Macs. Populated by the "Pull via MDM" action.
    @State private var mdmSec: [String: MDMSecurityFacts] = [:]
    /// When each device's MDM SecurityInfo was last pulled — drives the
    /// "checked Xm ago" line and persists with the facts so firewall/SIP
    /// survive relaunch (cached until the next Pull via MDM).
    @State private var mdmSecAt: [String: Date] = [:]
    @State private var pullingSecurity = false
    @State private var enablingAll = false
    @State private var editingGroup: SmartGroup?
    @State private var pushCert: PushCertInfo?

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
        .onChange(of: settings.mdmRequireFileVault) { _, _ in rebuildFacts() }
        .onChange(of: settings.mdmMinOSVersion) { _, _ in rebuildFacts() }
        .onChange(of: selectedGroupID) { _, _ in inventoryDeviceID = nil; expandedInventoryRow = nil }
        .onChange(of: category) { _, _ in expandedInventoryRow = nil; invSortCol = nil }
        .onChange(of: inventoryDeviceID) { _, _ in expandedInventoryRow = nil }
    }

    // MARK: - Membership / facts

    private var allDevices: [MDMEnrollment] { enrollments.filter(\.isDevice) }

    /// Cached per-device facts the device table + chart read. Rebuilt when
    /// the fleet reloads, a drift check finishes, or the compliance
    /// baseline changes — not on every render — so the dashboard isn't
    /// re-deriving compliance, labels, and buckets for the whole fleet on
    /// each redraw.
    @State private var df: DashboardFacts = .empty

    private func rebuildFacts() {
        df = DashboardFacts(osVersions: osVersions, fileVault: fileVault, models: models,
                            hosts: hostStore.hosts, deviceLabels: deviceLabels,
                            requireFileVault: settings.mdmRequireFileVault, minOS: settings.mdmMinOSVersion,
                            driftMissing: driftMissing, deploymentCounts: deploymentCounts)
    }
    private var deviceLabels: [String: String] {
        var m: [String: String] = [:]
        for dev in settings.mdmDevices where !dev.label.isEmpty { m[dev.id] = dev.label }
        return m
    }

    private func facts(for enr: MDMEnrollment) -> SmartGroup.DeviceFacts { df.facts(for: enr) }

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

    private func bscHost(for enr: MDMEnrollment) -> BlueSkyHost? { df.bscHost(for: enr) }

    /// Devices the dashboard grades — scoped minus the ones the operator hid
    /// (e.g. Macs too old for DDM that will never report). They drop out of
    /// compliance, the attention strip, and the breakdown; the Hidden section
    /// lists them with an Unhide.
    private var graded: [MDMEnrollment] {
        scoped.filter { !settings.isIgnoredForAttention($0.id) }
    }
    private var hiddenFromAttention: [MDMEnrollment] {
        scoped.filter { settings.isIgnoredForAttention($0.id) }
    }

    // MARK: - Rollups

    private struct Tally { var compliant = 0, nonCompliant = 0, unknown = 0 }

    private var compliance: Tally {
        var t = Tally()
        for d in graded {
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

    private var driftDeviceCount: Int { driftMissing.values.filter { !$0.isEmpty }.count }
    private var driftProfileCount: Int { driftMissing.values.reduce(0) { $0 + $1.count } }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                categoryRail
                Divider()
                categoryPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSaveView) { saveViewSheet }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupPicker
            if let err = loadError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: - Category rail (the Prism left list)

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Category.allCases) { c in
                let on = category == c
                Button { category = c } label: {
                    HStack(spacing: 8) {
                        Image(systemName: c.icon).frame(width: 16)
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(c.rawValue).font(.callout).fontWeight(on ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 178, alignment: .top)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Category panel

    @ViewBuilder
    private var categoryPanel: some View {
        if loading && enrollments.isEmpty {
            VStack { Spacer(); HStack { ProgressView().controlSize(.small); Text("Loading fleet…").foregroundStyle(.secondary) }; Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scoped.isEmpty {
            emptyScope
        } else {
            switch category {
            case .devices, .security:
                PrismDeviceTable(title: category.rawValue, security: category == .security,
                                 devices: scoped, facts: df, selection: $selection,
                                 enablingAll: enablingAll,
                                 onEnableReporting: { Task { await enableReportingAll() } })
            case .summary:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        savedViewsBar
                        heroCard
                        attentionStrip
                        if let drillKey, !drillDevices(drillKey).isEmpty { drillList(drillKey) }
                        PrismChart(devices: graded, facts: df)
                        hiddenSection
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .profiles:
                ScrollView { assignmentsCard.padding(18) }
            case .drift:
                ScrollView { driftCard.padding(18) }
            case .apps:
                inventoryTable(columns: appColumns, rows: appRows,
                               source: InvSource(name: "MunkiReport", checkedAt: mrOldestFetch(), note: nil,
                                                 coverage: mrCoverage()),
                               drillDevices: inventoryDeviceID == nil ? { macsWithApp($0) } : nil)
            case .users:
                inventoryTable(columns: userColumns, rows: userRows,
                               source: InvSource(name: "MunkiReport", checkedAt: mrOldestFetch(),
                                                 note: "MDM can't enumerate local accounts", coverage: mrCoverage()),
                               drillDevices: inventoryDeviceID == nil ? { macsWithUser($0) } : nil)
            case .storage:
                inventoryTable(columns: [("Device", 180), ("Free", 100), ("Total", 100), ("Encrypted", 100), ("SMART", 90)], rows: storageRows,
                               source: InvSource(name: "MunkiReport", checkedAt: mrOldestFetch(), note: nil,
                                                 coverage: mrCoverage()),
                               deviceRows: true)
            case .updates:
                inventoryTable(columns: [("Device", 180), ("Pending", 90), ("Last check", 170)], rows: updateRows,
                               source: InvSource(name: "MunkiReport", checkedAt: mrOldestFetch(), note: nil,
                                                 coverage: mrCoverage()),
                               deviceRows: true)
            case .attention:
                inventoryTable(columns: [("Device", 180), ("Issues", 400), ("Score", 64)], rows: attentionRows,
                               deviceRows: true)
            case .appFirewall:
                inventoryTable(columns: [("Device", 180), ("State", 150), ("Stealth", 90), ("Logging", 90)], rows: firewallRows,
                               source: InvSource(name: "MDM live, MunkiReport fallback", checkedAt: mdmNewestPull(),
                                                 note: "Pull via MDM to refresh", coverage: mdmSecCoverage()),
                               deviceRows: true,
                               onPullMDM: { Task { await pullSecurityViaMDM() } })
            case .gatekeeper:
                inventoryTable(columns: [("Device", 180), ("Gatekeeper", 130), ("SIP", 130), ("Activation Lock", 140)], rows: gatekeeperRows,
                               source: InvSource(name: "SIP via MDM; Gatekeeper/Lock MunkiReport", checkedAt: mdmNewestPull(),
                                                 note: "Pull via MDM to refresh", coverage: mdmSecCoverage()),
                               deviceRows: true,
                               onPullMDM: { Task { await pullSecurityViaMDM() } })
            }
        }
    }

    // MARK: - MunkiReport-backed category tables (Kandji Prism style)

    private func attentionScore(_ d: MDMEnrollment) -> (score: Int, issues: [String]) { df.attentionScore(d) }

    /// The Macs the category tables show: all in scope, or the one the
    /// operator picked from the table's Mac menu.
    private var inventoryScope: [MDMEnrollment] {
        guard let id = inventoryDeviceID else { return scoped }
        return scoped.filter { $0.id == id }
    }

    private var attentionRows: [(id: String, cells: [String])] {
        inventoryScope.compactMap { d -> (id: String, cells: [String])? in
            let r = attentionScore(d)
            guard r.score > 0 else { return nil }
            return (id: d.id, cells: [label(for: d), r.issues.joined(separator: " · "), "\(r.score)"])
        }
        .sorted { (Int($0.cells[2]) ?? 0) > (Int($1.cells[2]) ?? 0) }
    }

    private func mr(for d: MDMEnrollment) -> MRHostInventory? {
        guard let s = d.serialNumber?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return mrInventory.bySerial[s]
    }

    // Apps / Local Users drop the per-machine "Device" column: the Mac menu
    // already says which machine you're looking at, and the rolled-up "All
    // Macs" view counts machines instead of listing one row each.
    private var appColumns: [(String, CGFloat)] {
        inventoryDeviceID == nil
            ? [("Application", 340), ("Version", 120), ("On Macs", 110)]
            : [("Application", 340), ("Version", 120), ("Status", 120)]
    }
    private var userColumns: [(String, CGFloat)] {
        inventoryDeviceID == nil
            ? [("User", 180), ("Admin", 150), ("On Macs", 90)]
            : [("User", 180), ("Admin", 90), ("Last login", 150)]
    }

    private var appRows: [(id: String, cells: [String])] {
        if let id = inventoryDeviceID {
            // One Mac: its installed apps.
            guard let d = scoped.first(where: { $0.id == id }),
                  let apps = mr(for: d)?.managed_installs else { return [] }
            return apps.filter(\.installed).map { a in
                (id: "\(id)|\(a.id)", cells: [a.display_name ?? a.name ?? "?", a.version ?? "—", a.status ?? "installed"])
            }.sorted { $0.cells[0].localizedCaseInsensitiveCompare($1.cells[0]) == .orderedAscending }
        }
        // All Macs: one row per app, with how many Macs have it.
        var byApp: [String: (versions: Set<String>, devices: Set<String>)] = [:]
        for d in scoped {
            guard let apps = mr(for: d)?.managed_installs else { continue }
            for a in apps where a.installed {
                let name = a.display_name ?? a.name ?? "?"
                var e = byApp[name] ?? (versions: [], devices: [])
                e.versions.insert(a.version ?? "—")
                e.devices.insert(d.id)
                byApp[name] = e
            }
        }
        let total = scoped.count
        return byApp.map { name, e in
            let version = e.versions.count == 1 ? (e.versions.first ?? "—") : "varies"
            return (id: name, cells: [name, version, "\(e.devices.count) of \(total)"])
        }.sorted { $0.cells[0].localizedCaseInsensitiveCompare($1.cells[0]) == .orderedAscending }
    }

    private var userRows: [(id: String, cells: [String])] {
        if let id = inventoryDeviceID {
            // One Mac: its local accounts.
            guard let d = scoped.first(where: { $0.id == id }),
                  let users = mr(for: d)?.users else { return [] }
            return users.map { u in
                let last = u.lastLoginDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
                return (id: "\(id)|\(u.id)", cells: [u.shortName, (u.admin?.isOn == true) ? "Admin" : "", last])
            }.sorted { $0.cells[0].localizedCaseInsensitiveCompare($1.cells[0]) == .orderedAscending }
        }
        // All Macs: one row per username, with admin + machine counts.
        var byUser: [String: (adminOn: Int, devices: Set<String>)] = [:]
        for d in scoped {
            guard let users = mr(for: d)?.users else { continue }
            for u in users {
                var e = byUser[u.shortName] ?? (adminOn: 0, devices: [])
                e.devices.insert(d.id)
                if u.admin?.isOn == true { e.adminOn += 1 }
                byUser[u.shortName] = e
            }
        }
        return byUser.map { name, e in
            (id: name, cells: [name, e.adminOn > 0 ? "Admin on \(e.adminOn)" : "—", "\(e.devices.count)"])
        }.sorted { $0.cells[0].localizedCaseInsensitiveCompare($1.cells[0]) == .orderedAscending }
    }

    /// Which Macs (by label) have a given app installed — for the rolled-up
    /// Apps row's drill-down.
    private func macsWithApp(_ appName: String) -> [String] {
        scoped.compactMap { d in
            guard let apps = mr(for: d)?.managed_installs else { return nil }
            return apps.contains { $0.installed && ($0.display_name ?? $0.name ?? "?") == appName } ? label(for: d) : nil
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Which Macs (by label) have a given local account — for the rolled-up
    /// Local Users row's drill-down.
    private func macsWithUser(_ shortName: String) -> [String] {
        scoped.compactMap { d in
            guard let users = mr(for: d)?.users else { return nil }
            return users.contains { $0.shortName == shortName } ? label(for: d) : nil
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var storageRows: [(id: String, cells: [String])] {
        inventoryScope.compactMap { d in
            guard let disk = mr(for: d)?.disk_report else { return nil }
            return (id: d.id, cells: [label(for: d),
                                      disk.freeString ?? "—", disk.totalString ?? "—",
                                      (disk.encrypted ?? 0) == 1 ? "Yes" : "No",
                                      disk.smartstatus ?? "—"])
        }
    }

    private var updateRows: [(id: String, cells: [String])] {
        inventoryScope.compactMap { d in
            guard let su = mr(for: d)?.software_updates else { return nil }
            let pending = su.recommendedupdates?.value.map(String.init) ?? "—"
            return (id: d.id, cells: [label(for: d), pending, su.lastsuccessfuldate ?? "—"])
        }
    }

    private var firewallRows: [(id: String, cells: [String])] {
        inventoryScope.compactMap { d in
            let mdm = mdmSec[d.id]              // live MDM (preferred)
            let fw = mr(for: d)?.firewall       // MunkiReport (fallback)
            guard mdm != nil || fw != nil else { return nil }
            // MDM doesn't report the logging setting; that stays MunkiReport.
            return (id: d.id, cells: [label(for: d),
                                      mdm?.firewallStateText ?? fw?.stateText ?? "—",
                                      mdm?.stealthText ?? fw?.stealthText ?? "—",
                                      fw?.loggingText ?? "—"])
        }
    }

    private var gatekeeperRows: [(id: String, cells: [String])] {
        inventoryScope.compactMap { d in
            let mdm = mdmSec[d.id]
            let s = mr(for: d)?.security
            guard mdm != nil || s != nil else { return nil }
            // Gatekeeper + Activation Lock have no (cheap) MDM source, so they
            // stay MunkiReport; SIP prefers the live MDM value.
            return (id: d.id, cells: [label(for: d),
                                      s?.gatekeeperText ?? "—",
                                      mdm?.sipText ?? s?.sipText ?? "—",
                                      s?.activationLockText ?? "—"])
        }
    }

    /// Query firewall + SIP live from each scoped Mac via the MDM
    /// SecurityInfo command, overriding MunkiReport for the ones that answer.
    /// On demand (not in refresh) — it's a command-per-device pull and needs
    /// each Mac online.
    @MainActor
    private func pullSecurityViaMDM() async {
        pullingSecurity = true
        defer { pullingSecurity = false }
        let nano = NanoMDMService(settings: settings)
        let api = EnrollmentsAPI(settings: settings)
        for d in inventoryScope {
            guard let uuid = try? await nano.requestSecurityInfo(enrollmentID: d.id) else { continue }
            _ = try? await nano.push(enrollmentIDs: d.id)
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                if let res = try? await api.commandResult(uuid: uuid) {
                    let facts = MDMSecurityFacts(securityInfo: res.dict("SecurityInfo"))
                    if facts.hasData { mdmSec[d.id] = facts; mdmSecAt[d.id] = Date() }
                    break
                }
            }
        }
        saveSecurityCache()
    }

    // MARK: - MDM security cache (persistent + timestamped)

    private struct CachedSecurity: Codable { var facts: MDMSecurityFacts; var at: Date }
    private static var securityCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("EdictMDM", isDirectory: true)
            .appendingPathComponent("mdm-security-cache.json")
    }
    /// Rehydrate firewall/SIP from disk so the tables show last-known posture
    /// immediately on launch (cached until a fresh Pull via MDM).
    private func loadSecurityCache() {
        guard let data = try? Data(contentsOf: Self.securityCacheURL),
              let map = try? JSONDecoder().decode([String: CachedSecurity].self, from: data)
        else { return }
        for (id, c) in map where mdmSec[id] == nil { mdmSec[id] = c.facts; mdmSecAt[id] = c.at }
    }
    private func saveSecurityCache() {
        var map: [String: CachedSecurity] = [:]
        for (id, f) in mdmSec { map[id] = CachedSecurity(facts: f, at: mdmSecAt[id] ?? Date()) }
        let url = Self.securityCacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url) }
    }

    // MARK: - Source + freshness, per category

    /// What sources a category table and how fresh that data is, shown as a
    /// caption under the toolbar so the user always knows where a value came
    /// from and whether it's stale.
    private struct InvSource { let name: String; let checkedAt: Date?; let note: String?
        var coverage: (have: Int, total: Int)? = nil }

    /// Oldest MunkiReport fetch across the current scope — the most
    /// conservative freshness (flags the stalest Mac, e.g. wiped-but-cached).
    private func mrOldestFetch() -> Date? {
        inventoryScope.compactMap { mrInventory.lastFetched($0.serialNumber) }.min()
    }
    /// Most recent MDM SecurityInfo pull across the current scope.
    private func mdmNewestPull() -> Date? {
        inventoryScope.compactMap { mdmSecAt[$0.id] }.max()
    }
    /// How many scoped Macs actually have MunkiReport data — answers "why does
    /// only one Mac show up here" (the rest aren't MunkiReport clients).
    private func mrCoverage() -> (have: Int, total: Int) {
        (inventoryScope.filter { mr(for: $0) != nil }.count, inventoryScope.count)
    }
    /// How many scoped Macs have answered an MDM SecurityInfo pull.
    private func mdmSecCoverage() -> (have: Int, total: Int) {
        (inventoryScope.filter { mdmSec[$0.id] != nil }.count, inventoryScope.count)
    }

    @ViewBuilder
    private func sourceCaption(_ s: InvSource) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle").font(.caption2)
            Text("Source: \(s.name)")
            if let d = s.checkedAt {
                Text("· checked \(d.formatted(.relative(presentation: .named)))")
            } else {
                Text("· not checked yet")
            }
            if let c = s.coverage {
                Text("· \(c.have) of \(c.total) Mac\(c.total == 1 ? "" : "s") reporting")
                    .foregroundStyle(c.have < c.total ? Color.orange : .secondary)
            }
            if let n = s.note { Text("· \(n)").foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 18).padding(.bottom, 6)
    }

    // MARK: - Searchable device picker (scales past a flat dropdown)

    private var devicePickerPopover: some View {
        let q = devicePickerQuery.trimmingCharacters(in: .whitespaces)
        let matches = q.isEmpty ? scoped : scoped.filter {
            label(for: $0).localizedCaseInsensitiveContains(q)
                || ($0.serialNumber ?? "").localizedCaseInsensitiveContains(q)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search Macs", text: $devicePickerQuery).textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    devicePickerRow(label: "All Macs", sub: nil, selected: inventoryDeviceID == nil) {
                        inventoryDeviceID = nil; showDevicePicker = false
                    }
                    ForEach(matches, id: \.id) { d in
                        devicePickerRow(label: label(for: d), sub: d.serialNumber,
                                        selected: inventoryDeviceID == d.id) {
                            inventoryDeviceID = d.id; showDevicePicker = false
                        }
                    }
                    if matches.isEmpty {
                        Text("No match").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 260)
    }

    @ViewBuilder
    private func devicePickerRow(label: String, sub: String?, selected: Bool,
                                 _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "laptopcomputer")
                    .foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).lineLimit(1)
                    if let sub, !sub.isEmpty {
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.1) : .clear)
    }

    /// When a per-device inventory row (Storage, Updates, Firewall, …) is
    /// tapped, select that Mac in the main window so the right-hand inspector
    /// shows it — same behavior the Devices/Security table gives.
    private func selectHost(forRowID rowID: String) {
        guard let dev = scoped.first(where: { $0.id == rowID }) else { return }
        selection = [df.hostID(for: dev)]
    }
    /// The main-window selection id for a per-device row, to highlight it.
    private func isRowSelected(_ rowID: String) -> Bool {
        guard let dev = scoped.first(where: { $0.id == rowID }) else { return false }
        return selection.contains(df.hostID(for: dev))
    }

    private func filteredRows(_ rows: [(id: String, cells: [String])]) -> [(id: String, cells: [String])] {
        let q = tableSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { row in row.cells.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    // MARK: - Inventory-table sort + resizable columns

    /// Effective column widths for the current category: dragged overrides if
    /// present (and still matching the column count), else the natural widths.
    private func invWidths(_ columns: [(String, CGFloat)]) -> [CGFloat] {
        if let data = invColWidthsRaw.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: [Double]].self, from: data),
           let saved = map[category.rawValue], saved.count == columns.count {
            return saved.map { CGFloat($0) }
        }
        return columns.map(\.1)
    }

    private func setInvWidth(_ columns: [(String, CGFloat)], index: Int, to newWidth: CGFloat) {
        var widths = invWidths(columns)
        guard index < widths.count else { return }
        widths[index] = max(48, newWidth)
        var map: [String: [Double]] = [:]
        if let data = invColWidthsRaw.data(using: .utf8),
           let m = try? JSONDecoder().decode([String: [Double]].self, from: data) { map = m }
        map[category.rawValue] = widths.map { Double($0) }
        if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) {
            invColWidthsRaw = s
        }
    }

    private func toggleInvSort(_ i: Int) {
        if invSortCol == i { invSortAsc.toggle() } else { invSortCol = i; invSortAsc = true }
    }

    /// Sort the (already filtered) rows by the active column. Numeric when the
    /// cell starts with a number ("12 of 30", "45.2 GB"), else case-insensitive
    /// text. nil sort column leaves the rows in their incoming order.
    private func sortedRows(_ rows: [(id: String, cells: [String])]) -> [(id: String, cells: [String])] {
        guard let col = invSortCol else { return rows }
        func cell(_ r: (id: String, cells: [String])) -> String { col < r.cells.count ? r.cells[col] : "" }
        func leadingNumber(_ s: String) -> Double? {
            var n = ""
            for ch in s.trimmingCharacters(in: .whitespaces) {
                if ch.isNumber || ch == "." { n.append(ch) }
                else if n.isEmpty && ch == "-" { n.append(ch) }
                else { break }
            }
            return n.isEmpty ? nil : Double(n)
        }
        return rows.sorted { a, b in
            let ka = cell(a), kb = cell(b)
            let asc: Bool
            if let na = leadingNumber(ka), let nb = leadingNumber(kb), na != nb {
                asc = na < nb
            } else {
                asc = ka.localizedCaseInsensitiveCompare(kb) == .orderedAscending
            }
            return invSortAsc ? asc : !asc
        }
    }

    /// A sortable, drag-to-resize header cell for the inventory tables.
    @ViewBuilder
    private func invHeaderCell(_ title: String, width: CGFloat, index: Int,
                               columns: [(String, CGFloat)]) -> some View {
        HStack(spacing: 0) {
            Button { toggleInvSort(index) } label: {
                HStack(spacing: 3) {
                    Text(title)
                    if invSortCol == index {
                        Image(systemName: invSortAsc ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }
                }
                .frame(width: max(40, width) - 8, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Color.clear.frame(width: 8, height: 14)
                .overlay(Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1))
                .contentShape(Rectangle())
                .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if invResizeStart == nil { invResizeStart = width }
                        setInvWidth(columns, index: index, to: (invResizeStart ?? width) + v.translation.width)
                    }
                    .onEnded { _ in invResizeStart = nil })
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// Generic Kandji-style category table: a toolbar with title + filter,
    /// then a horizontally-scrolling sortable-width table. Column width 0
    /// means "flexible".
    private func inventoryTable(columns: [(String, CGFloat)], rows: [(id: String, cells: [String])],
                                source: InvSource? = nil,
                                deviceRows: Bool = false,
                                drillDevices: ((String) -> [String])? = nil,
                                onPullMDM: (() -> Void)? = nil) -> some View {
        let widths = invWidths(columns)
        let filtered = sortedRows(filteredRows(rows))
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(category.rawValue).font(.title3.bold())
                Text("\(filtered.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let onPullMDM {
                    Button { onPullMDM() } label: {
                        if pullingSecurity { ProgressView().controlSize(.small) }
                        else { Label("Pull via MDM", systemImage: "antenna.radiowaves.left.and.right") }
                    }
                    .controlSize(.small)
                    .disabled(pullingSecurity)
                    .help("Query firewall + SIP live from each Mac in scope via MDM, overriding MunkiReport for the ones that answer.")
                }
                Button {
                    devicePickerQuery = ""
                    showDevicePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "laptopcomputer").font(.caption2).foregroundStyle(.secondary)
                        Text(inventoryDeviceID.flatMap { id in scoped.first { $0.id == id }.map { label(for: $0) } } ?? "All Macs")
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 190, alignment: .leading)
                }
                .help("Roll up every Mac, or search to narrow to just one")
                .popover(isPresented: $showDevicePicker, arrowEdge: .bottom) { devicePickerPopover }
                Button {
                    TableCSVExport.save(filename: "\(category.rawValue).csv", columns: columns.map(\.0), rows: filtered.map(\.cells))
                } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export this view as CSV").disabled(filtered.isEmpty)
                .accessibilityLabel("Export this view as CSV")
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Filter", text: $tableSearch).textFieldStyle(.plain).frame(width: 150)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            if let source { sourceCaption(source) }
            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Nothing reported yet — MunkiReport fills this in as Macs check in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                // Fixed-width columns, left-packed with a trailing spacer so
                // the slack lands on the right edge (a clean Mac list look)
                // instead of inflating one column and leaving an interior gap.
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        // Keep header aligned with the rows' disclosure chevron.
                        if drillDevices != nil { Color.clear.frame(width: 12, height: 1) }
                        ForEach(columns.indices, id: \.self) { i in
                            invHeaderCell(columns[i].0, width: widths[i], index: i, columns: columns)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 5)
                    Divider()
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered, id: \.id) { row in
                                inventoryRow(row, columns: columns, widths: widths,
                                             deviceRows: deviceRows, drillDevices: drillDevices)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One category-table row. When `drillDevices` is supplied (rolled-up
    /// Apps / Local Users), the row is tappable to reveal which Macs it's on.
    @ViewBuilder
    private func inventoryRow(_ row: (id: String, cells: [String]), columns: [(String, CGFloat)],
                             widths: [CGFloat],
                             deviceRows: Bool = false,
                             drillDevices: ((String) -> [String])?) -> some View {
        let expandable = drillDevices != nil
        let isOpen = expandedInventoryRow == row.id
        let selected = deviceRows && isRowSelected(row.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if expandable {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                }
                ForEach(columns.indices, id: \.self) { i in
                    invCell(i < row.cells.count ? row.cells[i] : "", widths[i], header: false, first: i == 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if expandable { expandedInventoryRow = isOpen ? nil : row.id }
                else if deviceRows { selectHost(forRowID: row.id) }
            }
            .accessibilityAddTraits((expandable || deviceRows) ? .isButton : [])
            if isOpen, let drillDevices {
                let macs = drillDevices(row.id)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(macs, id: \.self) { m in
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer").font(.caption2).foregroundStyle(.secondary)
                            Text(m).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 48).padding(.trailing, 18).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.05))
            }
        }
    }

    @ViewBuilder
    private func invCell(_ text: String, _ width: CGFloat, header: Bool, first: Bool = false) -> some View {
        let view = Text(text.isEmpty && !header ? "—" : text)
            .font(header ? .caption.weight(.semibold) : (first ? .callout.weight(.medium) : .callout))
            .foregroundStyle(header ? .secondary : (first ? .primary : .secondary))
            .lineLimit(1).truncationMode(.tail)
        if width == 0 { view.frame(maxWidth: .infinity, alignment: .leading) }
        else { view.frame(width: width, alignment: .leading) }
    }

    // MARK: - Prism (saved, configurable views)

    private var savedViewsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(savedViews) { v in
                    let isActive = activeViewID == v.id
                    HStack(spacing: 4) {
                        Button { apply(v) } label: {
                            Label(v.name, systemImage: "bookmark.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        if isActive {
                            Button { deleteView(v) } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Delete saved view “\(v.name)”")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(isActive ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor)))
                    .overlay(Capsule().stroke(isActive ? Color.accentColor : .clear, lineWidth: 1))
                }
                Button { saveViewName = suggestedViewName; showSaveView = true } label: {
                    Label("Save view", systemImage: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])))
            }
        }
        .scrollIndicators(.hidden)
    }

    private var suggestedViewName: String {
        selectedGroup?.name ?? "All devices"
    }

    private func apply(_ v: PrismView) {
        activeViewID = v.id
        selectedGroupID = v.groupID
    }

    private func deleteView(_ v: PrismView) {
        savedViews.removeAll { $0.id == v.id }
        settings.prismViews = savedViews
        if activeViewID == v.id { activeViewID = nil }
    }

    private func saveCurrentView() {
        let name = saveViewName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let v = PrismView(name: name, groupID: selectedGroupID, attribute: .osVersion)
        savedViews.append(v)
        settings.prismViews = savedViews
        activeViewID = v.id
        showSaveView = false
    }

    private var saveViewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Prism View").font(.headline)
            Text("Saves the current scope (\(selectedGroup?.name ?? "All devices")) so you can flip back to it from the bar above.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("View name", text: $saveViewName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSaveView = false }.keyboardShortcut(.cancelAction)
                Button("Save") { saveCurrentView() }.keyboardShortcut(.defaultAction)
                    .disabled(saveViewName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 380)
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
            Menu {
                Button("New Smart Group…") {
                    editingGroup = SmartGroup(name: "New Group", rules: [SmartGroupRule(field: .fileVaultOff)])
                }
                if let g = selectedGroup {
                    Button("Edit “\(g.name)”…") { editingGroup = g }
                    Button("Delete “\(g.name)”", role: .destructive) {
                        settings.smartGroups.removeAll { $0.id == g.id }
                        selectedGroupID = nil
                    }
                }
            } label: { Image(systemName: "person.2.badge.gearshape") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Manage smart groups")
            .accessibilityLabel("Manage smart groups")
            if let cert = pushCert, let days = cert.daysLeft {
                Label("\(days)d", systemImage: "key.horizontal")
                    .font(.caption).foregroundStyle(days < 30 ? .orange : .secondary)
                    .help("MDM push certificate expires in \(days) days (topic \(cert.topic))")
            }
            Button {
                Task { await refresh() }
            } label: {
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh")
            .keyboardShortcut("r")
            .disabled(loading)
        }
        .sheet(item: $editingGroup) { g in
            SmartGroupEditor(group: g) { saved in
                var groups = settings.smartGroups
                if let idx = groups.firstIndex(where: { $0.id == saved.id }) { groups[idx] = saved }
                else { groups.append(saved) }
                settings.smartGroups = groups
                selectedGroupID = saved.id
            }
        }
    }

    // MARK: - Hero (compliance ring + stat legend)

    private var heroCard: some View {
        let c = compliance
        let total = graded.count
        return HStack(alignment: .center, spacing: 24) {
            complianceRing(compliant: c.compliant, total: total)
            VStack(alignment: .leading, spacing: 6) {
                statRow("All devices", total, .accentColor, "laptopcomputer", drill: "all")
                statRow("Compliant", c.compliant, .green, "checkmark.seal.fill", drill: "compliant")
                statRow("Out of compliance", c.nonCompliant,
                        c.nonCompliant == 0 ? .secondary : .red, "xmark.seal.fill", drill: "nonCompliant")
                statRow("Not reporting", c.unknown,
                        c.unknown == 0 ? .secondary : .yellow, "questionmark.circle", drill: "unknown")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func complianceRing(compliant: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(compliant) / Double(total) : 0
        let pct = Int((fraction * 100).rounded())
        let color: Color = total == 0 ? .secondary : (fraction >= 0.9 ? .green : (fraction >= 0.7 ? .yellow : .red))
        return ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 14)
            Circle().trim(from: 0, to: max(0.0001, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            VStack(spacing: 0) {
                Text(total == 0 ? "—" : "\(pct)%")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("compliant").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityElement()
        .accessibilityLabel("\(pct) percent compliant, \(compliant) of \(total)")
    }

    private func statRow(_ title: String, _ count: Int, _ color: Color, _ icon: String, drill: String) -> some View {
        let isOpen = drillKey == drill
        return Button { drillKey = (drillKey == drill) ? nil : drill } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(title).font(.callout)
                Spacer(minLength: 24)
                Text("\(count)").font(.title3.weight(.semibold).monospacedDigit())
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOpen ? color.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 240)
    }

    // MARK: - Attention strip (actionable alerts)

    private struct DashAlert: Identifiable {
        let id = UUID(); let text: String; let icon: String; let color: Color; let drill: String?
    }

    private var needsOnboardingCount: Int {
        guard settings.hasOnboardingBaseline else { return 0 }
        return graded.filter { $0.isEnabled && !settings.isOnboarded($0.id) }.count
    }

    private var dashAlerts: [DashAlert] {
        let c = compliance
        var a: [DashAlert] = []
        if c.nonCompliant > 0 {
            a.append(.init(text: "\(c.nonCompliant) out of compliance", icon: "xmark.seal.fill", color: .red, drill: "nonCompliant"))
        }
        let needs = needsOnboardingCount
        if needs > 0 {
            a.append(.init(text: "\(needs) need onboarding", icon: "shippingbox", color: .orange, drill: nil))
        }
        if driftCheckedAt != nil && driftProfileCount > 0 {
            a.append(.init(text: "\(driftProfileCount) profile\(driftProfileCount == 1 ? "" : "s") drifted on \(driftDeviceCount)", icon: "exclamationmark.triangle.fill", color: .orange, drill: nil))
        }
        if c.unknown > 0 {
            a.append(.init(text: "\(c.unknown) not reporting", icon: "questionmark.circle", color: .yellow, drill: "unknown"))
        }
        return a
    }

    /// Macs the operator hid from grading (e.g. too old for DDM) — collapsed,
    /// with an Unhide each. Only shown when something is hidden.
    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = hiddenFromAttention
        if !hidden.isEmpty {
            DisclosureGroup {
                ForEach(hidden, id: \.id) { d in
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                        Text(label(for: d)).font(.callout)
                        Spacer()
                        Button("Unhide") { settings.setIgnoredForAttention(d.id, false) }
                            .buttonStyle(.link).font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                Label("\(hidden.count) hidden from attention", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Excluded from compliance, attention, and the breakdown — typically Macs too old to report via DDM.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    @ViewBuilder
    private var attentionStrip: some View {
        let alerts = dashAlerts
        if alerts.isEmpty {
            Label("Everything looks good across \(graded.count) device\(graded.count == 1 ? "" : "s").",
                  systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(alerts) { alert in alertChip(alert) }
            }
        }
    }

    @ViewBuilder
    private func alertChip(_ alert: DashAlert) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: alert.icon).foregroundStyle(alert.color)
            Text(alert.text).font(.callout).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if alert.drill != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(alert.color.opacity(0.12)))
        .contentShape(Rectangle())
        if let d = alert.drill {
            Button { drillKey = (drillKey == d) ? nil : d } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    /// Devices matching a summary-card category, for the drill-down list.
    private func drillDevices(_ key: String) -> [MDMEnrollment] {
        switch key {
        case "all": return graded
        case "compliant", "nonCompliant", "unknown":
            return graded.filter { d in
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
                    .accessibilityLabel("Close")
            }
            ForEach(drillDevices(key), id: \.id) { d in
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    Text(label(for: d)).font(.callout)
                    Spacer()
                    if let os = osVersions[d.id] { Text("macOS \(os)").font(.caption).foregroundStyle(.secondary) }
                    fileVaultChip(for: d)
                    Button { settings.setIgnoredForAttention(d.id, true) } label: {
                        Image(systemName: "eye.slash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide from attention — for a Mac too old to report via DDM")
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

    /// A compact device × profile matrix from the deployment log — at a
    /// glance, which Edict-deployed profiles each device is supposed to
    /// have. Columns are the distinct profile names across the scope.
    private var assignmentsCard: some View {
        let log = deploymentLog
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

    private func label(for enr: MDMEnrollment) -> String { df.label(for: enr) }

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

    /// Subscribe every scoped device to DDM status reporting in one go, so
    /// the table's Model / macOS / FileVault columns stop showing "—".
    @MainActor
    private func enableReportingAll() async {
        enablingAll = true
        defer { enablingAll = false }
        let set = "default"
        let configID = "com.hellocomputer.edict.status-subscriptions"
        let kmf = KMFDDMService(settings: settings)
        let nano = NanoMDMService(settings: settings)
        try? await kmf.deploy(configJSON: DDMDeclarations.statusSubscriptions(identifier: configID),
                              configID: configID, toSet: set)
        for d in scoped {
            try? await kmf.assign(enrollmentID: d.id, toSet: set)
            _ = try? await nano.push(enrollmentIDs: d.id)
        }
        // Give the fleet a moment to process, then re-read facts.
        try? await Task.sleep(for: .seconds(8))
        await refresh()
    }

    @MainActor
    private func refresh() async {
        savedViews = settings.prismViews
        loadSecurityCache()
        let log = DeploymentLog.load()
        deploymentLog = log
        deploymentCounts = log.mapValues { $0.count }
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let api = EnrollmentsAPI(settings: settings)
            enrollments = try await api.list()
            pushCert = try? await api.pushCert()
            let svc = KMFDDMService(settings: settings)
            var os: [String: String] = [:], fv: [String: String] = [:], mdl: [String: String] = [:]
            for d in allDevices {
                let f = await svc.deviceFacts(enrollmentID: d.id)
                if let v = f.os { os[d.id] = v }
                if let v = f.model { mdl[d.id] = v }
                if let v = f.fileVault { fv[d.id] = v ? "true" : "false" }
            }
            osVersions = os; fileVault = fv; models = mdl
            rebuildFacts()
            // Pull MunkiReport inventory for the category tables (Apps,
            // Users, Storage, Updates). loadIfNeeded dedupes.
            if settings.isMunkiReportAPIConfigured {
                for d in allDevices {
                    if let s = d.serialNumber?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
                        mrInventory.loadIfNeeded(serial: s, settings: settings)
                    }
                }
            }
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
        rebuildFacts()
    }
}
