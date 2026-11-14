import SwiftUI

struct MDMEnrollmentWorkspace: View {
    var initialTab = "Manual enrollment"
    @State private var tab = "Manual enrollment"
    @Environment(MDMFleetIndex.self) private var fleet
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Enrollment").font(.title2.bold())
                Spacer()
                Picker("Enrollment method", selection: $tab) {
                    Text("Manual enrollment").tag("Manual enrollment")
                    Text("Automated enrollment").tag("Automated enrollment")
                    Text("Onboarding progress").tag("Onboarding progress")
                }.pickerStyle(.segmented).frame(maxWidth: 580)
            }.padding(18)
            Divider()
            switch tab {
            case "Automated enrollment": DEPView()
            case "Onboarding progress": progress
            default: EnrollmentView()
            }
        }.onAppear { tab = initialTab }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enrollment, reporting, and baseline delivery are separate steps. Queued configurations still require device verification.")
                .font(.callout).foregroundStyle(.secondary).padding(18)
            Table(fleet.devices) {
                TableColumn("Device") { d in Text(fleet.names[d.id] ?? d.serialNumber ?? d.id) }
                TableColumn("Enrollment") { d in Text(d.isEnabled ? "Managed" : "Checked out") }
                TableColumn("Reporting") { d in
                    Text(fleet.errors[d.id] != nil ? "Read failed" : (fleet.snapshots[d.id]?.hasData == true ? "Evidence available" : "Awaiting evidence"))
                }
                TableColumn("Baseline") { d in
                    Text(!settings.hasOnboardingBaseline ? "Not configured" :
                            (settings.isOnboarded(d.id) ? "Queued; verify in Policies" : "Not queued"))
                }
                TableColumn("Last check-in") { d in
                    if let at = d.lastSeenDate { Text(at, style: .relative) } else { Text("Unknown") }
                }
            }
        }
    }
}
