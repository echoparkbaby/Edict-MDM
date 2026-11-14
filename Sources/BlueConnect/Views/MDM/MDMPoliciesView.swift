import SwiftUI

struct MDMPoliciesView: View {
    @Binding var selection: Set<Int>
    var initialTab = "Configuration profiles"
    @State private var tab = "Configuration profiles"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Policies").font(.title2.bold())
                Text("Build configurations, assign targets, and verify what devices received.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Policy workspace", selection: $tab) {
                    Text("Profiles").tag("Configuration profiles")
                    Text("Declarations").tag("Declarations")
                    Text("Bundles").tag("Bundles")
                    Text("Assignments").tag("Assignments")
                    Text("Verification").tag("Verification")
                    Text("Advanced").tag("Advanced")
                }.pickerStyle(.segmented)
            }.padding(18)
            Divider()
            switch tab {
            case "Declarations": DeclarationLibraryPane()
            case "Bundles": SetsGridPane()
            case "Assignments": GroupDashboardView(selection: $selection, destination: .profiles)
            case "Verification": GroupDashboardView(selection: $selection, destination: .drift)
            case "Advanced": DeclarationsView(serverOnly: true)
            default: ProfilesView()
            }
        }
        .onAppear { tab = initialTab }
        .onChange(of: initialTab) { _, value in tab = value }
    }
}
