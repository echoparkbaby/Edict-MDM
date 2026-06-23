import SwiftUI

/// Build a DEP enrollment profile in Apple Business Manager via NanoDEP — the
/// profile that makes an assigned device auto-enroll. Pick the enrollment URL,
/// supervision/mandatory flags, and which Setup Assistant panes to skip, then
/// create it (optionally as the auto-assigner for all new ABM devices).
struct DEPProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    let defaultURL: String
    /// (profileUUID, wasSetAsAutoAssigner)
    let onCreate: (String, Bool) -> Void

    @State private var name = "Edict Auto-Enroll"
    @State private var url = ""
    @State private var supervised = true
    @State private var mandatory = false
    @State private var mdmRemovable = true
    @State private var awaitConfigured = false
    @State private var allowPairing = true
    @State private var supportPhone = ""
    @State private var supportEmail = ""
    @State private var department = ""
    @State private var skip = Set(DEPProfileSheet.defaultSkips)
    @State private var setAsAutoAssigner = true
    @State private var working = false
    @State private var error: String?

    /// Common macOS/iOS Setup Assistant panes (key, label). The annoying ones
    /// are skipped by default.
    static let skipCatalog: [(key: String, label: String)] = [
        ("AppleID", "Apple Account sign-in"),
        ("Siri", "Siri"),
        ("TOS", "Terms of Service"),
        ("Diagnostics", "Diagnostics / analytics"),
        ("Privacy", "Privacy"),
        ("Payment", "Apple Pay"),
        ("Location", "Location Services"),
        ("Restore", "Restore / migration"),
        ("Biometric", "Touch ID / Face ID"),
        ("ScreenTime", "Screen Time"),
        ("FileVault", "FileVault"),
        ("Accessibility", "Accessibility"),
        ("Appearance", "Appearance (light/dark)"),
        ("iCloudStorage", "iCloud storage"),
        ("SoftwareUpdate", "Software Update"),
        ("UnlockWithWatch", "Unlock with Apple Watch"),
    ]
    static let defaultSkips = ["AppleID", "Siri", "TOS", "Diagnostics", "Privacy", "Payment", "Location", "Restore"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New DEP Enrollment Profile").font(.headline)

            Form {
                Section("Basics") {
                    TextField("Profile name", text: $name)
                    TextField("Enrollment URL", text: $url, prompt: Text(verbatim: "https://mdm.example.com/mdm/enroll"))
                        .help("Where the device fetches its enrollment profile during Setup Assistant — for NanoMDM the /mdm/enroll endpoint, NOT the /mdm check-in path. Verify against your enrollment service.")
                }
                Section("Behavior") {
                    Toggle("Supervised", isOn: $supervised)
                    Toggle("Mandatory (user can't skip enrollment)", isOn: $mandatory)
                    Toggle("MDM profile removable", isOn: $mdmRemovable)
                    Toggle("Wait until configured (await Setup Assistant)", isOn: $awaitConfigured)
                    Toggle("Allow pairing (Configurator/Xcode)", isOn: $allowPairing)
                }
                Section("Skip Setup Assistant panes") {
                    ForEach(Self.skipCatalog, id: \.key) { item in
                        Toggle(item.label, isOn: binding(for: item.key))
                    }
                }
                Section("Support (optional)") {
                    TextField("Department", text: $department)
                    TextField("Support phone", text: $supportPhone)
                    TextField("Support email", text: $supportEmail)
                }
                Section {
                    Toggle("Set as auto-assigner for new ABM devices", isOn: $setAsAutoAssigner)
                    Text("New devices get this profile automatically — but only once the server's depsyncer runs (it's not instant).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 420)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create in ABM") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { if url.isEmpty { url = defaultURL } }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(get: { skip.contains(key) },
                set: { on in if on { skip.insert(key) } else { skip.remove(key) } })
    }

    @MainActor private func create() async {
        working = true; error = nil; defer { working = false }
        do {
            let svc = NanoDEPService(settings: settings)
            let uuid = try await svc.defineProfile(
                profileName: name.trimmingCharacters(in: .whitespaces),
                url: url.trimmingCharacters(in: .whitespaces),
                supervised: supervised, mandatory: mandatory, mdmRemovable: mdmRemovable,
                awaitConfigured: awaitConfigured, allowPairing: allowPairing,
                supportPhone: supportPhone, supportEmail: supportEmail, department: department,
                skipSetupItems: Array(skip))
            if setAsAutoAssigner { try await svc.setAutoAssigner(profileUUID: uuid) }
            onCreate(uuid, setAsAutoAssigner)
            dismiss()
        } catch {
            self.error = (error as? MDMError)?.localizedDescription ?? error.localizedDescription
        }
    }
}
