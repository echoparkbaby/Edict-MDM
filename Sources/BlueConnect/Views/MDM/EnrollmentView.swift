import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edict MDM enrollment-profile builder — the center pane for the
/// sidebar's Device Management → Enrollment row. Personalize the profile
/// users see, sign it with your Developer ID so it installs as Verified,
/// and download it to hand out.
struct EnrollmentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(ActivityLog.self) private var activity
    @Environment(DDMLibraryStore.self) private var ddmLibrary

    @State private var savedProfiles: [SavedProfile] = []
    @State private var challengeBuffer = ""
    @State private var topic: String?
    @State private var signingIdentity: String?
    @State private var signProfile = true
    @State private var working = false
    @State private var status: String?
    @State private var statusIsError = false

    private var ready: Bool {
        !settings.mdmPublicURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !challengeBuffer.isEmpty
            && topic != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                serverCard
                personalizationCard
                onboardingCard
                signingCard
                actionRow
                if let status {
                    Label(status, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(statusIsError ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)   // center the column — no dead space on the right
        }
        .frame(maxWidth: .infinity)
        .task {
            challengeBuffer = settings.scepChallenge
            signingIdentity = EnrollmentProfileExporter.developerIDIdentity()
            savedProfiles = SavedProfilesStore.load()
            await loadTopic()
        }
    }

    // MARK: - Onboarding baseline

    private var onboardSets: [String] { ddmLibrary.setNames }

    private var onboardingCard: some View {
        card("Onboarding baseline", "shippingbox") {
            Text("The enrollment profile only enrolls a Mac. Pick what every newly-enrolled Mac should then receive — Edict applies it automatically the next time it refreshes the fleet (there's no instant enrollment signal, so it lands within a refresh cycle, not the same second). A per-device Onboard button is on each device's detail too.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Automatically onboard new Macs", isOn: $settings.mdmOnboardingEnabled)
                .onChange(of: settings.mdmOnboardingEnabled) { _, on in
                    if on { settings.mdmOnboardingEnabledAt = Date().timeIntervalSince1970 }
                }
            if settings.mdmOnboardingEnabled {
                Text("Applies only to Macs that enroll from now on. Use the Onboard button on a device to baseline ones that enrolled earlier.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Configuration profiles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if savedProfiles.isEmpty {
                Text("No saved profiles yet — build and save some in the Profiles tab.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(savedProfiles) { p in
                    Toggle(isOn: profileBinding(p.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.callout)
                            if !p.summary.isEmpty {
                                Text(p.summary).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            Text("Declaration sets").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if onboardSets.isEmpty {
                Text("No declaration sets yet — create them in Declarations → Sets.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(onboardSets, id: \.self) { set in
                    Toggle(set, isOn: setBinding(set))
                }
            }

            if settings.hasOnboardingBaseline {
                Divider()
                Text("New Macs will get \(settings.mdmOnboardProfileIDs.count) profile\(settings.mdmOnboardProfileIDs.count == 1 ? "" : "s") and \(settings.mdmOnboardSets.count) set\(settings.mdmOnboardSets.count == 1 ? "" : "s").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func profileBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.mdmOnboardProfileIDs.contains(id) },
            set: { on in
                var ids = settings.mdmOnboardProfileIDs
                if on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
                settings.mdmOnboardProfileIDs = ids
            })
    }

    private func setBinding(_ set: String) -> Binding<Bool> {
        Binding(
            get: { settings.mdmOnboardSets.contains(set) },
            set: { on in
                var sets = settings.mdmOnboardSets
                if on { if !sets.contains(set) { sets.append(set) } } else { sets.removeAll { $0 == set } }
                settings.mdmOnboardSets = sets
            })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enrollment Profile").font(.title2).bold()
            Text("Build the .mobileconfig new devices install to enroll. The same profile enrolls Macs, iPhones, iPads, and Apple TVs (user enrollment via download). Hand it out by AirDrop, a download link, or push it to a fleet Mac from the Devices tab. Zero-touch / supervised iOS & tvOS needs Apple Configurator or Automated Device Enrollment.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline).bold()
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var serverCard: some View {
        card("Server", "server.rack") {
            LabeledContent("Public URL") {
                TextField("", text: $settings.mdmPublicURL, prompt: Text(verbatim: "https://mdm.example.com"))
            }
            LabeledContent("SCEP challenge") {
                SecureField("", text: $challengeBuffer)
                    .onChange(of: challengeBuffer) { _, v in settings.setSCEPChallenge(v) }
            }
            Text("The SCEP challenge is the shared secret your SCEP server requires before it hands a device its identity certificate. It's embedded in the profile so the Mac can authenticate to SCEP during enrollment. It's the `-challenge` value in your stack's .env (SCEP_CHALLENGE) — without it, enrollment fails at the certificate step.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: topic != nil ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(topic != nil ? .green : .secondary)
                Text(topic.map { "Push topic: \($0)" } ?? "Push topic unavailable — check the Devices API URL in Settings")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var personalizationCard: some View {
        card("Personalization", "textformat") {
            LabeledContent("Display name") {
                TextField("", text: $settings.mdmProfileDisplayName, prompt: Text("Edict MDM Enrollment"))
            }
            LabeledContent("Organization") {
                TextField("", text: $settings.mdmProfileOrganization, prompt: Text("McMurtrie Consulting"))
            }
            LabeledContent("Description") {
                TextField("", text: $settings.mdmProfileDescription, prompt: Text("Enrolls this Mac into management."))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Consent text (shown at install)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $settings.mdmProfileConsentText)
                    .font(.caption).frame(minHeight: 54)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private var signingCard: some View {
        card("Signing", "signature") {
            if let id = signingIdentity {
                Toggle(isOn: $signProfile) {
                    Text("Sign with Developer ID")
                }
                Text(signProfile
                     ? "Signs as “\(id)” — the profile installs as Verified instead of showing an unsigned warning."
                     : "Profile will be unsigned (installs with an “Unverified” warning).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No Developer ID found in your keychain — the profile will be unsigned.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button {
                Task { await download() }
            } label: {
                if working { ProgressView().controlSize(.small) }
                else { Label("Download Profile…", systemImage: "arrow.down.circle.fill") }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!ready || working)
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadTopic() async {
        guard !settings.mdmDevicesAPIBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        topic = try? await EnrollmentsAPI(settings: settings).pushCert().topic
    }

    @MainActor
    private func download() async {
        working = true; status = nil; statusIsError = false
        defer { working = false }
        guard let topic else { fail("Push topic unavailable."); return }
        do {
            var data = try EnrollmentProfileExporter.makeProfile(.init(
                publicURL: settings.mdmPublicURL,
                challenge: settings.scepChallenge,
                topic: topic,
                profileIdentifier: settings.mdmEnrollmentProfileID,
                displayName: settings.mdmProfileDisplayName,
                organization: settings.mdmProfileOrganization,
                profileDescription: settings.mdmProfileDescription,
                consentText: settings.mdmProfileConsentText
            ))
            var note = "unsigned"
            if signProfile, let id = signingIdentity {
                data = try EnrollmentProfileExporter.sign(data, identity: id)
                note = "signed"
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Edict-Enroll.mobileconfig"
            panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            status = "Saved \(url.lastPathComponent) — \(note). Install it on a Mac to enroll."
            activity.record(.connect, title: "Exported enrollment profile", detail: note)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ msg: String) { status = msg; statusIsError = true }
}
