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

    @Environment(MDMFleetIndex.self) private var fleet
    let destination: Category
    let onNavigate: (SidebarFilter) -> Void

    init(selection: Binding<Set<Int>>, destination: Category = .summary,
         onNavigate: @escaping (SidebarFilter) -> Void = { _ in }) {
        _selection = selection
        self.destination = destination
        self.onNavigate = onNavigate
        _category = State(initialValue: destination)
    }

    private var enrollments: [MDMEnrollment] { fleet.enrollments }
    private var osVersions: [String: String] { fleet.snapshots.compactMapValues(\.os) }
    private var fileVault: [String: String] { fleet.snapshots.compactMapValues { $0.fileVault.map { $0 ? "true" : "false" } } }
    private var models: [String: String] { fleet.snapshots.compactMapValues(\.model) }
    private var loading: Bool { fleet.loading }
    private var loadError: String? { actionError ?? fleet.loadError }
    private var selectedGroupID: UUID? {
        get { fleet.selectedGroupID }
        nonmutating set { fleet.selectedGroupID = newValue }
    }
    private var driftMissing: [String: [DeploymentLog.Entry]] {
        fleet.drift.filter { $0.value.outcome == .verified }.mapValues(\.missing)
    }
    private var driftCheckedAt: Date? { scoped.compactMap { fleet.drift[$0.id]?.checkedAt }.max() }
    @State private var driftChecking = false
    @State private var actionError: String?
    @State private var showUpdate = false

    // Prism saved views — now scope bookmarks (the Breakdown card shows every
    // attribute at once, so a view just captures which scope to flip to).
    @State private var savedViews: [PrismView] = []
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
    @State var category: Category = .summary
    /// Inventory-table sort — kept here (not in PrismInventoryTable) so the
    /// reset-on-category `.onChange` below stays unchanged. nil = natural order.
    @State var invSortCol: Int?
    @State var invSortAsc = true
    /// Which Mac the category tables are scoped to (nil = all, rolled up). Read
    /// by `inventoryScope`, so it's owned here and passed to the table as a
    /// binding; `expandedInventoryRow` resets alongside it.
    @State var inventoryDeviceID: String?
    /// A rolled-up Apps / Local Users row expanded to show which Macs it's on.
    @State var expandedInventoryRow: String?
    // Transient table-local UI state (filter text, device-picker popover, live
    // column-drag width, per-category persisted widths) lives in
    // PrismInventoryTable.
    private var mdmSec: [String: MDMSecurityFacts] { fleet.security }
    private var mdmSecAt: [String: Date] { fleet.securityAt }
    private var mdmSU: [String: KMFDDMService.DDMSoftwareUpdate] {
        fleet.snapshots.mapValues { .init(installState: $0.updateState, pendingOS: $0.pendingOS, failureReason: $0.updateFailure) }
    }
    private var factsAt: Date? { fleet.refreshedAt }
    private var mdmNames: [String: String] { fleet.names }
    @State var pullingSecurity = false
    @State private var enablingAll = false
    @State private var editingGroup: SmartGroup?
    private var pushCert: PushCertInfo? { fleet.pushCert }

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
        .onChange(of: destination) { _, value in category = value; inventoryDeviceID = nil }
        .onChange(of: fleet.version) { _, _ in rebuildFacts() }
        .onChange(of: hostStore.hosts) { _, _ in rebuildFacts() }
        .onChange(of: settings.mdmRequireFileVault) { _, _ in rebuildFacts() }
        .onChange(of: settings.mdmMinOSVersion) { _, _ in rebuildFacts() }
        .onChange(of: selectedGroupID) { _, _ in inventoryDeviceID = nil; expandedInventoryRow = nil }
        .onChange(of: category) { _, _ in expandedInventoryRow = nil; invSortCol = nil }
        .onChange(of: inventoryDeviceID) { _, _ in expandedInventoryRow = nil }
        // When MunkiReport inventory lands, rebuild facts so computer names
        // (and anything else MR-derived) refresh into the labels.
        .onChange(of: mrInventory.bySerial) { _, _ in rebuildFacts() }
    }

    // MARK: - Membership / facts

    private var allDevices: [MDMEnrollment] { enrollments.filter(\.isDevice) }

    /// Cached per-device facts the device table + chart read. Rebuilt when
    /// the fleet reloads, a drift check finishes, or the compliance
    /// baseline changes — not on every render — so the dashboard isn't
    /// re-deriving compliance, labels, and buckets for the whole fleet on
    /// each redraw.
    @State var df: DashboardFacts = .empty

    private func rebuildFacts() {
        df = DashboardFacts(osVersions: osVersions, fileVault: fileVault, models: models,
                            hosts: hostStore.hosts, deviceLabels: deviceLabels, mrNames: knownDeviceNames,
                            requireFileVault: settings.mdmRequireFileVault, minOS: settings.mdmMinOSVersion,
                            driftMissing: driftMissing, deploymentCounts: deploymentCounts)
        for d in allDevices { if let inv = mr(for: d) { df.fillGaps(d.id, from: inv) } }
        df.unavailableDeviceIDs = Set(allDevices.filter {
            fleet.errors[$0.id] != nil || fleet.loadError != nil
                || $0.lastSeenDate.map { Date().timeIntervalSince($0) >= 7 * 86400 } != false
        }.map(\.id))
    }
    /// enrollmentID → best non-hostname name, so an MDM-only Mac reads as its
    /// real name instead of a bare serial: MunkiReport computer name preferred,
    /// else the live MDM `DeviceName` we pulled and cached.
    private var knownDeviceNames: [String: String] {
        var names: [String: String] = [:]
        for d in allDevices {
            if let s = d.serialNumber?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
               let mr = mrInventory.bySerial[s]?.machine?.computer_name, !mr.isEmpty {
                names[d.id] = mr
            } else if let live = mdmNames[d.id], !live.isEmpty {
                names[d.id] = live
            }
        }
        return names
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
    var scoped: [MDMEnrollment] {
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
    private var hiddenFromAttention: [MDMEnrollment] {
        scoped.filter { settings.isIgnoredForAttention($0.id) }
    }

    private var driftDeviceCount: Int { scoped.filter { !(driftMissing[$0.id] ?? []).isEmpty }.count }
    private var driftProfileCount: Int { scoped.reduce(0) { $0 + (driftMissing[$1.id]?.count ?? 0) } }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if destination == .devices {
                Picker("Inventory", selection: $category) {
                    Text("Devices").tag(Category.devices)
                    Text("Managed apps").tag(Category.apps)
                    Text("Local users").tag(Category.users)
                    Text("Storage").tag(Category.storage)
                }
                .pickerStyle(.segmented).padding(.horizontal, 18).padding(.vertical, 10)
            }
            categoryPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Category panel

    @ViewBuilder
    var categoryPanel: some View {
        @Bindable var fleet = fleet
        if loading && enrollments.isEmpty {
            VStack { Spacer(); HStack { ProgressView().controlSize(.small); Text("Loading fleet…").foregroundStyle(.secondary) }; Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if enrollments.isEmpty, let error = fleet.loadError {
            ContentUnavailableView("Inventory unavailable", systemImage: "wifi.exclamationmark",
                                   description: Text(error))
        } else if scoped.isEmpty {
            emptyScope
        } else {
            switch category {
            case .security:
                MDMSecurityPane(devices: scoped, facts: df, snapshots: fleet.snapshots,
                                live: mdmSec, liveAt: mdmSecAt, errors: fleet.errors,
                                selection: $selection, pulling: pullingSecurity,
                                onRefresh: { Task { await pullSecurityViaMDM() } })
            case .devices:
                PrismDeviceTable(title: category.rawValue, security: category == .security,
                                 devices: scoped, facts: df, selection: $selection,
                                 enablingAll: enablingAll,
                                 onEnableReporting: { Task { await enableReportingAll() } }, tableSearch: $fleet.deviceQuery)
            case .summary:
                MDMOverviewPane(devices: scoped, facts: df, snapshots: fleet.snapshots,
                                errors: fleet.errors, loadError: fleet.loadError, cert: pushCert,
                                excludedIDs: Set(hiddenFromAttention.map(\.id)),
                                onNavigate: onNavigate,
                                onSelect: { selection = [df.hostID(for: $0)] })
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
                                                 note: "Local-account inventory from MunkiReport", coverage: mrCoverage()),
                               drillDevices: inventoryDeviceID == nil ? { macsWithUser($0) } : nil)
            case .storage:
                inventoryTable(columns: [("Device", 180), ("Free", 100), ("Total", 100), ("Encrypted", 100), ("SMART", 90)], rows: storageRows,
                               source: InvSource(name: "MunkiReport", checkedAt: mrOldestFetch(), note: nil,
                                                 coverage: mrCoverage()),
                               deviceRows: true)
            case .updates:
                VStack(spacing: 0) {
                    HStack {
                        Text("Approved OS target and device-reported installation progress.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Enforce update…", systemImage: "arrow.down.circle") { showUpdate = true }
                    }.padding(18)
                    inventoryTable(columns: [("Device", 180), ("macOS", 84), ("Baseline OS", 100), ("Installation", 180), ("Detail", 260)], rows: updateRows,
                               source: InvSource(name: "DDM status (Edict), MunkiReport fallback", checkedAt: factsAt,
                                                 note: "Target is the minimum macOS version configured in Settings", coverage: mdmSUCoverage()),
                               deviceRows: true)
                }
                .sheet(isPresented: $showUpdate) {
                    UpdateEnforcementSheet { config, id, set in
                        try await KMFDDMService(settings: settings).deploy(configJSON: config, configID: id, toSet: set)
                    }
                }
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

    /// The newest macOS any reporting Mac runs — the yardstick for the
    /// fleet-relative "Behind" verdict. We don't query Apple's release feed, so
    /// "Behind" means older than the newest macOS in *your* fleet, not absolute.
    private var fleetNewestOS: String? {
        osVersions.values.max { df.osRank($0) < df.osRank($1) }
    }

    private var updateRows: [(id: String, cells: [String])] {
        let target = settings.mdmMinOSVersion.trimmingCharacters(in: .whitespaces)
        return inventoryScope.map { d in
            let update = mdmSU[d.id]
            let states = ["none": "No installation pending", "waiting": "Waiting", "downloading": "Downloading",
                          "prepared": "Ready to install", "installing": "Installing", "failed": "Failed"]
            let installation = update?.installState.map { states[$0] ?? $0 } ?? "Not reported"
            let detail: String
            if let error = fleet.errors[d.id] { detail = "Read failed: \(error)" }
            else if let failure = update?.failureReason { detail = "Failed: \(failure)" }
            else if let pending = update?.pendingOS { detail = "Installing macOS \(pending)" }
            else if !target.isEmpty, let os = osVersions[d.id] {
                detail = SmartGroup.atLeast(os, target) ? "Meets baseline OS target" : "Below baseline OS target"
            } else { detail = "No baseline OS target configured" }
            return (id: d.id, cells: [label(for: d), osVersions[d.id] ?? "Unknown",
                                      target.isEmpty ? "Not set" : target, installation, detail])
        }
    }
    /// How many scoped Macs report software-update status via the DDM channel.
    private func mdmSUCoverage() -> (have: Int, total: Int) {
        (inventoryScope.filter { mdmSU[$0.id] != nil }.count, inventoryScope.count)
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
        pullingSecurity = true; actionError = nil
        defer { pullingSecurity = false }
        let nano = NanoMDMService(settings: settings)
        let api = EnrollmentsAPI(settings: settings)
        var answered = 0
        let targets = inventoryScope
        for d in targets {
            do {
                let uuid = try await nano.requestSecurityInfo(enrollmentID: d.id)
                for _ in 0..<6 {
                    try await Task.sleep(for: .seconds(2))
                    if let result = try await api.commandResult(uuid: uuid) {
                        guard result.acknowledged else { break }
                        let facts = MDMSecurityFacts(securityInfo: result.dict("SecurityInfo"))
                        if facts.hasData { fleet.recordSecurity(facts, for: d.id); answered += 1 }
                        break
                    }
                }
            } catch { actionError = error.localizedDescription }
        }
        if answered < targets.count {
            actionError = "Security refreshed for \(answered) of \(targets.count) devices. Others retain last-known evidence; see Activity for command results."
        }
    }

    // MARK: - Source + freshness, per category

    // InvSource lives in PrismInventoryTable.swift (used by both the table and
    // the callers below that construct the source attribution).

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

    // MARK: - Inventory tables (rendered by PrismInventoryTable)

    /// Adapter so the category `switch` keeps calling `inventoryTable(...)` while
    /// PrismInventoryTable owns the rendering + local UI state.
    private func inventoryTable(columns: [(String, CGFloat)], rows: [(id: String, cells: [String])],
                                source: InvSource? = nil,
                                deviceRows: Bool = false,
                                drillDevices: ((String) -> [String])? = nil,
                                onPullMDM: (() -> Void)? = nil) -> some View {
        // Filter `scoped` once per table and index it, so the per-row
        // select / is-selected callbacks are O(1) instead of re-filtering
        // the fleet through smart-group rules for every row.
        let scoped = self.scoped
        let byID = Dictionary(scoped.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PrismInventoryTable(
            category: category.rawValue,
            columns: columns, rows: rows, source: source,
            deviceRows: deviceRows, drillDevices: drillDevices,
            onPullMDM: onPullMDM, pullingSecurity: pullingSecurity,
            // Devices for the table's "narrow to one Mac" picker.
            pickerDevices: scoped.map { PrismPickerDevice(id: $0.id, label: label(for: $0), serial: $0.serialNumber) },
            // Select a per-device row's Mac in the main window so the inspector
            // shows it — same behavior the Devices/Security table gives.
            onSelectRow: { id in if let d = byID[id] { selection = [df.hostID(for: d)] } },
            isRowSelected: { id in byID[id].map { selection.contains(df.hostID(for: $0)) } ?? false },
            inventoryDeviceID: $inventoryDeviceID,
            invSortCol: $invSortCol,
            invSortAsc: $invSortAsc,
            expandedInventoryRow: $expandedInventoryRow
        )
    }


    // MARK: - Prism (saved, configurable views)

    private var suggestedViewName: String {
        selectedGroup?.name ?? "All devices"
    }

    private func saveCurrentView() {
        let name = saveViewName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let v = PrismView(name: name, groupID: selectedGroupID, attribute: .osVersion, search: fleet.deviceQuery,
                          hiddenColumns: UserDefaults.standard.string(forKey: "prismHiddenColumns"),
                          sortKey: UserDefaults.standard.string(forKey: "mdmDeviceSortKey"),
                          sortAscending: UserDefaults.standard.object(forKey: "mdmDeviceSortAscending") as? Bool)
        savedViews.append(v)
        settings.prismViews = savedViews
        showSaveView = false
    }

    private var saveViewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Device View").font(.headline)
            Text("Saves search, columns, sort order, and scope (\(selectedGroup?.name ?? "All devices")) so you can flip back to it from the bar above.")
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
        @Bindable var fleet = fleet
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination == .summary ? "Overview" : destination.rawValue).font(.title2).bold()
                Text(selectedGroup.map { "Smart group: \($0.name)" } ?? "All enrolled devices")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if destination == .devices {
                Button("Save view", systemImage: "bookmark") { saveViewName = suggestedViewName; showSaveView = true }
            }
            Picker("", selection: $fleet.selectedGroupID) {
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
                Task { await forceRefresh() }
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
            let checked = scoped.compactMap { fleet.drift[$0.id] }
            let verified = checked.filter { $0.outcome == .verified }.count
            let waiting = checked.filter { $0.outcome == .waiting }.count
            let failed = checked.filter { $0.outcome == .failed }.count
            Text("\(verified) verified · \(waiting) waiting · \(failed) failed · \(scoped.count - checked.count + checked.filter { $0.outcome == .untracked }.count) untracked")
                .font(.callout).foregroundStyle(.secondary)
            if let at = driftCheckedAt {
                if driftProfileCount == 0 && verified > 0 {
                    Label("No missing profiles found in verified responses.",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                } else if driftProfileCount > 0 {
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
                Text("Last checked \(at, style: .time) — automation is available in Activity.")
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Profile assignments", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                if !rows.isEmpty {
                    Text("\(columns.count) profile\(columns.count == 1 ? "" : "s") · \(rows.count) device\(rows.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text("Edict hasn't deployed any profiles to these devices yet. Deploys you make from the Profiles tab show up here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Device").font(.caption2.bold()).foregroundStyle(.secondary)
                                .frame(width: 160, alignment: .leading)
                            ForEach(columns, id: \.key) { col in
                                // Wrap, don't truncate — it's in a horizontal scroll
                                // with room to spare; a clipped profile name is useless.
                                Text(col.value).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 150, alignment: .center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(col.value)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                        ForEach(Array(rows.enumerated()), id: \.element.enr.id) { idx, row in
                            let sel = selection.contains(df.hostID(for: row.enr))
                            Button { selection = [df.hostID(for: row.enr)] } label: {
                                HStack(spacing: 0) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "laptopcomputer").font(.caption2).foregroundStyle(.secondary)
                                        Text(label(for: row.enr)).font(.caption).lineLimit(1).truncationMode(.middle)
                                    }
                                    .frame(width: 160, alignment: .leading)
                                    ForEach(columns, id: \.key) { col in
                                        Image(systemName: row.ids.contains(col.key) ? "checkmark.circle.fill" : "minus")
                                            .font(.caption)
                                            .foregroundStyle(row.ids.contains(col.key) ? Color.green : Color.secondary.opacity(0.3))
                                            .frame(width: 150, alignment: .center)
                                    }
                                }
                                .padding(.vertical, 5)
                                .background(sel ? Color.accentColor.opacity(0.16)
                                            : (idx.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.04)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("A ✓ means Edict queued that profile. Run verification to confirm it is installed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .deviceArrowKeys(rows.map { df.hostID(for: $0.enr) },
                         selected: rows.map { df.hostID(for: $0.enr) }.first(where: selection.contains),
                         select: { selection = [$0] })
        .frame(maxWidth: 820, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }

    func label(for enr: MDMEnrollment) -> String { df.label(for: enr) }

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
        enablingAll = true; actionError = nil
        defer { enablingAll = false }
        let targets = scoped.filter(\.isEnabled)
        let set = "default"
        let configID = "com.hellocomputer.edict.status-subscriptions"
        let kmf = KMFDDMService(settings: settings)
        var assigned = 0
        do {
            try await kmf.deploy(configJSON: DDMDeclarations.statusSubscriptions(identifier: configID),
                                 configID: configID, toSet: set)
            for device in targets {
                do { try await kmf.assign(enrollmentID: device.id, toSet: set); assigned += 1 }
                catch { actionError = error.localizedDescription }
            }
            if assigned < targets.count {
                actionError = "Reporting subscription assigned to \(assigned) of \(targets.count) devices. Some assignments failed."
            }
            await forceRefresh()
        } catch { actionError = "Couldn't assign reporting: \(error.localizedDescription)" }
    }

    @MainActor
    private func refresh() async {
        savedViews = settings.prismViews
        deploymentLog = DeploymentLog.load()
        deploymentCounts = deploymentLog.mapValues { $0.count }
        if fleet.refreshedAt == nil && !fleet.loading {
            let serials = Set(hostStore.hosts.compactMap { $0.serialnum?.uppercased() })
            await fleet.refresh(settings: settings, bscSerials: serials)
        }
        rebuildFacts()
        if settings.isMunkiReportAPIConfigured {
            for d in allDevices {
                if let serial = d.serialNumber { mrInventory.loadIfNeeded(serial: serial, settings: settings) }
            }
        }
    }

    private func forceRefresh() async {
        let serials = Set(hostStore.hosts.compactMap { $0.serialnum?.uppercased() })
        await fleet.refresh(settings: settings, bscSerials: serials)
        await refresh()
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
        for d in scoped {
            let tracked = log[d.id] ?? []
            guard !tracked.isEmpty else { fleet.drift[d.id] = .init(outcome: .untracked); continue }
            do {
                let uuid = try await nano.requestProfileList(enrollmentID: d.id)
                var reply: CommandResult?
                for _ in 0..<6 {
                    try await Task.sleep(for: .seconds(2))
                    if let response = try await api.commandResult(uuid: uuid) { reply = response; break }
                }
                fleet.drift[d.id] = MDMDriftAssessment.evaluate(reply, tracked: tracked)
            } catch { fleet.drift[d.id] = .init(outcome: .failed, detail: error.localizedDescription) }
        }
        rebuildFacts()
    }
}
