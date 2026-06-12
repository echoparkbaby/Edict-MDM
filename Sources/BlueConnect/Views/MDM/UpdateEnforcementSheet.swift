import SwiftUI

/// Form for the declarative software-update enforcement — "this macOS
/// version must be installed by this deadline." Generates the
/// configuration + paired activation and deploys both into a set; every
/// Mac associated with the set starts nagging, downloading, and
/// ultimately force-installing on its own (macOS 14+). No JSON shown.
struct UpdateEnforcementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @Environment(ActivityLog.self) private var activity
    /// Called after a successful deploy so the declarations list refreshes.
    let onDeployed: () -> Void

    @State private var targetVersion = ""
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var detailsURL = ""
    @State private var setName = "default"
    @State private var working = false
    @State private var error: String?

    private var trimmedVersion: String {
        targetVersion.trimmingCharacters(in: .whitespaces)
    }
    private var versionLooksValid: Bool {
        // 15, 15.5, 15.5.1 — digits and dots only.
        trimmedVersion.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil
    }
    private var identifier: String {
        "com.hellocomputer.edict.update-\(trimmedVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enforce a macOS Update").font(.headline)
            Text("Every Mac in the set is told to install the target version by the deadline. macOS handles the nagging, download, and forced install itself — including for users who never click anything. Requires macOS 14 or newer on the device.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Target macOS version", text: $targetVersion,
                          prompt: Text(verbatim: "15.5"))
                    .help("The OS version devices must reach, e.g. 15.5 or 15.5.1")
                DatePicker("Install deadline", selection: $deadline, in: Date()...)
                    .help("Local time on each device. After the deadline the install is forced.")
                TextField("Details URL (optional)", text: $detailsURL,
                          prompt: Text(verbatim: "https://wiki.example.com/why-update"))
                    .help("Shown to the user in the update notification — a 'why' link")
                TextField("Set", text: $setName)
                    .help("Which KMFDDM set receives the enforcement. Every device associated with the set gets it.")
            }
            .formStyle(.columns)

            if versionLooksValid {
                Text("Creates “\(identifier)” (+ activation) in set “\(setName)”. Re-running with the same version updates it in place.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await deploy() }
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Enforce")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!versionLooksValid
                          || setName.trimmingCharacters(in: .whitespaces).isEmpty
                          || working)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @MainActor
    private func deploy() async {
        working = true
        error = nil
        defer { working = false }
        let config = DDMDeclarations.updateEnforcement(
            identifier: identifier,
            targetVersion: trimmedVersion,
            deadline: deadline,
            detailsURL: detailsURL.trimmingCharacters(in: .whitespaces)
        )
        do {
            try await KMFDDMService(settings: settings).deploy(
                configJSON: config,
                configID: identifier,
                toSet: setName.trimmingCharacters(in: .whitespaces)
            )
            activity.record(.category, title: "Enforced macOS \(trimmedVersion)",
                            detail: "by \(deadline.formatted(date: .abbreviated, time: .shortened)), set “\(setName)”")
            onDeployed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
