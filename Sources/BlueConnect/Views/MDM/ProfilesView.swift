import SwiftUI

/// Edict MDM configuration-profile library — the center pane for the
/// sidebar's Device Management → Profiles row. Pick a template, fill a
/// form, choose which enrolled Macs to push it to, and Edict builds the
/// .mobileconfig and sends it via the InstallProfile command. No XML.
struct ProfilesView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(ActivityLog.self) private var activity

    enum Template: String, CaseIterable, Identifiable {
        case wifi = "Wi-Fi Network"
        case passcode = "Password Policy"
        case custom = "Custom Profile"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .passcode: return "lock.rectangle"
            case .custom: return "doc.text"
            }
        }
        var blurb: String {
            switch self {
            case .wifi: return "Auto-join Wi-Fi network pushed to the Mac's system store."
            case .passcode: return "Login password requirements (length, complexity, lock timeout)."
            case .custom: return "Paste any .mobileconfig you already have and deploy it."
            }
        }
    }

    @State private var template: Template = .wifi

    // Wi-Fi
    @State private var ssid = ""
    @State private var wifiPassword = ""
    @State private var wifiHidden = false
    @State private var wifiSecurity: ProfilePayloads.WiFiSecurity = .wpa2

    // Passcode
    @State private var minLength = 8
    @State private var requireAlphanumeric = true
    @State private var maxInactivity = 0   // minutes; 0 = none

    // Custom
    @State private var customXML = ""

    // Targets + deploy
    @State private var devices: [MDMEnrollment] = []
    @State private var targetIDs = Set<String>()
    @State private var loadingDevices = false
    @State private var deploying = false
    @State private var result: String?

    var body: some View {
        Group {
            if !settings.mdmEnabled || !settings.mdmConfigured {
                unconfigured
            } else {
                HSplitView {
                    catalog.frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                    editor.frame(minWidth: 380, maxWidth: .infinity)
                }
            }
        }
        .task { await loadDevices() }
    }

    private var unconfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Device Management isn't configured").font(.headline)
            Text("Set the server URLs and keys in Settings → Device Management first.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var catalog: some View {
        List(Template.allCases, selection: $template) { t in
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.rawValue)
                    Text(t.blurb).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: { Image(systemName: t.icon) }
            .tag(t)
        }
        .listStyle(.sidebar)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(template.rawValue).font(.headline)
                    formForTemplate
                    Divider()
                    targetPicker
                    if let result {
                        Text(result).font(.caption)
                            .foregroundStyle(result.hasPrefix("Deployed") ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    Task { await deploy() }
                } label: {
                    if deploying { ProgressView().controlSize(.small) }
                    else { Label("Deploy to \(targetIDs.count) device\(targetIDs.count == 1 ? "" : "s")",
                                 systemImage: "paperplane.fill") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(deploying || targetIDs.isEmpty || !formValid)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var formForTemplate: some View {
        switch template {
        case .wifi:
            Form {
                TextField("Network name (SSID)", text: $ssid)
                Picker("Security", selection: $wifiSecurity) {
                    ForEach(ProfilePayloads.WiFiSecurity.allCases) { Text($0.rawValue).tag($0) }
                }
                if wifiSecurity.needsPassword {
                    SecureField("Password", text: $wifiPassword)
                }
                Toggle("Hidden network", isOn: $wifiHidden)
            }
            .formStyle(.columns)
        case .passcode:
            Form {
                Stepper("Minimum length: \(minLength)", value: $minLength, in: 4...64)
                Toggle("Require letters and numbers", isOn: $requireAlphanumeric)
                Stepper(maxInactivity == 0 ? "Auto-lock: off"
                        : "Auto-lock after \(maxInactivity) min",
                        value: $maxInactivity, in: 0...60, step: 5)
            }
            .formStyle(.columns)
        case .custom:
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste a .mobileconfig (XML). It must be a Configuration profile.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $customXML)
                    .font(.caption.monospaced())
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Deploy to").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                if loadingDevices { ProgressView().controlSize(.small) }
                Button(targetIDs.count == devices.count ? "None" : "All") {
                    targetIDs = targetIDs.count == devices.count ? [] : Set(devices.map(\.id))
                }
                .font(.caption).buttonStyle(.link)
            }
            if devices.isEmpty && !loadingDevices {
                Text("No enrolled devices. Enroll a Mac first (Devices tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(devices) { d in
                Toggle(isOn: Binding(
                    get: { targetIDs.contains(d.id) },
                    set: { if $0 { targetIDs.insert(d.id) } else { targetIDs.remove(d.id) } }
                )) {
                    Text(deviceLabel(d))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func deviceLabel(_ d: MDMEnrollment) -> String {
        if let stored = settings.mdmDevices.first(where: { $0.id == d.id })?.label, !stored.isEmpty {
            return stored
        }
        return d.serialNumber ?? String(d.id.prefix(8))
    }

    private var formValid: Bool {
        switch template {
        case .wifi: return !ssid.trimmingCharacters(in: .whitespaces).isEmpty
        case .passcode: return true
        case .custom: return !customXML.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func buildProfile() throws -> (data: Data, name: String) {
        switch template {
        case .wifi:
            return (ProfilePayloads.wifi(ssid: ssid, password: wifiPassword,
                                         hidden: wifiHidden, security: wifiSecurity),
                    "Wi-Fi “\(ssid)”")
        case .passcode:
            return (ProfilePayloads.passcode(minLength: minLength,
                                             requireAlphanumeric: requireAlphanumeric,
                                             maxInactivityMinutes: maxInactivity == 0 ? nil : maxInactivity),
                    "Password Policy")
        case .custom:
            return (try ProfilePayloads.custom(xml: customXML), "Custom profile")
        }
    }

    @MainActor
    private func loadDevices() async {
        guard settings.mdmEnabled, settings.mdmConfigured,
              !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        devices = (try? await EnrollmentsAPI(settings: settings).list().filter(\.isDevice)) ?? []
    }

    @MainActor
    private func deploy() async {
        deploying = true
        result = nil
        defer { deploying = false }
        let built: (data: Data, name: String)
        do { built = try buildProfile() }
        catch { result = "Couldn't build profile: \(error.localizedDescription)"; return }

        let nano = NanoMDMService(settings: settings)
        let targets = devices.filter { targetIDs.contains($0.id) }
        var ok = 0, failed = 0
        for t in targets {
            do {
                try await nano.installProfile(enrollmentID: t.id, profile: built.data)
                _ = try? await nano.push(enrollmentIDs: t.id)
                ok += 1
            } catch { failed += 1 }
        }
        result = failed == 0
            ? "Deployed \(built.name) to \(ok) device\(ok == 1 ? "" : "s")"
            : "Deployed to \(ok), failed \(failed)"
        activity.record(.category, title: "Deployed profile: \(built.name)",
                        detail: "\(ok) device\(ok == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) failed" : ""))
    }
}
