import SwiftUI

/// What the Add-a-Declaration gallery returns. The guided templates open a
/// simple form; the Advanced options are the JSON/file escape hatches.
enum AddChoice {
    case enforceUpdate
    case softwareUpdateSettings
    case statusReporting
    case passcodePolicy
    case diskRestrictions
    case pasteJSON
    case importFiles
    case pullFromServer
}

/// The single "Add" entry point for the library — a gallery of plain-English
/// templates so an operator picks "Enforce a macOS update" instead of having
/// to know `com.apple.configuration.softwareupdate.enforcement.specific` and
/// hand-type JSON. Each card describes what the declaration *does*; picking
/// one hands the choice back to the library pane, which opens its form.
struct AddDeclarationGallery: View {
    @Environment(\.dismiss) private var dismiss
    let onChoose: (AddChoice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a Declaration").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Software updates") {
                        card(.enforceUpdate,
                             title: "Enforce a macOS update",
                             icon: "arrow.down.circle.dotted",
                             blurb: "Require a macOS version by a deadline. Each Mac nags, downloads, and installs on its own — no user action needed.")
                        card(.softwareUpdateSettings,
                             title: "Software update settings",
                             icon: "gearshape.arrow.triangle.2.circlepath",
                             blurb: "Control automatic downloads/installs, defer updates by N days, and notifications. macOS 15+.")
                    }
                    group("Reporting") {
                        card(.statusReporting,
                             title: "Status reporting",
                             icon: "checklist",
                             blurb: "Have each Mac keep reporting facts — OS version, model, serial, FileVault state — so the dashboard stays current.")
                    }
                    group("Security & storage") {
                        card(.passcodePolicy,
                             title: "Passcode policy",
                             icon: "lock.shield",
                             blurb: "Set login-password rules — minimum length, complexity, auto-lock, expiry, and lockout. macOS 13+.")
                        card(.diskRestrictions,
                             title: "Restrict external & network drives",
                             icon: "externaldrive.badge.xmark",
                             blurb: "Make USB/SD drives and network shares read-only or block them entirely. macOS 15+, supervised.")
                    }
                    group("Advanced") {
                        card(.pasteJSON,
                             title: "Paste JSON…",
                             icon: "curlybraces",
                             blurb: "Author any declaration by hand. For types without a template yet.")
                        card(.importFiles,
                             title: "Import .json file(s)…",
                             icon: "square.and.arrow.down",
                             blurb: "Add declarations from files, e.g. from macadmins/ddm_examples.")
                        card(.pullFromServer,
                             title: "Pull from KMFDDM…",
                             icon: "arrow.down.to.line",
                             blurb: "Import declarations already on the server to edit or adopt them.")
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 540, height: 520)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func card(_ choice: AddChoice, title: String, icon: String, blurb: String) -> some View {
        Button {
            onChoose(choice)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2).foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(blurb).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
