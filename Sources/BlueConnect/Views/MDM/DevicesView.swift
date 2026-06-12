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
                HSplitView {
                    List(selection: $selectedDeviceID) {
                        ForEach(devices) { enr in
                            deviceRow(enr).tag(enr.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity)
                    .onChange(of: selectedDeviceID) { _, newID in
                        statusValues = []; statusError = nil
                        if let id = newID { Task { await loadStatus(id: id) } }
                    }
                    deviceDetail
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Devices").font(.headline)
            if loading { ProgressView().controlSize(.small) }
            Text("\(devices.count)")
                .font(.caption).foregroundStyle(.secondary)
            if let target = updateTarget, !devices.isEmpty {
                rolloutSummary(target)
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
                    if let serial = enr.serialNumber {
                        Text(serial).font(.caption2.monospaced())
                    }
                    Text(enr.id).font(.caption2.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 280, alignment: .leading)
                    if let seen = enr.lastSeenDate {
                        Text("seen \(seen.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer()
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

    /// One reported OS version per device — feeds the chips and summary.
    @MainActor
    private func loadOSVersions() async {
        let svc = KMFDDMService(settings: settings)
        var result: [String: String] = [:]
        for d in devices {
            if let values = try? await svc.statusValues(
                enrollmentID: d.id,
                pathPrefix: ".StatusItems.device.operating-system.version"
            ), let v = values.first?.value {
                result[d.id] = v
            }
        }
        osVersions = result
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
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(label(for: enr)).font(.headline)
                    Spacer()
                    if statusLoading { ProgressView().controlSize(.small) }
                    Button {
                        Task { await loadStatus(id: enr.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Re-read this device's reported status")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let err = statusError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if hasDeviceFacts {
                            factsGrid
                            rawValuesDisclosure
                        } else if !statusLoading {
                            reportingSetup
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("Select a device")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var factsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if let os = statusValue("operating-system.marketing-name"),
               let ver = statusValue("operating-system.version") {
                fact("macOS", "\(os) \(ver)"
                     + (statusValue("operating-system.build-version").map { " (\($0))" } ?? ""))
            } else if let ver = statusValue("operating-system.version") {
                fact("macOS", ver)
            }
            if let model = statusValue("model.marketing-name") {
                fact("Model", model
                     + (statusValue("model.identifier").map { " — \($0)" } ?? ""))
            }
            if let serial = statusValue("identifier.serial-number") {
                fact("Serial", serial)
            }
            if let fv = statusValue("filevault.enabled") {
                fact("FileVault", fv == "true" || fv == "1" ? "On" : "Off")
            }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).font(.caption).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value).font(.callout).textSelection(.enabled)
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
        return enr.serialNumber ?? String(enr.id.prefix(8))
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
            // target + each device's reported OS version.
            await loadUpdateTarget()
            await loadOSVersions()
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
    private func flash(_ message: String) {
        actionError = nil
        actionNotice = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if actionNotice == message { actionNotice = nil }
        }
    }
}
