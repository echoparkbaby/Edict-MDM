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
    @State private var showErase = false
    @State private var confirmShutdown = false
    @State private var enablingReporting = false

    // Live inventory pulled straight from the Mac.
    enum InvKind: String { case hardware = "Hardware", profiles = "Profiles", apps = "Apps" }
    @State private var invKind: InvKind?
    @State private var invItems: [String] = []
    @State private var invLoading = false
    @State private var invError: String?

    private var nano: NanoMDMService { NanoMDMService(settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusGrid
            Divider()
            inventorySection
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
        .sheet(isPresented: $showErase) {
            EraseDeviceSheet(deviceName: host.displayName) { pin in
                await act("Erase command sent — the Mac wipes on receipt") {
                    try await nano.erase(enrollmentID: entry.enrollmentID, pin: pin)
                }
            }
        }
        .alert("Shut down \(host.displayName)?", isPresented: $confirmShutdown) {
            Button("Cancel", role: .cancel) {}
            Button("Shut Down", role: .destructive) {
                Task { await act("Shutdown command sent") { try await nano.shutDown(enrollmentID: entry.enrollmentID) } }
            }
        } message: {
            Text("The Mac powers off when it receives the command. It must be online now.")
        }
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

    // MARK: - Live inventory (queried from the Mac)

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Inventory").font(.caption.bold())
                Spacer()
                if invLoading { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 6) {
                ForEach([InvKind.hardware, .profiles, .apps], id: \.self) { kind in
                    Button(kind.rawValue) { Task { await fetchInv(kind) } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(invLoading)
                }
            }
            if let invError {
                Text(invError).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let invKind, !invLoading {
                if invItems.isEmpty {
                    Text("\(invKind.rawValue): nothing reported.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(invItems.prefix(40), id: \.self) { item in
                            Text(item).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        if invItems.count > 40 {
                            Text("+ \(invItems.count - 40) more…").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("Query live hardware, installed profiles, or apps straight from this Mac.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
            // Enable reporting fixes the "Not reported" facts: subscribes
            // the Mac to report OS / model / FileVault via DDM status.
            if entry.os == nil || entry.fileVault == nil {
                Button { Task { await enableReporting() } } label: {
                    if enablingReporting { ProgressView().controlSize(.small) }
                    else { Label("Enable reporting", systemImage: "antenna.radiowaves.left.and.right") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Subscribe this Mac to report OS, model, and FileVault status so its facts stop showing “Not reported”.")
            }
            HStack(spacing: 8) {
                Button { renameText = host.displayName; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                Button { showLock = true } label: { Label("Lock", systemImage: "lock.fill") }
                Button { Task { await act("Restart command sent") { try await nano.restart(enrollmentID: entry.enrollmentID) } } } label: { Label("Restart", systemImage: "restart") }
                Button { confirmShutdown = true } label: { Label("Shut Down", systemImage: "power") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            HStack(spacing: 8) {
                Button(role: .destructive) { confirmUnenroll = true } label: {
                    Label("Unenroll", systemImage: "shield.slash")
                }
                .tint(.red)
                Button(role: .destructive) { showErase = true } label: {
                    Label("Erase", systemImage: "trash.fill")
                }
                .tint(.red)
            }
            .buttonStyle(.bordered).controlSize(.small)
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

    /// Subscribe the Mac to DDM status reporting (OS / model / FileVault),
    /// so the dashboard, columns, and this pane stop reading "Not reported".
    /// Deploys the subscription to the default set and assigns this device.
    private func enableReporting() async {
        enablingReporting = true
        notice = nil; errorText = nil
        defer { enablingReporting = false }
        let set = "default"
        let configID = "com.hellocomputer.edict.status-subscriptions"
        do {
            let kmf = KMFDDMService(settings: settings)
            try await kmf.deploy(configJSON: DDMDeclarations.statusSubscriptions(identifier: configID),
                                 configID: configID, toSet: set)
            try await kmf.assign(enrollmentID: entry.enrollmentID, toSet: set)
            _ = try? await nano.push(enrollmentIDs: entry.enrollmentID)
            notice = "Reporting enabled — facts arrive as the Mac syncs."
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Query live inventory from the Mac (DeviceInformation / ProfileList /
    /// InstalledApplicationList), pushing so an idle Mac wakes to answer.
    private func fetchInv(_ kind: InvKind) async {
        invKind = kind; invItems = []; invError = nil; invLoading = true
        defer { invLoading = false }
        let api = EnrollmentsAPI(settings: settings)
        do {
            let uuid: String
            switch kind {
            case .hardware: uuid = try await nano.requestDeviceInformation(enrollmentID: entry.enrollmentID)
            case .profiles: uuid = try await nano.requestProfileList(enrollmentID: entry.enrollmentID)
            case .apps:     uuid = try await nano.requestInstalledApps(enrollmentID: entry.enrollmentID)
            }
            _ = try? await nano.push(enrollmentIDs: entry.enrollmentID)
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(2))
                guard let res = try await api.commandResult(uuid: uuid) else { continue }
                switch kind {
                case .hardware:
                    invItems = Self.formatDeviceInformation(res.dict("QueryResponses"))
                case .profiles:
                    invItems = res.array("ProfileList").compactMap {
                        ($0["PayloadDisplayName"] as? String) ?? ($0["PayloadIdentifier"] as? String)
                    }.sorted()
                case .apps:
                    invItems = res.array("InstalledApplicationList").compactMap { app in
                        let name = (app["Name"] as? String) ?? (app["Identifier"] as? String) ?? "?"
                        let ver = app["ShortVersion"] as? String ?? app["Version"] as? String
                        return ver.map { "\(name) \($0)" } ?? name
                    }.sorted()
                }
                return
            }
            invError = "No answer yet — the Mac may be offline. Try again."
        } catch {
            invError = error.localizedDescription
        }
    }

    /// Readable rows from a DeviceInformation QueryResponses dict.
    private static func formatDeviceInformation(_ q: [String: Any]) -> [String] {
        var out: [String] = []
        func gb(_ v: Any?) -> String? {
            if let d = v as? Double { return String(format: "%.1f GB", d) }
            if let i = v as? Int { return "\(i) GB" }
            return nil
        }
        if let model = q["ModelName"] as? String ?? q["ProductName"] as? String { out.append("Model: \(model)") }
        if let os = q["OSVersion"] as? String {
            out.append("OS: \(os)" + ((q["BuildVersion"] as? String).map { " (\($0))" } ?? ""))
        }
        if let avail = gb(q["AvailableDeviceCapacity"]), let total = gb(q["DeviceCapacity"]) {
            out.append("Storage: \(avail) free of \(total)")
        }
        if let b = q["BatteryLevel"] as? Double, b >= 0 { out.append("Battery: \(Int(b * 100))%") }
        if let serial = q["SerialNumber"] as? String { out.append("Serial: \(serial)") }
        if let name = q["DeviceName"] as? String { out.append("Device name: \(name)") }
        if let mac = q["WiFiMAC"] as? String { out.append("Wi-Fi MAC: \(mac)") }
        if let mac = q["EthernetMAC"] as? String { out.append("Ethernet MAC: \(mac)") }
        return out
    }

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
