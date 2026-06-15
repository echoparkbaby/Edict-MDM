import SwiftUI

struct UserCell: View {
    let host: BlueSkyHost
    let defaultUser: String
    /// Fires when the operator clicks the hover pencil. Parent opens
    /// the Set Username sheet pre-filled with this host's value.
    var onEditRequested: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        // MDM-only rows have no BlueSky user — show a dash rather than the
        // SSH default. Otherwise show the host's BlueSky user.
        let eff = host.isMDMOnly ? "—" : host.effectiveUser(default: defaultUser)
        HStack(spacing: 4) {
            Text(eff).foregroundStyle(host.isMDMOnly ? .secondary : .primary)
            if !host.isMDMOnly, (host.username ?? "").isEmpty {
                Text("(default)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Pencil reveals on row hover so it doesn't clutter the
            // table at rest. Click routes to the same sheet as the
            // right-click "Set Username…" menu item.
            if hovering, onEditRequested != nil {
                Button(action: { onEditRequested?() }) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Set username for this host")
                .accessibilityLabel("Set username for this host")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
