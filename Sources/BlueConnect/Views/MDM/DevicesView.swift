import SwiftUI

/// Edict MDM managed-devices view — the center pane for the sidebar's
/// Device Management → Devices row.
///
/// The list populates itself from the enrollments API on the MDM server
/// (a read-only sidecar in front of NanoMDM's database — NanoMDM exposes
/// no list API). Every enrolled Mac appears automatically with its
/// serial and last-seen time; nothing is registered by hand. Labels are
/// the only local state: friendly names the operator assigns, persisted
/// in @AppStorage keyed by enrollment ID.
///
/// Per-device actions go through the admin APIs: Ping (APNs push →
/// device checks in), Assign to Set (KMFDDM association → declarations
/// flow to it), and Remove from MDM (RemoveProfile of the enrollment
/// profile → the device unenrolls itself; it must be online).
struct DevicesView: View {
    @EnvironmentObject private var settings: SettingsStore
    /// The BSC fleet — used to match MDM devices to BlueSky hosts by
    /// serial number, so one machine shows both identities.
    @Environment(BlueSkyHostListStore.self) private var hostStore
    @Environment(ActivityLog.self) private var activity
    @Environment(TerminalSessionsManager.self) private var terminals

    @State private var enrollments: [MDMEnrollment] = []
    @State private var loading = false
    @State private var loadError: String?

    // Detail pane (status values reported by the selected device)
    @State private var selectedDeviceID: String?
    @State private var statusValues: [DDMStatusValue] = []
    @State private var statusLoading = false
    @State private var statusError: String?
    @State private var reportingSetName = "default"
    @State private var enablingReporting = false

    // Update rollout: the enforced target (from Edict's enforcement
    // declarations) and each device's reported OS version.
    @State private var updateTarget: UpdateTarget?
    @State private var osVersions: [String: String] = [:]
    /// Per-device FileVault state ("true"/"false") where reported.
    @State private var fileVault: [String: String] = [:]
    /// APNs push cert info — drives the expiry warning banner.
    @State private var pushCert: PushCertInfo?
    @State private var confirmingEndEnforcement = false

    // Lock / Erase
    @State private var lockTarget: MDMEnrollment?
    @State private var eraseTarget: MDMEnrollment?

    // Inventory (per selected device)
    @State private var inventoryKind: InventoryKind?
    @State private var inventoryItems: [String] = []
    @State private var inventoryLoading = false
    @State private var inventoryError: String?

    enum InventoryKind: String { case profiles = "Profiles", apps = "Installed Apps" }

    // Bulk selection
    @State private var multiSelection = Set<String>()
    @State private var bulkAssignSheet = false
    @State private var bulkSetName = "default"

    struct UpdateTarget: Equatable {
        let version: String
        let deadline: Date?
        let declarationID: String
    }

    private enum Compliance {
        case compliant          // reported version >= target
        case behind             // below target, deadline still ahead
        case overdue            // below target, deadline passed
        case unreported         // no OS version reported (reporting off)
    }

    /// Pass/fail against the configured baseline, with reasons.
    struct ComplianceResult {
        let passing: Bool
        let failures: [String]
        let unknowns: [String]
    }

    // Per-action feedback
    @State private var busyDeviceID: String?
    @State private var actionNotice: String?
    @State private var actionError: String?

    // Sheets / alerts
    @State private var unenrollTarget: MDMEnrollment?
    @State private var assignTarget: MDMEnrollment?
    @State private var assignSetName = "default"
    @State private var labelTarget: MDMEnrollment?
    @State private var labelText = ""

    /// Device-channel enrollments only — the Macs themselves. User-channel
    /// rows are sync plumbing, not separate machines.
    private var devices: [MDMEnrollment] {
        enrollments.filter(\.isDevice)
    }

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
        .alert(item: $unenrollTarget) { enr in
            Alert(
                title: Text("Remove “\(label(for: enr))” from MDM?"),
                message: Text("Sends a RemoveProfile command for the enrollment profile (\(settings.mdmEnrollmentProfileID)). The Mac unenrolls itself the moment it receives the push — management, declarations, and the MDM certificate all go with it. The device must be online."),
                primaryButton: .destructive(Text("Remove from MDM")) {
                    Task { await unenroll(enr) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $assignTarget) { enr in
            assignSheet(enr)
        }
        .sheet(item: $labelTarget) { enr in
            labelSheet(enr)
        }
        .sheet(item: $lockTarget) { enr in
            LockDeviceSheet(deviceName: label(for: enr)) { pin, message in
                await lock(enr, pin: pin, message: message)
            }
        }
        .sheet(item: $eraseTarget) { enr in
            EraseDeviceSheet(deviceName: label(for: enr)) { pin in
                await erase(enr, pin: pin)
            }
        }
        .alert("Stop enforcing this update?", isPresented: $confirmingEndEnforcement) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Enforcing", role: .destructive) {
                Task { await endEnforcement() }
            }
        } message: {
            Text("Removes the “macOS \(updateTarget?.version ?? "")” enforcement from every set and deletes it. Devices already updating finish on their own; nothing new is forced.")
        }
    }

    // MARK: - Unconfigured states

    private var notConfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Device Management isn't configured")
                .font(.headline)
            Text("Set the NanoMDM and KMFDDM server URLs and API keys in Settings → Device Management, then come back here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsDevicesAPI: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Devices API not set")
                .font(.headline)
            Text("Enter the Devices API URL in Settings → Device Management (the enrollments endpoint next to NanoMDM — usually the same host on its own port). The device list fills itself from there; no manual registration.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Retry") { Task { await refresh() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if devices.isEmpty && !loading {
                VStack(spacing: 8) {
                    Text("No devices enrolled")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Install the enrollment profile on a Mac and it appears here automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !multiSelection.isEmpty { bulkBar }
                HSplitView {
                    List(selection: $selectedDeviceID) {
                        ForEach(devices) { enr in
                            deviceRow(enr)
                                .tag(enr.id)
                                .contextMenu { selectionContextMenu(enr) }
                        }
                        if !onboardableHosts.isEmpty {
                            Section("Not yet enrolled — from BlueSky") {
                                ForEach(onboardableHosts, id: \.blueskyid) { host in
                                    onboardRow(host)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity)
                    .onChange(of: selectedDeviceID) { _, newID in
                        statusValues = []; statusError = nil
                        inventoryKind = nil; inventoryItems = []; inventoryError = nil
                        if let id = newID { Task { await loadStatus(id: id) } }
                    }
                    deviceDetail
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 540)
                }
            }
        }
        .sheet(isPresented: $bulkAssignSheet) { bulkAssignSheetView }
    }

    // MARK: - Bulk actions

    /// Multi-select is driven by ⌘/⇧-click selection captured per-row via
    /// the context menu + a checkbox affordance isn't needed; the bulk bar
    /// appears whenever more than one row's id is in multiSelection. Since
    /// the List selection binding already tracks one id, bulk uses an
    /// explicit Set toggled from the row context menu.
    private var selectedForBulk: [MDMEnrollment] {
        devices.filter { multiSelection.contains($0.id) }
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedForBulk.count) selected").font(.caption).bold()
            Button("Ping") { Task { await bulk { try await NanoMDMService(settings: settings).push(enrollmentIDs: $0.id) } } }
            Button("Assign to Set…") { bulkSetName = "default"; bulkAssignSheet = true }
            Button("Clear") { multiSelection.removeAll() }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private func selectionContextMenu(_ enr: MDMEnrollment) -> some View {
        if multiSelection.contains(enr.id) {
            Button("Deselect") { multiSelection.remove(enr.id) }
        } else {
            Button("Select for bulk action") { multiSelection.insert(enr.id) }
        }
        if !multiSelection.isEmpty {
            Button("Select all") { multiSelection = Set(devices.map(\.id)) }
        }
    }

    private var bulkAssignSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assign \(selectedForBulk.count) devices to a Set").font(.headline)
            TextField("Set name", text: $bulkSetName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { bulkAssignSheet = false }.keyboardShortcut(.cancelAction)
                Button("Assign") {
                    let set = bulkSetName.trimmingCharacters(in: .whitespaces)
                    bulkAssignSheet = false
                    if !set.isEmpty {
                        Task { await bulk { try await KMFDDMService(settings: settings).assign(enrollmentID: $0.id, toSet: set) } }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bulkSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    @MainActor
    private func bulk(_ op: @escaping (MDMEnrollment) async throws -> Void) async {
        let targets = selectedForBulk
        var ok = 0, failed = 0
        for t in targets {
            do { try await op(t); ok += 1 } catch { failed += 1 }
        }
        flash("Bulk action: \(ok) ok\(failed > 0 ? ", \(failed) failed" : "")")
        activity.record(.connect, title: "MDM bulk action on \(targets.count) devices",
                        detail: "\(ok) succeeded, \(failed) failed")
        multiSelection.removeAll()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Devices").font(.headline)
            if loading { ProgressView().controlSize(.small) }
            Text("\(devices.count)")
                .font(.caption).foregroundStyle(.secondary)
            if settings.mdmComplianceConfigured, !devices.isEmpty {
                complianceSummary
            }
            if let target = updateTarget, !devices.isEmpty {
                rolloutSummary(target)
                Button {
                    confirmingEndEnforcement = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop enforcing this update — removes the enforcement from every set and deletes it")
            }
            if let cert = pushCert, let days = cert.daysLeft, days < 60 {
                Label("Push cert expires in \(days) day\(days == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(days < 14 ? .red : .orange)
                    .help("APNs push certificate expires \(cert.notAfter). An expired cert silently kills all MDM communication — renew via identity.apple.com using the vendor cert (sign-push-request.sh), then re-upload to NanoMDM.")
            }
            Spacer()
            if let notice = actionNotice {
                Text(notice).font(.caption).foregroundStyle(.green)
            }
            if let err = actionError {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail)
                    .help(err)
            }
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-fetch the enrolled-device list from the MDM server")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func deviceRow(_ enr: MDMEnrollment) -> some View {
        HStack(spacing: 10) {
            baselineDot(enr)
            Image(systemName: "laptopcomputer")
                .foregroundStyle(enr.isEnabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label(for: enr))
                        .foregroundStyle(enr.isEnabled ? .primary : .secondary)
                    if !enr.isEnabled {
                        Text("unenrolled")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if bscHost(for: enr) != nil {
                        Label("BlueSky", systemImage: "link")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .help("Matched to a BlueSky fleet host by serial number — same machine, both consoles")
                    }
                    if let serial = enr.serialNumber {
                        Text(serial).font(.caption2.monospaced())
                    }
                    if let seen = enr.lastSeenDate {
                        Text("seen \(seen.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer()
            if let fv = fileVault[enr.id] {
                let on = fv == "true" || fv == "1"
                chip(on ? "FV on" : "FV off", color: on ? .green : .red,
                     help: on ? "FileVault disk encryption is on"
                              : "FileVault is OFF — this disk is unencrypted")
            }
            if updateTarget != nil {
                complianceChip(enr)
            }
            if busyDeviceID == enr.id {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await ping(enr) }
            } label: {
                Label("Ping", systemImage: "dot.radiowaves.up.forward")
            }
            .disabled(busyDeviceID != nil || !enr.isEnabled)
            .help("Send an APNs push — the Mac checks in with the MDM within seconds if it's online")

            Menu {
                Button {
                    labelText = label(for: enr)
                    labelTarget = enr
                } label: {
                    Label("Set Label…", systemImage: "tag")
                }
                Button {
                    assignSetName = "default"
                    assignTarget = enr
                } label: {
                    Label("Assign to Set…", systemImage: "rectangle.stack.badge.plus")
                }
                Divider()
                Button {
                    lockTarget = enr
                } label: {
                    Label("Lock Mac…", systemImage: "lock.laptopcomputer")
                }
                .disabled(!enr.isEnabled)
                Button(role: .destructive) {
                    eraseTarget = enr
                } label: {
                    Label("Erase Mac…", systemImage: "externaldrive.badge.xmark")
                }
                .disabled(!enr.isEnabled)
                Divider()
                Button(role: .destructive) {
                    unenrollTarget = enr
                } label: {
                    Label("Remove from MDM…", systemImage: "minus.circle")
                }
                .disabled(!enr.isEnabled)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .disabled(busyDeviceID != nil)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Onboard from BlueSky

    /// Online BlueSky fleet hosts whose serial isn't in the MDM enrollment
    /// list — candidates to onboard. We can reach them over the existing
    /// BSC tunnel to hand them the enrollment profile.
    private var onboardableHosts: [BlueSkyHost] {
        let enrolledSerials = Set(devices.compactMap { $0.serialNumber?.lowercased() })
        return hostStore.hosts.filter { h in
            h.active
                && !(h.serialnum ?? "").isEmpty
                && !enrolledSerials.contains((h.serialnum ?? "").lowercased())
        }
    }

    private func onboardRow(_ host: BlueSkyHost) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.arrow.down").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                Text(host.serialnum ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if busyDeviceID == "bsc-\(host.blueskyid)" {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await onboard(host) }
            } label: {
                Label("Send Profile", systemImage: "paperplane")
            }
            .help("Push the enrollment profile to this Mac's Desktop over the BlueSky tunnel — the user double-clicks it to enroll")
            .disabled(busyDeviceID != nil)
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func onboard(_ host: BlueSkyHost) async {
        busyDeviceID = "bsc-\(host.blueskyid)"
        defer { busyDeviceID = nil }
        // Build the profile from settings + live topic.
        guard !settings.mdmPublicURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !settings.scepChallenge.isEmpty else {
            actionError = "Set the Public enrollment URL and SCEP challenge in Settings → Device Management first."
            return
        }
        guard let topic = pushCert?.topic else {
            actionError = "Push topic unavailable — check the Devices API URL."
            return
        }
        let user = host.effectiveUser(default: settings.defaultRemoteUser)
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            actionError = "No remote username for \(host.displayName) — set one in BlueSky first."
            return
        }
        do {
            let profile = try EnrollmentProfileExporter.makeProfile(.init(
                publicURL: settings.mdmPublicURL,
                challenge: settings.scepChallenge,
                topic: topic,
                profileIdentifier: settings.mdmEnrollmentProfileID
            ))
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("edict-enroll-\(host.blueskyid).mobileconfig")
            try profile.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let svc = ConnectionService(
                server: settings.serverFqdn,
                adminKeyPath: settings.expandedKeyPath,
                serverSshPort: settings.sshTunnelPort,
                terminals: terminals
            )
            let (status, stderr) = await svc.pushFileViaSCP(
                localPath: tmp.path,
                remotePath: "/Users/\(user)/Desktop/Edict-Enroll.mobileconfig",
                host: host, remoteUser: user
            )
            if status == 0 {
                flash("Profile sent to \(host.displayName) — have them open Edict-Enroll.mobileconfig on the Desktop")
                activity.record(.connect, title: "Sent enrollment profile to \(host.displayName)",
                                detail: "via BlueSky tunnel")
            } else {
                actionError = "Couldn't deliver to \(host.displayName): \(stderr.isEmpty ? "exit \(status)" : stderr)"
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Compliance summary

    private var complianceSummary: some View {
        let results = devices.compactMap { complianceResult(for: $0) }
        let pass = results.filter(\.passing).count
        let total = results.count
        return HStack(spacing: 4) {
            Image(systemName: pass == total ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(pass == total ? .green : .red)
            Text("\(pass)/\(total) compliant").font(.caption)
        }
        .help("Against your baseline" +
              (settings.mdmRequireFileVault ? " · FileVault required" : "") +
              (settings.mdmMinOSVersion.isEmpty ? "" : " · macOS ≥ \(settings.mdmMinOSVersion)"))
    }

    // MARK: - Update rollout

    private func rolloutSummary(_ target: UpdateTarget) -> some View {
        let states = devices.map { compliance(for: $0) }
        let done = states.filter { if case .compliant = $0 { return true } else { return false } }.count
        let unreported = states.filter { if case .unreported = $0 { return true } else { return false } }.count
        var text = "Target macOS \(target.version)"
        if let d = target.deadline {
            text += " by \(d.formatted(date: .abbreviated, time: .shortened))"
        }
        text += " — \(done)/\(devices.count) updated"
        if unreported > 0 { text += ", \(unreported) not reporting" }
        return Text(text)
            .font(.caption)
            .foregroundStyle(done == devices.count ? Color.green : Color.secondary)
            .help("From the highest version enforced via Enforce Update…. Devices report their own OS version when Device Reporting is on.")
    }

    @ViewBuilder
    private func complianceChip(_ enr: MDMEnrollment) -> some View {
        let version = osVersions[enr.id]
        switch compliance(for: enr) {
        case .compliant:
            chip(version ?? "✓", color: .green,
                 help: "On or past the enforced version")
        case .behind:
            chip("\(version ?? "?") → \(updateTarget?.version ?? "")", color: .orange,
                 help: "Below the enforced version — deadline hasn't passed yet")
        case .overdue:
            chip("\(version ?? "?") → \(updateTarget?.version ?? "")", color: .red,
                 help: "Below the enforced version and past the deadline")
        case .unreported:
            chip("no report", color: .secondary,
                 help: "This device isn't reporting its OS version — enable Device Reporting")
        }
    }

    private func chip(_ text: String, color: Color, help: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .help(help)
    }

    /// Grade a device against the configured baseline (FileVault, min OS).
    private func complianceResult(for enr: MDMEnrollment) -> ComplianceResult? {
        guard settings.mdmComplianceConfigured else { return nil }
        var failures: [String] = []
        var unknowns: [String] = []
        if settings.mdmRequireFileVault {
            switch fileVault[enr.id] {
            case .some(let v) where v == "true" || v == "1": break
            case .some: failures.append("FileVault off")
            case nil: unknowns.append("FileVault")
            }
        }
        let minOS = settings.mdmMinOSVersion.trimmingCharacters(in: .whitespaces)
        if !minOS.isEmpty {
            if let v = osVersions[enr.id] {
                if !versionAtLeast(v, minOS) { failures.append("macOS \(v) < \(minOS)") }
            } else {
                unknowns.append("macOS version")
            }
        }
        return ComplianceResult(passing: failures.isEmpty && unknowns.isEmpty,
                                failures: failures, unknowns: unknowns)
    }

    @ViewBuilder
    private func baselineDot(_ enr: MDMEnrollment) -> some View {
        if let r = complianceResult(for: enr) {
            if r.passing {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    .help("Meets the compliance baseline")
            } else if !r.failures.isEmpty {
                Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                    .help("Out of compliance: \(r.failures.joined(separator: ", "))")
            } else {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
                    .help("Can't verify: \(r.unknowns.joined(separator: ", ")) not reported")
            }
        }
    }

    private func compliance(for enr: MDMEnrollment) -> Compliance {
        guard let target = updateTarget else { return .unreported }
        guard let version = osVersions[enr.id] else { return .unreported }
        if versionAtLeast(version, target.version) { return .compliant }
        if let deadline = target.deadline, deadline < Date() { return .overdue }
        return .behind
    }

    /// Numeric segment-wise version compare: 15.10 > 15.5.
    private func versionAtLeast(_ v: String, _ target: String) -> Bool {
        let a = v.split(separator: ".").map { Int($0) ?? 0 }
        let b = target.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Read the enforced target from Edict's own enforcement declarations
    /// (ids `com.hellocomputer.edict.update-*`). Multiple enforcements →
    /// the highest version wins; set membership is intentionally ignored
    /// for this fleet-level summary.
    @MainActor
    private func loadUpdateTarget() async {
        do {
            let svc = KMFDDMService(settings: settings)
            let ids = try await svc.listDeclarations()
                .filter { $0.hasPrefix("com.hellocomputer.edict.update-") && !$0.hasSuffix(".activation") }
            var best: UpdateTarget?
            for id in ids {
                let raw = try await svc.declaration(id: id)
                guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let payload = obj["Payload"] as? [String: Any],
                      let version = payload["TargetOSVersion"] as? String
                else { continue }
                let deadline = (payload["TargetLocalDateTime"] as? String)
                    .flatMap { Self.localDateTime.date(from: $0) }
                if best == nil || !versionAtLeast(best!.version, version) {
                    best = UpdateTarget(version: version, deadline: deadline, declarationID: id)
                }
            }
            updateTarget = best
        } catch {
            updateTarget = nil
        }
    }

    /// Reported OS version + FileVault state per device — feeds the
    /// chips and summary.
    @MainActor
    private func loadOSVersions() async {
        let svc = KMFDDMService(settings: settings)
        var versions: [String: String] = [:]
        var fv: [String: String] = [:]
        for d in devices {
            if let values = try? await svc.statusValues(
                enrollmentID: d.id,
                pathPrefix: ".StatusItems.device.operating-system.version"
            ), let v = values.first?.value {
                versions[d.id] = v
            }
            if let values = try? await svc.statusValues(
                enrollmentID: d.id,
                pathPrefix: ".StatusItems.diskmanagement.filevault.enabled"
            ), let v = values.first?.value {
                fv[d.id] = v
            }
        }
        osVersions = versions
        fileVault = fv
    }

    private static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Device detail (live status reported by the device)

    private var selectedEnrollment: MDMEnrollment? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first { $0.id == id }
    }

    /// First reported value whose path ends in `suffix`.
    private func statusValue(_ suffix: String) -> String? {
        statusValues.first { $0.path.hasSuffix(suffix) }?.value
    }

    /// True once the device is reporting real device facts (vs. only the
    /// client-capabilities noise every device sends).
    private var hasDeviceFacts: Bool {
        statusValue("device.operating-system.version") != nil
    }

    @ViewBuilder
    private var deviceDetail: some View {
        if let enr = selectedEnrollment {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailHeader(enr)
                    if let err = statusError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let r = complianceResult(for: enr) {
                        complianceCard(r, enr)
                    }
                    if hasDeviceFacts {
                        osCard
                        securityCard(enr)
                        identityCard(enr)
                    } else if !statusLoading {
                        cardBackground { reportingSetup }
                    }
                    cardBackground { inventorySection(enr) }
                    if hasDeviceFacts {
                        cardBackground { rawValuesDisclosure }
                    }
                }
                .padding(14)
            }
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Select a device").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Big device header: name, model subtitle, online + BlueSky badges,
    /// refresh.
    private func detailHeader(_ enr: MDMEnrollment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 30))
                .foregroundStyle(enr.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(label(for: enr)).font(.title3).bold()
                if let model = statusValue("model.marketing-name") {
                    Text(model).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    chip(enr.isEnabled ? "Enrolled" : "Unenrolled",
                         color: enr.isEnabled ? .green : .secondary,
                         help: "")
                    if bscHost(for: enr) != nil {
                        chip("BlueSky", color: .accentColor, help: "Matched to a BlueSky fleet host")
                    }
                    if let seen = enr.lastSeenDate {
                        Text("seen \(seen.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if statusLoading { ProgressView().controlSize(.small) }
            Button { Task { await loadStatus(id: enr.id) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Re-read this device's reported status")
        }
    }

    private var osCard: some View {
        detailCard("Operating System", "desktopcomputer") {
            if let os = statusValue("operating-system.marketing-name"),
               let ver = statusValue("operating-system.version") {
                infoRow("Version", "\(os) \(ver)")
            } else if let ver = statusValue("operating-system.version") {
                infoRow("Version", ver)
            }
            if let build = statusValue("operating-system.build-version") {
                infoRow("Build", build, mono: true)
            }
            if let fam = statusValue("operating-system.family") {
                infoRow("Family", fam)
            }
        }
    }

    private func securityCard(_ enr: MDMEnrollment) -> some View {
        detailCard("Security", "lock.shield") {
            HStack {
                Text("FileVault").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                if let fv = statusValue("filevault.enabled") {
                    let on = fv == "true" || fv == "1"
                    chip(on ? "On" : "Off", color: on ? .green : .red, help: "")
                } else {
                    Text("unknown").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if updateTarget != nil {
                HStack {
                    Text("Updates").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    complianceChip(enr)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func identityCard(_ enr: MDMEnrollment) -> some View {
        detailCard("Identity", "number") {
            if let serial = statusValue("identifier.serial-number") ?? enr.serialNumber {
                infoRow("Serial", serial, mono: true)
            }
            if let model = statusValue("model.identifier") {
                infoRow("Model ID", model, mono: true)
            }
            infoRow("Hardware UUID", enr.id, mono: true)
            if let host = bscHost(for: enr) {
                infoRow("BlueSky", "\(host.displayName) (#\(host.blueskyid))")
            }
        }
    }

    @ViewBuilder
    private func complianceCard(_ r: ComplianceResult, _ enr: MDMEnrollment) -> some View {
        cardBackground {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: r.passing ? "checkmark.seal.fill"
                          : (r.failures.isEmpty ? "questionmark.circle.fill" : "xmark.seal.fill"))
                        .foregroundStyle(r.passing ? .green : (r.failures.isEmpty ? .secondary : .red))
                    Text(r.passing ? "Compliant" : (r.failures.isEmpty ? "Can't verify" : "Out of compliance"))
                        .font(.caption).bold()
                        .foregroundStyle(r.passing ? .green : (r.failures.isEmpty ? .secondary : .red))
                }
                ForEach(r.failures, id: \.self) { f in
                    HStack {
                        Label(f, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                        Spacer()
                        if f.hasPrefix("FileVault") {
                            Button("Turn on") { Task { await remediateFileVault(enr) } }
                                .font(.caption).buttonStyle(.link)
                                .disabled(busyDeviceID != nil)
                        }
                    }
                }
                ForEach(r.unknowns, id: \.self) { u in
                    Label("\(u) not reported", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private func remediateFileVault(_ enr: MDMEnrollment) async {
        busyDeviceID = enr.id
        defer { busyDeviceID = nil }
        do {
            let profile = ProfilePayloads.fileVault(deferEnable: true)
            _ = try await NanoMDMService(settings: settings).installProfile(enrollmentID: enr.id, profile: profile)
            _ = try? await NanoMDMService(settings: settings).push(enrollmentIDs: enr.id)
            flash("FileVault profile pushed to \(label(for: enr)) — enables at next logout")
            activity.record(.category, title: "Remediated FileVault on \(label(for: enr))")
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Detail card helpers

    private func cardBackground<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func detailCard<C: View>(_ title: String, _ icon: String,
                                     @ViewBuilder _ content: () -> C) -> some View {
        cardBackground {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.caption).bold().foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value).font(mono ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var rawValuesDisclosure: some View {
        DisclosureGroup("All reported values (\(statusValues.count))") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(statusValues, id: \.self) { v in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(v.path.replacingOccurrences(of: ".StatusItems.", with: ""))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(v.value).font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private var reportingSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No device reporting yet")
                .font(.callout).foregroundStyle(.secondary)
            Text("Macs only report what a status-subscription declaration asks for. Enable reporting once and every device in the set keeps its OS version, model, serial, and FileVault state current here — the device pushes changes itself.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Set", text: $reportingSetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button {
                    Task { await enableReporting() }
                } label: {
                    if enablingReporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Enable Device Reporting", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(enablingReporting
                          || reportingSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("This device must be in the set too (⋯ → Assign to Set…). Values appear after its next sync — usually seconds.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func inventorySection(_ enr: MDMEnrollment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Inventory").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Button("Profiles") { Task { await fetchInventory(enr, .profiles) } }
                    .buttonStyle(.link).font(.caption)
                Button("Apps") { Task { await fetchInventory(enr, .apps) } }
                    .buttonStyle(.link).font(.caption)
            }
            if inventoryLoading {
                HStack(spacing: 6) { ProgressView().controlSize(.small)
                    Text("Asking the device…").font(.caption).foregroundStyle(.secondary) }
            } else if let err = inventoryError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let kind = inventoryKind {
                Text("\(kind.rawValue) (\(inventoryItems.count))")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(inventoryItems.prefix(200), id: \.self) { item in
                    Text(item).font(.caption2.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                Text("Query what's installed on this Mac — live from the device.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func fetchInventory(_ enr: MDMEnrollment, _ kind: InventoryKind) async {
        inventoryLoading = true
        inventoryError = nil
        inventoryItems = []
        inventoryKind = kind
        defer { inventoryLoading = false }
        let nano = NanoMDMService(settings: settings)
        let api = EnrollmentsAPI(settings: settings)
        do {
            let uuid: String
            switch kind {
            case .profiles: uuid = try await nano.requestProfileList(enrollmentID: enr.id)
            case .apps:     uuid = try await nano.requestInstalledApps(enrollmentID: enr.id)
            }
            // Push so an idle Mac wakes and answers, then poll the result.
            _ = try? await nano.push(enrollmentIDs: enr.id)
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(2))
                if let res = try await api.commandResult(uuid: uuid) {
                    switch kind {
                    case .profiles:
                        inventoryItems = res.array("ProfileList").compactMap {
                            ($0["PayloadDisplayName"] as? String) ?? ($0["PayloadIdentifier"] as? String)
                        }.sorted()
                    case .apps:
                        inventoryItems = res.array("InstalledApplicationList").compactMap { app in
                            let name = (app["Name"] as? String) ?? (app["Identifier"] as? String) ?? "?"
                            let ver = app["ShortVersion"] as? String ?? app["Version"] as? String
                            return ver.map { "\(name) \($0)" } ?? name
                        }.sorted()
                    }
                    return
                }
            }
            inventoryError = "No answer yet — the Mac may be offline. Try again."
        } catch {
            inventoryError = error.localizedDescription
        }
    }

    @MainActor
    private func loadStatus(id: String) async {
        statusLoading = true
        statusError = nil
        defer { statusLoading = false }
        do {
            statusValues = try await KMFDDMService(settings: settings)
                .statusValues(enrollmentID: id, pathPrefix: ".StatusItems.device")
            // Pull the FileVault + remaining items too when the narrow
            // prefix came back empty — older reports may differ in shape.
            let extra = try await KMFDDMService(settings: settings)
                .statusValues(enrollmentID: id, pathPrefix: ".StatusItems.diskmanagement")
            statusValues.append(contentsOf: extra)
        } catch {
            statusError = error.localizedDescription
        }
    }

    @MainActor
    private func enableReporting() async {
        enablingReporting = true
        defer { enablingReporting = false }
        let configID = "com.hellocomputer.edict.status-subscriptions"
        do {
            try await KMFDDMService(settings: settings).deploy(
                configJSON: DDMDeclarations.statusSubscriptions(identifier: configID),
                configID: configID,
                toSet: reportingSetName.trimmingCharacters(in: .whitespaces)
            )
            flash("Reporting enabled — values arrive as devices sync")
            if let id = selectedDeviceID {
                try? await Task.sleep(for: .seconds(6))
                await loadStatus(id: id)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Labels (local-only friendly names)

    private func label(for enr: MDMEnrollment) -> String {
        if let stored = settings.mdmDevices.first(where: { $0.id == enr.id })?.label,
           !stored.isEmpty {
            return stored
        }
        if let host = bscHost(for: enr) { return host.displayName }
        return enr.serialNumber ?? String(enr.id.prefix(8))
    }

    /// The BSC fleet host with the same serial number, if any.
    private func bscHost(for enr: MDMEnrollment) -> BlueSkyHost? {
        guard let serial = enr.serialNumber, !serial.isEmpty else { return nil }
        return hostStore.hosts.first {
            ($0.serialnum ?? "").caseInsensitiveCompare(serial) == .orderedSame
        }
    }

    private func setLabel(_ text: String, for enr: MDMEnrollment) {
        var list = settings.mdmDevices
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        list.removeAll { $0.id == enr.id }
        if !trimmed.isEmpty {
            list.append(MDMDevice(id: enr.id, label: trimmed))
        }
        settings.mdmDevices = list
    }

    // MARK: - Sheets

    private func assignSheet(_ enr: MDMEnrollment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assign “\(label(for: enr))” to a Set").font(.headline)
            Text("Every declaration in the set flows to this device immediately, and KMFDDM keeps it in sync as the set changes.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Set name", text: $assignSetName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { assignTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Assign") {
                    let set = assignSetName.trimmingCharacters(in: .whitespaces)
                    assignTarget = nil
                    if !set.isEmpty { Task { await assign(enr, set: set) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(assignSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func labelSheet(_ enr: MDMEnrollment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Label for \(enr.serialNumber ?? enr.id)").font(.headline)
            Text("A friendly name shown in this list. Stored locally in Edict; empty falls back to the serial number.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Label", text: $labelText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitLabel(enr) }
            HStack {
                Spacer()
                Button("Cancel") { labelTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitLabel(enr) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func commitLabel(_ enr: MDMEnrollment) {
        setLabel(labelText, for: enr)
        labelTarget = nil
    }

    // MARK: - Data

    @MainActor
    private func refresh() async {
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let api = EnrollmentsAPI(settings: settings)
            var rows = try await api.list()
            // Self-clean: a checked-out device is dead weight. Purge its
            // leftover rows (server refuses with 409 if it's actually
            // still enabled) so the list only ever shows live
            // enrollments — no matter whether the unenroll came from
            // Edict or the user removing the profile on the Mac.
            let dead = rows.filter { $0.isDevice && !$0.isEnabled }
            if !dead.isEmpty {
                for d in dead {
                    try? await api.purge(deviceID: d.id)
                    setLabel("", for: d)
                }
                rows = try await api.list()
            }
            enrollments = rows
            // Rollout data rides along with every refresh: the enforced
            // target + each device's reported facts + push-cert health.
            await loadUpdateTarget()
            await loadOSVersions()
            pushCert = try? await api.pushCert()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Actions

    @MainActor
    private func ping(_ enr: MDMEnrollment) async {
        busyDeviceID = enr.id
        defer { busyDeviceID = nil }
        do {
            _ = try await NanoMDMService(settings: settings).push(enrollmentIDs: enr.id)
            flash("Pushed — \(label(for: enr)) should check in momentarily")
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func assign(_ enr: MDMEnrollment, set: String) async {
        busyDeviceID = enr.id
        defer { busyDeviceID = nil }
        do {
            try await KMFDDMService(settings: settings)
                .assign(enrollmentID: enr.id, toSet: set)
            flash("\(label(for: enr)) assigned to “\(set)”")
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func unenroll(_ enr: MDMEnrollment) async {
        busyDeviceID = enr.id
        defer { busyDeviceID = nil }
        let name = label(for: enr)
        do {
            _ = try await NanoMDMService(settings: settings).unenroll(
                enrollmentID: enr.id,
                profileIdentifier: settings.mdmEnrollmentProfileID
            )
        } catch {
            actionError = error.localizedDescription
            return
        }
        // Wait for the device to receive the push and check out. refresh()
        // auto-purges checked-out devices, so success == the row is gone.
        // ~30s covers an online Mac comfortably; an offline one keeps its
        // row and disappears on whichever refresh follows its checkout.
        activity.record(.delete, title: "Unenrolled \(name)", detail: "RemoveProfile")
        flash("Unenroll sent — waiting for \(name) to check out…")
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(3))
            await refresh()
            if !enrollments.contains(where: { $0.id == enr.id }) {
                flash("\(name) removed and purged")
                return
            }
        }
        flash("\(name) hasn't checked out yet (offline?) — it disappears automatically once it does")
    }

    @MainActor
    private func lock(_ enr: MDMEnrollment, pin: String, message: String?) async {
        busyDeviceID = enr.id
        defer { busyDeviceID = nil }
        do {
            _ = try await NanoMDMService(settings: settings)
                .lock(enrollmentID: enr.id, pin: pin, message: message)
            flash("Lock sent — \(label(for: enr)) locks with PIN \(pin) when it receives the push. Keep that PIN.")
            activity.record(.delete, title: "Locked \(label(for: enr))", detail: "DeviceLock, PIN \(pin)")
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func erase(_ enr: MDMEnrollment, pin: String) async {
        busyDeviceID = enr.id
        defer { busyDeviceID = nil }
        do {
            _ = try await NanoMDMService(settings: settings)
                .erase(enrollmentID: enr.id, pin: pin)
            flash("Erase sent — \(label(for: enr)) wipes when it receives the push. PIN \(pin) unlocks Intel/T2 Macs afterward.")
            activity.record(.delete, title: "ERASED \(label(for: enr))", detail: "EraseDevice, PIN \(pin)")
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func endEnforcement() async {
        guard let target = updateTarget else { return }
        do {
            try await KMFDDMService(settings: settings).retire(configID: target.declarationID)
            flash("Stopped enforcing macOS \(target.version)")
            activity.record(.category, title: "Stopped enforcing macOS \(target.version)")
            await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func flash(_ message: String) {
        actionError = nil
        actionNotice = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if actionNotice == message { actionNotice = nil }
        }
    }
}

// MARK: - Lock sheet

/// PIN + optional message for DeviceLock. The PIN is what unlocks the
/// Mac afterward — losing it means a trip to recovery, so it's front
/// and center in the confirmation.
private struct LockDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deviceName: String
    let onLock: (String, String?) async -> Void

    @State private var pin = ""
    @State private var message = ""
    @State private var working = false

    private var pinValid: Bool {
        pin.count == 6 && pin.allSatisfy(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lock “\(deviceName)”").font(.headline)
            Text("The Mac reboots into a lock screen and is unusable until this 6-digit PIN is entered. Write the PIN down — without it, unlocking requires Apple support or recovery.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6-digit PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            TextField("Message shown on the lock screen (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            HStack {
                if !pin.isEmpty && !pinValid {
                    Label("PIN must be exactly 6 digits", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        await onLock(pin, message.isEmpty ? nil : message)
                        working = false
                        dismiss()
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Lock Mac") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pinValid || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Erase sheet

/// Remote wipe with a typed-name confirmation — the one action in the
/// app with no undo, so it gets the strongest guard.
private struct EraseDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deviceName: String
    let onErase: (String) async -> Void

    @State private var pin = ""
    @State private var confirmText = ""
    @State private var working = false

    private var pinValid: Bool {
        pin.count == 6 && pin.allSatisfy(\.isNumber)
    }
    private var confirmed: Bool {
        confirmText == deviceName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Erase “\(deviceName)”", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)
            Text("This wipes the Mac completely the moment it receives the push. Every file on it is destroyed. There is no undo and no cancel once sent. The PIN unlocks Intel/T2 Macs after the wipe.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6-digit PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            TextField("Type the device name to confirm: \(deviceName)", text: $confirmText)
                .textFieldStyle(.roundedBorder)
            HStack {
                if !pin.isEmpty && !pinValid {
                    Label("PIN must be exactly 6 digits", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    working = true
                    Task {
                        await onErase(pin)
                        working = false
                        dismiss()
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Erase This Mac") }
                }
                .disabled(!pinValid || !confirmed || working)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
