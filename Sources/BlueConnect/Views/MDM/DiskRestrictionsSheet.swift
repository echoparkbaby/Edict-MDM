import SwiftUI

/// Form for the disk-management declaration — restrict USB/network storage to
/// read-write, read-only, or blocked, without touching JSON. Builds the
/// configuration + its paired activation into a set. Requires macOS 15+ on a
/// supervised Mac; older or unsupervised Macs simply ignore it.
struct DiskRestrictionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (_ config: Data, _ configID: String, _ set: String) -> Void

    /// Mirrors the schema's `Allowed` / `ReadOnly` / `Disallowed`.
    enum Access: String, CaseIterable, Identifiable {
        case allowed = "Allowed"
        case readOnly = "ReadOnly"
        case disallowed = "Disallowed"
        var id: String { rawValue }
        var label: String { DDMDeclarationSummary.storageLabel(rawValue) }
    }

    @State private var external: Access = .allowed
    @State private var network: Access = .allowed
    @State private var setName = "default"

    private let configID = "com.hellocomputer.edict.disk-restrictions"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restrict External & Network Drives").font(.headline)
            Text("Control whether Macs can use USB/SD/Thunderbolt drives and network shares. Read-only refuses to mount read-write volumes rather than converting them. Requires macOS 15 or newer on a supervised Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("External drives (USB, SD)", selection: $external) {
                    ForEach(Access.allCases) { Text($0.label).tag($0) }
                }
                Picker("Network shares", selection: $network) {
                    ForEach(Access.allCases) { Text($0.label).tag($0) }
                }
                TextField("Set", text: $setName)
                    .help("Which KMFDDM set receives this. Every Mac associated with the set is restricted.")
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func commit() {
        let config = DDMDeclarations.diskManagement(
            identifier: configID,
            externalStorage: external.rawValue,
            networkStorage: network.rawValue)
        onAdd(config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
