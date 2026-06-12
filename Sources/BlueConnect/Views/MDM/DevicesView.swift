import SwiftUI

/// Edict MDM managed-devices view — the center pane for the sidebar's
/// Device Management → Devices row.
///
/// NanoMDM has no list-enrollments API, so devices are registered here
/// by enrollment ID (the Mac's hardware UUID — System Information →
/// Hardware UUID, or the `id=` field in NanoMDM's checkin logs) and the
/// list persists locally. Per-device actions go through the NanoMDM
/// admin API: Ping (APNs push → device checks in), Assign to Set
/// (KMFDDM association → declarations flow to it), and Remove from MDM
/// (RemoveProfile of the enrollment profile → the device unenrolls
/// itself; it must be online to receive the push).
struct DevicesView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var newID = ""
    @State private var newLabel = ""

    // Per-action feedback
    @State private var busyDeviceID: String?
    @State private var actionNotice: String?
    @State private var actionError: String?

    // Sheets / alerts
    @State private var unenrollTarget: MDMDevice?
    @State private var assignTarget: MDMDevice?
    @State private var assignSetName = "default"

    var body: some View {
        Group {
            if !settings.mdmEnabled || !settings.mdmConfigured {
                notConfigured
            } else {
                content
            }
        }
        .alert(item: $unenrollTarget) { device in
            Alert(
                title: Text("Remove “\(device.label)” from MDM?"),
                message: Text("Sends a RemoveProfile command for the enrollment profile (\(settings.mdmEnrollmentProfileID)). The Mac unenrolls itself the moment it receives the push — management, declarations, and the MDM certificate all go with it. The device must be online."),
                primaryButton: .destructive(Text("Remove from MDM")) {
                    Task { await unenroll(device) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $assignTarget) { device in
            assignSheet(device)
        }
    }

    // MARK: - Empty / unconfigured

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

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if settings.mdmDevices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Devices").font(.headline)
            Text("\(settings.mdmDevices.count)")
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
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            VStack(spacing: 8) {
                Text("No devices registered")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Add an enrolled Mac by its enrollment ID — the hardware UUID shown in System Information, and in NanoMDM's logs as “id=” on every checkin.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            addRow.frame(maxWidth: 560)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(settings.mdmDevices) { device in
                    deviceRow(device)
                }
            }
            .listStyle(.inset)
            Divider()
            addRow.padding(10)
        }
    }

    private func deviceRow(_ device: MDMDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.label)
                Text(device.id)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if busyDeviceID == device.id {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await ping(device) }
            } label: {
                Label("Ping", systemImage: "dot.radiowaves.up.forward")
            }
            .disabled(busyDeviceID != nil)
            .help("Send an APNs push — the Mac checks in with the MDM within seconds if it's online")

            Menu {
                Button {
                    assignSetName = "default"
                    assignTarget = device
                } label: {
                    Label("Assign to Set…", systemImage: "rectangle.stack.badge.plus")
                }
                Divider()
                Button(role: .destructive) {
                    unenrollTarget = device
                } label: {
                    Label("Remove from MDM…", systemImage: "minus.circle")
                }
                Button {
                    forget(device)
                } label: {
                    Label("Forget (remove from this list)", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .disabled(busyDeviceID != nil)
        }
        .padding(.vertical, 3)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Enrollment ID (hardware UUID)", text: $newID)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            TextField("Label", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Button {
                addDevice()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(trimmedNewID.isEmpty)
        }
    }

    private var trimmedNewID: String {
        newID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Assign sheet

    private func assignSheet(_ device: MDMDevice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assign “\(device.label)” to a Set").font(.headline)
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
                    if !set.isEmpty { Task { await assign(device, set: set) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(assignSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Actions

    private func addDevice() {
        let id = trimmedNewID
        guard !id.isEmpty else { return }
        var list = settings.mdmDevices
        guard !list.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            actionError = "That enrollment ID is already registered."
            return
        }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        list.append(MDMDevice(id: id, label: label.isEmpty ? id : label))
        settings.mdmDevices = list
        newID = ""; newLabel = ""
        flash("Device added")
    }

    private func forget(_ device: MDMDevice) {
        settings.mdmDevices.removeAll { $0.id == device.id }
        flash("Forgot \(device.label) — it stays enrolled on the server")
    }

    @MainActor
    private func ping(_ device: MDMDevice) async {
        busyDeviceID = device.id
        defer { busyDeviceID = nil }
        do {
            _ = try await NanoMDMService(settings: settings).push(enrollmentIDs: device.id)
            flash("Pushed — \(device.label) should check in momentarily")
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func assign(_ device: MDMDevice, set: String) async {
        busyDeviceID = device.id
        defer { busyDeviceID = nil }
        do {
            try await KMFDDMService(settings: settings)
                .assign(enrollmentID: device.id, toSet: set)
            flash("\(device.label) assigned to “\(set)”")
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func unenroll(_ device: MDMDevice) async {
        busyDeviceID = device.id
        defer { busyDeviceID = nil }
        do {
            _ = try await NanoMDMService(settings: settings).unenroll(
                enrollmentID: device.id,
                profileIdentifier: settings.mdmEnrollmentProfileID
            )
            flash("Unenroll sent — \(device.label) removes its profile on next checkin")
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
