import SwiftUI

/// Settings → Device Management. Points Edict at its NanoMDM + KMFDDM
/// servers (the Apple MDM core + the declarative-management server).
///
/// These are the ADMIN APIs, reached over the tailnet — e.g.
/// `http://192.0.2.10:9090` (NanoMDM) and `http://192.0.2.10:9093`
/// (KMFDDM) — not the public device-facing enrollment URL. Test
/// Connection exercises both services plus a live declarations fetch, so
/// a green result confirms the whole service layer end to end.
struct MDMSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var nanoKeyBuffer: String = ""
    @State private var kmfddmKeyBuffer: String = ""
    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case success(nano: String, kmfddm: String, declarations: Int)
        case failure(String)
    }

    var body: some View {
        Form {
            enableSection
            if settings.mdmEnabled {
                nanoSection
                kmfddmSection
                testSection
            }
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            nanoKeyBuffer = settings.nanoMDMAPIKey
            kmfddmKeyBuffer = settings.kmfddmAPIKey
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle("Enable Device Management", isOn: $settings.mdmEnabled)
            Text("Connects Edict to your NanoMDM + KMFDDM servers for Apple MDM and Declarative Device Management. Leave off if you only use the classic remote-support tools.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nanoSection: some View {
        Section("NanoMDM (MDM core)") {
            TextField("Admin URL", text: $settings.nanoMDMBaseURL,
                      prompt: Text(verbatim: "http://192.0.2.10:9090"))
                .help("NanoMDM admin API base over the tailnet. Not the public /mdm enrollment URL.")
                .onChange(of: settings.nanoMDMBaseURL) { _, _ in testResult = nil }
            SecureField("API Key", text: $nanoKeyBuffer)
                .onChange(of: nanoKeyBuffer) { _, newValue in
                    settings.setNanoMDMAPIKey(newValue)
                    testResult = nil
                }
                .help("The -api key NanoMDM was started with (HTTP Basic password, user 'nanomdm').")
        }
    }

    private var kmfddmSection: some View {
        Section("KMFDDM (declarative management)") {
            TextField("Admin URL", text: $settings.kmfddmBaseURL,
                      prompt: Text(verbatim: "http://192.0.2.10:9093"))
                .help("KMFDDM admin API base over the tailnet.")
                .onChange(of: settings.kmfddmBaseURL) { _, _ in testResult = nil }
            SecureField("API Key", text: $kmfddmKeyBuffer)
                .onChange(of: kmfddmKeyBuffer) { _, newValue in
                    settings.setKMFDDMAPIKey(newValue)
                    testResult = nil
                }
                .help("The -api key KMFDDM was started with (HTTP Basic password, user 'kmfddm').")
        }
    }

    private var testSection: some View {
        Section {
            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!settings.mdmConfigured || testing)
                Spacer()
            }
            if let result = testResult {
                switch result {
                case .success(let nano, let kmfddm, let decls):
                    Label("Connected — NanoMDM \(nano), KMFDDM \(kmfddm), \(decls) declaration\(decls == 1 ? "" : "s")",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                case .failure(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Text("""
                Edict reaches these admin APIs over your tailnet. Apple devices enroll against the public endpoint (the reverse proxy in front of NanoMDM), which is configured separately on the server.

                Test Connection checks NanoMDM /version, KMFDDM /version, and lists declarations — a green result means the full path (URL, key, auth, declarative store) is reachable.
                """)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Test

    @MainActor
    private func runTest() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let nano = NanoMDMService(settings: settings)
        let kmfddm = KMFDDMService(settings: settings)
        do {
            let nanoVer = try await nano.version()
            let kmfddmVer = try await kmfddm.version()
            let decls = try await kmfddm.listDeclarations()
            testResult = .success(nano: nanoVer, kmfddm: kmfddmVer, declarations: decls.count)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
