import SwiftUI

/// Form for the software-update settings declaration — automatic-update
/// behavior, deferral windows, and notifications, no JSON. Only the keys
/// Apple marks macOS-available are offered. Builds the configuration + its
/// paired activation into a set. Requires macOS 15 or newer.
struct SoftwareUpdateSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (_ config: Data, _ configID: String, _ set: String) -> Void

    /// Mirrors the schema's `Allowed` / `AlwaysOn` / `AlwaysOff`.
    enum AutoAction: String, CaseIterable, Identifiable {
        case allowed = "Allowed"
        case alwaysOn = "AlwaysOn"
        case alwaysOff = "AlwaysOff"
        var id: String { rawValue }
        var label: String { DDMDeclarationSummary.actionLabel(rawValue) }
    }

    @State private var download: AutoAction = .allowed
    @State private var installOS: AutoAction = .allowed
    @State private var installSecurity: AutoAction = .alwaysOn   // sensible default: security updates on
    @State private var deferMajor = 0
    @State private var deferMinor = 0
    @State private var deferSystem = 0
    @State private var notifications = true
    @State private var setName = "default"

    private let configID = "com.hellocomputer.edict.softwareupdate-settings"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Software Update Settings").font(.headline)
            Text("Set how Macs download and install updates, and how long they can be deferred. Requires macOS 15 or newer. This is the recommended everyday default — let macOS schedule installs (Always on). A 90-day deferral isn't a target: aim lower and re-assess regularly, and pair this with “Enforce a macOS update” only to hit a hard deadline.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("Automatic updates") {
                    Picker("Download updates", selection: $download) { actionOptions }
                    Picker("Install macOS updates", selection: $installOS) { actionOptions }
                    Picker("Install security updates", selection: $installSecurity) { actionOptions }
                }
                Section("Defer updates") {
                    deferStepper("Major macOS updates", value: $deferMajor)
                    deferStepper("Minor macOS updates", value: $deferMinor)
                    deferStepper("Other updates", value: $deferSystem)
                }
                Section {
                    Toggle("Show update notifications", isOn: $notifications)
                    TextField("Set", text: $setName)
                        .help("Which KMFDDM set receives this. Every Mac associated with the set gets these settings.")
                }
            }
            .formStyle(.grouped)
            .frame(height: 360)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private var actionOptions: some View {
        ForEach(AutoAction.allCases) { Text($0.label).tag($0) }
    }

    private func deferStepper(_ label: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...90) {
            Text(value.wrappedValue == 0
                 ? "\(label): no delay"
                 : "\(label): \(value.wrappedValue) day\(value.wrappedValue == 1 ? "" : "s")")
        }
        .help("0 means no deferral. Apple caps deferrals at 90 days.")
    }

    private func commit() {
        let config = DDMDeclarations.softwareUpdateSettings(
            identifier: configID,
            download: download.rawValue,
            installOS: installOS.rawValue,
            installSecurity: installSecurity.rawValue,
            deferMajorDays: deferMajor,
            deferMinorDays: deferMinor,
            deferSystemDays: deferSystem,
            notifications: notifications)
        onAdd(config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
