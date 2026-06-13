import SwiftUI

/// The MDM half of a Mac's unified detail, shown in the ConnectPanel's
/// "MDM" tab right next to the BlueSky connect actions — so one selected
/// Mac surfaces both worlds and all their actions in one place. Builds its
/// own MDM services from settings; reuses LockDeviceSheet from DevicesView.
struct MDMHostDetail: View {
    @EnvironmentObject private var settings: SettingsStore
    let host: BlueSkyHost
    let entry: MDMFleetIndex.Entry

    @State private var deployed: [DeploymentLog.Entry] = []
    @State private var savedProfiles: [SavedProfile] = []
    @State private var busy = false
    @State private var notice: String?
    @State private var errorText: String?
    @State private var showLock = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmUnenroll = false

    private var nano: NanoMDMService { NanoMDMService(settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusGrid
            Divider()
            profilesSection
            Divider()
            actionsSection
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: entry.enrollmentID) {
            deployed = DeploymentLog.entries(for: entry.enrollmentID)
            savedProfiles = SavedProfilesStore.load()
        }
        .sheet(isPresented: $showLock) {
            LockDeviceSheet(deviceName: host.displayName) { pin, message in
                await act("Lock command sent") { try await nano.lock(enrollmentID: entry.enrollmentID, pin: pin, message: message) }
            }
        }
        .sheet(isPresented: $showRename) { renameSheet }
        .alert("Remove \(host.displayName) from MDM?", isPresented: $confirmUnenroll) {
            Button("Cancel", role: .cancel) {}
            Button("Unenroll", role: .destructive) {
                Task { await act("Unenroll command sent") {
                    try await nano.unenroll(enrollmentID: entry.enrollmentID, profileIdentifier: settings.mdmEnrollmentProfileID)
                } }
            }
        } message: {
            Text("Sends RemoveProfile for the enrollment profile. The Mac drops management, declarations, and its MDM certificate the moment it receives the push. It must be online.")
        }
    }

    // MARK: - Status

    private var statusGrid: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: entry.enrolled ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(entry.enrolled ? .green : .secondary)
                Text(entry.enrolled ? "Enrolled in MDM" : "MDM enrollment checked out").font(.subheadline.bold())
            }
            if let c = entry.compliant {
                row("Compliance", c ? "Meets baseline" : "Out of compliance",
                    color: c ? .green : .orange)
            } else {
                row("Compliance", "Not determined", color: .secondary)
            }
            row("macOS", entry.os ?? "Not reported")
            row("Model", entry.model ?? "Not reported")
            switch entry.fileVault {
            case .some(true): row("FileVault", "On", color: .green)
            case .some(false): row("FileVault", "Off", color: .red)
            case nil: row("FileVault", "Not reported", color: .secondary)
            }
            if let seen = entry.lastSeen {
                row("Last check-in", seen.formatted(.relative(presentation: .named)))
            }
            if let serial = host.serialnum, !serial.isEmpty { row("Serial", serial) }
        }
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.caption).foregroundStyle(color).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Deployed profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profiles Edict deployed (\(deployed.count))").font(.caption.bold())
            if deployed.isEmpty {
                Text("None yet. Deploy from the Profiles tab.").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(deployed, id: \.identifier) { e in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill").font(.caption2).foregroundStyle(.secondary)
                        Text(e.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MDM Actions").font(.caption.bold())
            HStack(spacing: 8) {
                Button { Task { await act("Pushed — \(host.displayName) should check in") { try await nano.push(enrollmentIDs: entry.enrollmentID) } } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if !savedProfiles.isEmpty {
                    Menu {
                        ForEach(savedProfiles) { p in
                            Button(p.name) { Task { await deploy(p) } }
                        }
                    } label: { Label("Deploy profile", systemImage: "paperplane.fill") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            HStack(spacing: 8) {
                Button { renameText = host.displayName; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                Button { showLock = true } label: { Label("Lock", systemImage: "lock.fill") }
                Button { Task { await act("Restart command sent") { try await nano.restart(enrollmentID: entry.enrollmentID) } } } label: { Label("Restart", systemImage: "restart") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button(role: .destructive) { confirmUnenroll = true } label: {
                Label("Unenroll from MDM", systemImage: "shield.slash")
            }
            .buttonStyle(.bordered).controlSize(.small).tint(.red)
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Mac").font(.headline)
            Text("Sets the device name via MDM. The Mac applies it on next check-in.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("New device name", text: $renameText).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showRename = false }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    showRename = false
                    Task { await act("Rename sent: \(name)") { try await nano.setDeviceName(enrollmentID: entry.enrollmentID, name: name) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
    }

    // MARK: - Helpers

    private func deploy(_ p: SavedProfile) async {
        await act("Deployed \(p.name)") {
            let data = try await nano.installProfile(enrollmentID: entry.enrollmentID, profile: p.data)
            _ = try? await nano.push(enrollmentIDs: entry.enrollmentID)
            DeploymentLog.record(profileData: p.data, name: p.name, to: [entry.enrollmentID],
                                 nowEpoch: Date().timeIntervalSince1970)
            deployed = DeploymentLog.entries(for: entry.enrollmentID)
            return data
        }
    }

    /// Run an MDM call with the shared busy/notice/error handling and a
    /// follow-up push so an idle Mac wakes to receive the command.
    @discardableResult
    private func act(_ ok: String, _ op: @escaping () async throws -> Data) async -> Bool {
        busy = true; notice = nil; errorText = nil
        defer { busy = false }
        do {
            _ = try await op()
            _ = try? await nano.push(enrollmentIDs: entry.enrollmentID)
            notice = ok
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }
}
