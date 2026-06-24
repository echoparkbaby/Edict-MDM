import SwiftUI

/// One device fact the operator can ask Macs to report, with a plain-English
/// label over its reverse-DNS status-item name.
struct StatusFact: Identifiable {
    var id: String { name }
    let label: String
    let name: String
    var on: Bool
}

/// Form for the status-subscriptions declaration — check the facts each Mac
/// should keep reporting (OS version, FileVault, …) instead of typing
/// reverse-DNS item names or JSON. Builds the configuration + its paired
/// activation and adds both to a set. The dashboard reads these back.
struct StatusReportingSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Receives the built configuration, its identifier, and the chosen set;
    /// the library pane adds it (plus the paired activation) to the library.
    let onAdd: (_ config: Data, _ configID: String, _ set: String) -> Void

    /// The curated catalog — real macOS DDM status items. The common ones
    /// the device-detail pane needs are on by default.
    static let catalog: [StatusFact] = [
        StatusFact(label: "macOS version",   name: "device.operating-system.version",          on: true),
        StatusFact(label: "FileVault on/off", name: "diskmanagement.filevault.enabled",         on: true),
        StatusFact(label: "Serial number",   name: "device.identifier.serial-number",          on: true),
        StatusFact(label: "Model name",      name: "device.model.marketing-name",              on: true),
        StatusFact(label: "macOS build",     name: "device.operating-system.build-version",    on: false),
        StatusFact(label: "macOS name",      name: "device.operating-system.marketing-name",   on: false),
        StatusFact(label: "Model identifier", name: "device.model.identifier",                  on: false),
        StatusFact(label: "Model family",    name: "device.model.family",                      on: false),
        StatusFact(label: "Model number",    name: "device.model.number",                      on: false),
        StatusFact(label: "Hardware UDID",   name: "device.identifier.udid",                   on: false),
        StatusFact(label: "Battery health",  name: "device.power.battery-health",              on: false),
        StatusFact(label: "macOS RSR build", name: "device.operating-system.supplemental.build-version", on: false),
        StatusFact(label: "Has a passcode",  name: "passcode.is-present",                      on: false),
        StatusFact(label: "Passcode compliant", name: "passcode.is-compliant",                 on: false),
        StatusFact(label: "Pending OS version", name: "softwareupdate.pending-version",        on: false),
        StatusFact(label: "Update state",    name: "softwareupdate.install-state",             on: false),
    ]

    @State private var facts = StatusReportingSheet.catalog
    @State private var setName = "default"

    private let configID = "com.hellocomputer.edict.status-subscriptions"
    private var selectedCount: Int { facts.filter(\.on).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Status Reporting").font(.headline)
            Text("Pick the facts each Mac should keep reporting back. The device updates them on its own, and the dashboard reads them — no scans or check-ins to schedule.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("Report these facts") {
                    ForEach($facts) { $fact in
                        Toggle(fact.label, isOn: $fact.on)
                    }
                }
                Section {
                    TextField("Set", text: $setName)
                        .help("Which KMFDDM set receives this. Every Mac associated with the set starts reporting.")
                }
            }
            .formStyle(.grouped)
            .frame(height: 320)

            HStack {
                Text("\(selectedCount) fact\(selectedCount == 1 ? "" : "s") selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0 || setName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func commit() {
        let names = facts.filter(\.on).map(\.name)
        let config = DDMDeclarations.statusSubscriptions(identifier: configID, itemNames: names)
        onAdd(config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
