import SwiftUI

struct MDMDeviceDetailView: View {
    let host: BlueSkyHost
    let enrollmentID: String
    @Environment(MDMFleetIndex.self) private var fleet
    @Environment(MDMCommandStore.self) private var commands
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.displayName).font(.title2.bold())
                    Text(host.serialnum ?? enrollmentID).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = fleet.errors[enrollmentID] {
                        Label("Status read failed: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let snapshot = fleet.snapshots[enrollmentID] {
                        Text("DDM last read \(snapshot.checkedAt.formatted(.relative(presentation: .named))). Device observation time is shown when reported.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let entry = fleet.entry(for: host) {
                        MDMHostDetail(host: host, entry: entry, compact: false)
                    }
                    Divider()
                    Text("Command history").font(.headline)
                    let entries = commands.entries.filter { $0.target == enrollmentID && $0.server == settings.nanoMDMBaseURL }
                    if entries.isEmpty { Text("No commands recorded by this console.").foregroundStyle(.secondary) }
                    ForEach(Array(entries.prefix(20))) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.kind)
                                if let detail = entry.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(entry.state.rawValue).foregroundStyle(.secondary)
                            Text(entry.createdAt, style: .relative).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }.padding(20)
            }
        }.frame(minWidth: 720, idealWidth: 860, minHeight: 620, idealHeight: 780)
    }
}
