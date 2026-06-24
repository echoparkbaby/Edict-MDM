import SwiftUI

/// Apple Automated Device Enrollment (DEP) via NanoDEP + Apple Business
/// Manager — the zero-touch path. Configure the NanoDEP server in Settings,
/// see the devices ABM assigned to this MDM, build a DEP enrollment profile
/// (supervised / mandatory / Setup-Assistant skips), assign it to devices, and
/// optionally set it as the auto-assigner so new ABM devices enroll on their own.
///
/// Built against NanoDEP + Apple's DEP web service, but NOT verified against a
/// live ABM token — the banner says so.
struct DEPView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(ActivityLog.self) private var activity

    @State private var account: DEPAccount?
    @State private var devices: [DEPDevice] = []
    @State private var selection = Set<String>()
    @State private var loadingAccount = false
    @State private var loadingDevices = false
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showProfileSheet = false
    @State private var lastProfileUUID: String?
    @State private var autoAssignerUUID: String?

    private var svc: NanoDEPService { NanoDEPService(settings: settings) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                untestedBanner
                if !settings.depConfigured {
                    notConfigured
                } else {
                    accountCard
                    devicesCard
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18).frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)   // center — no dead space on the right
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showProfileSheet) {
            DEPProfileSheet(defaultURL: defaultEnrollURL) { uuid, setAuto in
                lastProfileUUID = uuid
                if setAuto { autoAssignerUUID = uuid }
                flash("Created DEP profile \(uuid.prefix(8))…" + (setAuto ? " and set as auto-assigner" : ""))
            }
            .environmentObject(settings)
        }
        .task { if settings.depConfigured { await loadAccount(); await loadAssigner() } }
    }

    private var defaultEnrollURL: String {
        NanoDEPService.enrollURL(publicBase: settings.mdmPublicURL)
    }

    // MARK: - Header / states

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Automated Enrollment (DEP)").font(.title2).bold()
            Text("Zero-touch enrollment for devices in Apple Business Manager. A device assigned here enrolls into MDM automatically when it's first set up — no profile to install. Needs an ABM (or ASM) account and a running NanoDEP server.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var untestedBanner: some View {
        Label("This feature is built to NanoDEP + Apple's DEP spec but hasn't been verified against a live Apple Business Manager token. Treat assignment actions with care.",
              systemImage: "flask")
            .font(.caption).foregroundStyle(.orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("NanoDEP isn't configured", systemImage: "gearshape").font(.subheadline.bold())
            Text("Set the NanoDEP server URL, API key, and DEP name in Settings → Device Management. NanoDEP also needs your ABM MDM-server token loaded (a one-time server-side step).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Account

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Apple Business Manager", systemImage: "building.2").font(.subheadline.bold())
                Spacer()
                Button { Task { await loadAccount() } } label: {
                    if loadingAccount { ProgressView().controlSize(.small) }
                    else { Label("Test / refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(loadingAccount)
            }
            if let a = account {
                row("Organization", a.orgName ?? "—")
                row("MDM server", a.serverName ?? "—")
                row("Admin", a.adminID ?? "—")
                if let uuid = autoAssignerUUID {
                    row("Auto-assigner", "\(uuid.prefix(8))… — applied to new devices when the server's depsyncer runs")
                } else {
                    row("Auto-assigner", "none set")
                }
            } else {
                Text("Test the connection to load your ABM account detail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ABM Devices", systemImage: "ipad.and.iphone").font(.subheadline.bold())
                if !devices.isEmpty { Text("\(devices.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { showProfileSheet = true } label: { Label("New DEP Profile", systemImage: "plus") }
                Button { Task { await loadDevices() } } label: {
                    if loadingDevices { ProgressView().controlSize(.small) }
                    else { Label("Fetch devices", systemImage: "arrow.down.circle") }
                }
                .disabled(loadingDevices)
            }
            if devices.isEmpty {
                Text("Fetch the devices Apple Business Manager has assigned to this MDM server. (Empty is normal if no devices are assigned yet.)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Table(devices, selection: $selection) {
                    TableColumn("Serial") { Text($0.serialNumber).font(.callout.monospaced()) }.width(min: 100, ideal: 130)
                    TableColumn("Model") { Text($0.model ?? $0.description ?? "—") }
                    TableColumn("OS") { Text(osLabel($0)) }.width(min: 50, ideal: 80, max: 110)
                    TableColumn("Profile") { d in profileStatusChip(d.profileStatus) }.width(min: 70, ideal: 90, max: 120)
                }
                .frame(minHeight: 220, maxHeight: 360)

                if !selection.isEmpty, let uuid = lastProfileUUID {
                    HStack {
                        Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await assign(uuid: uuid) } } label: {
                            if working { ProgressView().controlSize(.small) }
                            else { Label("Assign “\(uuid.prefix(8))…” to selected", systemImage: "checkmark.circle") }
                        }
                        .disabled(working)
                    }
                } else if !selection.isEmpty {
                    Text("Create a DEP profile first, then assign it to the selected devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func osLabel(_ d: DEPDevice) -> String {
        [d.deviceFamily, d.os].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces).ifEmpty("—")
    }

    @ViewBuilder
    private func profileStatusChip(_ status: String?) -> some View {
        let s = (status ?? "empty").lowercased()
        let (label, color): (String, Color) = {
            switch s {
            case "pushed":   return ("Pushed", .green)
            case "assigned": return ("Assigned", .blue)
            case "removed":  return ("Removed", .secondary)
            default:          return ("None", .secondary)
            }
        }()
        Text(label).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    // MARK: - Actions

    @MainActor private func loadAccount() async {
        loadingAccount = true; error = nil; defer { loadingAccount = false }
        do { account = try await svc.account() }
        catch { self.error = friendly(error) }
    }

    @MainActor private func loadAssigner() async {
        autoAssignerUUID = try? await svc.autoAssigner()
    }

    @MainActor private func loadDevices() async {
        loadingDevices = true; error = nil; defer { loadingDevices = false }
        do { devices = try await svc.allDevices() }
        catch { self.error = friendly(error) }
    }

    @MainActor private func assign(uuid: String) async {
        working = true; error = nil; defer { working = false }
        let serials = Array(selection)
        do {
            let result = try await svc.assignProfile(uuid: uuid, serials: serials)
            let ok = result.values.filter { $0.uppercased() == "SUCCESS" }.count
            flash("Assigned to \(ok)/\(serials.count) device\(serials.count == 1 ? "" : "s")")
            activity.record(.category, title: "DEP profile assigned", detail: "\(ok)/\(serials.count) devices")
            await loadDevices()
        } catch { self.error = friendly(error) }
    }

    private func flash(_ message: String) {
        error = nil; notice = message
        Task { try? await Task.sleep(for: .seconds(4)); if notice == message { notice = nil } }
    }

    private func friendly(_ error: Error) -> String {
        (error as? MDMError)?.localizedDescription ?? error.localizedDescription
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
