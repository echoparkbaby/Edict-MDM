import SwiftUI

/// "What a Mac in this set receives" — opened from the Sets grid by clicking a
/// set name. Lists each configuration in the set in plain English (reusing the
/// declaration summaries) and flags any configuration whose activation isn't in
/// the set, since that configuration won't take effect on the device.
struct SetContentsPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DDMLibraryStore.self) private var library
    let set: String

    private var contents: DDMSetContents {
        DDMSetContents.make(set: set, items: library.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A Mac in “\(set)” receives").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if contents.configs.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !contents.unactivated.isEmpty {
                            warning
                        }
                        ForEach(contents.configs) { entry in
                            configCard(entry)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 480, height: 480)
    }

    private var subtitle: String {
        let n = contents.configs.count
        return "\(n) configuration\(n == 1 ? "" : "s")"
            + (contents.otherCount > 0 ? " · \(contents.otherCount) other" : "")
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("Nothing in this set yet").font(.callout).foregroundStyle(.secondary)
            Text("Check declarations into “\(set)” in the grid, then they'll appear here.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warning: some View {
        Label("\(contents.unactivated.count) configuration\(contents.unactivated.count == 1 ? "" : "s") won't take effect — no activation in this set references them.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func configCard(_ entry: DDMSetContents.ConfigEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.summary.title).font(.callout.weight(.semibold))
                if !entry.isActivated {
                    Label("not active", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2).foregroundStyle(.orange)
                        .help("No activation in this set references it, so it won't take effect on the device.")
                }
                Spacer(minLength: 0)
            }
            Text(entry.summary.blurb).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.summary.rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.summary.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.label).font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text(row.value).font(.caption2).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5) }
    }
}
