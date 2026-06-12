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
                List {
                    ForEach(devices) { enr in
                        deviceRow(enr)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Devices").font(.headline)
            if loading { ProgressView().controlSize(.small) }
            Text("\(devices.count)")
                .font(.caption).foregroundStyle(.secondary)
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
            enrollments = try await EnrollmentsAPI(settings: settings).list()
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
        do {
            _ = try await NanoMDMService(settings: settings).unenroll(
                enrollmentID: enr.id,
                profileIdentifier: settings.mdmEnrollmentProfileID
            )
            flash("Unenroll sent — \(label(for: enr)) removes its profile on next checkin")
            // Give the device a moment to check out, then reflect reality.
            try? await Task.sleep(for: .seconds(4))
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
