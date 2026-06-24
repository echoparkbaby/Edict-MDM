import SwiftUI

/// Form for the macOS Screen Sharing host-settings declaration — control file
/// copy in/out, the virtual-display count, and high-performance connections,
/// no JSON. Builds the configuration + its paired activation into a set.
/// Requires macOS 14+ on a supervised/local-enrolled Mac.
struct ScreenSharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (_ config: Data, _ configID: String, _ set: String) -> Void

    /// -1 = leave at the Mac's default (omit the key); 0–2 = set it.
    @State private var maxDisplays = -1
    @State private var blockCopyFromHost = false
    @State private var blockCopyToHost = false
    @State private var blockHighPerformance = false
    @State private var setPortBase = false
    @State private var portBase = 5901
    @State private var setName = "default"

    private let configID = "com.hellocomputer.edict.screensharing"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screen Sharing").font(.headline)
            Text("Control macOS Screen Sharing on each Mac — whether files can be copied to/from the host, how many virtual displays a client can open, and performance. Requires macOS 14 or newer.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("File transfer") {
                    Toggle("Block copying files from this Mac", isOn: $blockCopyFromHost)
                    Toggle("Block copying files to this Mac", isOn: $blockCopyToHost)
                }
                Section("Displays & performance") {
                    Picker("Max virtual displays", selection: $maxDisplays) {
                        Text("Mac default").tag(-1)
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                    }
                    Toggle("Block high-performance connections", isOn: $blockHighPerformance)
                }
                Section("Advanced") {
                    Toggle("Set a custom UDP port base", isOn: $setPortBase)
                    if setPortBase {
                        Stepper("Port base: \(portBase)", value: $portBase, in: 1024...65535)
                            .help("Initial UDP port; TCP 5900 is still used to establish the connection.")
                    }
                }
                Section {
                    TextField("Set", text: $setName)
                        .help("Which KMFDDM set receives this. Every Mac associated with the set enforces it.")
                }
            }
            .formStyle(.grouped)
            .frame(height: 340)

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
        let config = DDMDeclarations.screenSharing(
            identifier: configID,
            maxVirtualDisplays: maxDisplays >= 0 ? maxDisplays : nil,
            portBase: setPortBase ? portBase : 0,
            preventCopyFromHost: blockCopyFromHost,
            preventCopyToHost: blockCopyToHost,
            preventHighPerformance: blockHighPerformance)
        onAdd(config, configID, setName.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
